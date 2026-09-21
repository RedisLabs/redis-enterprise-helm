#!/usr/bin/env bash
set -euo pipefail

# Rendered-chart assertions for the shared configuration-overlay helpers
# (redis-onprem.overlay*) as consumed by the product charts.
#
# A fixture always renders the current library source, independently of consumer
# pins and publication. Product renders additionally protect existing contracts.
#
# Usage: template-overlays.sh [--library-only]

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
cd "$REPO_ROOT"

RAM_BASE=(
  --set image.tag=0.0.0-test
  --set license.existingSecret=license-test
  --set config.existingSecret=config-test
  --set config.secretKey=config.yaml
  --set controlplane.image.tag=cp-0.0.0-test
  --set controlplane.config.existingSecret=cp-config-test
  --set identityService.image.tag=ids-0.0.0-test
  --set identityService.metadata.existingSecret=ids-metadata
)

LC_BASE=(
  --set dataplane.image.tag=0.0.0-test
  --set controlplane.image.tag=0.0.0-test
  --set dataplane.license.existingSecret=license-test
  --set dataplane.secrets.secretName=dp-base
  --set controlplane.secrets.secretName=cp-base
  --set dataplane.embedding.endpoint.baseURL=https://embedding.example.test
  --set dataplane.embedding.models.defaultEmbeddingModel=fixture-model
  --set dataplane.embedding.models.dimensions=8
  --set identityService.bundled.image.tag=0.0.0-test
  --set identityService.bundled.metadata.existingSecret=ids-metadata-test
)

failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

assert_contains() { # <rendered> <needle> <description>
  if ! grep -qF -- "$2" <<<"$1"; then
    fail "$3 (expected to find: $2)"
  fi
}

assert_scalar() { # <rendered> <field> <value> <description>
  if ! grep -qF -- "$2: $3" <<<"$1" && ! grep -qF -- "$2: \"$3\"" <<<"$1"; then
    fail "$4 (expected $2 to be $3)"
  fi
}

assert_absent() { # <rendered> <needle> <description>
  if grep -qF -- "$2" <<<"$1"; then
    fail "$3 (expected NOT to find: $2)"
  fi
}

assert_order() { # <rendered> <first> <second> <description>
  local first second
  first=$(grep -nF -- "$2" <<<"$1" | head -1 | cut -d: -f1 || true)
  second=$(grep -nF -- "$3" <<<"$1" | head -1 | cut -d: -f1 || true)
  if [[ -z "$first" || -z "$second" || "$first" -ge "$second" ]]; then
    fail "$4 (expected $2 before $3)"
  fi
}

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cp -R common/helm/lib/onprem/tests/fixtures/overlays/. "$fixture/"
mkdir -p "$fixture/charts/redis-iris-onprem-lib"
cp common/helm/lib/onprem/Chart.yaml "$fixture/charts/redis-iris-onprem-lib/"
cp -R common/helm/lib/onprem/templates "$fixture/charts/redis-iris-onprem-lib/"

echo "== Library source: empty, ordered, custom and YAML-sensitive overlays =="
out=$(helm template fixture "$fixture")
assert_absent "$out" "volumeMounts:" "empty overlays must not mount anything"
assert_absent "$out" '"--config"' "empty overlays must not add arguments"
assert_absent "$out" "volumes:" "empty overlays must not add volumes"

out=$(helm template fixture "$fixture" --set secrets.secretName=primary --set 'secrets.additionalSecrets={second,third}')
assert_contains "$out" 'secretName: "primary"' "source library renders the primary Secret"
assert_contains "$out" 'secretName: "third"' "source library renders additional Secrets"
assert_contains "$out" 'name: fixture-overlay-2' "source library preserves volume indexes"
assert_contains "$out" 'mountPath: /etc/fixture/overlays/2' "source library preserves mount bases"
assert_contains "$out" 'readOnly: true' "overlays must be read-only"
assert_absent "$out" 'subPath' "overlays must receive Secret rotations"
assert_order "$out" '"/etc/fixture/overlays/0/overlay.yaml"' '"/etc/fixture/overlays/1/overlay.yaml"' "primary precedes additional overlays"
assert_order "$out" '"/etc/fixture/overlays/1/overlay.yaml"' '"/etc/fixture/overlays/2/overlay.yaml"' "additional overlays retain input order"
checksum=$(printf '%s' '["primary","second","third"]' | sha256sum | cut -d' ' -f1)
assert_contains "$out" "checksum/overlays: \"$checksum\"" "checksum covers the ordered names"
reordered=$(helm template fixture "$fixture" --set secrets.secretName=primary --set 'secrets.additionalSecrets={third,second}')
assert_absent "$reordered" "$checksum" "reordering overlays must change the checksum"

for scalar in true null 123; do
  out=$(helm template fixture "$fixture" --set-string "secrets.secretName=$scalar,key=$scalar,path=$scalar")
  assert_contains "$out" "secretName: \"$scalar\"" "Secret name must remain a YAML string"
  assert_contains "$out" "key: \"$scalar\"" "Secret key must remain a YAML string"
  assert_contains "$out" "path: \"$scalar\"" "projected filename must remain a YAML string"
  assert_contains "$out" "\"/etc/fixture/overlays/0/$scalar\"" "custom filename must match the config argument"
done

out=$(helm template fixture "$fixture" --set 'secrets.additionalSecrets={only-additional}')
assert_contains "$out" 'secretName: "only-additional"' "additional overlays work without a primary"

if [[ "${1:-}" == "--library-only" ]]; then
  (( failures == 0 )) || exit 1
  echo "All library source assertions passed."
  exit 0
fi

echo "== RAM: no overlays renders no overlay volumes, mounts or args =="
out=$(helm template test memory/helm "${RAM_BASE[@]}")
assert_absent "$out" "config-overlay-0" "RAM without secrets.secretName must render no overlay volume"
assert_absent "$out" "/etc/ai/overlays/" "RAM without secrets.secretName must render no overlay mount"

echo "== RAM: a single overlay mounts read-only and is passed via --config =="
out=$(helm template test memory/helm "${RAM_BASE[@]}" --set secrets.secretName=ram-secret)
assert_contains "$out" "name: config-overlay-0" "RAM single overlay volume name"
assert_scalar "$out" secretName ram-secret "RAM single overlay Secret name"
assert_contains "$out" "mountPath: /etc/ai/overlays/0" "RAM single overlay mount path"
assert_contains "$out" "readOnly: true" "RAM overlay mounts are read-only"
assert_contains "$out" '"/etc/ai/overlays/0/overlay.yaml"' "RAM single overlay --config argument"
assert_absent "$out" "subPath" "overlay mounts must not use subPath, which would pin a rotated Secret's old inode"

echo "== RAM: multiple overlays keep secretName first, then additionalSecrets in order =="
out=$(helm template test memory/helm "${RAM_BASE[@]}" \
  --set secrets.secretName=ram-secret \
  --set 'secrets.additionalSecrets={eu-overlay,us-overlay}')
assert_scalar "$out" secretName ram-secret "RAM multi overlay keeps the primary Secret"
assert_scalar "$out" secretName eu-overlay "RAM multi overlay includes the first additional Secret"
assert_scalar "$out" secretName us-overlay "RAM multi overlay includes the second additional Secret"
assert_contains "$out" "mountPath: /etc/ai/overlays/2" "RAM multi overlay indexes mounts by position"
assert_order "$out" '"/etc/ai/overlays/0/overlay.yaml"' '"/etc/ai/overlays/1/overlay.yaml"' \
  "RAM overlay --config args must stay in merge order so later overlays win"
assert_order "$out" '"/etc/ai/overlays/1/overlay.yaml"' '"/etc/ai/overlays/2/overlay.yaml"' \
  "RAM overlay --config args must stay in merge order so later overlays win"

echo "== RAM: a custom overlayKey changes the Secret key, not the projected filename =="
out=$(helm template test memory/helm "${RAM_BASE[@]}" \
  --set secrets.secretName=ram-secret --set secrets.overlayKey=custom.yaml)
assert_scalar "$out" key custom.yaml "RAM custom overlayKey selects the Secret key"
assert_scalar "$out" path overlay.yaml "RAM custom overlayKey still projects as overlay.yaml"
assert_contains "$out" '"/etc/ai/overlays/0/overlay.yaml"' "RAM custom overlayKey leaves the --config path unchanged"

echo "== RAM: every consuming workload receives the overlay =="
for workload in deployment.yaml controlplane-deployment.yaml deployment-worker.yaml; do
  out=$(helm template test memory/helm "${RAM_BASE[@]}" --set secrets.secretName=ram-secret \
    --show-only "templates/$workload")
  assert_contains "$out" "config-overlay-0" "RAM $workload must mount the overlay"
done

echo "== LangCache: data plane and control plane keep separate prefixes and mount bases =="
out=$(helm template test langcache/helm "${LC_BASE[@]}" \
  --set dataplane.secrets.secretName=dp --set 'dataplane.secrets.additionalSecrets={dp-extra}' \
  --set controlplane.secrets.secretName=cp --set 'controlplane.secrets.additionalSecrets={cp-extra}')
assert_contains "$out" "name: dp-config-overlay-0" "LangCache data-plane overlay volume prefix"
assert_contains "$out" "name: cp-config-overlay-0" "LangCache control-plane overlay volume prefix"
assert_contains "$out" "mountPath: /etc/langcache/overlays/1" "LangCache data-plane overlay mount base"
assert_contains "$out" "mountPath: /etc/langcache-controlplane/overlays/1" "LangCache control-plane overlay mount base"
assert_order "$out" '"/etc/langcache/overlays/0/overlay.yaml"' '"/etc/langcache/overlays/1/overlay.yaml"' \
  "LangCache data-plane overlay args must stay in merge order"
assert_order "$out" '"/etc/langcache-controlplane/overlays/0/overlay.yaml"' '"/etc/langcache-controlplane/overlays/1/overlay.yaml"' \
  "LangCache control-plane overlay args must stay in merge order"

echo "== LangCache: per-tier custom overlay keys stay independent =="
out=$(helm template test langcache/helm "${LC_BASE[@]}" \
  --set dataplane.secrets.overlayKey=dp-custom.yaml \
  --set controlplane.secrets.overlayKey=cp-custom.yaml)
assert_scalar "$out" key dp-custom.yaml "LangCache data-plane custom overlayKey"
assert_scalar "$out" key cp-custom.yaml "LangCache control-plane custom overlayKey"

if (( failures > 0 )); then
  echo "$failures overlay rendering assertion(s) failed" >&2
  exit 1
fi

echo "All overlay rendering assertions passed."
