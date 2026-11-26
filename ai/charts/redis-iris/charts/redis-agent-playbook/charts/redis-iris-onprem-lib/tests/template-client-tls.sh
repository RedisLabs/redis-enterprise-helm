#!/usr/bin/env bash
set -euo pipefail

# Rendered assertions for the shared Redis client certificate helpers
# (redis-onprem.redisClientTLS.*), against the current library source.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
cd "$REPO_ROOT"

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
assert_contains() { grep -qF -- "$2" <<<"$1" || fail "$3 (expected to find: $2)"; }
assert_absent() { ! grep -qF -- "$2" <<<"$1" || fail "$3 (expected NOT to find: $2)"; }
assert_fails() { # <description> <needle> <helm flags...>
  local description=$1 needle=$2 err
  shift 2
  if err=$(helm template fixture "$fixture" "$@" 2>&1 >/dev/null); then
    fail "$description (render succeeded)"
  elif ! grep -qF -- "$needle" <<<"$err"; then
    fail "$description (error does not name $needle: $err)"
  fi
}

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cp -R common/helm/lib/onprem/tests/fixtures/client-tls/. "$fixture/"
mkdir -p "$fixture/charts/redis-iris-onprem-lib"
cp common/helm/lib/onprem/Chart.yaml "$fixture/charts/redis-iris-onprem-lib/"
cp -R common/helm/lib/onprem/templates "$fixture/charts/redis-iris-onprem-lib/"

echo "== No redisClientTLS: nothing rendered =="
out=$(helm template fixture "$fixture")
assert_absent "$out" "redis-client-tls" "no Secret must mount nothing"
assert_absent "$out" "redis_client_tls" "no Secret must configure nothing"

echo "== Default and extra certificates: one read-only projected volume =="
out=$(helm template fixture "$fixture" \
  --set redisClientTLS.existingSecret=memory-client \
  --set 'redisClientTLS.extraCertificates[0].name=store-1' \
  --set 'redisClientTLS.extraCertificates[0].existingSecret=store-1-client')
assert_contains "$out" "cert_path: /etc/redis-client-tls/tls.crt" "config names the default certificate"
assert_contains "$out" "key_path: /etc/redis-client-tls/tls.key" "config names the default key"
assert_contains "$out" "mountPath: /etc/redis-client-tls" "the volume is mounted at the shared path"
assert_contains "$out" "readOnly: true" "the mount is read-only"
assert_absent "$out" "subPath" "a subPath mount would never see a renewed pair"
assert_contains "$out" "projected:" "the Secrets are projected into one volume"
assert_contains "$out" 'name: "memory-client"' "the default Secret is projected"
assert_contains "$out" 'name: "store-1-client"' "the extra Secret is projected"
assert_contains "$out" "path: store-1/tls.crt" "the extra certificate lands in its own directory"
assert_contains "$out" "path: store-1/tls.key" "the extra key lands in its own directory"

echo "== Extra certificates only: mounted, no default in the config =="
out=$(helm template fixture "$fixture" \
  --set 'redisClientTLS.extraCertificates[0].name=store-1' \
  --set 'redisClientTLS.extraCertificates[0].existingSecret=store-1-client')
assert_contains "$out" "path: store-1/tls.crt" "an extra certificate mounts without a default"
assert_absent "$out" "redis_client_tls" "without existingSecret there is no process default"

echo "== Invalid extra certificates fail the render =="
assert_fails "an invalid name must fail" "redisClientTLS.extraCertificates[0].name" \
  --set 'redisClientTLS.extraCertificates[0].name=Store_1' \
  --set 'redisClientTLS.extraCertificates[0].existingSecret=s'
assert_fails "a duplicate name must fail" "redisClientTLS.extraCertificates[1].name" \
  --set 'redisClientTLS.extraCertificates[0].name=a' --set 'redisClientTLS.extraCertificates[0].existingSecret=s' \
  --set 'redisClientTLS.extraCertificates[1].name=a' --set 'redisClientTLS.extraCertificates[1].existingSecret=t'
assert_fails "a missing Secret must fail" "redisClientTLS.extraCertificates[0].existingSecret" \
  --set 'redisClientTLS.extraCertificates[0].name=a'

if (( failures > 0 )); then
  echo "$failures client certificate rendering assertion(s) failed" >&2
  exit 1
fi
echo "All client certificate rendering assertions passed."
