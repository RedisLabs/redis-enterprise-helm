// Package tests: guards against the standalone pre-install preflight spec
// (support/langcache-preflight.yaml, used with `kubectl preflight` before the
// chart is installed) silently drifting from the chart-rendered preflight
// ConfigMap (templates/preflight.yaml, used after install). The two are
// intentionally byte-identical apart from the templated metadata.name, which
// is itself always the static "langcache-preflight" because the chart pins
// fullnameOverride — see README "Support bundles and preflight".
package tests

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestStandalonePreflightSpecMatchesRenderedConfigMap(t *testing.T) {
	rendered := helmTemplate(t, "--show-only", "templates/preflight.yaml")

	configMaps := parseConfigMaps(t, rendered)
	preflightCM := findConfigMap(t, configMaps, "langcache-preflight")

	embeddedSpec := preflightCM.Data["preflight-spec"]
	require.NotEmpty(t, embeddedSpec, "templates/preflight.yaml did not render a preflight-spec key")

	_, file, _, ok := runtime.Caller(0)
	require.True(t, ok)

	standalonePath := filepath.Join(filepath.Dir(file), "..", "support", "langcache-preflight.yaml")

	standaloneBytes, err := os.ReadFile(standalonePath)
	require.NoError(t, err)

	require.Equal(t, string(standaloneBytes), embeddedSpec+"\n",
		"support/langcache-preflight.yaml has drifted from the preflight-spec rendered by templates/preflight.yaml; "+
			"update both together (see the shared comment in each file)")
}
