using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Identity.Web;
using Microsoft.McpGateway.Management.Authorization;
using Microsoft.McpGateway.Management.Deployment;
using Microsoft.McpGateway.Management.Service;
using Microsoft.McpGateway.Management.Store;
using Microsoft.McpGateway.Service.Authentication;
using Microsoft.McpGateway.Service.Routing;
using System.Text.Json;
using System.Text.Json.Serialization;

var builder = WebApplication.CreateBuilder(args);

// ------------------------
// Logging
// ------------------------
builder.Services.AddLogging();

// ------------------------
// Kubernetes Services
// ------------------------
builder.Services.AddSingleton<IKubernetesClientFactory, LocalKubernetesClientFactory>();

// ------------------------
// Authentication & Redis
// ------------------------
if (builder.Environment.IsDevelopment())
{
    // Development authentication
    builder.Services
        .AddAuthentication(DevelopmentAuthenticationHandler.SchemeName)
        .AddScheme<Microsoft.AspNetCore.Authentication.AuthenticationSchemeOptions, DevelopmentAuthenticationHandler>(
            DevelopmentAuthenticationHandler.SchemeName, null);

    // Redis cache for development
    var redisConnection = builder.Configuration.GetValue<string>("Redis:ConnectionString") ?? "localhost:6379";
    
    try
    {
        builder.Services.AddStackExchangeRedisCache(options =>
        {
            options.Configuration = redisConnection;
            options.InstanceName = "mcpgateway:";
            options.ConfigurationOptions = StackExchange.Redis.ConfigurationOptions.Parse(redisConnection);
            options.ConfigurationOptions.ConnectTimeout = 10000;
            options.ConfigurationOptions.SyncTimeout = 10000;
            options.ConfigurationOptions.AbortOnConnectFail = false;
        });

        builder.Services.AddSingleton<IAdapterResourceStore, RedisAdapterResourceStore>();
        builder.Services.AddSingleton<IToolResourceStore, RedisToolResourceStore>();
    }
    catch (Exception ex)
    {
        builder.Logging.AddConsole().AddDebug();
        var logger = LoggerFactory.Create(config => config.AddConsole()).CreateLogger("Startup");
        logger.LogWarning(ex, "Failed to connect to Redis. Using in-memory cache instead.");
        
        // Fallback to in-memory cache
        builder.Services.AddDistributedMemoryCache();
        builder.Services.AddSingleton<IAdapterResourceStore, InMemoryAdapterResourceStore>();
        builder.Services.AddSingleton<IToolResourceStore, InMemoryToolResourceStore>();
    }

    builder.Logging.AddConsole();
    builder.Logging.SetMinimumLevel(LogLevel.Debug);
}
else
{
    // Production: standard Azure AD / OIDC authentication
    var azureAdConfig = builder.Configuration.GetSection("AzureAd");
    builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
        .AddMicrosoftIdentityWebApi(azureAdConfig);

    // Redis cache for production
    var redisConnection = builder.Configuration.GetValue<string>("Redis:ConnectionString") ?? "redis:6379";
    
    builder.Services.AddStackExchangeRedisCache(options =>
    {
        options.Configuration = redisConnection;
        options.InstanceName = "mcpgateway:";
        options.ConfigurationOptions = StackExchange.Redis.ConfigurationOptions.Parse(redisConnection);
        options.ConfigurationOptions.ConnectTimeout = 10000;
        options.ConfigurationOptions.SyncTimeout = 10000;
        options.ConfigurationOptions.AbortOnConnectFail = false;
        options.ConfigurationOptions.ConnectRetry = 3;
    });

    builder.Services.AddSingleton<IAdapterResourceStore, RedisAdapterResourceStore>();
    builder.Services.AddSingleton<IToolResourceStore, RedisToolResourceStore>();
}

// ------------------------
// MCP Gateway Services
// ------------------------
builder.Services.AddSingleton<IKubeClientWrapper>(c =>
{
    var kubeClientFactory = c.GetRequiredService<IKubernetesClientFactory>();
    return new KubeClient(kubeClientFactory, "adapter");
});

builder.Services.AddSingleton<IPermissionProvider, SimplePermissionProvider>();

builder.Services.AddSingleton<IAdapterDeploymentManager>(c =>
{
    var config = builder.Configuration.GetSection("ContainerRegistrySettings");
    return new KubernetesAdapterDeploymentManager(
        config["Endpoint"]!, 
        c.GetRequiredService<IKubeClientWrapper>(), 
        c.GetRequiredService<ILogger<KubernetesAdapterDeploymentManager>>());
});

builder.Services.AddSingleton<IAdapterManagementService, AdapterManagementService>();
builder.Services.AddSingleton<IToolManagementService, ToolManagementService>();
builder.Services.AddSingleton<IAdapterRichResultProvider, AdapterRichResultProvider>();

// ------------------------
// Authorization & Controllers
// ------------------------
builder.Services.AddAuthorization();
builder.Services.AddControllers();
builder.Services.AddHttpClient();

// ------------------------
// Kestrel
// ------------------------
builder.WebHost.ConfigureKestrel(options =>
{
    options.ListenAnyIP(8000);
});

// ------------------------
// Build & Run
// ------------------------
var app = builder.Build();

app.UseAuthentication();
app.UseAuthorization();
app.MapControllers();

await app.RunAsync();