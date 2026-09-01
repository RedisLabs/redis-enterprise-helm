// Package tests renders the langcache chart's support-package and redactor
// specs via `helm template` and asserts their structure and behavior:
// (a) the right number/kind of collectors and analyzers appear for bundled
// vs. external Identity Service mode, (b) specific Secret keys are or are
// not value-collected, and (c) the redactor spec's regex/yamlPath rules
// actually strip the sensitive fixture values they claim to cover without
// over-redacting ordinary field names.
package tests

import (
	"bytes"
	"errors"
	"io"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"gopkg.in/yaml.v3"
)

const redactedValue = "<redacted>"

func TestSupportPackageSpecsRenderInBundledMode(t *testing.T) {
	rendered := helmTemplate(t, "--show-only", "templates/support-package.yaml")

	configMaps := parseConfigMaps(t, rendered)
	supportBundleCM := findConfigMap(t, configMaps, "langcache-support-bundle")
	redactorCM := findConfigMap(t, configMaps, "langcache-support-redactors")

	require.Equal(t, "support-package", supportBundleCM.Metadata.Labels["app.kubernetes.io/component"])
	require.Equal(t, "support-bundle", supportBundleCM.Metadata.Labels["troubleshoot.sh/kind"])
	require.NotEmpty(t, supportBundleCM.Data["support-bundle-spec"])
	require.NotEmpty(t, redactorCM.Data["redactor-spec"])

	supportBundle := parseSupportBundleSpec(t, supportBundleCM.Data["support-bundle-spec"])
	require.Equal(t, "SupportBundle", supportBundle.Kind)
	require.Contains(t, supportBundleCM.Data["support-bundle-spec"], `"dataplaneDeployment": "langcache"`)
	require.Contains(t, supportBundleCM.Data["support-bundle-spec"], `"controlplaneDeployment": "langcache-controlplane"`)
	require.Contains(t, supportBundleCM.Data["support-bundle-spec"], `"identityServiceMode": "bundled"`)

	helmCollector := findCollector(t, supportBundle, "helm")
	require.Equal(t, "langcache-helm-release", helmCollector["collectorName"])
	require.Equal(t, false, helmCollector["collectValues"])

	// Bundled mode Secrets: Data Plane overlay, license, Control Plane
	// overlay, admin token, internal token, Identity Service metadata
	// overlay, Identity Service control token, Data Plane's Identity
	// Service runtime credential = 8. (The Data Plane/Control
	// Plane/Identity Service configs render as ConfigMaps by default —
	// see configMap below — not Secrets.)
	requireCollectorCount(t, supportBundle.Spec.Collectors, "secret", 8)
	// DP live+ready, CP live+ready, IdS live+ready = 6.
	requireCollectorCount(t, supportBundle.Spec.Collectors, "runPod", 6)
	requireCollectorCount(t, supportBundle.Spec.Collectors, "configMap", 3)
	requireCollectorCount(t, supportBundle.Spec.Collectors, "registryImages", 1)
	requireCollectorCount(t, supportBundle.Spec.Collectors, "nodeMetrics", 1)
	requireAnalyzerCount(t, supportBundle.Spec.Analyzers, "secret", 8)

	requireSecretCollector(t, supportBundle, "license-test", "license", false)
	requireSecretCollector(t, supportBundle, "langcache-controlplane-admin-token", "token", false)
}

func TestSupportPackageCollectsBYOConfigSecretValue(t *testing.T) {
	rendered := helmTemplate(t,
		"--show-only", "templates/support-package.yaml",
		"--set", "dataplane.config.render=false",
		"--set", "dataplane.config.existingSecret=dp-config-secret",
	)

	configMaps := parseConfigMaps(t, rendered)
	supportBundleCM := findConfigMap(t, configMaps, "langcache-support-bundle")
	supportBundle := parseSupportBundleSpec(t, supportBundleCM.Data["support-bundle-spec"])

	requireSecretCollector(t, supportBundle, "dp-config-secret", "onprem-dataplane.config.yaml", true)
}

func TestSupportPackageSpecsRenderInExternalMode(t *testing.T) {
	rendered := helmTemplate(t,
		"--show-only", "templates/support-package.yaml",
		"--set", "identityService.mode=external",
		"--set", "identityService.external.baseURL=https://suite-ids.example.com",
		"--set", "identityService.external.credential.existingSecret=ext-ids-cred",
	)

	configMaps := parseConfigMaps(t, rendered)
	supportBundleCM := findConfigMap(t, configMaps, "langcache-support-bundle")
	supportBundle := parseSupportBundleSpec(t, supportBundleCM.Data["support-bundle-spec"])

	require.Contains(t, supportBundleCM.Data["support-bundle-spec"], `"identityServiceMode": "external"`)

	// No bundled Identity Service means no metadata/control-token/runtime
	// Secrets and no IdS runPod checks: DP overlay, license, CP overlay,
	// admin token, internal token, external DP credential = 6.
	requireCollectorCount(t, supportBundle.Spec.Collectors, "secret", 6)
	// Only DP live+ready and CP live+ready = 4.
	requireCollectorCount(t, supportBundle.Spec.Collectors, "runPod", 4)

	requireSecretCollector(t, supportBundle, "ext-ids-cred", "token", false)

	for _, collector := range supportBundle.Spec.Collectors {
		if logs, ok := collector["logs"].(map[string]any); ok {
			require.NotContains(t, logs["name"], "identity-service")
		}
	}
}

func TestSupportPackageSpecsDoNotRenderWhenDisabled(t *testing.T) {
	rendered := helmTemplate(t, "--set", "supportPackage.enabled=false")

	configMaps := parseConfigMaps(t, rendered)
	for _, cm := range configMaps {
		if strings.HasSuffix(cm.Metadata.Name, "-support-bundle") || strings.HasSuffix(cm.Metadata.Name, "-support-redactors") {
			t.Fatalf("support-package ConfigMap rendered while supportPackage.enabled=false: %s", cm.Metadata.Name)
		}
	}
}

func TestSupportPackageRedactorsCoverLangCacheFixtures(t *testing.T) {
	spec := renderedRedactorSpec(t)

	requireRuleNames(t, spec, []string{
		"langcache-redis-url-credentials",
		"langcache-redis-url-query-parameters",
		"langcache-api-keys-and-tokens",
		"langcache-sensitive-field-values",
		"langcache-cache-content-fields",
		"langcache-private-keys-and-cert-material",
		"langcache-sensitive-yaml-paths",
	})

	fixture := `
profile: prod
metadata:
  urls:
    - rediss://meta-user:FIXTURE_METADATA_PASSWORD@metadata-redis.example.test:6380?token=FIXTURE_METADATA_QUERY_TOKEN
databases:
  target-a:
    name: Target A
    urls:
      - redis://cache-user:FIXTURE_CACHE_PASSWORD@cache-db.example.test:6379
auth:
  admin_token: FIXTURE_ADMIN_TOKEN
  agent_keys:
    introspection:
      credential:
        token: FIXTURE_INTROSPECTION_TOKEN
embedding:
  credentials:
    api_key: FIXTURE_EMBEDDING_API_KEY
entries:
  - prompt: "what is the capital of FIXTURE_PROMPT_CONTENT"
    response: "the answer is FIXTURE_RESPONSE_CONTENT"
license:
  contents: FIXTURE_LICENSE_CONTENT
tls_key: |-
  -----BEGIN RSA PRIVATE KEY-----
  FIXTURE_PRIVATE_KEY_MATERIAL
  -----END RSA PRIVATE KEY-----
`

	output, counts := applyRedactors(t, spec, fixture, true)

	sensitive := markers(
		"metadata redis password", "FIXTURE_METADATA_PASSWORD",
		"metadata redis query", "FIXTURE_METADATA_QUERY_TOKEN",
		"cache db password", "FIXTURE_CACHE_PASSWORD",
		"admin token", "FIXTURE_ADMIN_TOKEN",
		"introspection token", "FIXTURE_INTROSPECTION_TOKEN",
		"embedding api key", "FIXTURE_EMBEDDING_API_KEY",
		"prompt content", "FIXTURE_PROMPT_CONTENT",
		"response content", "FIXTURE_RESPONSE_CONTENT",
		"license content", "FIXTURE_LICENSE_CONTENT",
		"private key material", "FIXTURE_PRIVATE_KEY_MATERIAL",
	)
	requireNoSensitiveMarkers(t, output, sensitive)
	require.NotEmpty(t, counts, "expected at least one redactor rule to fire")

	// Ordinary structural field names must survive verbatim — the redactor
	// rules target specific key names (admin_token, api_key, token, prompt,
	// response, ...), not everything under auth/metadata/databases.
	requireSafeContains(t, output, "profile: prod")
	requireSafeContains(t, output, "name: Target A")
}

func TestSupportPackageRedactorYAMLPaths(t *testing.T) {
	spec := renderedRedactorSpec(t)

	requireYAMLPaths(t, spec, []string{
		"auth.admin_token",
		"auth.internal_token",
		"auth.agent_keys.introspection.credential",
		"runtime.service_credentials.*.token",
		"product_validation.*.credential.token",
		"embedding.credentials.api_key",
		"license",
		"prompt",
		"response",
		"entries",
		"attributes",
		"vector",
		"vectors",
	})

	// These are legitimate structural field/value names in LangCache's own
	// config and must not be blanket-redacted.
	requireNoYAMLPaths(t, spec, []string{
		"profile",
		"metadata",
		"databases",
		"server",
		"embedding",
		"client_pool",
		"client_side_cache",
	})
}

func renderedRedactorSpec(t *testing.T) redactorSpec {
	t.Helper()

	rendered := helmTemplate(t, "--show-only", "templates/support-package.yaml")
	configMaps := parseConfigMaps(t, rendered)
	redactorCM := findConfigMap(t, configMaps, "langcache-support-redactors")

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

func helmTemplate(t *testing.T, args ...string) string {
	t.Helper()

	out, err := runHelmTemplate(t, args...)
	if err != nil {
		t.Fatalf("helm template failed: %v\n%s", err, string(out))
	}

	return string(out)
}

func runHelmTemplate(t *testing.T, args ...string) ([]byte, error) {
	t.Helper()

	_, file, _, ok := runtime.Caller(0)
	require.True(t, ok)

	chartDir := filepath.Clean(filepath.Join(filepath.Dir(file), ".."))

	baseArgs := []string{
		"template", "langcache-fixture", chartDir,
		"--namespace", "langcache-fixture",
		"--set", "dataplane.image.tag=0.0.0-test",
		"--set", "controlplane.image.tag=0.0.0-test",
		"--set", "dataplane.license.existingSecret=license-test",
		"--set", "dataplane.secrets.secretName=dp-overlay-test",
		"--set", "controlplane.secrets.secretName=cp-overlay-test",
		"--set", "dataplane.embedding.endpoint.baseURL=https://embedding.example.test",
		"--set", "dataplane.embedding.models.defaultEmbeddingModel=fixture-model",
		"--set", "dataplane.embedding.models.dimensions=8",
		"--set", "identityService.bundled.image.tag=0.0.0-test",
		"--set", "identityService.bundled.metadata.existingSecret=ids-metadata-test",
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

	for _, cm := range configMaps {
		if cm.Metadata.Name == name {
			return cm
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

	for _, collector := range spec.Spec.Collectors {
		raw, ok := collector["secret"]
		if !ok {
			continue
		}

		typed, ok := raw.(map[string]any)
		require.True(t, ok)

		if typed["name"] == name && typed["key"] == key {
			require.Equal(t, includeValue, typed["includeValue"], "unexpected includeValue for Secret %q key %q", name, key)
			return
		}
	}

	t.Fatalf("secret collector for Secret %q key %q was not found", name, key)
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

	result := make([]sensitiveMarker, 0, len(items)/2)
	for i := 0; i < len(items); i += 2 {
		result = append(result, sensitiveMarker{name: items[i], value: items[i+1]})
	}

	return result
}

func requireNoSensitiveMarkers(t *testing.T, output string, markers []sensitiveMarker) {
	t.Helper()

	for _, marker := range markers {
		if strings.Contains(output, marker.value) {
			t.Fatalf("sensitive marker %q (%s) survived redaction", marker.name, marker.value)
		}
	}
}

func requireSafeContains(t *testing.T, output string, marker string) {
	t.Helper()

	require.Contains(t, output, marker, "expected safe operational marker %q to survive redaction", marker)
}
