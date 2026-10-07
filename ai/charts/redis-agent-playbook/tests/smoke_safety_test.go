package helm_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"go.yaml.in/yaml/v3"
)

func TestSmokeRefusesAnUnselectedKindContext(t *testing.T) {
	commands := smokeCommandFixture(t, "eks-production", "already-exists")
	err := exec.CommandContext(t.Context(), "bash", "kind-smoke.sh").Run()
	require.Error(t, err)
	require.NotContains(t, readCommands(t, commands), "create namespace")
	require.NotContains(t, readCommands(t, commands), "delete namespace")
}

func TestSmokeDoesNotDeleteAnExistingNamespace(t *testing.T) {
	commands := smokeCommandFixture(t, "kind-playbook-onprem", "already-exists")
	err := exec.CommandContext(t.Context(), "bash", "kind-smoke.sh").Run()
	require.Error(t, err)
	require.Contains(t, readCommands(t, commands), "create namespace")
	require.NotContains(t, readCommands(t, commands), "delete namespace")
}

func TestSmokeCleansItsOwnNamespaceAfterSetupFailure(t *testing.T) {
	commands := smokeCommandFixture(t, "kind-playbook-onprem", "created")
	err := exec.CommandContext(t.Context(), "bash", "kind-smoke.sh").Run()
	require.Error(t, err)
	recorded := readCommands(t, commands)
	require.Contains(t, recorded, "--context kind-playbook-onprem create namespace playbook-kind-smoke")
	require.Contains(t, recorded, "--context kind-playbook-onprem -n playbook-kind-smoke get pods")
	require.Contains(t, recorded, "--context kind-playbook-onprem delete namespace playbook-kind-smoke")
}

func smokeCommandFixture(t *testing.T, currentContext, namespaceState string) string {
	t.Helper()
	directory := t.TempDir()
	commands := filepath.Join(directory, "commands")
	require.NoError(t, os.WriteFile(commands, nil, 0o600))
	t.Setenv("PATH", directory+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("PLAYBOOK_KIND_CONTEXT", "kind-playbook-onprem")
	t.Setenv("PLAYBOOK_KIND_NAMESPACE", "playbook-kind-smoke")
	t.Setenv("TEST_CURRENT_CONTEXT", currentContext)
	t.Setenv("TEST_NAMESPACE_STATE", namespaceState)
	t.Setenv("TEST_COMMANDS", commands)
	require.NoError(t, os.WriteFile(filepath.Join(directory, "kubectl"), []byte(`#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_COMMANDS"
if [ "$1" = config ]; then
  printf '%s\n' "$TEST_CURRENT_CONTEXT"
  exit 0
fi
[ "$1" = --context ] || exit 2
shift 2
if [ "$1" = create ]; then
  [ "$TEST_NAMESPACE_STATE" = created ]
elif [ "$1" = -n ] && [ "$3" = apply ]; then
  exit 1
fi
`), 0o700))

	return commands
}

func readCommands(t *testing.T, path string) string {
	t.Helper()

	commands, err := os.ReadFile(path)
	require.NoError(t, err)

	return string(commands)
}

// Exercise the actual smoke script against objects rendered by Helm. The fake
// cluster serves those objects, so a reconstructed, untruncated name fails.
func TestSmokeFindsRenderedCredentialsAndServicesForLongReleaseNames(t *testing.T) {
	for _, release := range []string{"playbook-smoke", strings.Repeat("r", 18), strings.Repeat("r", 27), strings.Repeat("r", 53)} {
		t.Run(release, func(t *testing.T) {
			command := exec.CommandContext(t.Context(), "helm", "template", release, "..", "-f", "values-test.yaml",
				"--set-string", "controlplane.adminToken.existingSecret=",
				"--set-string", "controlplane.internalToken.existingSecret=",
				"--set-string", "identityService.controlToken.existingSecret=",
				"--set-string", "identityService.runtimeToken.existingSecret=")
			rendered, err := command.Output()
			require.NoError(t, err)
			directory := t.TempDir()
			resources := filepath.Join(directory, "resources")
			require.NoError(t, os.Mkdir(resources, 0o700))

			lists := map[string][]map[string]any{}
			decoder := yaml.NewDecoder(bytes.NewReader(rendered))

			for {
				var object map[string]any

				err := decoder.Decode(&object)
				if errors.Is(err, io.EOF) {
					break
				}

				require.NoError(t, err)

				kind := object["kind"]
				if kind != "Secret" && kind != "Service" {
					continue
				}

				metadata := object["metadata"].(map[string]any)
				name := metadata["name"].(string)
				labels := metadata["labels"].(map[string]any)
				require.Equal(t, release, labels["app.kubernetes.io/instance"])
				component := labels["app.kubernetes.io/component"].(string)

				resource := "services"
				if kind == "Secret" {
					resource = "secrets"
					token := object["data"].(map[string]any)["token"].(string)
					decoded, err := base64.StdEncoding.DecodeString(token)
					require.NoError(t, err)

					if strings.HasSuffix(name, "-admin-token") {
						t.Setenv("TEST_CP_TOKEN", string(decoded))
					}

					if strings.HasSuffix(name, "-control-token") {
						t.Setenv("TEST_IDS_TOKEN", string(decoded))
					}
				}

				encoded, err := json.Marshal(object)
				require.NoError(t, err)
				require.NoError(t, os.WriteFile(filepath.Join(resources, name), encoded, 0o600))

				lists[resource] = append(lists[resource], object)
				lists[resource+"-"+component] = append(lists[resource+"-"+component], object)
			}

			for name, items := range lists {
				encoded, err := json.Marshal(map[string]any{"items": items})
				require.NoError(t, err)
				require.NoError(t, os.WriteFile(filepath.Join(resources, name), encoded, 0o600))
			}

			writeCommand := func(name, body string) {
				t.Helper()
				require.NoError(t, os.WriteFile(filepath.Join(directory, name), []byte("#!/usr/bin/env bash\nset -euo pipefail\n"+body), 0o700))
			}
			writeCommand("kubectl", `
if [ "$1" = config ]; then echo kind-playbook-onprem; exit; fi
[ "$1" = --context ] || exit 2
shift 2
if [ "$1" = -n ]; then shift 2; fi
case "$1" in
  get)
    resource="$2"; shift 2
    if [ "$resource" = secret ]; then cat "$TEST_RESOURCES/$1"; exit; fi
    [ "$1" = -l ] || exit 2
    selector="$2"
    [ "${selector%%,*}" = "app.kubernetes.io/instance=$PLAYBOOK_KIND_RELEASE" ] || exit 2
    file="$resource"
    if [[ "$selector" == *,* ]]; then file="$file-${selector##*=}"; fi
    cat "$TEST_RESOURCES/$file"
    ;;
  port-forward)
    [ "$2" = --address ] || exit 2
    test -f "$TEST_RESOURCES/${4#service/}"
    touch "$TEST_RESOURCES/forwarded-${4#service/}"
    ;;
  apply) cat >/dev/null ;;
esac
`)
			writeCommand("helm", "exit 0\n")
			writeCommand("python3", `
[ "$PLAYBOOK_ADMIN_TOKEN" = "$TEST_CP_TOKEN" ]
[ "$PLAYBOOK_IDS_CONTROL_TOKEN" = "$TEST_IDS_TOKEN" ]
for attempt in {1..100}; do
  forwards=("$TEST_RESOURCES"/forwarded-*)
  if [ "${#forwards[@]}" = 3 ]; then break; fi
  sleep 0.01
done
[ "${#forwards[@]}" = 3 ]
touch "$TEST_SMOKE_REACHED"
`)
			t.Setenv("PATH", directory+string(os.PathListSeparator)+os.Getenv("PATH"))
			t.Setenv("TEST_RESOURCES", resources)
			t.Setenv("TEST_SMOKE_REACHED", filepath.Join(directory, "smoke-reached"))
			t.Setenv("PLAYBOOK_KIND_RELEASE", release)
			t.Setenv("PLAYBOOK_KIND_CONTEXT", "kind-playbook-onprem")
			t.Setenv("PLAYBOOK_KIND_CHART", "")
			output, err := exec.CommandContext(t.Context(), "bash", "kind-smoke.sh").CombinedOutput()
			require.NoError(t, err, string(output))
			require.FileExists(t, filepath.Join(directory, "smoke-reached"))
		})
	}
}
