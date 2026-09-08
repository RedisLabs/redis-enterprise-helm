// Package tests: guards against values.schema.json declaring a numeric
// constraint (e.g. "minimum") that contradicts the chart's own shipped
// default in values.yaml. `helm lint` treats a schema violation as a hard
// error even though it tolerates the required-value `fail()` calls in
// langcache.validate (those are logged as INFO, not failures) — so a schema/
// default mismatch is invisible to every test in this package that passes
// representative --set overrides, and only surfaces on a bare `helm lint`
// with no overrides at all. That's exactly what RedisLabs/redis-enterprise-helm's
// "AI Helm Lint" CI runs against the synced chart on every release, with no
// values file — see MOD-17459's langcache-onprem-v0.0.1-test dry run, where
// dataplane.embedding.models.dimensions (default 0, schema minimum 1) failed
// there despite passing every other check in this repo.
package tests

import (
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestBareHelmLintPassesWithNoOverrides(t *testing.T) {
	_, file, _, ok := runtime.Caller(0)
	require.True(t, ok)

	chartDir := filepath.Clean(filepath.Join(filepath.Dir(file), ".."))

	out, err := exec.Command("helm", "lint", chartDir).CombinedOutput()
	require.NoError(t, err, "helm lint langcache/helm with no --set overrides must pass — "+
		"this is exactly what RedisLabs/redis-enterprise-helm's CI runs against the synced chart. "+
		"A failure here almost always means a values.schema.json constraint contradicts a "+
		"deliberately-invalid required-value default (image.tag: \"\", dimensions: 0, etc.) in "+
		"values.yaml. Widen the schema constraint (e.g. minimum: 0 instead of minimum: 1) rather "+
		"than changing the default — langcache.validate still enforces the real requirement at "+
		"install/template time.\n\n%s", string(out))
}
