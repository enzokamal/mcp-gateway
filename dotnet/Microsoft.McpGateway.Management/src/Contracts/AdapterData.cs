using System.ComponentModel.DataAnnotations;
using System.Linq;
using System.Text.Json.Serialization;

namespace Microsoft.McpGateway.Management.Contracts
{
    public class AdapterData
    {
        [JsonPropertyOrder(1)]
        [RegularExpression("^[a-z0-9-]+$", ErrorMessage = "Name must contain only lowercase letters, numbers and dashes.")]
        public required string Name { get; set; }

        [JsonPropertyOrder(2)]
        public required string ImageName { get; set; }

        [JsonPropertyOrder(3)]
        public required string ImageVersion { get; set; }

        [JsonPropertyOrder(4)]
        public Dictionary<string, string> EnvironmentVariables { get; set; } = [];

        [JsonPropertyOrder(5)]
        public int ReplicaCount { get; set; } = 1;

        [JsonPropertyOrder(6)]
        public string Description { get; set; } = string.Empty;

        [JsonPropertyOrder(7)]
        public bool UseWorkloadIdentity { get; set; } = false;

        [JsonPropertyOrder(8)]
        public IList<string> RequiredRoles { get; set; } = [];

        [JsonPropertyOrder(9)]
        public string? SecretName { get; set; }

        [JsonPropertyOrder(10)]
        public Dictionary<string, string>? SecretData { get; set; }

        [JsonPropertyOrder(11)]
        public string? ConfigMapName { get; set; }

        public AdapterData(
            string name,
            string imageName,
            string imageVersion,
            Dictionary<string, string>? environmentVariables = null,
            int? replicaCount = 1,
            string description = "",
            bool useWorkloadIdentity = false,
            IEnumerable<string>? requiredRoles = null,
            string? secretName = null,
            Dictionary<string, string>? secretData = null,
            string? configMapName = null)
        {
            ArgumentException.ThrowIfNullOrEmpty(name);
            ArgumentException.ThrowIfNullOrEmpty(imageName);
            ArgumentException.ThrowIfNullOrEmpty(imageVersion);

            Name = name;
            ImageName = imageName;
            ImageVersion = imageVersion;
            EnvironmentVariables = environmentVariables ?? [];
            ReplicaCount = replicaCount ?? 1;
            Description = description;
            UseWorkloadIdentity = useWorkloadIdentity;
            RequiredRoles = requiredRoles?.Where(static role => !string.IsNullOrWhiteSpace(role))
                                          .Select(static role => role.Trim())
                                          .Distinct(StringComparer.OrdinalIgnoreCase)
                                          .ToList() ?? [];
            SecretName = secretName;
            SecretData = secretData;
            ConfigMapName = configMapName;
        }

        public AdapterData() { }
    }
}
