// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using System.Net;
using System.Text.Json;
using k8s.Autorest;
using k8s.Models;
using Microsoft.Extensions.Logging;
using Microsoft.McpGateway.Management.Contracts;
using Microsoft.McpGateway.Management.Extensions;

namespace Microsoft.McpGateway.Management.Deployment
{
    public class KubernetesAdapterDeploymentManager : IAdapterDeploymentManager
    {
        private const string AdapterNamespace = "adapter";
        private readonly IKubeClientWrapper _kubeClient;
        private readonly string _containerRegistryAddress;
        private readonly ILogger<KubernetesAdapterDeploymentManager> _logger;

        public KubernetesAdapterDeploymentManager(string containerRegistryAddress, IKubeClientWrapper kubeClient, ILogger<KubernetesAdapterDeploymentManager> logger)
        {
            ArgumentException.ThrowIfNullOrEmpty(containerRegistryAddress);
            _containerRegistryAddress = containerRegistryAddress;
            _kubeClient = kubeClient ?? throw new ArgumentNullException(nameof(kubeClient));
            _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        }

        public async Task CreateDeploymentAsync(AdapterData request, ResourceType resourceType, CancellationToken cancellationToken)
        {
            var labels = new Dictionary<string, string>
            {
                { $"{AdapterNamespace}/type", resourceType.ToString().ToLowerInvariant() },
                { $"{AdapterNamespace}/name", request.Name },
                { "azure.workload.identity/use", request.UseWorkloadIdentity.ToString().ToLowerInvariant() }
            };

            // Create Secret if provided
            if (!string.IsNullOrEmpty(request.SecretName) && request.SecretData != null && request.SecretData.Any())
            {
                var secret = new V1Secret
                {
                    Metadata = new V1ObjectMeta
                    {
                        Name = request.SecretName,
                        NamespaceProperty = AdapterNamespace,
                        Labels = new Dictionary<string, string> { { "app", request.Name } }
                    },
                    Type = "Opaque",
                    StringData = request.SecretData
                };

                _logger.LogInformation("Creating/updating secret {secretName} for adapter {adapterName}.", request.SecretName, request.Name);
                await _kubeClient.UpsertSecretAsync(secret, AdapterNamespace, cancellationToken);
            }

            // StatefulSet
            var statefulSet = new V1StatefulSet
            {
                Metadata = new V1ObjectMeta { Name = request.Name },
                Spec = new V1StatefulSetSpec
                {
                    ServiceName = $"{request.Name}-service",
                    Replicas = request.ReplicaCount,
                    Selector = new V1LabelSelector { MatchLabels = labels },
                    Template = new V1PodTemplateSpec
                    {
                        Metadata = new V1ObjectMeta { Labels = labels },
                        Spec = new V1PodSpec
                        {
                            ServiceAccountName = "workload-sa",
                            SecurityContext = new V1PodSecurityContext
                            {
                                RunAsUser = 1100,
                                RunAsGroup = 1100
                            },
                            Containers = new List<V1Container>
                            {
                                new V1Container
                                {
                                    Name = $"{request.Name}-container",
                                    Image = $"{_containerRegistryAddress}/{request.ImageName}:{request.ImageVersion}",
                                    ImagePullPolicy = "Always",
                                    Env = request.EnvironmentVariables?.Select(x => new V1EnvVar { Name = x.Key, Value = x.Value }).ToList(),
                                    EnvFrom = new List<V1EnvFromSource>
                                    {
                                        request.ConfigMapName != null ? new V1EnvFromSource
                                        {
                                            ConfigMapRef = new V1ConfigMapEnvSource { Name = request.ConfigMapName }
                                        } : null,
                                        request.SecretName != null ? new V1EnvFromSource
                                        {
                                            SecretRef = new V1SecretEnvSource { Name = request.SecretName }
                                        } : null
                                    }.Where(x => x != null).ToList(),
                                    Ports = new List<V1ContainerPort>
                                    {
                                        new V1ContainerPort { ContainerPort = 8000, Protocol = "TCP" }
                                    },
                                    SecurityContext = new V1SecurityContext
                                    {
                                        AllowPrivilegeEscalation = false,
                                        Capabilities = new V1Capabilities { Drop = new List<string> { "ALL" } }
                                    },
                                    Resources = new V1ResourceRequirements
                                    {
                                        Limits = new Dictionary<string, ResourceQuantity>
                                        {
                                            ["cpu"] = new ResourceQuantity("1"),
                                            ["memory"] = new ResourceQuantity("512Mi"),
                                            ["ephemeral-storage"] = new ResourceQuantity("2Gi")
                                        },
                                        Requests = new Dictionary<string, ResourceQuantity>
                                        {
                                            ["cpu"] = new ResourceQuantity("250m"),
                                            ["memory"] = new ResourceQuantity("256Mi")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            };

            // Service
            var service = new V1Service
            {
                Metadata = new V1ObjectMeta { Name = $"{request.Name}-service" },
                Spec = new V1ServiceSpec
                {
                    ClusterIP = resourceType == ResourceType.Tool ? null : "None",
                    Selector = labels,
                    Ports = new List<V1ServicePort>
                    {
                        new V1ServicePort { Port = 8000, TargetPort = 8000, Protocol = "TCP" }
                    }
                }
            };

            _logger.LogInformation("Creating deployment for {name} with resource type {resourceType}.", request.Name.Sanitize(), resourceType.ToString().ToLowerInvariant());

            try
            {
                await _kubeClient.UpsertStatefulSetAsync(statefulSet, AdapterNamespace, cancellationToken);
                _logger.LogInformation("Submitted Kubernetes deployment for {name}.", request.Name.Sanitize());
            }
            catch (HttpOperationException ex) when (ex.Response.StatusCode == HttpStatusCode.Conflict)
            {
                _logger.LogInformation("Kubernetes deployment for {name} already exists. Skipping.", request.Name.Sanitize());
            }

            try
            {
                await _kubeClient.UpsertServiceAsync(service, AdapterNamespace, cancellationToken);
                _logger.LogInformation("Submitted Kubernetes service for {name}.", request.Name.Sanitize());
            }
            catch (HttpOperationException ex) when (ex.Response.StatusCode == HttpStatusCode.Conflict)
            {
                _logger.LogInformation("Kubernetes service for {name} already exists. Skipping.", request.Name.Sanitize());
            }
        }

        public async Task UpdateDeploymentAsync(AdapterData request, ResourceType resourceType, CancellationToken cancellationToken)
        {
            var statefulSet = await _kubeClient.ReadStatefulSetAsync(request.Name, AdapterNamespace, cancellationToken);

            var patch = new
            {
                spec = new
                {
                    replicas = request.ReplicaCount,
                    template = new
                    {
                        metadata = new
                        {
                            labels = new Dictionary<string, string>
                            {
                                { $"{AdapterNamespace}/type", resourceType.ToString().ToLowerInvariant() },
                                { $"{AdapterNamespace}/name", request.Name },
                                { "azure.workload.identity/use", request.UseWorkloadIdentity.ToString().ToLowerInvariant() }
                            }
                        },
                        spec = new
                        {
                            containers = new[]
                            {
                                new
                                {
                                    name = $"{request.Name}-container",
                                    image = $"{_containerRegistryAddress}/{request.ImageName}:{request.ImageVersion}",
                                    env = request.EnvironmentVariables?.Select(x => new V1EnvVar{ Name = x.Key, Value = x.Value }).ToArray(),
                                    envFrom = new List<V1EnvFromSource>
                                    {
                                        request.ConfigMapName != null ? new V1EnvFromSource { ConfigMapRef = new V1ConfigMapEnvSource { Name = request.ConfigMapName } } : null,
                                        request.SecretName != null ? new V1EnvFromSource { SecretRef = new V1SecretEnvSource { Name = request.SecretName } } : null
                                    }.Where(x => x != null).ToArray()
                                }
                            }
                        }
                    }
                }
            };

            var patchContent = new V1Patch(JsonSerializer.Serialize(patch), V1Patch.PatchType.StrategicMergePatch);
            await _kubeClient.PatchStatefulSetAsync(patchContent, request.Name, AdapterNamespace, cancellationToken);
        }

        public async Task DeleteDeploymentAsync(string name, CancellationToken cancellationToken)
        {
            try
            {
                await _kubeClient.DeleteStatefulSetAsync(name, AdapterNamespace, cancellationToken);
                await _kubeClient.DeleteServiceAsync($"{name}-service", AdapterNamespace, cancellationToken);
            }
            catch (HttpOperationException ex) when (ex.Response.StatusCode == HttpStatusCode.NotFound)
            {
                _logger.LogWarning("Deployment {name} does not exist.", name.Sanitize());
            }
        }

        public async Task<AdapterStatus> GetDeploymentStatusAsync(string name, CancellationToken cancellationToken)
        {
            var statefulSet = await _kubeClient.ReadStatefulSetAsync(name, AdapterNamespace, cancellationToken);
            var status = new AdapterStatus
            {
                ReadyReplicas = statefulSet.Status.ReadyReplicas,
                UpdatedReplicas = statefulSet.Status.UpdatedReplicas,
                AvailableReplicas = statefulSet.Status.AvailableReplicas,
                Image = statefulSet.Spec.Template.Spec.Containers.FirstOrDefault()?.Image ?? "Unknown"
            };
            status.ReplicaStatus = (status.ReadyReplicas ?? 0) == (statefulSet.Spec.Replicas ?? 0)
                ? "Healthy"
                : $"Degraded: {status.ReadyReplicas ?? 0}/{statefulSet.Spec.Replicas ?? 0} ready";
            return status;
        }

        public async Task<string> GetDeploymentLogsAsync(string name, int ordinal = 0, CancellationToken cancellationToken = default)
        {
            var podName = $"{name}-{ordinal}";
            using var logStream = await _kubeClient.GetContainerLogStream(podName, 1000, AdapterNamespace, cancellationToken);
            using var reader = new StreamReader(logStream);
            return await reader.ReadToEndAsync(cancellationToken);
        }
    }
}
