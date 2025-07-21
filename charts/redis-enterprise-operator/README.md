# Redis Enterprise Operator Helm Chart

Official Helm chart for installing, configuring and upgrading **Redis Enterprise Operator for Kubernetes**.

[Redis Enterprise](https://redis.com/redis-enterprise-software/overview/) is a self-managed data platform that unlocks the full potential of Redis at enterprise scale - on premises or in the cloud.  
[Redis Enterprise Operator for Kubernetes](https://redis.com/redis-enterprise-software/redis-enterprise-on-kubernetes/) provides a simple, Kubernetes-native way for deploying and managing Redis Enterprise on Kubernetes.

## Prerequisites

- Kubernetes 1.28+  
  Supported Kubernetes versions can vary according to the Kubernetes distribution being used.  
  Please consult the [release notes](https://redis.io/docs/latest/operate/kubernetes/release-notes/) for detailed supported distributions information per operator version.
- Helm 3.10+ (or 3.18 for migrating from a non-Helm installation)

## Installing the Chart

To install the chart:

```sh
helm install [RELEASE_NAME] [PATH_TO_CHART]
```

The `[PATH_TO_CHART]` may be a path to the chart root directory, or a chart archive on the local filesystem.  

Install using the Redis Helm repository:

```sh
helm repo add redis-enterprise-operator https://helm.redis.io/
helm install my-redis-enterprise-operator redis-enterprise-operator/redis-enterprise-operator --version [VERSION]
```

To install the chart on **OpenShift**, set the `openshift.mode=true` value:

```sh
helm install [RELEASE_NAME] [PATH_TO_CHART] \
     --set openshift.mode=true
```

To create and select a namespace for the installation, specify the `--namespace` and `--create-namespace` flags:

```sh
helm install [RELEASE_NAME] [PATH_TO_CHART] \
     --namespace [NAMESPACE] \
     --create-namespace
```

For example, to install the chart with release name "my-redis-enterprise" from within the chart's root directory:

```sh
helm install my-redis-enterprise . \
     --namespace redis-enterprise \
     --create-namespace
```

Note: the chart installation includes several jobs that configure the CRDs and admission controller used by the operator.  
These jobs run synchronously during the execution of `helm install` command, and may take around 1 minute to complete.  
To view additional progress information during the `helm install` execution, use the `--debug` flag:

```sh
helm install [RELEASE_NAME] [PATH_TO_CHART] \
     --debug
```

See [Configuration](#configuration) section below for various configuration options.  
See [Creating a Redis Enterprise Cluster](#creating-a-redis-enterprise-cluster) section below for instructions for creating a Redis Enterprise Cluster.  
See [helm install](https://helm.sh/docs/helm/helm_install/) and [Using Helm](https://helm.sh/docs/intro/using_helm/#helm-install-installing-a-package) for more information and options when installing charts.

## Upgrading the Chart

To upgrade to a new version of the chart:

```sh
helm upgrade [RELEASE_NAME] [PATH_TO_CHART]
```

For example, to upgrade the chart with release name "my-redis-enterprise" from within the chart's root directory:

```sh
helm upgrade my-redis-enterprise .
```

You can also upgrade using the Redis Helm repository:

```sh
helm upgrade my-redis-enterprise-operator redis-enterprise-operator/redis-enterprise-operator --version [VERSION]
```

To upgrade the chart on **OpenShift**, make sure to include the `openshift.mode=true` parameter:

```sh
helm upgrade [RELEASE_NAME] [PATH_TO_CHART] \
     --set openshift.mode=true
```

The upgrade process will automatically update the operator and its components, including the CRDs. The CRDs are versioned and will only be updated if the new version is higher than the existing one.

After upgrading the operator, you may need to upgrade your Redis Enterprise Clusters depending on the Redis Software version bundled with the operator. For detailed information on the upgrade process, please refer to the [Redis Enterprise for Kubernetes Upgrade documentation](https://redis.io/docs/latest/operate/kubernetes/upgrade/).

See [helm upgrade](https://helm.sh/docs/helm/helm_upgrade/) for more information and options when upgrading charts.

## Uninstalling the Chart

Before uninstalling the chart, delete any custom resources managed by the Redis Enterprise Operator:

```sh
kubectl delete redb <name>
kubectl delete rerc <name>
kubectl delete reaadb <name>
kubectl delete rec <name>
```

To uninstall a previously installed chart:

```sh
helm uninstall [RELEASE_NAME]
```

This removes all the Kubernetes resources associated with the chart and deletes the release.

See [helm uninstall](https://helm.sh/docs/helm/helm_uninstall/) for more information and options when uninstalling charts.

## Creating a Redis Enterprise Cluster

Once the chart is installed and the Redis Enterprise Operator is running, a Redis Enterprise Cluster can be created.  
As of now, the Redis Enterprise Cluster is created directly via custom resources, and not via Helm.

To create a Redis Enterprise Cluster:

1. Validate that the `redis-enterprise-operator` pod is in `RUNNING` state:

```sh
kubectl get pods -n [NAMESPACE]
```

2. Create a file for the `RedisEnterpriseCluster` custom resource:

```yaml
apiVersion: app.redislabs.com/v1
kind: RedisEnterpriseCluster
metadata:
  name: rec
spec:
  nodes: 3
```

3. Apply the custom resource:

```sh
kubectl apply -f rec.yaml -n [NAMESPACE]
```

See [Create a Redis Enterprise cluster](https://redis.io/docs/latest/operate/kubernetes/deployment/quick-start/#create-a-redis-enterprise-cluster-rec) and [Redis Enterprise Cluster API](https://github.com/RedisLabs/redis-enterprise-k8s-docs/blob/master/redis_enterprise_cluster_api.md) for more information and options for creating a Redis Enterprise Cluster.

## Configuration

The chart supports several configuration options that allows to customize the behavior and capabilities of the Redis Enterprise Operator.  
For a list of configurable options and their descriptions, please refer to the `values.yaml` file at the root of the chart.

To install the chart with a customized values file:

```sh
helm install [RELEASE_NAME] [PATH_TO_CHART] \
     --values [PATH_TO_VALUES_FILE]
```

To install the chart with the default values files but with some specific values overriden:

```sh
helm install [RELEASE_NAME] [PATH_TO_CHART] \
     --set key1=value1 \
     --set key2=value2
```

See [Customizing the Chart Before Installing](https://helm.sh/docs/intro/using_helm/#customizing-the-chart-before-installing) for additional information on how to customize the chart installation.

## Migrating from a non-Helm installation

To migrate an existing, non-Helm installation of the Redis Enterprise Operator to a Helm-based installation, follow these steps:
1. Upgrade the Redis Enterprise Operator to the same version as the desired Helm chart version, using the same non-Helm deployment method previously used.
   See [Upgrade instructions] for further information.
2. Install the Helm chart using the same steps as in the [Installing the Chart](#installing-the-chart) section, but add the `--take-ownership` flag:
   ```sh
   helm install [RELEASE_NAME] [PATH_TO_CHART] --take-ownership
   ```
   - The `--take-ownership` flag is available with Helm versions 3.18 or newer.
   - This flag is only needed with the first installation of the chart; Subsequent upgrades of the chart don't need this flag.
   - Note the use of `helm install` command, and not `helm upgrade`.
3. Delete the old `ValidatingWebhookConfiguration` object of the previous non-Helm installation:
   ```sh
   kubectl delete validatingwebhookconfiguration redis-enterprise-admission
   ```
   
   This step is only needed when the `admission.limitToNamespace` chart value is set to `true` (which is the default), in which case
   the webhook object installed by the chart is named `redis-enterprise-admission-<namespace>`. If `admission.limitToNamespace` is set to `false`,
   then the webhook installed by the chart is named `redis-enterprise-admission`, and hence the existing webhook object is re-used.
Â
## Known Limitations

This is a preliminary release of this Helm chart, and as of now some if its functionality is still limited:

- The chart only installs the Redis Enterprise Operator, but doesn't create a Redis Enterprise Cluster. See [Creating a Redis Enterprise Cluster](#creating-a-redis-enterprise-cluster) section for instructions on how to directly create a Redis Enterprise Cluster.
- Several configuration options for the operator are still unsupported, including multiple REDB namespaces, rack-aware, and vault integration. These options can be enabled by following the relevant instructions in the [product documentation](https://redis.io/docs/latest/operate/kubernetes/).
- CRDs installed by the chart are not removed upon chart uninstallation. These could be manually removed when the chart is uninstalled and are no longer needed, using the following command:
  ```sh
  kubectl delete crds -l app=redis-enterprise
  ```
- Limited testing in advanced setups such as Active-Active configurations, airgapped deployments, IPv6/dual-stack environments.
