// Package tests: guards against the nodeResources preflight analyzer blocks
// that templates/support-package.yaml embeds a second, hand-duplicated copy
// of (from templates/preflight.yaml) silently drifting apart. The three
// checks shared by both specs ("LangCache default minimum cluster CPU",
// "LangCache default minimum cluster memory", "LangCache recommended node
// spread") must stay byte-identical; preflight.yaml additionally has its own
// "LangCache single-pod schedulable node floor" check that support-package's
// spec intentionally does not carry.
package tests

import (
	"reflect"
	"testing"

	"gopkg.in/yaml.v3"
)

// nodeResourcesAnalyzersByCheckName renders `helm template -s <template>`,
// pulls the given ConfigMap's `data[dataKey]` (an embedded troubleshoot spec
// as a YAML string), and returns each `nodeResources` analyzer entry keyed
// by its checkName.
func nodeResourcesAnalyzersByCheckName(t *testing.T, template, configMapName, dataKey string) map[string]any {
	t.Helper()

	rendered := helmTemplate(t, "--show-only", template)
	configMaps := parseConfigMaps(t, rendered)
	cm := findConfigMap(t, configMaps, configMapName)

	var spec struct {
		Spec struct {
			Analyzers []map[string]any `yaml:"analyzers"`
		} `yaml:"spec"`
	}
	if err := yaml.Unmarshal([]byte(cm.Data[dataKey]), &spec); err != nil {
		t.Fatalf("failed to parse %s: %v", dataKey, err)
	}

	byCheckName := map[string]any{}

	for _, analyzer := range spec.Spec.Analyzers {
		nodeResources, ok := analyzer["nodeResources"].(map[string]any)
		if !ok {
			continue
		}

		checkName, _ := nodeResources["checkName"].(string)
		if checkName != "" {
			byCheckName[checkName] = nodeResources
		}
	}

	return byCheckName
}

func TestSupportPackageNodeResourcesChecksMatchPreflight(t *testing.T) {
	preflightChecks := nodeResourcesAnalyzersByCheckName(t, "templates/preflight.yaml", "langcache-preflight", "preflight-spec")
	supportChecks := nodeResourcesAnalyzersByCheckName(t, "templates/support-package.yaml", "langcache-support-bundle", "support-bundle-spec")

	shared := []string{
		"LangCache default minimum cluster CPU",
		"LangCache default minimum cluster memory",
		"LangCache recommended node spread",
	}

	for _, checkName := range shared {
		preflightCheck, ok := preflightChecks[checkName]
		if !ok {
			t.Fatalf("preflight.yaml no longer has a nodeResources check named %q", checkName)
		}

		supportCheck, ok := supportChecks[checkName]
		if !ok {
			t.Fatalf("support-package.yaml no longer has a nodeResources check named %q", checkName)
		}

		if !reflect.DeepEqual(preflightCheck, supportCheck) {
			t.Errorf("nodeResources check %q has drifted between templates/preflight.yaml and templates/support-package.yaml:\npreflight: %#v\nsupport:   %#v",
				checkName, preflightCheck, supportCheck)
		}
	}

	// support-package.yaml intentionally doesn't carry this one — assert
	// that stays true so a future edit that adds it there doesn't silently
	// skip being added to the `shared` list above too.
	if _, ok := supportChecks["LangCache single-pod schedulable node floor"]; ok {
		t.Error("support-package.yaml now has \"LangCache single-pod schedulable node floor\" too; add it to the `shared` list in this test")
	}
}
