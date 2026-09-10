package tests

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"gopkg.in/yaml.v3"
)

const redactedValue = "<redacted>"

func TestSupportPackageSpecsRenderRedactorsWhenEnabled(t *testing.T) {
	rendered := helmTemplate(t,
		"--show-only", "templates/support-package.yaml",
		"--set", "supportPackage.enabled=true",
	)

	configMaps := parseConfigMaps(t, rendered)
	supportBundleCM := findConfigMap(t, configMaps, "redis-agent-memory-support-bundle")
	redactorCM := findConfigMap(t, configMaps, "redis-agent-memory-support-redactors")

	require.Equal(t, "support-package", supportBundleCM.Metadata.Labels["app.kubernetes.io/component"])
	require.Equal(t, "support-bundle", supportBundleCM.Metadata.Labels["troubleshoot.sh/kind"])
	require.NotEmpty(t, supportBundleCM.Data["support-bundle-spec"])
	require.NotEmpty(t, redactorCM.Data["redactor-spec"])

	supportBundle := parseSupportBundleSpec(t, supportBundleCM.Data["support-bundle-spec"])
	require.Equal(t, "SupportBundle", supportBundle.Kind)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"chartVersion": "0.0.14"`)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"appVersion": "0.1.0"`)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"releaseName": "ram-fixture"`)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"namespace": "ram-fixture"`)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"imageTag": "0.0.0-test"`)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"serverDeployment": "redis-agent-memory"`)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"workerDeployment": "redis-agent-memory-worker"`)
	helmCollector := findCollector(t, supportBundle, "helm")
	require.Equal(t, "ram-helm-release", helmCollector["collectorName"])
	require.Equal(t, false, helmCollector["collectValues"])
	// The Identity Service is enabled by default, so its three Secrets (control
	// token, runtime credential, metadata overlay) and its two runPod probes are
	// part of a default bundle.
	requireCollectorCount(t, supportBundle.Spec.Collectors, "secret", 8)
	requireCollectorCount(t, supportBundle.Spec.Collectors, "runPod", 8)
	requireCollectorCount(t, supportBundle.Spec.Collectors, "registryImages", 1)
	requireCollectorCount(t, supportBundle.Spec.Collectors, "nodeMetrics", 1)
	requireAnalyzerCount(t, supportBundle.Spec.Analyzers, "secret", 8)
	requireAnalyzerCount(t, supportBundle.Spec.Analyzers, "textAnalyze", 9)
	requireAnalyzerCount(t, supportBundle.Spec.Analyzers, "registryImages", 1)
	requireAnalyzerCount(t, supportBundle.Spec.Analyzers, "nodeMetrics", 1)
	requireAnalyzerCount(t, supportBundle.Spec.Analyzers, "nodeResources", 4)
	requireSecretCollector(t, supportBundle, "config-test", "config.yaml", true)
	requireSecretCollector(t, supportBundle, "license-test", "license", false)
	registryImages := findCollector(t, supportBundle, "registryImages")
	requireContainsValue(t, registryImages["images"], "replicated/troubleshoot:0.131.0")
	requireNamedEntry(t, supportBundle.Spec.Analyzers, "textAnalyze", "checkName", "RAM node metrics collection")
	requireNamedEntry(t, supportBundle.Spec.Analyzers, "nodeMetrics", "checkName", "RAM PVC usage")
	requireNamedEntry(t, supportBundle.Spec.Analyzers, "nodeResources", "checkName", "RAM default minimum cluster CPU")
	requireNamedEntry(t, supportBundle.Spec.Analyzers, "nodeResources", "checkName", "RAM default minimum cluster memory")
	requireNamedEntry(t, supportBundle.Spec.Analyzers, "nodeResources", "checkName", "RAM single-pod schedulable node floor")
	requireNamedEntry(t, supportBundle.Spec.Analyzers, "nodeResources", "checkName", "RAM recommended node spread")
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"configValuesCollected": true`)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"httpHealthCollected": true`)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"registryImagesCollected": true`)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"nodeMetricsCollected": true`)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"nodeResourcesAnalyzed": true`)
	require.NotContains(t, supportBundleCM.Data["support-bundle-spec"], "redisChecksDeclared")
	require.NotContains(t, supportBundleCM.Data["support-bundle-spec"], `command: ["collect", "redis"]`)
	require.NotContains(t, supportBundleCM.Data["support-bundle-spec"], `"isConnected": *true`)
	require.NotContains(t, supportBundleCM.Data["support-bundle-spec"], "hostDiagnosticsCollected")
	require.NotContains(t, supportBundleCM.Data["support-bundle-spec"], "hostCollectors")
	require.NotContains(t, supportBundleCM.Data["support-bundle-spec"], "hostAnalyzers")
	require.NotContains(t, supportBundleCM.Data["support-bundle-spec"], "secretValuesCollected")
	require.NotContains(t, supportBundleCM.Data["support-bundle-spec"], "healthChecksEnabled")
	require.NotContains(t, supportBundleCM.Data["support-bundle-spec"], "registryImagesEnabled")
	require.NotContains(t, supportBundleCM.Data["support-bundle-spec"], "nodeMetricsEnabled")

	redactor := parseRedactorSpec(t, redactorCM.Data["redactor-spec"])
	require.Equal(t, "Redactor", redactor.Kind)
	requireRuleNames(t, redactor, []string{
		"ram-redis-url-credentials",
		"ram-redis-url-query-parameters",
		"ram-api-keys-and-tokens",
		"ram-sensitive-field-values",
		"ram-customer-content-fields",
		"ram-private-keys-and-cert-material",
		"ram-sensitive-yaml-paths",
	})
	requireYAMLPaths(t, redactor, []string{
		"embedders_connection_details.*.credentials",
		"session_summarisation.llm.credentials",
		"promote_session_memory.strategies.*.llm.credentials",
		"auth.admin_token",
		"auth.internal_token",
		"auth.control.token",
		"auth.worker_identity.jwks_uri",
		"runtime.service_credentials.*.token",
		"product_validation.*.credential.token",
		"license",
		"*.api_key",
		"*.private_key",
		"body",
		"payload",
		"response_body",
	})
	requireNoYAMLPaths(t, redactor, []string{
		"memory",
		"*.memory",
		"response",
		"*.response",
	})
}

func TestSupportPackageSparseReusedValuesUseDefaultEnabledCollectors(t *testing.T) {
	rendered := helmTemplate(t,
		"--set-json", `supportPackage={"enabled":true,"healthChecks":null,"registryImages":null,"logLimits":null,"healthCheckImage":null,"healthCheckPodTimeout":null}`,
	)

	configMaps := parseConfigMaps(t, rendered)
	supportBundleCM := findConfigMap(t, configMaps, "redis-agent-memory-support-bundle")
	supportBundle := parseSupportBundleSpec(t, supportBundleCM.Data["support-bundle-spec"])

	requireCollectorCount(t, supportBundle.Spec.Collectors, "runPod", 8)
	requireCollectorCount(t, supportBundle.Spec.Collectors, "registryImages", 1)
	requireCollectorCount(t, supportBundle.Spec.Collectors, "nodeMetrics", 1)
	requireAnalyzerCount(t, supportBundle.Spec.Analyzers, "textAnalyze", 9)
	requireAnalyzerCount(t, supportBundle.Spec.Analyzers, "registryImages", 1)
	requireAnalyzerCount(t, supportBundle.Spec.Analyzers, "nodeMetrics", 1)
	requireAnalyzerCount(t, supportBundle.Spec.Analyzers, "nodeResources", 4)
	requireSafeContains(t, rendered, "name: redis-agent-memory-worker-support")
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"httpHealthCollected": true`)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"registryImagesCollected": true`)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"nodeMetricsCollected": true`)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"nodeResourcesAnalyzed": true`)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], "maxLines: 10000")
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], "maxBytes: 5000000")
}

func TestSupportPackageSpecsDoNotRenderWhenDisabled(t *testing.T) {
	rendered := helmTemplate(t, "--set", "supportPackage.enabled=false")

	configMaps := parseConfigMaps(t, rendered)
	for _, configMap := range configMaps {
		if strings.HasSuffix(configMap.Metadata.Name, "-support-bundle") ||
			strings.HasSuffix(configMap.Metadata.Name, "-support-redactors") {
			t.Fatalf("support-package ConfigMap rendered while supportPackage.enabled=false: %s", configMap.Metadata.Name)
		}
	}
}

func TestSupportPackageIncludesBundledControlPlaneCollectors(t *testing.T) {
	rendered := helmTemplate(t,
		"--show-only", "templates/support-package.yaml",
		"--set", "supportPackage.enabled=true",
		"--set", "controlplane.image.tag=0.0.0-test",
		"--set", "controlplane.config.existingSecret=cp-config-test",
		"--set", "controlplane.config.secretKey=controlplane-onprem.config.yaml",
	)

	configMaps := parseConfigMaps(t, rendered)
	supportBundleCM := findConfigMap(t, configMaps, "redis-agent-memory-support-bundle")
	spec := supportBundleCM.Data["support-bundle-spec"]
	requireSafeContains(t, spec, "logs/controlplane")
	requireSafeContains(t, spec, "redis-agent-memory-controlplane")
}

func TestSupportPackageIncludesIdentityServiceCollectorsWhenEnabled(t *testing.T) {
	rendered := helmTemplate(t,
		"--show-only", "templates/support-package.yaml",
		"--set", "supportPackage.enabled=true",
		"--set", "controlplane.image.tag=0.0.0-test",
		"--set", "controlplane.config.existingSecret=cp-config-test",
		"--set", "controlplane.config.secretKey=controlplane-onprem.config.yaml",
		"--set", "identityService.enabled=true",
		"--set", "identityService.image.tag=0.0.0-test",
		"--set", "identityService.config.render=true",
		"--set", "identityService.metadata.existingSecret=ids-metadata",
		"--set", "identityService.metadata.secretKey=metadata.yaml",
	)

	configMaps := parseConfigMaps(t, rendered)
	supportBundleCM := findConfigMap(t, configMaps, "redis-agent-memory-support-bundle")
	spec := parseSupportBundleSpec(t, supportBundleCM.Data["support-bundle-spec"])

	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"identityServiceEnabled": true`)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"identityServiceDeployment": "redis-agent-memory-identity-service"`)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"identityServiceImageRepository": "redislabs/iris-identity-service"`)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"identityServiceImageTag": "0.0.0-test"`)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], "logs/identity-service")
	requireCollectorCount(t, spec.Spec.Collectors, "runPod", 8)
	requireAnalyzerCount(t, spec.Spec.Analyzers, "textAnalyze", 9)
	requireSecretCollector(t, spec, "ids-metadata", "metadata.yaml", true)
	requireSecretCollector(t, spec, "redis-agent-memory-identity-service-control-token", "token", false)
	requireSecretCollector(t, spec, "redis-agent-memory-identity-service-runtime-memory-dp", "token", false)
	requireNamedEntry(t, spec.Spec.Collectors, "configMap", "name", "redis-agent-memory-identity-service-config")
	requireNamedEntry(t, spec.Spec.Collectors, "runPod", "name", "iris-identity-service-live")
	requireNamedEntry(t, spec.Spec.Collectors, "runPod", "name", "iris-identity-service-ready")
	requireNamedEntry(t, spec.Spec.Analyzers, "textAnalyze", "collectorName", "iris-identity-service-live")
	requireNamedEntry(t, spec.Spec.Analyzers, "deploymentStatus", "name", "redis-agent-memory-identity-service")

	registryImages := findCollector(t, spec, "registryImages")
	requireContainsValue(t, registryImages["images"], "redislabs/iris-identity-service:0.0.0-test")
}

func TestSupportPackageDeepDiagnosticsRenderFromDefaults(t *testing.T) {
	rendered := helmTemplate(t,
		"--set", "supportPackage.enabled=true",
		"--set", "supportPackage.registryImages.imagePullSecretName=registry-pull",
		"--set", "supportPackage.healthCheckImage.repository=registry.example.com/troubleshoot",
		"--set", "supportPackage.healthCheckImage.tag=0.131.0",
		"--set", "secrets.secretName=ram-overlay-base",
		"--set", "secrets.additionalSecrets[0]=ram-overlay-region",
		"--set", "tls.caCertSecret=ram-ca",
		"--set", "tls.caCertKey=ca.pem",
		"--set", "controlplane.image.tag=0.0.0-test",
		"--set", "controlplane.config.existingSecret=cp-config-test",
		"--set", "controlplane.config.secretKey=controlplane-onprem.config.yaml",
		"--set", "controlplane.adminToken.existingSecret=cp-admin-token",
		"--set", "controlplane.adminToken.secretKey=admin-token",
		"--set", "controlplane.queueMonitor.enabled=true",
		"--set", "controlplane.queueMonitor.redis.existingSecret=queue-monitor-redis",
		"--set", "controlplane.queueMonitor.redis.urlKey=QUEUE_REDIS_URL",
	)

	configMaps := parseConfigMaps(t, rendered)
	supportBundleCM := findConfigMap(t, configMaps, "redis-agent-memory-support-bundle")
	spec := parseSupportBundleSpec(t, supportBundleCM.Data["support-bundle-spec"])

	requireCollectorCount(t, spec.Spec.Collectors, "secret", 14)
	requireCollectorCount(t, spec.Spec.Collectors, "runPod", 9)
	requireCollectorCount(t, spec.Spec.Collectors, "registryImages", 1)
	requireCollectorCount(t, spec.Spec.Collectors, "nodeMetrics", 1)
	requireAnalyzerCount(t, spec.Spec.Analyzers, "secret", 14)
	requireAnalyzerCount(t, spec.Spec.Analyzers, "textAnalyze", 10)
	requireAnalyzerCount(t, spec.Spec.Analyzers, "registryImages", 1)
	requireAnalyzerCount(t, spec.Spec.Analyzers, "nodeMetrics", 1)
	requireAnalyzerCount(t, spec.Spec.Analyzers, "nodeResources", 4)

	requireSecretCollector(t, spec, "config-test", "config.yaml", true)
	requireSecretCollector(t, spec, "ram-overlay-base", "overlay.yaml", true)
	requireSecretCollector(t, spec, "ram-overlay-region", "overlay.yaml", true)
	requireSecretCollector(t, spec, "license-test", "license", false)
	requireSecretCollector(t, spec, "cp-admin-token", "admin-token", false)
	requireSecretCollector(t, spec, "redis-agent-memory-controlplane-internal-token", "token", false)
	requireSecretCollector(t, spec, "queue-monitor-redis", "QUEUE_REDIS_URL", false)
	requireSafeContains(t, rendered, "name: redis-agent-memory-worker-support")

	for _, collectorName := range []string{
		"ram-server-liveness",
		"ram-server-readiness",
		"ram-worker-liveness",
		"ram-worker-readiness",
		"ram-controlplane-live",
		"ram-controlplane-ready",
		"ram-queue-monitor-root",
	} {
		requireNamedEntry(t, spec.Spec.Collectors, "runPod", "name", collectorName)
		requireNamedEntry(t, spec.Spec.Analyzers, "textAnalyze", "collectorName", collectorName)
	}

	registryImages := findCollector(t, spec, "registryImages")
	require.Equal(t, "registry-pull", nestedString(t, registryImages, "imagePullSecret", "name"))
	requireContainsValue(t, registryImages["images"], "redislabs/agent-memory:0.0.0-test")
	requireContainsValue(t, registryImages["images"], "redislabs/agent-memory-control-plane:0.0.0-test")
	requireContainsValue(t, registryImages["images"], "hibiken/asynqmon:0.7.2")
	requireContainsValue(t, registryImages["images"], "registry.example.com/troubleshoot:0.131.0")

	requireNamedEntry(t, spec.Spec.Analyzers, "textAnalyze", "checkName", "RAM node metrics collection")
	requireNamedEntry(t, spec.Spec.Analyzers, "nodeMetrics", "checkName", "RAM PVC usage")
	requireNamedEntry(t, spec.Spec.Analyzers, "nodeResources", "checkName", "RAM default minimum cluster CPU")
	requireNamedEntry(t, spec.Spec.Analyzers, "nodeResources", "checkName", "RAM default minimum cluster memory")
	require.NotContains(t, supportBundleCM.Data["support-bundle-spec"], "RAM pod memory usage")
	require.NotContains(t, supportBundleCM.Data["support-bundle-spec"], "RAM pod CPU usage")
	require.NotContains(t, supportBundleCM.Data["support-bundle-spec"], "RAM node memory availability")
	require.NotContains(t, supportBundleCM.Data["support-bundle-spec"], "ignoreIfNoFiles")
	require.NotContains(t, supportBundleCM.Data["support-bundle-spec"], `when: "timezone != UTC"`)
	require.NotContains(t, supportBundleCM.Data["support-bundle-spec"], `command: ["collect", "redis"]`)
	require.NotContains(t, supportBundleCM.Data["support-bundle-spec"], `"isConnected": *true`)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"configValuesCollected": true`)
	require.NotContains(t, supportBundleCM.Data["support-bundle-spec"], "redisChecksDeclared")
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"nodeResourcesAnalyzed": true`)
}

func TestSupportPackageCollectsConfigSecretValuesByDefault(t *testing.T) {
	rendered := helmTemplate(t,
		"--show-only", "templates/support-package.yaml",
		"--set", "supportPackage.enabled=true",
		"--set", "secrets.secretName=ram-overlay-base",
	)

	configMaps := parseConfigMaps(t, rendered)
	supportBundleCM := findConfigMap(t, configMaps, "redis-agent-memory-support-bundle")
	spec := parseSupportBundleSpec(t, supportBundleCM.Data["support-bundle-spec"])

	requireSecretCollector(t, spec, "config-test", "config.yaml", true)
	requireSecretCollector(t, spec, "ram-overlay-base", "overlay.yaml", true)
	requireSafeContains(t, supportBundleCM.Data["support-bundle-spec"], `"configValuesCollected": true`)
	require.NotContains(t, supportBundleCM.Data["support-bundle-spec"], "secretValuesCollected")
}

func TestSupportPackageRejectsRemovedRedisChecksValues(t *testing.T) {
	inlineRedisURI := fixtureRedisURL("redis", "user", "pass", "redis:6379", "")
	output := helmTemplateError(t,
		"--show-only", "templates/support-package.yaml",
		"--set", "supportPackage.enabled=true",
		"--set", "supportPackage.redisChecks[0].name=metadata-redis",
		"--set", "supportPackage.redisChecks[0].uri="+inlineRedisURI,
	)

	requireSafeContains(t, output, "redisChecks")
	require.NotContains(t, output, fmt.Sprintf("value: %q", inlineRedisURI))
}

func TestSupportPackageCollectsRenderedConfigMaps(t *testing.T) {
	rendered := helmTemplate(t,
		"--show-only", "templates/support-package.yaml",
		"--set", "supportPackage.enabled=true",
		"--set", "config.existingSecret=",
		"--set", "config.render=true",
		"--set", "memory.auth.method=none",
		"--set", "controlplane.image.tag=0.0.0-test",
		"--set", "controlplane.config.existingSecret=",
		"--set", "controlplane.config.render=true",
		"--set", "controlplane.configData.auth.admin_token.token_file=/etc/controlplane-onprem/admin/token",
	)

	configMaps := parseConfigMaps(t, rendered)
	supportBundleCM := findConfigMap(t, configMaps, "redis-agent-memory-support-bundle")
	spec := parseSupportBundleSpec(t, supportBundleCM.Data["support-bundle-spec"])

	requireCollectorCount(t, spec.Spec.Collectors, "configMap", 3)
	requireAnalyzerCount(t, spec.Spec.Analyzers, "configMap", 3)
	requireNamedEntry(t, spec.Spec.Collectors, "configMap", "name", "redis-agent-memory-config")
	requireNamedEntry(t, spec.Spec.Collectors, "configMap", "name", "redis-agent-memory-controlplane-config")
	// The Identity Service renders its config into a ConfigMap by default, so the
	// bundle has a third one to collect.
	requireNamedEntry(t, spec.Spec.Collectors, "configMap", "name", "redis-agent-memory-identity-service-config")
}

func TestBundledControlPlaneAlwaysRenders(t *testing.T) {
	rendered := helmTemplate(t)

	requireSafeContains(t, rendered, "name: redis-agent-memory-controlplane")
	requireSafeContains(t, rendered, "app.kubernetes.io/component: controlplane")
}

func TestControlPlaneRequiresPositiveReplicaCount(t *testing.T) {
	output := helmTemplateError(t, "--set", "controlplane.replicaCount=0")

	requireSafeContains(t, output, "minimum: got 0, want 1")
}

func TestRemovedControlPlaneEnabledValueIsRejected(t *testing.T) {
	output := helmTemplateError(t, "--set", "controlplane.enabled=false")

	requireSafeContains(t, output, "enabled")
}

func TestSupportPackageRedactorsCoverRAMFixtures(t *testing.T) {
	redactor := renderedRedactorSpec(t)
	totalCounts := map[string]int{}
	classes := map[string]struct{}{}

	for _, fixture := range redactorFixtures() {
		classes[fixture.class] = struct{}{}

		output, counts := applyRedactors(t, redactor, fixture.input, fixture.structured)
		for name, count := range counts {
			totalCounts[name] += count
		}

		requireNoSensitiveMarkers(t, output, fixture.sensitiveMarkers)

		for _, safe := range fixture.safeMarkers {
			requireSafeContains(t, output, safe)
		}
	}

	for _, ruleName := range []string{
		"ram-redis-url-credentials",
		"ram-redis-url-query-parameters",
		"ram-api-keys-and-tokens",
		"ram-sensitive-field-values",
		"ram-customer-content-fields",
		"ram-private-keys-and-cert-material",
		"ram-sensitive-yaml-paths",
	} {
		if totalCounts[ruleName] == 0 {
			t.Fatalf("fixture suite did not exercise redactor rule %q", ruleName)
		}
	}

	t.Logf("support-package redactor fixture coverage: classes=%s rules=%s", sortedKeys(classes), sortedRuleCounts(totalCounts))
}

func TestSupportPackageRedactorsPreserveNodeMetricsMemoryObjects(t *testing.T) {
	redactor := renderedRedactorSpec(t)

	jsonMetrics := `{"podRef":{"namespace":"ram-fixture","name":"redis-agent-memory-worker-0"},"containers":[{"name":"redis-agent-memory","memory":{"usageBytes":805306368},"cpu":{"usageNanoCores":900000000}}],"node":{"nodeName":"worker-a","memory":{"availableBytes":1073741824}}}`
	output, _ := applyRedactors(t, redactor, jsonMetrics, false)
	requireSafeContains(t, output, `"memory":{"usageBytes":805306368}`)
	requireSafeContains(t, output, `"memory":{"availableBytes":1073741824}`)

	nodeResources := `{"items":[{"metadata":{"name":"worker-a"},"status":{"allocatable":{"cpu":"14","memory":"12586056Ki","pods":"110"},"capacity":{"cpu":"14","memory":"16339912Ki","pods":"110"}}}]}`
	output, _ = applyRedactors(t, redactor, nodeResources, false)
	requireSafeContains(t, output, `"memory":"12586056Ki"`)
	requireSafeContains(t, output, `"memory":"16339912Ki"`)

	managedFields := `{"metadata":{"managedFields":[{"fieldsV1":{"f:spec":{"f:volumes":{"k:{\"name\":\"config-overlay-0\"}":{"f:name":{},"f:secret":{".":{},"f:secretName":{}}}}}}}]},"spec":{"volumes":[{"name":"config-overlay-0","secret":{"secretName":"ram-secrets"}}]}}`
	output, _ = applyRedactors(t, redactor, managedFields, false)
	require.True(t, json.Valid([]byte(output)), output)
	requireSafeContains(t, output, `"f:secret":{`)
	requireNoSensitiveMarkers(t, output, markers("secret name", "ram-secrets"))

	podCommand := `{"spec":{"automountServiceAccountToken":false,"containers":[{"args":["def request(method, path, payload=None):\n    body = resp.read().decode(\"utf-8\")\n    if not body:\n        return {}\n    prompt=FIXTURE_LOG_PROMPT\n"]}]}}`
	output, _ = applyRedactors(t, redactor, podCommand, false)
	require.True(t, json.Valid([]byte(output)), output)
	requireSafeContains(t, output, `"automountServiceAccountToken":false`)
	requireNoSensitiveMarkers(t, output, markers("log prompt", "FIXTURE_LOG_PROMPT"))

	yamlMetrics := `podRef:
  namespace: ram-fixture
  name: redis-agent-memory-worker-0
containers:
  - name: redis-agent-memory
    memory:
      usageBytes: 805306368
node:
  nodeName: worker-a
  memory:
    availableBytes: 1073741824
`
	output, _ = applyRedactors(t, redactor, yamlMetrics, true)
	requireSafeContains(t, output, "usageBytes: 805306368")
	requireSafeContains(t, output, "availableBytes: 1073741824")
}

func TestSupportPackageRedactorsPreserveHTTPCollectorStatus(t *testing.T) {
	redactor := renderedRedactorSpec(t)

	httpResult := `{"response":{"status":200,"body":"FIXTURE_HEALTH_RESPONSE_BODY","headers":{"Authorization":"Bearer FIXTURE_HEALTH_TOKEN"}}}`
	output, _ := applyRedactors(t, redactor, httpResult, true)

	requireSafeContains(t, output, `"status": 200`)
	requireNoSensitiveMarkers(t, output, markers(
		"health response body", "FIXTURE_HEALTH_RESPONSE_BODY",
		"health auth token", "FIXTURE_HEALTH_TOKEN",
	))

	rawHTTPLog := `{"response":{"status":200,"body":"{\"status\":\"FIXTURE_HEALTH_BODY\"}"}}`
	output, _ = applyRedactors(t, redactor, rawHTTPLog, false)
	requireSafeContains(t, output, `"status":200`)
	requireSafeContains(t, output, `"body":"<redacted>"`)
	requireNoSensitiveMarkers(t, output, markers(
		"escaped health body", "FIXTURE_HEALTH_BODY",
	))
}

func TestSupportPackageRedactorsPreserveEscapedYAMLConfigShape(t *testing.T) {
	redactor := renderedRedactorSpec(t)

	redisURI := fixtureRedisURL("redis", "user", "FIXTURE_REDIS_PASSWORD", "redis.example.test:6379", "token=FIXTURE_REDIS_QUERY_TOKEN")
	secretCollectorJSON := fmt.Sprintf(`{"value":"embedders_connection_details:\n  openai:\n    credentials:\n      api_key: FIXTURE_OPENAI_KEY\nmetadata:\n  stores:\n    \"00000000000000000000000000000001\":\n      urls:\n        - %s\nsession_summarisation:\n  llm:\n    credentials:\n      api_key: FIXTURE_SUMMARY_KEY\npromote_session_memory:\n  strategies:\n    instruct:\n      llm:\n        credentials:\n          api_key: FIXTURE_PROMOTION_KEY\n"}`, redisURI)

	output, _ := applyRedactors(t, redactor, secretCollectorJSON, false)
	require.True(t, json.Valid([]byte(output)), output)
	requireNoSensitiveMarkers(t, output, markers(
		"openai api key", "FIXTURE_OPENAI_KEY",
		"redis password", "FIXTURE_REDIS_PASSWORD",
		"redis query token", "FIXTURE_REDIS_QUERY_TOKEN",
		"summary api key", "FIXTURE_SUMMARY_KEY",
		"promotion api key", "FIXTURE_PROMOTION_KEY",
	))

	var collected struct {
		Value string `json:"value"`
	}
	require.NoError(t, json.Unmarshal([]byte(output), &collected))
	requireSafeContains(t, collected.Value, "\nmetadata:\n")
	requireSafeContains(t, collected.Value, "\nsession_summarisation:\n")
	requireSafeContains(t, collected.Value, "\npromote_session_memory:\n")
	requireSafeContains(t, collected.Value, "redis.example.test:6379")

	var node yaml.Node
	require.NoError(t, yaml.Unmarshal([]byte(collected.Value), &node), collected.Value)
}

func renderedRedactorSpec(t *testing.T) redactorSpec {
	t.Helper()

	rendered := helmTemplate(t,
		"--show-only", "templates/support-package.yaml",
		"--set", "supportPackage.enabled=true",
	)
	configMaps := parseConfigMaps(t, rendered)
	redactorCM := findConfigMap(t, configMaps, "redis-agent-memory-support-redactors")

	return parseRedactorSpec(t, redactorCM.Data["redactor-spec"])
}

type configMap struct {
	Kind     string `yaml:"kind"`
	Metadata struct {
		Name   string            `yaml:"name"`
		Labels map[string]string `yaml:"labels"`
	} `yaml:"metadata"`
	Data map[string]string `yaml:"data"`
}

type supportBundleSpec struct {
	Kind string `yaml:"kind"`
	Spec struct {
		Collectors []map[string]any `yaml:"collectors"`
		Analyzers  []map[string]any `yaml:"analyzers"`
	} `yaml:"spec"`
}

type redactorSpec struct {
	Kind string `yaml:"kind"`
	Spec struct {
		Redactors []redactorRule `yaml:"redactors"`
	} `yaml:"spec"`
}

type redactorRule struct {
	Name     string `yaml:"name"`
	Removals struct {
		Regex []struct {
			Redactor string `yaml:"redactor"`
		} `yaml:"regex"`
		YAMLPath []string `yaml:"yamlPath"`
	} `yaml:"removals"`
}

type sensitiveMarker struct {
	name  string
	value string
}

type redactorFixture struct {
	name             string
	class            string
	structured       bool
	input            string
	sensitiveMarkers []sensitiveMarker
	safeMarkers      []string
}

func redactorFixtures() []redactorFixture {
	return []redactorFixture{
		{
			name:       "ram config paths and redis urls",
			class:      "ram-config-and-redis-urls",
			structured: true,
			input: fmt.Sprintf(`chart:
  name: redis-agent-memory
  version: 0.0.13
release:
  name: ram-fixture
  namespace: ram-fixture
component: worker
deployment: redis-agent-memory-worker
request_region:
  default: eu1
background_jobs:
  redis:
    enabled: true
    queue_prefix: ram-jobs
    worker_regions: ["eu1", "us1"]
    urls:
      - %s
metadata:
  urls:
    - %s
databases:
  "1":
    name: content
    region: eu1
    urls:
      - %s
idempotency:
  urls:
    - %s
override_clients:
  redis_url: %s
auth:
  admin_token: FIXTURE_AUTH_ADMIN_TOKEN
  worker_identity:
    jwks_uri: https://issuer.example.test/.well-known/jwks.json?token=FIXTURE_JWKS_QUERY_TOKEN
license:
  contents: FIXTURE_LICENSE_CONTENT
status_counts:
  ready: 2
  pending: 1
analyzer:
  outcome: queue-backlog
`,
				fixtureRedisURL("rediss", "job-user", "FIXTURE_JOB_REDIS_PASSWORD", "job-redis.example.test:6380/0", "client_name=FIXTURE_JOB_CLIENT&token=FIXTURE_JOB_QUERY_TOKEN"),
				fixtureRedisURL("rediss", "metadata-user", "FIXTURE_METADATA_REDIS_PASSWORD", "metadata-redis.example.test:6380", "credential=FIXTURE_METADATA_QUERY_CREDENTIAL"),
				fixtureRedisURL("redis", "content-user", "FIXTURE_CONTENT_REDIS_PASSWORD", "content-redis.example.test:6379/1", "password=FIXTURE_CONTENT_QUERY_PASSWORD"),
				fixtureRedisURL("redis", "idem-user", "FIXTURE_IDEMPOTENCY_REDIS_PASSWORD", "idempotency-redis.example.test:6379", "token=FIXTURE_IDEMPOTENCY_QUERY_TOKEN"),
				fixtureRedisURL("rediss", "override-user", "FIXTURE_OVERRIDE_REDIS_PASSWORD", "override-redis.example.test:6380", "api_key=FIXTURE_OVERRIDE_QUERY_KEY"),
			),
			sensitiveMarkers: markers(
				"job redis password", "FIXTURE_JOB_REDIS_PASSWORD",
				"job redis query", "FIXTURE_JOB_QUERY_TOKEN",
				"job redis client query", "FIXTURE_JOB_CLIENT",
				"content redis password", "FIXTURE_CONTENT_REDIS_PASSWORD",
				"content redis query", "FIXTURE_CONTENT_QUERY_PASSWORD",
				"metadata redis password", "FIXTURE_METADATA_REDIS_PASSWORD",
				"metadata redis query", "FIXTURE_METADATA_QUERY_CREDENTIAL",
				"idempotency redis password", "FIXTURE_IDEMPOTENCY_REDIS_PASSWORD",
				"idempotency redis query", "FIXTURE_IDEMPOTENCY_QUERY_TOKEN",
				"override redis password", "FIXTURE_OVERRIDE_REDIS_PASSWORD",
				"override redis query", "FIXTURE_OVERRIDE_QUERY_KEY",
				"admin token", "FIXTURE_AUTH_ADMIN_TOKEN",
				"jwks query token", "FIXTURE_JWKS_QUERY_TOKEN",
				"license content", "FIXTURE_LICENSE_CONTENT",
			),
			safeMarkers: []string{
				"redis-agent-memory",
				"ram-fixture",
				"redis-agent-memory-worker",
				"ram-jobs",
				"eu1",
				"us1",
				"rediss://",
				"redis://",
				"job-redis.example.test:6380",
				"content-redis.example.test:6379",
				"metadata-redis.example.test:6380",
				"idempotency-redis.example.test:6379",
				"override-redis.example.test:6380",
				"queue-backlog",
			},
		},
		{
			name:       "provider auth materials and shared secrets",
			class:      "provider-auth-and-private-material",
			structured: true,
			input: `embedders_connection_details:
  openai:
    protocol: openai
    base_url: https://embed.example.test/v1
    credentials:
      api_key: FIXTURE_EMBEDDER_OPENAI_KEY
  bedrock:
    protocol: bedrock
    region: us-east-1
    credentials:
      aws_access_key_id: FIXTURE_AWS_ACCESS_KEY_ID
      aws_secret_access_key: FIXTURE_AWS_SECRET_ACCESS_KEY
session_summarisation:
  enabled: true
  llm:
    provider: azure_openai
    credentials:
      api_key: FIXTURE_SUMMARY_AZURE_KEY
      azure_ad_token: FIXTURE_SUMMARY_AZURE_TOKEN
promote_session_memory:
  strategies:
    instruct:
      llm:
        provider: openai_compatible
        credentials:
          api_key: FIXTURE_PROMOTION_LLM_KEY
reranker:
  provider: voyage
  api_key: FIXTURE_RERANKER_KEY
auth:
  session_shared_secret: FIXTURE_SESSION_SHARED_SECRET
  worker_identity:
    shared_secret: FIXTURE_WORKER_SHARED_SECRET
webhook:
  headers:
    Authorization: Bearer FIXTURE_WEBHOOK_BEARER
    x-provider-token: FIXTURE_WEBHOOK_PROVIDER_TOKEN
tls:
  private_key: |
    -----BEGIN PRIVATE KEY-----
    FIXTURE_TLS_PRIVATE_KEY
    -----END PRIVATE KEY-----
redis:
  password: FIXTURE_REDIS_PASSWORD
custom_credential_name: FIXTURE_CUSTOM_CREDENTIAL
`,
			sensitiveMarkers: markers(
				"embedder openai api key", "FIXTURE_EMBEDDER_OPENAI_KEY",
				"aws access key id", "FIXTURE_AWS_ACCESS_KEY_ID",
				"aws secret access key", "FIXTURE_AWS_SECRET_ACCESS_KEY",
				"summary azure api key", "FIXTURE_SUMMARY_AZURE_KEY",
				"summary azure token", "FIXTURE_SUMMARY_AZURE_TOKEN",
				"promotion llm api key", "FIXTURE_PROMOTION_LLM_KEY",
				"reranker api key", "FIXTURE_RERANKER_KEY",
				"session shared secret", "FIXTURE_SESSION_SHARED_SECRET",
				"worker shared secret", "FIXTURE_WORKER_SHARED_SECRET",
				"webhook bearer", "FIXTURE_WEBHOOK_BEARER",
				"webhook provider token", "FIXTURE_WEBHOOK_PROVIDER_TOKEN",
				"tls private key", "FIXTURE_TLS_PRIVATE_KEY",
				"redis password", "FIXTURE_REDIS_PASSWORD",
				"custom credential", "FIXTURE_CUSTOM_CREDENTIAL",
			),
			safeMarkers: []string{
				"openai",
				"bedrock",
				"us-east-1",
				"azure_openai",
				"openai_compatible",
				"voyage",
				"https://embed.example.test/v1",
			},
		},
		{
			name:       "control plane config snippet",
			class:      "control-plane-config",
			structured: true,
			input: fmt.Sprintf(`component: controlplane
deployment: redis-agent-memory-controlplane
namespace: ram-fixture
auth:
  admin_token: FIXTURE_CP_ADMIN_TOKEN
metadata:
  namespace: iris:memory
  stores:
    admin:
      region: eu1
      urls:
        - %s
status_counts:
  stores: 4
`,
				fixtureRedisURL("rediss", "cp-metadata-user", "FIXTURE_CP_METADATA_PASSWORD", "cp-metadata-redis.example.test:6380", "token=FIXTURE_CP_METADATA_QUERY_TOKEN"),
			),
			sensitiveMarkers: markers(
				"control plane admin token", "FIXTURE_CP_ADMIN_TOKEN",
				"control plane metadata redis password", "FIXTURE_CP_METADATA_PASSWORD",
				"control plane metadata redis query", "FIXTURE_CP_METADATA_QUERY_TOKEN",
			),
			safeMarkers: []string{
				"controlplane",
				"redis-agent-memory-controlplane",
				"ram-fixture",
				"iris:memory",
				"cp-metadata-redis.example.test:6380",
				"stores",
			},
		},
		{
			name:       "json customer content payload",
			class:      "customer-content-json",
			structured: true,
			input: `{
  "component": "worker",
  "deployment": "redis-agent-memory-worker",
  "region": "eu1",
  "queue": "ram-jobs",
  "health": {"ready": 2, "failed": 0},
  "payload": {
    "prompt": "FIXTURE_PROMPT_TEXT",
    "messages": [{"role": "user", "content": "FIXTURE_MESSAGE_CONTENT"}],
    "memory": {"text": "FIXTURE_MEMORY_TEXT"}
  },
  "request": {"body": "FIXTURE_REQUEST_BODY"},
  "response": {"body": "FIXTURE_RESPONSE_BODY"},
  "response_body": "FIXTURE_RESPONSE_BODY_FIELD"
}`,
			sensitiveMarkers: markers(
				"prompt text", "FIXTURE_PROMPT_TEXT",
				"message content", "FIXTURE_MESSAGE_CONTENT",
				"memory text", "FIXTURE_MEMORY_TEXT",
				"request body", "FIXTURE_REQUEST_BODY",
				"response body", "FIXTURE_RESPONSE_BODY",
				"response body field", "FIXTURE_RESPONSE_BODY_FIELD",
			),
			safeMarkers: []string{
				"worker",
				"redis-agent-memory-worker",
				"eu1",
				"ram-jobs",
				"ready",
				"failed",
			},
		},
		{
			name:       "log auth and content fields",
			class:      "log-auth-and-content",
			structured: false,
			input: strings.Join([]string{
				`level=info component=server deployment=redis-agent-memory region=eu1 queue=ram-jobs analyzer=healthy`,
				`Authorization: Bearer FIXTURE_LOG_BEARER api_key=FIXTURE_LOG_API_KEY prompt=FIXTURE_LOG_PROMPT response_body=FIXTURE_LOG_RESPONSE`,
				`{"level":"info","component":"server","Authorization":"Bearer FIXTURE_JSON_LOG_BEARER","api_key":"FIXTURE_JSON_LOG_API_KEY","prompt":"FIXTURE_JSON_LOG_PROMPT with spaces","response_body":"FIXTURE_JSON_LOG_RESPONSE with spaces"}`,
				`prompt="FIXTURE_QUOTED_LOG_PROMPT with spaces" response_body='FIXTURE_QUOTED_LOG_RESPONSE with spaces'`,
				`provider_header_token=FIXTURE_LOG_PROVIDER_TOKEN private_key=FIXTURE_LOG_PRIVATE_KEY`,
				`-----BEGIN PRIVATE KEY-----`,
				`FIXTURE_LOG_PEM_BODY`,
				`-----END PRIVATE KEY-----`,
			}, "\n"),
			sensitiveMarkers: markers(
				"log bearer", "FIXTURE_LOG_BEARER",
				"log api key", "FIXTURE_LOG_API_KEY",
				"log prompt", "FIXTURE_LOG_PROMPT",
				"log response", "FIXTURE_LOG_RESPONSE",
				"json log bearer", "FIXTURE_JSON_LOG_BEARER",
				"json log api key", "FIXTURE_JSON_LOG_API_KEY",
				"json log prompt", "FIXTURE_JSON_LOG_PROMPT with spaces",
				"json log response", "FIXTURE_JSON_LOG_RESPONSE with spaces",
				"quoted log prompt", "FIXTURE_QUOTED_LOG_PROMPT with spaces",
				"quoted log response", "FIXTURE_QUOTED_LOG_RESPONSE with spaces",
				"log provider token", "FIXTURE_LOG_PROVIDER_TOKEN",
				"log private key field", "FIXTURE_LOG_PRIVATE_KEY",
				"log pem body", "FIXTURE_LOG_PEM_BODY",
			),
			safeMarkers: []string{
				"component=server",
				"deployment=redis-agent-memory",
				"region=eu1",
				"queue=ram-jobs",
				"analyzer=healthy",
			},
		},
	}
}

func fixtureRedisURL(scheme, user, password, endpoint, query string) string {
	url := scheme + "://" + user + ":" + password + "@" + endpoint
	if query == "" {
		return url
	}

	return url + "?" + query
}

func helmTemplate(t *testing.T, args ...string) string {
	t.Helper()

	out, err := runHelmTemplate(t, args...)
	if err != nil {
		t.Fatalf("helm template failed: %v\n%s", err, string(out))
	}

	return string(out)
}

func helmTemplateError(t *testing.T, args ...string) string {
	t.Helper()

	out, err := runHelmTemplate(t, args...)
	require.Error(t, err)

	return string(out)
}

func runHelmTemplate(t *testing.T, args ...string) ([]byte, error) {
	t.Helper()

	_, file, _, ok := runtime.Caller(0)
	require.True(t, ok)

	chartDir := filepath.Clean(filepath.Join(filepath.Dir(file), ".."))

	baseArgs := []string{
		"template", "ram-fixture", chartDir,
		"--namespace", "ram-fixture",
		"--set", "image.tag=0.0.0-test",
		"--set", "license.existingSecret=license-test",
		"--set", "config.existingSecret=config-test",
		"--set", "config.secretKey=config.yaml",
		"--set", "controlplane.image.tag=0.0.0-test",
		"--set", "controlplane.config.existingSecret=cp-config-test",
		"--set", "controlplane.config.secretKey=controlplane-onprem.config.yaml",
		// The Identity Service is enabled by default, and enabling it makes the
		// image tag and the metadata Redis overlay Secret mandatory.
		"--set", "identityService.image.tag=0.0.0-test",
		"--set", "identityService.metadata.existingSecret=ids-metadata",
	}
	cmd := exec.Command("helm", append(baseArgs, args...)...)

	return cmd.CombinedOutput()
}

func parseConfigMaps(t *testing.T, rendered string) []configMap {
	t.Helper()

	decoder := yaml.NewDecoder(strings.NewReader(rendered))

	var configMaps []configMap

	for {
		var doc configMap

		err := decoder.Decode(&doc)
		if errors.Is(err, io.EOF) {
			break
		}

		require.NoError(t, err)

		if doc.Kind == "ConfigMap" {
			configMaps = append(configMaps, doc)
		}
	}

	return configMaps
}

func findConfigMap(t *testing.T, configMaps []configMap, name string) configMap {
	t.Helper()

	for _, configMap := range configMaps {
		if configMap.Metadata.Name == name {
			return configMap
		}
	}

	t.Fatalf("rendered ConfigMap %q was not found", name)

	return configMap{}
}

func parseSupportBundleSpec(t *testing.T, raw string) supportBundleSpec {
	t.Helper()

	var spec supportBundleSpec
	require.NoError(t, yaml.Unmarshal([]byte(raw), &spec))

	return spec
}

func parseRedactorSpec(t *testing.T, raw string) redactorSpec {
	t.Helper()

	var spec redactorSpec
	require.NoError(t, yaml.Unmarshal([]byte(raw), &spec))

	return spec
}

func findCollector(t *testing.T, spec supportBundleSpec, name string) map[string]any {
	t.Helper()

	for _, collector := range spec.Spec.Collectors {
		raw, ok := collector[name]
		if !ok {
			continue
		}

		typed, ok := raw.(map[string]any)
		require.True(t, ok)

		return typed
	}

	t.Fatalf("support bundle collector %q was not found", name)

	return nil
}

func requireCollectorCount(t *testing.T, entries []map[string]any, name string, expected int) {
	t.Helper()

	require.Equal(t, expected, entryCount(entries, name), "unexpected collector count for %q", name)
}

func requireAnalyzerCount(t *testing.T, entries []map[string]any, name string, expected int) {
	t.Helper()

	require.Equal(t, expected, entryCount(entries, name), "unexpected analyzer count for %q", name)
}

func entryCount(entries []map[string]any, name string) int {
	count := 0

	for _, entry := range entries {
		if _, ok := entry[name]; ok {
			count++
		}
	}

	return count
}

func requireSecretCollector(t *testing.T, spec supportBundleSpec, name string, key string, includeValue bool) {
	t.Helper()

	collector := requireNamedEntry(t, spec.Spec.Collectors, "secret", "name", name)
	require.Equal(t, key, collector["key"])
	require.Equal(t, includeValue, collector["includeValue"])
	require.NotContains(t, collector, "selector")
	require.NotContains(t, collector, "includeAllData")
}

func requireNamedEntry(t *testing.T, entries []map[string]any, kind string, field string, value string) map[string]any {
	t.Helper()

	for _, entry := range entries {
		raw, ok := entry[kind]
		if !ok {
			continue
		}

		typed, ok := raw.(map[string]any)
		require.True(t, ok)

		if typed[field] == value {
			return typed
		}
	}

	t.Fatalf("%s entry with %s=%q was not found", kind, field, value)

	return nil
}

func nestedString(t *testing.T, values map[string]any, path ...string) string {
	t.Helper()

	var current any = values
	for _, part := range path {
		typed, ok := current.(map[string]any)
		require.True(t, ok)

		current = typed[part]
	}

	value, ok := current.(string)
	require.True(t, ok)

	return value
}

func requireContainsValue(t *testing.T, raw any, expected string) {
	t.Helper()

	values, ok := raw.([]any)
	require.True(t, ok)

	for _, value := range values {
		if value == expected {
			return
		}
	}

	t.Fatalf("expected %q in %v", expected, values)
}

func requireRuleNames(t *testing.T, spec redactorSpec, names []string) {
	t.Helper()

	existing := map[string]struct{}{}
	for _, rule := range spec.Spec.Redactors {
		existing[rule.Name] = struct{}{}
	}

	for _, name := range names {
		if _, ok := existing[name]; !ok {
			t.Fatalf("redactor rule %q was not found", name)
		}
	}
}

func requireYAMLPaths(t *testing.T, spec redactorSpec, paths []string) {
	t.Helper()

	existing := map[string]struct{}{}

	for _, rule := range spec.Spec.Redactors {
		for _, path := range rule.Removals.YAMLPath {
			existing[path] = struct{}{}
		}
	}

	for _, path := range paths {
		if _, ok := existing[path]; !ok {
			t.Fatalf("yamlPath redactor %q was not found", path)
		}
	}
}

func requireNoYAMLPaths(t *testing.T, spec redactorSpec, paths []string) {
	t.Helper()

	existing := map[string]struct{}{}

	for _, rule := range spec.Spec.Redactors {
		for _, path := range rule.Removals.YAMLPath {
			existing[path] = struct{}{}
		}
	}

	for _, path := range paths {
		if _, ok := existing[path]; ok {
			t.Fatalf("yamlPath redactor %q should not be rendered", path)
		}
	}
}

func applyRedactors(t *testing.T, spec redactorSpec, input string, structured bool) (string, map[string]int) {
	t.Helper()

	counts := map[string]int{}
	output := input

	if structured {
		var node yaml.Node
		require.NoError(t, yaml.Unmarshal([]byte(output), &node))

		for _, rule := range spec.Spec.Redactors {
			for _, path := range rule.Removals.YAMLPath {
				counts[rule.Name] += redactYAMLPath(&node, strings.Split(path, "."))
			}
		}

		marshaled, err := yaml.Marshal(&node)
		require.NoError(t, err)

		output = string(marshaled)
	}

	for _, rule := range spec.Spec.Redactors {
		for _, redactor := range rule.Removals.Regex {
			next, count := applyRegexRedactor(t, output, redactor.Redactor)
			output = next
			counts[rule.Name] += count
		}
	}

	return output, counts
}

func applyRegexRedactor(t *testing.T, input string, pattern string) (string, int) {
	t.Helper()

	re, err := regexp.Compile(pattern)
	require.NoError(t, err)

	maskIndex := re.SubexpIndex("mask")

	matches := re.FindAllStringSubmatchIndex(input, -1)
	if len(matches) == 0 {
		return input, 0
	}

	var output bytes.Buffer

	last := 0
	for _, match := range matches {
		output.WriteString(input[last:match[0]])

		if maskIndex >= 0 && match[2*maskIndex] >= 0 {
			output.WriteString(input[match[0]:match[2*maskIndex]])
			output.WriteString(redactedValue)
			output.WriteString(input[match[2*maskIndex+1]:match[1]])
		} else {
			output.WriteString(redactedValue)
		}

		last = match[1]
	}

	output.WriteString(input[last:])

	return output.String(), len(matches)
}

func redactYAMLPath(node *yaml.Node, parts []string) int {
	if node == nil {
		return 0
	}

	if len(parts) == 0 {
		redactYAMLNode(node)
		return 1
	}

	part := parts[0]

	switch node.Kind {
	case yaml.DocumentNode:
		if len(node.Content) == 0 {
			return 0
		}

		return redactYAMLPath(node.Content[0], parts)
	case yaml.MappingNode:
		count := 0

		for i := 0; i+1 < len(node.Content); i += 2 {
			if pathPartMatches(part, node.Content[i].Value) {
				count += redactYAMLPath(node.Content[i+1], parts[1:])
			}
		}

		return count
	case yaml.SequenceNode:
		if part != "*" {
			return 0
		}

		count := 0
		for _, child := range node.Content {
			count += redactYAMLPath(child, parts[1:])
		}

		return count
	case yaml.ScalarNode, yaml.AliasNode:
		return 0
	default:
		return 0
	}
}

func pathPartMatches(pattern string, value string) bool {
	return pattern == "*" || pattern == value
}

func redactYAMLNode(node *yaml.Node) {
	node.Kind = yaml.ScalarNode
	node.Tag = "!!str"
	node.Value = redactedValue
	node.Content = nil
	node.LineComment = ""
	node.FootComment = ""
	node.HeadComment = ""
}

func markers(items ...string) []sensitiveMarker {
	if len(items)%2 != 0 {
		panic("markers requires name/value pairs")
	}

	out := make([]sensitiveMarker, 0, len(items)/2)
	for i := 0; i < len(items); i += 2 {
		out = append(out, sensitiveMarker{name: items[i], value: items[i+1]})
	}

	return out
}

func requireNoSensitiveMarkers(t *testing.T, output string, markers []sensitiveMarker) {
	t.Helper()

	for _, marker := range markers {
		if strings.Contains(output, marker.value) {
			t.Fatalf("redacted fixture leaked sensitive marker %q", marker.name)
		}
	}
}

func requireSafeContains(t *testing.T, output string, marker string) {
	t.Helper()

	if !strings.Contains(output, marker) {
		t.Fatalf("redacted fixture is missing safe operational marker %q", marker)
	}
}

func sortedKeys(values map[string]struct{}) string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}

	sort.Strings(keys)

	return strings.Join(keys, ",")
}

func sortedRuleCounts(counts map[string]int) string {
	keys := make([]string, 0, len(counts))
	for key := range counts {
		keys = append(keys, key)
	}

	sort.Strings(keys)

	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		parts = append(parts, fmt.Sprintf("%s=%d", key, counts[key]))
	}

	return strings.Join(parts, ",")
}
