# Stage 1: Build
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build

WORKDIR /app

# Copy solution and all project files first (layer caching)
COPY . .

# Restore
RUN dotnet restore ./src/Microsoft.McpGateway.Service.csproj

# Publish
RUN dotnet publish ./src/Microsoft.McpGateway.Service.csproj -c Release -o /app/publish

# Stage 2: Runtime
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime

WORKDIR /app

COPY --from=build /app/publish .

EXPOSE 5000

ENTRYPOINT ["dotnet", "Microsoft.McpGateway.Service.dll"]
