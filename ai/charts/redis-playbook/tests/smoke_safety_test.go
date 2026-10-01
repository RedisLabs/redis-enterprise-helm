package helm_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
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
