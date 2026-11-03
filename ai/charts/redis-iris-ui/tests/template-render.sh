#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CHART="$ROOT/iris/ui/helm"
VALUES="$CHART/tests/values-test.yaml"
OUT="$(mktemp)"
BARE_OUT="$(mktemp)"
trap 'rm -f "$OUT" "$BARE_OUT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_count() {
  local file="$1"
  local pattern="$2"
  local expected="$3"
  local actual
  actual="$(grep -F -c -- "$pattern" "$file" || true)"
  [ "$actual" = "$expected" ] || fail "expected $expected occurrences of '$pattern', got $actual"
}

assert_exact_count() {
  local file="$1"
  local line="$2"
  local expected="$3"
  local actual
  actual="$(grep -F -x -c -- "$line" "$file" || true)"
  [ "$actual" = "$expected" ] || fail "expected $expected exact occurrences of '$line', got $actual"
}

# Substring matches, so a multi-line expectation must appear as one block (grep -F would match any one line).
assert_contains() {
  [[ "$(cat "$1")" == *"$2"* ]] || fail "expected rendered output to contain '$2'"
}

assert_absent() {
  if [[ "$(cat "$1")" == *"$2"* ]]; then
    fail "rendered output must not contain '$2'"
  fi
}

helm lint "$CHART" >/dev/null
helm lint "$CHART" -f "$VALUES" >/dev/null
helm template ui-test "$CHART" -f "$VALUES" >"$OUT"
helm template ui-bare "$CHART" --set image.tag=0.0.0-test >"$BARE_OUT"

# Exact-line matches, not substring counts: "kind: Service" is itself a
# prefix of "kind: ServiceAccount", so a plain substring count would
# double-count the ServiceAccount as a Service.
assert_exact_count "$OUT" "kind: Deployment" 1
assert_exact_count "$OUT" "kind: Service" 1
assert_exact_count "$OUT" "kind: ServiceAccount" 1
assert_exact_count "$OUT" "kind: ConfigMap" 2

# SPA history fallback and the static health location, per AC2.
assert_contains "$OUT" "try_files \$uri \$uri/ /index.html;"
assert_contains "$OUT" "location = /healthz"
# Redirects must not carry the internal Host:8080 behind an Ingress.
assert_contains "$OUT" "absolute_redirect off;"

# The Ingress is opt-in: none by default, and the Service stays ClusterIP
# (nothing else is exposed).
assert_count "$OUT" "kind: Ingress" 0
assert_count "$BARE_OUT" "kind: Ingress" 0
assert_contains "$OUT" "type: ClusterIP"

# Rootless nginx (docs/standards/docker.md "Use Rootless images").
assert_count "$OUT" "runAsNonRoot: true" 2
assert_count "$OUT" "runAsUser: 101" 2

# The image tag override from the values fixture reaches the rendered Pod spec.
assert_contains "$OUT" "image: \"redislabs/iris-ui-gateway:0.0.0-test\""

# Deployment args explicitly match the base image's own default CMD (see
# templates/deployment.yaml for why this must be explicit).
assert_contains "$OUT" "- nginx"
assert_contains "$OUT" "- daemon off;"

# --- Phase 2: reverse proxy + runtime config (AC3, AC4, AC5) ---

# /config.json location, and one reverse-proxy block per configured
# product, with the prefix stripped and the upstream basePath substituted
# (AC3's prefix rewrite).
assert_contains "$OUT" "location = /config.json"
assert_contains "$OUT" 'location ~ ^/api/memory/(?<rest>.*)$ {'
assert_contains "$OUT" 'set $upstream "http://redis-agent-memory-controlplane-onprem.redis-agent-memory.svc.cluster.local:8080";'
assert_contains "$OUT" 'proxy_pass $upstream/$rest$is_args$args;' # memory routes: empty basePath
assert_contains "$OUT" 'location ~ ^/api/memory-tls/(?<rest>.*)$ {'
assert_contains "$OUT" 'set $upstream "https://memory-tls.redis-agent-memory.svc.cluster.local:8443";'
assert_contains "$OUT" 'location ~ ^/api/api-keys/(?<rest>.*)$ {'
assert_contains "$OUT" 'set $upstream "http://iris-identity-service.redis-ai.svc.cluster.local:9200";'
assert_contains "$OUT" 'location ~ ^/api/lens/(?<rest>.*)$ {'
assert_contains "$OUT" 'set $upstream "https://lens-dataplane.lens.svc.cluster.local:9000";'
assert_absent "$OUT" 'proxy_pass $upstream/iris/data/v1beta1/lens/instances/' # lens route: empty basePath, the SDK paths carry /iris/data/v1beta1/lens/instances/<id>
grep -F -A2 'location ~ ^/api/lens/(?<rest>.*)$ {' "$OUT" | grep -F -q 'proxy_pass $upstream/$rest$is_args$args;' ||
  fail "the lens route must proxy to the data plane root"
assert_contains "$OUT" 'location = /api/playbook/health/readiness {'
assert_contains "$OUT" 'location = /api/playbook-dp/health/readiness {'
assert_contains "$OUT" 'proxy_pass $upstream/health/readiness;'
assert_contains "$OUT" 'location ~ ^/api/playbook/(?<rest>.*)$ {'
assert_contains "$OUT" 'set $upstream "http://playbook-controlplane.redis-ai.svc.cluster.local:9200";'
assert_contains "$OUT" 'location ~ ^/api/playbook-dp/(?<rest>.*)$ {'
assert_contains "$OUT" 'location = /api/intent/health/readiness {'
assert_contains "$OUT" 'location = /api/intent-data/health/readiness {'
assert_contains "$OUT" 'location ~ ^/api/intent/(?<rest>.*)$ {'
assert_contains "$OUT" 'location ~ ^/api/intent-data/(?<rest>.*)$ {'
assert_contains "$OUT" 'set $upstream "http://intent-redis-intent-router-controlplane.redis-ai.svc.cluster.local:9400";'
assert_contains "$OUT" 'set $upstream "http://intent-redis-intent-router-dataplane.redis-ai.svc.cluster.local:9401";'
assert_contains "$OUT" 'location = /api/context-gateway/health/readiness {'
assert_contains "$OUT" 'location ~ ^/api/context-gateway/(?<rest>.*)$ {'
assert_contains "$OUT" 'set $upstream "http://context-gateway-controlplane.redis-ai.svc.cluster.local:9100";'
assert_contains "$OUT" 'location = /api/context-gateway-dp/health/liveness {'
assert_contains "$OUT" 'location ~ ^/api/context-gateway-dp/(?<rest>.*)$ {'
# protectedResourceMetadata: the RFC 9728 metadata location, GET only, ahead of the route's own
# regex location, since nginx takes the first regex location that matches.
CG_DP_METADATA_LOCATION='location ~ ^/api/context-gateway-dp/\.well-known/oauth-protected-resource/(?<rest>.*)$ {'
assert_count "$OUT" "$CG_DP_METADATA_LOCATION" 1
assert_count "$OUT" 'oauth-protected-resource' 2 # the location and its proxy_pass, on context-gateway-dp only
assert_contains "$OUT" 'proxy_pass $upstream/.well-known/oauth-protected-resource/$rest$is_args$args;'
assert_contains "$OUT" 'limit_except GET {'
METADATA_LINE=$(grep -n -F -- "$CG_DP_METADATA_LOCATION" "$OUT" | cut -d: -f1)
CG_DP_LINE=$(grep -n -F -- 'location ~ ^/api/context-gateway-dp/(?<rest>.*)$ {' "$OUT" | cut -d: -f1)
[ "$METADATA_LINE" -lt "$CG_DP_LINE" ] || fail "the metadata location must come before the context-gateway-dp location"
assert_contains "$OUT" 'set $upstream "http://context-gateway-dataplane.redis-ai.svc.cluster.local:8083";'
assert_contains "$OUT" 'set $upstream "http://playbook-dataplane.redis-ai.svc.cluster.local:9201";'
assert_absent "$OUT" 'proxy_pass $upstream/v1/$rest$is_args$args;' # Playbook routes: empty basePath, the SDK paths carry /iris/v1/agent-playbooks

# Deferred DNS resolution (via the envsubst'd ${NGINX_LOCAL_RESOLVERS}, not
# a literal resolver address) so any one product's Service being
# unresolvable at nginx startup doesn't crash-loop the whole gateway --
# only that product's route would 502 at request time.
assert_contains "$OUT" 'resolver ${NGINX_LOCAL_RESOLVERS} valid=10s;'
assert_contains "$OUT" "name: NGINX_ENTRYPOINT_LOCAL_RESOLVERS"
assert_contains "$OUT" "default.conf.template: |"
assert_contains "$OUT" "mountPath: /etc/nginx/templates/default.conf.template"

# https + mounted CA vs. https + documented insecure-skip (AC4) -- both
# forms must be reachable from the same chart, on different products.
assert_contains "$OUT" "proxy_ssl_trusted_certificate /etc/nginx/ca/memory-tls/ca.crt;"
assert_contains "$OUT" "proxy_ssl_verify on;"
assert_contains "$OUT" "proxy_ssl_verify off;"

# Health probes bypass basePath via their own exact-match location --
# regression for the bug where the prefix location's basePath substitution
# 404'd every probe.
assert_contains "$OUT" "location = /api/memory/health/readiness"
assert_contains "$OUT" 'set $upstream "http://redis-agent-memory-controlplane-onprem.redis-agent-memory.svc.cluster.local:8080";'
assert_contains "$OUT" 'proxy_pass $upstream/health/readiness;'
assert_absent "$OUT" 'proxy_pass $upstream/v1/health/readiness;'
# Same check on both https products.
assert_contains "$OUT" "location = /api/memory-tls/health/readiness"
assert_contains "$OUT" "location = /api/lens/health/readiness"
assert_contains "$OUT" 'proxy_pass $upstream/health/readiness;'
assert_exact_count "$OUT" "kind: Secret" 0 # no Secret rendered -- caSecretName only references a BYO Secret
assert_contains "$OUT" "secretName: memory-tls-ca"
assert_contains "$OUT" "name: ca-memory-tls"
assert_absent "$OUT" "ca-lens" # insecureSkipVerify needs no CA volume

# No proxy_set_header override for Authorization or X-API-Key anywhere --
# nginx's own default passthrough is relied on unchanged (AC5).
assert_absent "$OUT" "proxy_set_header Authorization"
assert_absent "$OUT" "proxy_set_header X-API-Key"
assert_contains "$OUT" "client_max_body_size 1048576;"
assert_contains "$OUT" "error_page 413 = @request_too_large;"
assert_contains "$OUT" "application/problem+json"
# Single origin, no CORS ever added.
assert_absent "$OUT" "Access-Control-Allow"

# /config.json's contents match iris/ui/src/types/config.ts's ProductConfig
# exactly -- upstream host/port/basePath/scheme/caSecretName must never leak
# into the SPA-facing config.
assert_contains "$OUT" "\"key\": \"memory\""
assert_contains "$OUT" "\"authScheme\": \"apiKey\""
assert_contains "$OUT" "\"healthPath\": \"/health/readiness\""
assert_contains "$OUT" '"key": "playbook"'
assert_absent "$OUT" '"key": "playbook-dp"'
assert_contains "$OUT" '"key": "context-gateway"'
assert_absent "$OUT" '"key": "context-gateway-dp"'
assert_contains "$OUT" '"key": "api-keys"'
assert_contains "$OUT" '"instanceId": "test"'
assert_count "$OUT" '"instanceId"' 1 # only the lens route sets one
assert_absent "$OUT" "\"upstream\""
assert_absent "$OUT" "\"host\": \"redis-agent-memory-controlplane-onprem.redis-agent-memory.svc.cluster.local\""
assert_absent "$OUT" "\"basePath\""

# Edge case: zero products (values.yaml's own default) still renders a
# valid, empty runtime config and no /api/* blocks -- not an error.
assert_contains "$BARE_OUT" "config.json: |"
assert_contains "$BARE_OUT" "[]"
assert_absent "$BARE_OUT" "/api/"

# Edge case: a duplicate products[].key must fail fast at render time --
# without this guard, helm install succeeds but the resulting nginx.conf has
# two identical `location /api/<key>/` blocks, which crash-loops the pod
# with `nginx: [emerg] duplicate location` instead of a clear install error.
DUP_ERR="$(mktemp)"
if helm template ui-dup-key-test "$CHART" --set image.tag=0.0.0-test \
  --set 'products[0].key=memory' --set 'products[0].label=A' --set 'products[0].product=agent_memory' --set 'products[0].authScheme=bearer' --set 'products[0].healthPath=/health' \
  --set 'products[0].upstream.host=h1.ns.svc.cluster.local' --set 'products[0].upstream.port=1' --set 'products[0].upstream.basePath=/v1' --set 'products[0].upstream.scheme=http' \
  --set 'products[1].key=memory' --set 'products[1].label=B' --set 'products[1].product=agent_memory' --set 'products[1].authScheme=bearer' --set 'products[1].healthPath=/health' \
  --set 'products[1].upstream.host=h2.ns.svc.cluster.local' --set 'products[1].upstream.port=2' --set 'products[1].upstream.basePath=/v2' --set 'products[1].upstream.scheme=http' \
  >/dev/null 2>"$DUP_ERR"; then
  fail "expected helm template to reject duplicate products[].key values, but it succeeded"
fi
grep -q "is declared more than once" "$DUP_ERR" || fail "duplicate products[].key must fail with a clear message, got: $(cat "$DUP_ERR")"
rm -f "$DUP_ERR"

# Edge case: every products[] entry needs a `product` from the supported set
# (TDD AUTH-11). The schema rejects a missing or unknown value at render time.
expect_product_rejected() {
  local name="$1"
  shift
  local err
  err="$(mktemp)"
  if helm template ui-product-test "$CHART" --set image.tag=0.0.0-test \
    --set 'products[0].key=memory' --set 'products[0].label=A' --set 'products[0].authScheme=bearer' --set 'products[0].healthPath=/health' \
    --set 'products[0].upstream.host=h1.ns.svc.cluster.local' --set 'products[0].upstream.port=1' --set 'products[0].upstream.basePath=/v1' --set 'products[0].upstream.scheme=http' \
    "$@" >/dev/null 2>"$err"; then
    fail "expected helm template to reject $name, but it succeeded"
  fi
  grep -q "product" "$err" || fail "$name must fail on the product field, got: $(cat "$err")"
  rm -f "$err"
}
expect_product_rejected "a products entry without product"
expect_product_rejected "an unknown product" --set 'products[0].product=not-a-product'

# Edge case: the schema holds instanceId to the Lens chart's instance.id format.
INSTANCE_ERR="$(mktemp)"
if helm template ui-instance-test "$CHART" --set image.tag=0.0.0-test \
  --set 'products[0].key=lens' --set 'products[0].label=Lens' --set 'products[0].product=lens' --set 'products[0].authScheme=bearer' --set 'products[0].healthPath=/health' \
  --set 'products[0].instanceId=not/an-instance' \
  --set 'products[0].upstream.host=h1.ns.svc.cluster.local' --set 'products[0].upstream.port=1' --set 'products[0].upstream.basePath=' --set 'products[0].upstream.scheme=http' \
  >/dev/null 2>"$INSTANCE_ERR"; then
  fail "expected helm template to reject an instanceId with a slash, but it succeeded"
fi
grep -q "instanceId" "$INSTANCE_ERR" || fail "an invalid instanceId must fail on that field, got: $(cat "$INSTANCE_ERR")"
rm -f "$INSTANCE_ERR"

# Edge case: the Lens SDK paths carry /iris/data/v1beta1/lens/instances/<id>, so any lens basePath
# (the pre-MOD-19898 one or a typo) would prefix every read and 404 it.
for base_path in /iris/data/v1beta1/lens/instances/test /iris/v1beta1/lens/instance/test; do
  LENS_BASE_ERR="$(mktemp)"
  if helm template ui-lens-base-test "$CHART" --set image.tag=0.0.0-test \
    --set 'products[0].key=lens' --set 'products[0].label=Lens' --set 'products[0].product=lens' --set 'products[0].authScheme=bearer' --set 'products[0].healthPath=/health' \
    --set 'products[0].upstream.host=h1.ns.svc.cluster.local' --set 'products[0].upstream.port=1' --set "products[0].upstream.basePath=$base_path" --set 'products[0].upstream.scheme=http' \
    >/dev/null 2>"$LENS_BASE_ERR"; then
    fail "expected helm template to reject lens basePath $base_path, but it succeeded"
  fi
  grep -q "must be empty for a lens route" "$LENS_BASE_ERR" || fail "lens basePath $base_path must fail with a clear message, got: $(cat "$LENS_BASE_ERR")"
  rm -f "$LENS_BASE_ERR"
done

# Edge case: nginx's `listen` and the container's containerPort must stay
# fixed at 8080 regardless of .Values.service.port -- nginx runs as uid 101
# with every capability dropped, so it can never bind a privileged port
# (<1024) inside the container. The Service's own exposed port is the only
# thing .Values.service.port should ever change (targetPort resolves to the
# container's "http"-named port either way, so this stays wired correctly).
PORT_OUT="$(mktemp)"
helm template ui-port-test "$CHART" --set image.tag=0.0.0-test --set service.port=9090 >"$PORT_OUT"
assert_contains "$PORT_OUT" "listen 8080;"
assert_contains "$PORT_OUT" "containerPort: 8080"
assert_contains "$PORT_OUT" "port: 9090"
assert_absent "$PORT_OUT" "listen 9090;"
rm -f "$PORT_OUT"

# Edge case: an unset image.tag must fail closed at helm template/install
# time (a real deploy operation), matching every sibling on-prem chart's
# `required "...image.tag is required" ...` convention -- without this,
# `helm install` would succeed and render `image: "repo:"`, an invalid
# image reference that only surfaces later as ImagePullBackOff.
TAG_ERR="$(mktemp)"
if helm template ui-tag-test "$CHART" >/dev/null 2>"$TAG_ERR"; then
  fail "expected helm template to reject an unset image.tag, but it succeeded"
fi
grep -q "image.tag is required" "$TAG_ERR" || fail "unset image.tag must fail with a clear message, got: $(cat "$TAG_ERR")"
rm -f "$TAG_ERR"
# bare `helm lint` still "passes" (required() is INFO-only there), matching
# the sibling charts' own bare_lint_test.go convention -- this is the
# resolved intent of that check, not a regression of it.
helm lint "$CHART" >/dev/null

# Edge case: every rendered resource name must stay within Kubernetes'
# 63-character DNS label limit even for a long release name -- the
# runtime-config ConfigMap's helper previously truncated to 49 chars before
# appending the 15-character "-runtime-config" suffix (64 total, one over).
# tests.enabled=true so the health-test Pod name (also suffix-truncated) is
# actually included in this check, not silently skipped.
LONG_RELEASE="release-forty-three-chars-long-exactly-ok"
NAME_OUT="$(mktemp)"
helm template "$LONG_RELEASE" "$CHART" --set image.tag=0.0.0-test --set tests.enabled=true >"$NAME_OUT"
LONGEST_NAME="$(grep -E '^  name: ' "$NAME_OUT" | sed 's/^  name: //' | awk '{ print length, $0 }' | sort -rn | head -1 | cut -d' ' -f2-)"
LONGEST_LEN="$(printf '%s' "$LONGEST_NAME" | wc -c | tr -d ' ')"
[ "$LONGEST_LEN" -le 63 ] || fail "rendered name '$LONGEST_NAME' is $LONGEST_LEN chars, over Kubernetes' 63-char DNS label limit"
rm -f "$NAME_OUT"

# Edge case: a trailing slash on upstream.basePath must fail fast -- the
# reverse-proxy block always appends its own trailing slash, so "/v1/"
# would double up to "/v1//" in proxy_pass, which upstreams (e.g. Go's
# http.ServeMux) actually redirect on rather than silently normalize.
for BAD_BASE_PATH in "/v1/" "/"; do
  SLASH_ERR="$(mktemp)"
  if helm template ui-slash-test "$CHART" --set image.tag=x \
    --set 'products[0].key=memory' --set 'products[0].label=A' --set 'products[0].product=agent_memory' --set 'products[0].authScheme=bearer' --set 'products[0].healthPath=/health' \
    --set 'products[0].upstream.host=h1.ns.svc.cluster.local' --set 'products[0].upstream.port=1' --set "products[0].upstream.basePath=${BAD_BASE_PATH}" --set 'products[0].upstream.scheme=http' \
    >/dev/null 2>"$SLASH_ERR"; then
    fail "expected helm template to reject basePath '${BAD_BASE_PATH}', but it succeeded"
  fi
  grep -q "must not end with" "$SLASH_ERR" || fail "trailing-slash basePath must fail with a clear message, got: $(cat "$SLASH_ERR")"
  rm -f "$SLASH_ERR"
done

# Edge case: a non-empty upstream.basePath must start with "/".
RELATIVE_ERR="$(mktemp)"
if helm template ui-relative-test "$CHART" --set image.tag=x \
  --set 'products[0].key=memory' --set 'products[0].label=A' --set 'products[0].product=agent_memory' --set 'products[0].authScheme=bearer' --set 'products[0].healthPath=/health' \
  --set 'products[0].upstream.host=h1.ns.svc.cluster.local' --set 'products[0].upstream.port=1' --set 'products[0].upstream.basePath=v1' --set 'products[0].upstream.scheme=http' \
  >/dev/null 2>"$RELATIVE_ERR"; then
  fail "expected helm template to reject basePath 'v1', but it succeeded"
fi
grep -q "basePath" "$RELATIVE_ERR" || fail "a basePath without a leading slash must fail on basePath, got: $(cat "$RELATIVE_ERR")"
rm -f "$RELATIVE_ERR"

# Edge case: a bare (unqualified) upstream.host must fail fast -- nginx's own
# resolver never applies Kubernetes' DNS search-domain suffixing the way the
# OS resolver does, so a short Service name that "works" against Docker's
# own embedded DNS (see lifecycle.sh) would 502 in a real cluster instead of
# failing clearly at install time.
HOST_ERR="$(mktemp)"
if helm template ui-host-test "$CHART" --set image.tag=x \
  --set 'products[0].key=memory' --set 'products[0].label=A' --set 'products[0].product=agent_memory' --set 'products[0].authScheme=bearer' --set 'products[0].healthPath=/health' \
  --set 'products[0].upstream.host=bare-service-name' --set 'products[0].upstream.port=1' --set 'products[0].upstream.basePath=/v1' --set 'products[0].upstream.scheme=http' \
  >/dev/null 2>"$HOST_ERR"; then
  fail "expected helm template to reject a bare upstream.host, but it succeeded"
fi
grep -q "fully-qualified" "$HOST_ERR" || fail "a bare upstream.host must fail with a clear message, got: $(cat "$HOST_ERR")"
rm -f "$HOST_ERR"

# The helm-test health-check hook is opt-in (tests.enabled=false by
# default) and absent otherwise, matching every sibling on-prem chart's
# convention of not shipping test Pods in a normal install.
assert_count "$OUT" "kind: Pod" 0
assert_count "$BARE_OUT" "kind: Pod" 0

TESTS_OUT="$(mktemp)"
helm template ui-tests-test "$CHART" --set image.tag=0.0.0-test --set tests.enabled=true >"$TESTS_OUT"
assert_contains "$TESTS_OUT" "kind: Pod"
assert_contains "$TESTS_OUT" "helm.sh/hook: test"
assert_contains "$TESTS_OUT" "curl --fail --silent --show-error http://ui-tests-test-redis-iris-ui:8080/healthz"
rm -f "$TESTS_OUT"

# --- Optional Ingress and public URL (MOD-19445) ---

# Enabled: one host rule, path "/", backend the UI Service's port (which
# follows service.port, not the fixed container port), class and TLS from values.
ING_OUT="$(mktemp)"
helm template ui-ing "$CHART" --set image.tag=0.0.0-test \
  --set ingress.enabled=true --set ingress.host=iris.example.internal \
  --set ingress.className=customer-class --set ingress.tls.secretName=iris-tls \
  --set service.port=9090 >"$ING_OUT"
ING_ONLY="$(mktemp)"
helm template ui-ing "$CHART" --set image.tag=0.0.0-test \
  --set ingress.enabled=true --set ingress.host=iris.example.internal \
  --show-only templates/ingress.yaml >"$ING_ONLY"
assert_exact_count "$ING_OUT" "kind: Ingress" 1
assert_contains "$ING_OUT" "apiVersion: networking.k8s.io/v1"
assert_contains "$ING_OUT" "ingressClassName: customer-class"
assert_contains "$ING_OUT" 'host: "iris.example.internal"'
assert_contains "$ING_OUT" "path: /"
assert_contains "$ING_OUT" "pathType: Prefix"
assert_contains "$ING_OUT" "name: ui-ing-redis-iris-ui"
assert_contains "$ING_OUT" "number: 9090"
assert_contains "$ING_OUT" "secretName: iris-tls"
assert_contains "$ING_OUT" '- "iris.example.internal"'
assert_exact_count "$ING_OUT" "kind: Service" 1
assert_contains "$ING_OUT" "type: ClusterIP"
# The chart hard-codes no controller annotations.
assert_absent "$ING_OUT" "nginx.ingress.kubernetes.io"
assert_absent "$ING_ONLY" "annotations:"
rm -f "$ING_ONLY"

# No TLS Secret, no tls block; custom annotations pass through unchanged.
helm template ui-ing "$CHART" --set image.tag=0.0.0-test \
  --set ingress.enabled=true --set ingress.host=iris.example.internal \
  --set-string 'ingress.annotations.example\.com/setting=on' >"$ING_OUT"
assert_exact_count "$ING_OUT" "kind: Ingress" 1
assert_absent "$ING_OUT" "tls:"
assert_absent "$ING_OUT" "ingressClassName"
assert_contains "$ING_OUT" 'example.com/setting: "on"'
number_8080="$(grep -F -c -- "number: 8080" "$ING_OUT" || true)"
[ "$number_8080" = "1" ] || fail "default Ingress backend port must be the Service port 8080"

# An enabled Ingress needs a host.
HOST_REQ_ERR="$(mktemp)"
if helm template ui-ing "$CHART" --set image.tag=0.0.0-test --set ingress.enabled=true >/dev/null 2>"$HOST_REQ_ERR"; then
  fail "expected helm template to reject ingress.enabled without ingress.host, but it succeeded"
fi
grep -q "ingress.host is required" "$HOST_REQ_ERR" || fail "missing ingress.host must fail with a clear message, got: $(cat "$HOST_REQ_ERR")"
rm -f "$HOST_REQ_ERR" "$ING_OUT"

# ingress.host is a bare hostname: a scheme, port or path would only fail at apply time.
for BAD_HOST in "https://iris.example.internal" "iris.example.internal:8443" "iris.example.internal/ui"; do
  BAD_HOST_ERR="$(mktemp)"
  if helm template ui-ing "$CHART" --set image.tag=0.0.0-test --set ingress.enabled=true --set-string "ingress.host=${BAD_HOST}" >/dev/null 2>"$BAD_HOST_ERR"; then
    fail "expected helm template to reject ingress.host '${BAD_HOST}', but it succeeded"
  fi
  grep -q "must be a bare hostname" "$BAD_HOST_ERR" || fail "ingress.host '${BAD_HOST}' must fail with a clear message, got: $(cat "$BAD_HOST_ERR")"
  rm -f "$BAD_HOST_ERR"
done

# Only a ClusterIP Service is allowed.
SVC_ERR="$(mktemp)"
if helm template ui-svc "$CHART" --set image.tag=0.0.0-test --set service.type=NodePort >/dev/null 2>"$SVC_ERR"; then
  fail "expected helm template to reject a NodePort Service, but it succeeded"
fi
rm -f "$SVC_ERR"

# publicURL: https only, except host localhost on any port; a dedicated
# hostname with no path, query, fragment or credentials.
expect_public_url_rejected() {
  local url="$1"
  local expected="$2"
  local err
  err="$(mktemp)"
  if helm template ui-url "$CHART" --set image.tag=0.0.0-test --set-string "publicURL=${url}" >/dev/null 2>"$err"; then
    fail "expected helm template to reject publicURL '${url}', but it succeeded"
  fi
  grep -q "$expected" "$err" || fail "publicURL '${url}' must fail with '${expected}', got: $(cat "$err")"
  rm -f "$err"
}
expect_public_url_accepted() {
  helm template ui-url "$CHART" --set image.tag=0.0.0-test --set-string "publicURL=$1" >/dev/null ||
    fail "expected publicURL '$1' to render"
}
expect_public_url_rejected "http://example.com" "must start with https://"
expect_public_url_rejected "http://localhost.evil.com" "must start with https://"
expect_public_url_rejected "http://127.0.0.1" "must start with https://"
expect_public_url_rejected "ftp://iris.example.internal" "must start with https://"
expect_public_url_rejected "https://iris.example.internal/ui" "dedicated hostname"
expect_public_url_rejected "https://iris.example.internal?x=1" "dedicated hostname"
expect_public_url_rejected "https://user@iris.example.internal" "dedicated hostname"
expect_public_url_rejected "https://:443" "dedicated hostname"
expect_public_url_rejected "http://localhost:abc" "dedicated hostname"
expect_public_url_rejected "https://iris.example.internal:99999" "port must be between"
expect_public_url_rejected "https://iris.example.internal:0" "port must be between"
expect_public_url_accepted "http://localhost:5173"
expect_public_url_accepted "http://localhost"
expect_public_url_accepted "https://iris.example.internal"
expect_public_url_accepted "https://iris.example.internal:8443/"
# A leading zero is decimal, not octal.
expect_public_url_accepted "https://iris.example.internal:08443"

# One route's product limit must not cap or change another route's limit.
helm template ui-upload "$CHART" -f "$VALUES" --set 'products[0].maxRequestBodyBytes=16777216' >"$OUT"
assert_count "$OUT" "client_max_body_size 16777216;" 1
assert_count "$OUT" "client_max_body_size 8388608;" 1
assert_count "$OUT" "client_max_body_size 1048576;" 8

# Security headers on the SPA's pages and /config.json (TDD SEC-4). They do not
# depend on a session, so every render carries them, with SSO on or off. The SSO
# render below calls this same function.
SPA_CSP="add_header Content-Security-Policy \"default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; base-uri 'self'; form-action 'self'; frame-ancestors 'none'\" always;"
HSTS="add_header Strict-Transport-Security \"max-age=31536000\" always;"

# headers_in_location FILE LOCATION counts the add_header lines inside one location block.
headers_in_location() {
  awk -v loc="$2" 'index($0, loc) { on = 1 } on && /add_header/ { n++ } on && /^        }$/ { on = 0 } END { print n + 0 }' "$1"
}

assert_spa_security_headers() {
  local file="$1"
  local want_hsts="$2"
  local per_location=3
  [ "$want_hsts" = 1 ] && per_location=4

  assert_count "$file" "$SPA_CSP" 2
  assert_count "$file" 'add_header X-Content-Type-Options "nosniff" always;' 2
  assert_count "$file" 'add_header Referrer-Policy "same-origin" always;' 2
  assert_count "$file" "$HSTS" $((want_hsts * 2))

  [ "$(headers_in_location "$file" 'location = /config.json {')" = "$per_location" ] || fail "/config.json must carry exactly $per_location security headers"
  [ "$(headers_in_location "$file" 'location / {')" = "$per_location" ] || fail "the SPA location must carry exactly $per_location security headers"
  # A header on a proxied location would double the backend's own, and one on a
  # location that inherits nothing would silently drop the others.
  [ "$(grep -c 'add_header' "$file")" = $((per_location * 2)) ] || fail "security headers must appear only on the SPA and /config.json locations"
  [ "$(headers_in_location "$file" 'location ~ ^/api/memory/(?<rest>.*)$ {')" = 0 ] || fail "proxied API locations must not set security headers"
  [ "$(headers_in_location "$file" 'location = /healthz {')" = 0 ] || fail "/healthz must not set security headers"

  # No credentialed or wildcard CORS from the gateway (TDD SEC-1).
  assert_absent "$file" "Access-Control-"
}

helm template ui-headers "$CHART" -f "$VALUES" >"$OUT"
assert_spa_security_headers "$OUT" 0
assert_absent "$OUT" "Strict-Transport-Security"

helm template ui-headers "$CHART" -f "$VALUES" --set-string publicURL=https://iris.example.internal >"$OUT"
assert_spa_security_headers "$OUT" 1

helm template ui-headers "$CHART" -f "$VALUES" --set-string publicURL=http://localhost:5173 >"$OUT"
assert_spa_security_headers "$OUT" 0

# --- SSO: the UI auth service workload (MOD-19451) ---
SSO_VALUES="$CHART/tests/values-sso.yaml"
SSO_OUT="$(mktemp)"
sso_render() {
  helm template ui-sso "$CHART" -f "$VALUES" -f "$SSO_VALUES" "$@"
}

# SSO is off by default: no UI auth object renders, and the gateway objects are what they were.
assert_count "$OUT" "ui-auth" 0
helm template ui-bare "$CHART" -f "$VALUES" >"$OUT"
assert_count "$OUT" "ui-auth" 0
assert_count "$OUT" "kind: NetworkPolicy" 0
assert_exact_count "$OUT" "kind: Deployment" 1
assert_exact_count "$OUT" "kind: Secret" 0

# SSO on: one extra Deployment, Service and ConfigMap, the generated session Secret, a NetworkPolicy.
sso_render >"$SSO_OUT"
assert_exact_count "$SSO_OUT" "kind: Deployment" 2
assert_exact_count "$SSO_OUT" "kind: Service" 2
assert_exact_count "$SSO_OUT" "kind: ConfigMap" 3
assert_exact_count "$SSO_OUT" "kind: Secret" 1
assert_exact_count "$SSO_OUT" "kind: NetworkPolicy" 1
assert_contains "$SSO_OUT" "name: ui-sso-redis-iris-ui-auth-session-key"
assert_contains "$SSO_OUT" "image: \"redislabs/iris-ui-auth:0.0.0-test\""
assert_contains "$SSO_OUT" "path: /readyz"
assert_contains "$SSO_OUT" "path: /healthz"
assert_contains "$SSO_OUT" "runAsNonRoot: true"
assert_contains "$SSO_OUT" "readOnlyRootFilesystem: true"
# The two workloads are told apart by component, so neither Service selects the other's pods:
# ui-auth is on its Deployment (3), Service (2), ConfigMap, Secret and NetworkPolicy (2); gateway is
# on its Deployment (3), Service (2) and the NetworkPolicy's ingress source.
assert_count "$SSO_OUT" "app.kubernetes.io/component: ui-auth" 9
assert_count "$SSO_OUT" "app.kubernetes.io/component: gateway" 6

# Config: every route key with its product, the registered redirect base, mounted credential files.
assert_contains "$SSO_OUT" 'public_url: "https://iris.corp.example"'
assert_contains "$SSO_OUT" 'issuer_url: "https://idp.corp.example/realms/iris"'
assert_contains "$SSO_OUT" 'client_id: "iris-ui"'
assert_contains "$SSO_OUT" 'client_secret_file: "/etc/ui-auth/client/client-secret"'
assert_contains "$SSO_OUT" 'encryption_key_file: "/etc/ui-auth/session/key"'
assert_contains "$SSO_OUT" '  - key: "playbook-dp"'
assert_contains "$SSO_OUT" '  - key: "intent-data"'
assert_contains "$SSO_OUT" '    product: "intent"'
assert_contains "$SSO_OUT" '    product: "playbook"'
assert_contains "$SSO_OUT" '- "offline_access"'
assert_contains "$SSO_OUT" 'idle_timeout: "30m"'
assert_contains "$SSO_OUT" 'absolute_lifetime: "8h"'
# The Redis URL carries credentials: it is injected from a Secret, never rendered into a ConfigMap.
assert_contains "$SSO_OUT" "name: UIAUTH_SESSION_REDIS_URLS"
assert_contains "$SSO_OUT" "name: ui-auth-redis"
assert_absent "$SSO_OUT" "redis_url"
assert_absent "$SSO_OUT" "urls:"
# The audience is rendered (the service refuses a sign-in whose access token does not carry it);
# the default audience parameter and an unset access-token issuer are left out.
assert_contains "$SSO_OUT" 'audience: "api://redis-iris"'
assert_absent "$SSO_OUT" "audience_parameter"
assert_absent "$SSO_OUT" "access_token_issuer"
# The role claims and the product-keyed group-to-role mappings reach the service as given.
assert_contains "$SSO_OUT" '  role_claims:'
assert_contains "$SSO_OUT" '    - "groups"'
assert_contains "$SSO_OUT" 'role_mappings: {"agent_memory":{"iris-admins":"product_admin"},"playbook":{"iris-admins":"product_admin"}}'
sso_render --set 'sso.roleMappings=null' >"$SSO_OUT"
assert_absent "$SSO_OUT" "role_mappings"

# Per-IdP audience settings reach the service.
sso_render --set-string sso.audience=11111111-2222-3333-4444-555555555555 >"$SSO_OUT"
assert_contains "$SSO_OUT" 'audience: "11111111-2222-3333-4444-555555555555"'
sso_render --set sso.audienceParameter=audience >"$SSO_OUT"
assert_contains "$SSO_OUT" 'audience_parameter: "audience"'
sso_render --set sso.audienceParameter=resource >"$SSO_OUT"
assert_contains "$SSO_OUT" 'audience_parameter: "resource"'
sso_render --set sso.audienceParameter=none >"$SSO_OUT"
assert_absent "$SSO_OUT" "audience_parameter"

# The gateway's own security headers are the same with SSO on.
assert_spa_security_headers "$SSO_OUT" 1

# An operator-supplied session Secret is used as is: the chart generates nothing.
sso_render --set sso.session.existingSecret=my-session --set sso.session.secretKey=k >"$SSO_OUT"
assert_exact_count "$SSO_OUT" "kind: Secret" 0
assert_contains "$SSO_OUT" "secretName: my-session"
assert_contains "$SSO_OUT" 'encryption_key_file: "/etc/ui-auth/session/k"'

# private_key_jwt credential: the key file replaces the client secret.
sso_render --set sso.clientCredential.privateKeyKey=tls.key --set sso.clientCredential.privateKeyID=kid-1 >"$SSO_OUT"
assert_contains "$SSO_OUT" 'private_key_file: "/etc/ui-auth/client/tls.key"'
assert_contains "$SSO_OUT" 'private_key_id: "kid-1"'
assert_absent "$SSO_OUT" "client_secret_file"
assert_contains "$SSO_OUT" "- key: tls.key"

# Private CA: mounted where SSL_CERT_DIR points, in addition to the system roots.
sso_render --set sso.tls.caCertSecret=corp-ca >"$SSO_OUT"
assert_contains "$SSO_OUT" "name: SSL_CERT_DIR"
assert_contains "$SSO_OUT" "mountPath: /etc/ssl/custom"
assert_contains "$SSO_OUT" "secretName: corp-ca"
sso_render >"$SSO_OUT"
assert_absent "$SSO_OUT" "SSL_CERT_DIR"

# The image tag follows the gateway's unless set on its own.
# The auth service waits for Redis before it listens, so liveness starts after that wait.
sso_render >"$SSO_OUT"
assert_contains "$SSO_OUT" "initialDelaySeconds: 30"
sso_render --set uiAuth.livenessProbe.initialDelaySeconds=60 >"$SSO_OUT"
assert_contains "$SSO_OUT" "initialDelaySeconds: 60"

sso_render --set uiAuth.image.tag=9.9.9 >"$SSO_OUT"
assert_contains "$SSO_OUT" "image: \"redislabs/iris-ui-auth:9.9.9\""

# An access-token issuer may be http:// (AD FS) or https://.
sso_render --set sso.accessTokenIssuer=http://adfs.corp.example/adfs/services/trust >"$SSO_OUT" || fail "an http:// sso.accessTokenIssuer must render"
assert_contains "$SSO_OUT" 'access_token_issuer: "http://adfs.corp.example/adfs/services/trust"'

# NetworkPolicy: ingress only from the gateway pods by default; egress limited only when CIDRs are given.
sso_render >"$SSO_OUT"
assert_contains "$SSO_OUT" "kind: NetworkPolicy"
assert_exact_count "$SSO_OUT" "    - Ingress" 1
assert_exact_count "$SSO_OUT" "    - Egress" 0
assert_absent "$SSO_OUT" "ipBlock"
sso_render --set 'uiAuth.networkPolicy.egress={10.0.0.0/24,192.168.1.10/32}' >"$SSO_OUT"
assert_exact_count "$SSO_OUT" "    - Egress" 1
assert_contains "$SSO_OUT" 'cidr: "10.0.0.0/24"'
assert_contains "$SSO_OUT" 'cidr: "192.168.1.10/32"'
assert_contains "$SSO_OUT" "port: 53"
sso_render --set uiAuth.networkPolicy.enabled=false >"$SSO_OUT"
assert_count "$SSO_OUT" "kind: NetworkPolicy" 0

# Every rendered name stays within the 63-character limit, with the auth suffixes on a long release name.
sso_render >/dev/null
helm template "$LONG_RELEASE" "$CHART" -f "$VALUES" -f "$SSO_VALUES" >"$SSO_OUT"
LONGEST_NAME="$(grep -E '^  name: ' "$SSO_OUT" | sed 's/^  name: //' | awk '{ print length, $0 }' | sort -rn | head -1 | cut -d' ' -f2-)"
LONGEST_LEN="$(printf '%s' "$LONGEST_NAME" | wc -c | tr -d ' ')"
[ "$LONGEST_LEN" -le 63 ] || fail "SSO rendered name '$LONGEST_NAME' is $LONGEST_LEN chars, over Kubernetes' 63-char DNS label limit"

# Validation: each failure names the value to fix.
expect_sso_failure() {
  local message="$1"
  shift
  local err
  err="$(mktemp)"
  if sso_render "$@" >/dev/null 2>"$err"; then
    fail "expected helm template to reject: $message"
  fi
  grep -F -q -- "$message" "$err" || fail "expected failure containing '$message', got: $(cat "$err")"
  rm -f "$err"
}
# A development IdP over http:// is accepted only with the explicit opt-in, and reaches the service.
expect_sso_failure "an http:// issuer needs sso.allowInsecureTransport" --set-string sso.issuer=http://idp.localhost:8190/realms/iris
sso_render >"$SSO_OUT"
assert_absent "$SSO_OUT" "allow_insecure_transport"
sso_render --set-string sso.issuer=http://idp.localhost:8190/realms/iris --set sso.allowInsecureTransport=true >"$SSO_OUT"
assert_contains "$SSO_OUT" "allow_insecure_transport: true"
assert_contains "$SSO_OUT" 'issuer_url: "http://idp.localhost:8190/realms/iris"'
# The opt-in never makes a non-http(s) issuer valid.
expect_sso_failure "sso.issuer must be an https:// URL" --set sso.allowInsecureTransport=true --set-string sso.issuer=ftp://idp

expect_sso_failure "sso.enabled requires publicURL" --set-string publicURL=
expect_sso_failure "publicURL must start with https://" --set-string publicURL=http://iris.corp.example
expect_sso_failure "sso.issuer must be an https:// URL" --set-string sso.issuer=http://idp.corp.example
expect_sso_failure "sso.issuer must be an https:// URL" --set-string sso.issuer=
# The service refuses an issuer with credentials, a query or a fragment: fail here, not as a crash loop.
for BAD_ISSUER in "https://user@idp.corp.example/realms/iris" "https://idp.corp.example?tenant=x" "https://idp.corp.example/realms/iris#frag" "https://" "https://idp.corp.example/a b"; do
  expect_sso_failure "no credentials, query or fragment" --set-string "sso.issuer=${BAD_ISSUER}"
done
sso_render --set-string sso.issuer=https://idp.corp.example:8443/realms/iris >/dev/null || fail "an https issuer with a port and path must render"
sso_render --set-string sso.issuer=https://idp.corp.example >/dev/null || fail "an https issuer without a path must render"
expect_sso_failure "sso.clientId is required" --set-string sso.clientId=
expect_sso_failure "sso.scopes must include openid" --set 'sso.scopes={api://iris/.default}'
# An empty audience is unset and takes the shared default.
sso_render --set-string sso.audience= | grep -qF 'audience: "api://redis-iris"' || fail "an empty sso.audience must default to api://redis-iris"
expect_sso_failure "sso.clientCredential.existingSecret is required" --set-string sso.clientCredential.existingSecret=
expect_sso_failure "set sso.clientCredential.clientSecretKey" --set-string sso.clientCredential.clientSecretKey=
expect_sso_failure "sso.redis.existingSecret is required" --set-string sso.redis.existingSecret=
expect_sso_failure "sso.accessTokenIssuer must be an http:// or https:// URL" --set-string sso.accessTokenIssuer=ftp://x
# ui-auth refuses these at startup, so the chart must too.
for bad in 'https://sts.example/?tenant=x' 'https://sts.example/adfs#f' 'https://u:p@sts.example/adfs'; do
  expect_sso_failure "no credentials, query or fragment" --set-string "sso.accessTokenIssuer=$bad"
done
expect_sso_failure 'sso.roleMappings key "langcache" is not a product value used in products' --set 'sso.roleMappings.langcache.some-group=viewer'
# A mapping must name an Iris role and be keyed product, then group, as the product charts are.
expect_sso_failure 'roleMappings' --set 'sso.roleMappings.agent_memory.some-group=root'
# Schema failures.
expect_sso_failure "audienceParameter" --set-string sso.audienceParameter=bogus
expect_sso_failure "idleTimeout" --set-string sso.session.idleTimeout=soon
expect_sso_failure "idleTimeout" --set-string sso.session.idleTimeout=
expect_sso_failure "absoluteLifetime" --set-string sso.session.absoluteLifetime=
expect_sso_failure "idleTimeout" --set-string sso.session.idleTimeout=0s
expect_sso_failure "absoluteLifetime" --set-string sso.session.absoluteLifetime=000h
expect_sso_failure "secretKey" --set-string "sso.session.secretKey=a b"
expect_sso_failure "urlsKey" --set-string "sso.redis.urlsKey=a: b"
# Products are required with SSO on; the auth service only authorises the routes it is given.
SSO_NO_PRODUCTS_ERR="$(mktemp)"
if helm template ui-sso "$CHART" -f "$VALUES" -f "$SSO_VALUES" --set products=null >/dev/null 2>"$SSO_NO_PRODUCTS_ERR"; then
  fail "expected helm template to reject SSO without products"
fi
grep -q "requires at least one entry in products" "$SSO_NO_PRODUCTS_ERR" || fail "SSO without products must fail with a clear message, got: $(cat "$SSO_NO_PRODUCTS_ERR")"
rm -f "$SSO_NO_PRODUCTS_ERR" "$SSO_OUT"

# --- SSO: nginx auth_request wiring and the runtime config shape (MOD-19451) ---
SSO_OUT="$(mktemp)"
PRODUCT_ROUTES=$(grep -c '^  - key: ' "$SSO_VALUES") # every route in values-sso.yaml gets an auth_request
# Routes with protectedResourceMetadata (context-gateway-dp) also get an unchecked metadata location.
METADATA_ROUTES=$(grep -c '^    protectedResourceMetadata: true$' "$SSO_VALUES")
[ "$METADATA_ROUTES" -ge 1 ] || fail "values-sso.yaml must keep a protectedResourceMetadata route"

# SSO off: the nginx config carries none of the SSO wiring, and /config.json is the object shape
# with the product on every entry and SSO off.
helm template ui-bare "$CHART" -f "$VALUES" >"$OUT"
for DIRECTIVE in "ssoApiDirectives" "auth_request" "upstream ui_auth" "location /auth/" "_auth_check" "iris_token" 'proxy_set_header Cookie ""' 'proxy_set_header X-CSRF-Token ""'; do
  assert_absent "$OUT" "$DIRECTIVE"
done
assert_contains "$OUT" '"products": ['
assert_contains "$OUT" '"enabled": false'
# Routes with showInNavigation: false (playbook-dp, intent-data, context-gateway-dp) are not in /config.json.
navigation_routes() {
  echo $(( $(grep -c '^  - key: ' "$1") - $(grep -c '^    showInNavigation: false$' "$1" || true) ))
}
assert_count "$OUT" '"product": ' "$(navigation_routes "$VALUES")"
assert_count "$OUT" '"product": "context_gateway"' 1 # the control plane only: context-gateway-dp is hidden

# SSO on: /config.json says so.
sso_render >"$SSO_OUT"
assert_contains "$SSO_OUT" '"enabled": true'
assert_count "$SSO_OUT" '"product": ' "$(navigation_routes "$SSO_VALUES")"

# SSO on: the auth service upstream, the sign-in routes and the internal check.
assert_contains "$SSO_OUT" "upstream ui_auth {"
assert_contains "$SSO_OUT" "keepalive 16;"
assert_contains "$SSO_OUT" "location /auth/ {"
assert_contains "$SSO_OUT" "proxy_pass http://ui_auth;"
assert_contains "$SSO_OUT" "location = /_auth_check {"
assert_contains "$SSO_OUT" "proxy_pass http://ui_auth/internal/check;"
assert_count "$SSO_OUT" "internal;" 1
assert_contains "$SSO_OUT" "proxy_set_header X-Original-Method \$request_method;"
assert_contains "$SSO_OUT" "proxy_set_header X-Original-URI \$request_uri;"
assert_contains "$SSO_OUT" "proxy_buffer_size 16k;"
assert_contains "$SSO_OUT" "proxy_buffers 4 16k;"
assert_contains "$SSO_OUT" "client_max_body_size 64k;"
# The check drops only the body: the browser's Origin, Sec-Fetch-Site and X-CSRF-Token must reach the
# service, so the request headers are not switched off.
assert_contains "$SSO_OUT" "proxy_pass_request_body off;"
assert_absent "$SSO_OUT" "proxy_pass_request_headers off"
assert_absent "$SSO_OUT" 'proxy_set_header Origin'
assert_absent "$SSO_OUT" 'proxy_set_header Sec-Fetch-Site'

# SSO on: every product route is checked and gets the session's token instead of the browser's
# credentials, and the SPA, assets and /config.json are not checked. Health locations need no
# session but must not pass the session cookie to a product.
assert_count "$SSO_OUT" "auth_request /_auth_check;" "$PRODUCT_ROUTES"
assert_count "$SSO_OUT" 'auth_request_set $iris_token $upstream_http_x_auth_token;' "$PRODUCT_ROUTES"
assert_count "$SSO_OUT" 'proxy_set_header Authorization "Bearer $iris_token";' "$PRODUCT_ROUTES"
assert_count "$SSO_OUT" 'proxy_set_header Cookie "";' $((PRODUCT_ROUTES * 2 + METADATA_ROUTES))
assert_count "$SSO_OUT" 'proxy_set_header X-CSRF-Token "";' $((PRODUCT_ROUTES * 2 + METADATA_ROUTES))
assert_absent "$SSO_OUT" "proxy_set_header X-API-Key"

# SSO on: the Context Gateway data plane route stays session-checked like the control plane route,
# so /iris/data/v1/context-gateway/gateways/<id>/mcp needs a session through the UI. Only its RFC 9728 metadata location
# (protectedResourceMetadata) answers without one, for GET only, and with no credential or session
# cookie passed on.
location_block() {
  # ENVIRON, not -v: awk -v would read the backslash in a regex location as an escape.
  LOCATION_START="$2" awk 'index($0, ENVIRON["LOCATION_START"]) { found = 1 } found { print } found && /^[[:space:]]*}$/ { exit }' "$1"
}
CG_DP_BLOCK="$(mktemp)"
CG_CP_BLOCK="$(mktemp)"
CG_METADATA_BLOCK="$(mktemp)"
location_block "$SSO_OUT" 'location ~ ^/api/context-gateway-dp/(?<rest>.*)$ {' >"$CG_DP_BLOCK"
location_block "$SSO_OUT" 'location ~ ^/api/context-gateway/(?<rest>.*)$ {' >"$CG_CP_BLOCK"
location_block "$SSO_OUT" "$CG_DP_METADATA_LOCATION" >"$CG_METADATA_BLOCK"
for BLOCK in "$CG_DP_BLOCK" "$CG_CP_BLOCK"; do
  assert_contains "$BLOCK" "auth_request /_auth_check;"
  assert_contains "$BLOCK" 'proxy_set_header Authorization "Bearer $iris_token";'
  assert_contains "$BLOCK" 'proxy_set_header Cookie "";'
  assert_contains "$BLOCK" 'proxy_set_header X-CSRF-Token "";'
done
assert_contains "$CG_DP_BLOCK" 'set $upstream "http://context-gateway-dataplane.redis-ai.svc.cluster.local:8083";'
assert_contains "$CG_CP_BLOCK" 'set $upstream "http://context-gateway-controlplane.redis-ai.svc.cluster.local:9100";'
assert_contains "$CG_METADATA_BLOCK" 'set $upstream "http://context-gateway-dataplane.redis-ai.svc.cluster.local:8083";'
assert_contains "$CG_METADATA_BLOCK" 'proxy_pass $upstream/.well-known/oauth-protected-resource/$rest$is_args$args;'
assert_contains "$CG_METADATA_BLOCK" 'limit_except GET {'
assert_contains "$CG_METADATA_BLOCK" 'proxy_set_header Authorization "";'
assert_contains "$CG_METADATA_BLOCK" 'proxy_set_header Cookie "";'
assert_contains "$CG_METADATA_BLOCK" 'proxy_set_header X-CSRF-Token "";'
assert_absent "$CG_METADATA_BLOCK" "auth_request"
assert_absent "$CG_METADATA_BLOCK" "iris_token"
rm -f "$CG_DP_BLOCK" "$CG_CP_BLOCK" "$CG_METADATA_BLOCK"
CG_DP_INDEX=$(( $(grep '^  - key: ' "$SSO_VALUES" | grep -n 'context-gateway-dp$' | cut -d: -f1) - 1 ))
# The data plane route takes the session's bearer like any other, so apiKey is refused on it.
expect_sso_failure "products[context-gateway-dp].authScheme: apiKey is not supported with sso.enabled" --set "products[${CG_DP_INDEX}].authScheme=apiKey"
# The option is a boolean.
expect_sso_failure "protectedResourceMetadata" --set-string "products[${CG_DP_INDEX}].protectedResourceMetadata=yes"

# The gateway's own security headers are unchanged with SSO on.
assert_spa_security_headers "$SSO_OUT" 1

# Limits are configurable.
sso_render --set nginx.limits.authProxyBufferSize=32k --set 'nginx.limits.authProxyBuffers=8 32k' --set nginx.limits.authClientMaxBodySize=128k --set nginx.limits.authProxyReadTimeout=60s >"$SSO_OUT"
assert_contains "$SSO_OUT" "proxy_buffer_size 32k;"
assert_contains "$SSO_OUT" "proxy_buffers 8 32k;"
assert_contains "$SSO_OUT" "client_max_body_size 128k;"
assert_contains "$SSO_OUT" "proxy_read_timeout 60s;"

# The auth Service is plain HTTP in the cluster (it has no TLS listener), and the gateway resolves it at run
# time so a missing or recreated Service does not stop nginx from starting.
sso_render >"$SSO_OUT"
assert_absent "$SSO_OUT" "/etc/nginx/ca/ui-auth"
assert_absent "$SSO_OUT" "ca-ui-auth"
assert_absent "$SSO_OUT" "https://ui_auth"
assert_contains "$SSO_OUT" "zone ui_auth 64k;"
assert_contains "$SSO_OUT" 'resolver ${NGINX_LOCAL_RESOLVERS} valid=10s;'
assert_contains "$SSO_OUT" "server ui-sso-redis-iris-ui-auth.default.svc.cluster.local:9000 resolve;"
# nginx's resolver does not apply search domains, so the name is fully qualified and follows clusterDomain.
sso_render --set-string clusterDomain=k8s.corp.example >"$SSO_OUT"
assert_contains "$SSO_OUT" "server ui-sso-redis-iris-ui-auth.default.svc.k8s.corp.example:9000 resolve;"
sso_render >"$SSO_OUT"
assert_absent "$SSO_OUT" "uiAuth.service"
# /auth/ and /_auth_check carry the same header buffers: sign-in redirects and cookies are response headers.
assert_count "$SSO_OUT" "proxy_buffer_size 16k;" 2
assert_count "$SSO_OUT" "proxy_buffers 4 16k;" 2
assert_count "$SSO_OUT" "proxy_busy_buffers_size 16384;" 2
# A product keyed ui-auth no longer collides with anything of the auth service's.
sso_render --set 'products[0].key=ui-auth' >"$SSO_OUT" || fail "a product keyed ui-auth must render"
expect_sso_failure "authProxyBufferSize" --set-string nginx.limits.authProxyBufferSize=big
# nginx refuses a config whose proxy_busy_buffers_size is outside [max(header size, buffer size), all buffers minus one):
# the chart sets it explicitly, accepts consistent overrides, and rejects inconsistent ones at render time.
sso_render >"$SSO_OUT"
assert_contains "$SSO_OUT" "proxy_busy_buffers_size 16384;"
sso_render --set nginx.limits.authProxyBufferSize=32k >"$SSO_OUT"
assert_contains "$SSO_OUT" "proxy_busy_buffers_size 32768;"
sso_render --set-string 'nginx.limits.authProxyBuffers=4 8k' >"$SSO_OUT"
assert_contains "$SSO_OUT" "proxy_busy_buffers_size 16384;"
expect_sso_failure "is too large for nginx.limits.authProxyBuffers" --set nginx.limits.authProxyBufferSize=64k
expect_sso_failure "is too large for nginx.limits.authProxyBuffers" --set-string 'nginx.limits.authProxyBuffers=4 4k'
expect_sso_failure "authProxyBuffers" --set-string 'nginx.limits.authProxyBuffers=2 16k'
expect_sso_failure "products[memory-tls].authScheme: apiKey is not supported with sso.enabled" --set 'products[1].authScheme=apiKey'
rm -f "$SSO_OUT"

# A hidden Context Gateway route must still use the shared session. values-sso.yaml already lists
# context-gateway at index 5, so the case reshapes that entry instead of adding a second one.
sso_render \
  --set 'products[5].key=context-gateway' \
  --set 'products[5].label=Context Gateway' \
  --set 'products[5].product=context_gateway' \
  --set 'products[5].showInNavigation=false' \
  --set 'products[5].healthPath=/health/readiness' \
  --set 'products[5].upstream.host=context-gateway-controlplane.redis-ai.svc.cluster.local' \
  --set 'products[5].upstream.port=9100' \
  --set-string 'products[5].upstream.basePath=' \
  --set 'sso.roleMappings.context_gateway.gateway-viewers=viewer' \
  --set 'sso.roleMappings.context_gateway.gateway-operators=operator' \
  --set 'sso.roleMappings.context_gateway.gateway-admins=product_admin' \
  --set 'sso.roleMappings.context_gateway.iris-suite-admins=suite_admin' \
  >"$OUT" || fail "a hidden Context Gateway SSO route must render"
assert_contains "$OUT" '- key: "context-gateway"'
assert_contains "$OUT" 'product: "context_gateway"'
assert_contains "$OUT" '"context_gateway":{"gateway-admins":"product_admin","gateway-operators":"operator","gateway-viewers":"viewer","iris-suite-admins":"suite_admin"}'
assert_contains "$OUT" 'audience: "api://redis-iris"'
assert_contains "$OUT" 'location = /api/context-gateway/health/readiness {'
assert_absent "$OUT" '"key": "context-gateway"'
assert_absent "$OUT" '"product": "context_gateway"'

sed -n '/location ~.*\/api\/context-gateway\//,/^[[:space:]]*}/p' "$OUT" >"$BARE_OUT"
assert_contains "$BARE_OUT" 'location ~ ^/api/context-gateway/(?<rest>.*)$ {'
assert_contains "$BARE_OUT" 'auth_request /_auth_check;'
assert_contains "$BARE_OUT" 'auth_request_set $iris_token $upstream_http_x_auth_token;'
assert_contains "$BARE_OUT" 'proxy_set_header Authorization "Bearer $iris_token";'
assert_contains "$BARE_OUT" 'proxy_set_header Cookie "";'
assert_contains "$BARE_OUT" 'set $upstream "http://context-gateway-controlplane.redis-ai.svc.cluster.local:9100";'
assert_contains "$BARE_OUT" 'proxy_pass $upstream/$rest$is_args$args;'

# Derived upstream hosts (MOD-20389): upstream.service without host completes to a Service of the
# release namespace, under clusterDomain; under the umbrella a differing clusterDomain fails (MOD-20404).
service_render() {
  helm template ui-service-test "$CHART" --set image.tag=0.0.0-test \
    --set 'products[0].key=memory' --set 'products[0].label=Agent Memory' --set 'products[0].product=agent_memory' \
    --set 'products[0].authScheme=bearer' --set 'products[0].healthPath=/health/readiness' \
    --set 'products[0].upstream.port=9100' --set-string 'products[0].upstream.basePath=' --set 'products[0].upstream.scheme=https' \
    --set 'products[0].upstream.insecureSkipVerify=true' "$@"
}
service_render -n other-ns --set 'products[0].upstream.service=redis-agent-memory-controlplane' >"$OUT" \
  || fail "a service-only upstream must render"
assert_count "$OUT" 'set $upstream "https://redis-agent-memory-controlplane.other-ns.svc.cluster.local:9100";' 2
assert_contains "$OUT" 'proxy_ssl_name redis-agent-memory-controlplane.other-ns.svc.cluster.local;'
service_render -n other-ns --set 'products[0].upstream.service=svc' --set clusterDomain=corp.local >"$OUT"
assert_contains "$OUT" 'set $upstream "https://svc.other-ns.svc.corp.local:9100";'
if helm template ui-service-test "$CHART" --set image.tag=0.0.0-test --set clusterDomain=corp.local \
  --set global.iris.clusterDomain=iris.local >"$OUT" 2>&1; then
  fail "a clusterDomain differing from global.iris.clusterDomain must fail"
fi
assert_contains "$OUT" 'ui.clusterDomain ("corp.local") conflicts with global.iris.clusterDomain ("iris.local")'
service_render -n other-ns --set 'products[0].upstream.service=svc' --set 'products[0].upstream.host=explicit.ns.svc.cluster.local' >"$OUT"
assert_contains "$OUT" 'set $upstream "https://explicit.ns.svc.cluster.local:9100";'
assert_absent "$OUT" 'svc.other-ns'
SERVICE_ERR="$(mktemp)"
if service_render >/dev/null 2>"$SERVICE_ERR"; then
  fail "an upstream with neither host nor service must fail the schema"
fi
grep -q "upstream" "$SERVICE_ERR" || fail "a missing host and service must fail on upstream, got: $(cat "$SERVICE_ERR")"
if service_render --set 'products[0].upstream.service=Not_A_Label' >/dev/null 2>"$SERVICE_ERR"; then
  fail "upstream.service must be a DNS-1035 label"
fi
grep -q "service" "$SERVICE_ERR" || fail "an invalid service must fail on that field, got: $(cat "$SERVICE_ERR")"
rm -f "$SERVICE_ERR"

echo "OK"

# Under the redis-iris umbrella (MOD-20404): routes, SSO fields, role mappings, cluster domain,
# public URL and ingress derive from global.iris; explicit products entries override by key.
UMBRELLA=(--set image.tag=0.0.0-test --namespace ai
  --set global.iris.products.memory.enabled=true --set global.iris.products.playbook.enabled=true)
umbrella_render() { helm template iris "$CHART" "${UMBRELLA[@]}" "$@"; }
umbrella_fails() { # <message> <helm flags...>
  local want=$1
  shift
  if umbrella_render "$@" >"$OUT" 2>&1; then fail "expected the umbrella render to fail: $want"; fi
  assert_contains "$OUT" "$want"
}
umbrella_render >"$OUT"
for route in \
  'memory|redis-agent-memory-controlplane.ai.svc.cluster.local:9100' \
  'api-keys|iris-identity-service.ai.svc.cluster.local:9200' \
  'playbook|redis-agent-playbook-controlplane.ai.svc.cluster.local:9200' \
  'playbook-dp|redis-agent-playbook-dataplane.ai.svc.cluster.local:9201'; do
  assert_contains "$OUT" "location ~ ^/api/${route%%|*}/(?<rest>"
  assert_contains "$OUT" "set \$upstream \"http://${route#*|}\";"
done
assert_contains "$OUT" 'client_max_body_size 8388608;'
assert_contains "$OUT" '"key": "playbook",'
umbrella_render --set global.iris.products.playbook.enabled=false >"$OUT"
assert_absent "$OUT" '/api/playbook'
assert_contains "$OUT" 'location ~ ^/api/api-keys/(?<rest>'
umbrella_render --set global.iris.products.memory.enabled=false >"$OUT"
assert_absent "$OUT" '/api/memory/'
assert_contains "$OUT" 'location ~ ^/api/playbook-dp/(?<rest>'
umbrella_render --set global.iris.clusterDomain=corp.local >"$OUT"
assert_contains "$OUT" 'set $upstream "http://redis-agent-memory-controlplane.ai.svc.corp.local:9100";'
# Lens and Context Gateway: their routes in suite order, api-keys last.
route_keys() { grep -oE 'location ~ \^/api/[a-z-]+/\(' "$1" | sed -E 's#.*/api/([a-z-]+)/.*#\1#' | paste -sd' ' -; }
umbrella_render --set global.iris.products.lens.enabled=true --set global.iris.products.contextGateway.enabled=true >"$OUT"
for route in \
  'lens|redis-lens-dataplane.ai.svc.cluster.local:9000' \
  'context-gateway|redis-context-gateway-controlplane.ai.svc.cluster.local:9100' \
  'context-gateway-dp|redis-context-gateway-dataplane.ai.svc.cluster.local:8083'; do
  assert_contains "$OUT" "location ~ ^/api/${route%%|*}/(?<rest>"
  assert_contains "$OUT" "set \$upstream \"http://${route#*|}\";"
done
assert_contains "$OUT" '"instanceId": "default"'
assert_contains "$OUT" 'location ~ ^/api/context-gateway-dp/\.well-known/oauth-protected-resource/(?<rest>.*)$ {'
assert_contains "$OUT" 'location = /api/context-gateway-dp/health/liveness {'
[ "$(route_keys "$OUT")" = "memory playbook playbook-dp lens context-gateway context-gateway-dp api-keys" ] ||
  fail "unexpected route order: $(route_keys "$OUT")"

# Overrides: only label, showInNavigation and maxRequestBodyBytes; every enabled route stays.
umbrella_render --set 'products[0].key=memory' --set 'products[0].label=Memory' >"$OUT"
assert_contains "$OUT" '"label": "Memory",'
assert_contains "$OUT" 'location ~ ^/api/playbook-dp/(?<rest>'
assert_contains "$OUT" 'location ~ ^/api/api-keys/(?<rest>'
umbrella_render --set 'products[0].key=playbook-dp' --set 'products[0].maxRequestBodyBytes=1048576' >"$OUT"
assert_contains "$OUT" 'client_max_body_size 1048576;'
# An override for a disabled product is kept and adds no route; re-enabling restores it.
umbrella_render --set global.iris.products.playbook.enabled=false --set 'products[0].key=playbook' --set 'products[0].label=PB' >"$OUT"
assert_absent "$OUT" '/api/playbook'
umbrella_render --set 'products[0].key=playbook' --set 'products[0].label=PB' >"$OUT"
assert_contains "$OUT" '"label": "PB",'
umbrella_fails 'ui.products[1].key "memory" is declared more than once' --set 'products[0].key=memory' --set 'products[1].key=memory'
umbrella_fails 'ui.products[0].key "bogus" is not a redis-iris route' --set 'products[0].key=bogus'
umbrella_fails 'ui.products[0].product ("playbook") differs from the redis-iris route ("agent_memory")' --set 'products[0].key=memory' --set 'products[0].product=playbook'
umbrella_fails 'ui.products[0].authScheme ("apiKey") differs' --set 'products[0].key=memory' --set 'products[0].authScheme=apiKey'
umbrella_fails 'ui.products[0].upstream ({' --set-json 'products[0]={"key":"memory","upstream":{"service":"redis-agent-memory-controlplane","port":9999,"basePath":"","scheme":"http"}}'
umbrella_fails 'ui.products[0].upstream ({' --set-json 'products[0]={"key":"memory","upstream":{"service":"redis-agent-memory-controlplane","port":9100,"basePath":"/v2","scheme":"http"}}'

# SSO from global.iris.auth: issuer, access-token issuer, audience, role claims, CA, role mappings.
SSO_UMBRELLA=(--set sso.enabled=true --set sso.clientId=iris-ui --set sso.clientCredential.existingSecret=ui-client
  --set sso.redis.existingSecret=ui-redis --set ingress.enabled=true --set global.iris.publicURL=https://iris.corp.example:8443
  --set global.iris.auth.oidc.issuer=http://idp.localhost:8190/realms/iris --set global.iris.auth.oidc.jwksURI=http://idp.localhost:8190/certs
  --set global.iris.auth.oidc.audience=api://custom --set-json 'global.iris.auth.oidc.roleClaims=["teams"]'
  --set global.tls.caCertSecret=corp-ca --set global.iris.ingress.className=traefik --set global.iris.ingress.tls.secretName=iris-tls
  --set-json 'global.iris.auth.roleBindings=[{"group":"admins","role":"suite_admin"},{"group":"pb","role":"viewer","product":"playbook"},{"group":"keys","role":"viewer","product":"identity"}]')
umbrella_render "${SSO_UMBRELLA[@]}" --set global.iris.products.playbook.enabled=false >"$OUT"
assert_contains "$OUT" 'public_url: "https://iris.corp.example:8443"'
assert_contains "$OUT" 'issuer_url: "http://idp.localhost:8190/realms/iris"'
assert_contains "$OUT" 'allow_insecure_transport: true'
assert_contains "$OUT" 'audience: "api://custom"'
assert_contains "$OUT" 'access_token_issuer: "http://idp.localhost:8190/realms/iris"'
assert_contains "$OUT" "$(printf 'role_claims:\n        - "teams"')"
assert_contains "$OUT" 'role_mappings: {"agent_memory":{"admins":"suite_admin"},"identity":{"admins":"suite_admin","keys":"viewer"}}'
assert_contains "$OUT" 'secretName: corp-ca'
assert_contains "$OUT" 'ingressClassName: traefik'
assert_contains "$OUT" '- host: "iris.corp.example"'
assert_contains "$OUT" 'secretName: iris-tls'
umbrella_render "${SSO_UMBRELLA[@]}" >"$OUT"
assert_contains "$OUT" '"playbook":{"admins":"suite_admin","pb":"viewer"}'
# Only Context Gateway: its two routes and api-keys, and only its role mappings beside identity.
umbrella_render "${SSO_UMBRELLA[@]}" --set global.iris.products.memory.enabled=false --set global.iris.products.playbook.enabled=false \
  --set global.iris.products.contextGateway.enabled=true \
  --set-json 'global.iris.auth.roleBindings=[{"group":"gw","role":"operator","product":"context_gateway"},{"group":"ln","role":"viewer","product":"lens"}]' >"$OUT"
[ "$(route_keys "$OUT")" = "context-gateway context-gateway-dp api-keys" ] || fail "unexpected routes: $(route_keys "$OUT")"
assert_contains "$OUT" 'role_mappings: {"context_gateway":{"gw":"operator"},"identity":{}}'
# ui-auth fetches the discovery issuer itself, so an http one needs insecure transport even with an https JWKS URI.
umbrella_render "${SSO_UMBRELLA[@]}" --set global.iris.auth.oidc.jwksURI=https://idp.localhost/certs >"$OUT"
assert_contains "$OUT" 'allow_insecure_transport: true'
umbrella_fails 'no credentials, query or fragment' "${SSO_UMBRELLA[@]}" --set-string 'global.iris.auth.oidc.accessTokenIssuer=https://sts.example/?tenant=x'
umbrella_fails 'ui.sso.issuer ("https://other") conflicts with global.iris.auth.oidc.issuer' "${SSO_UMBRELLA[@]}" --set sso.issuer=https://other
umbrella_fails 'ui.sso.audience ("api://other") conflicts' "${SSO_UMBRELLA[@]}" --set sso.audience=api://other
umbrella_fails 'ui.sso.roleClaims (["roles"]) conflicts' "${SSO_UMBRELLA[@]}" --set-json 'sso.roleClaims=["roles"]'
umbrella_fails 'ui.sso.allowInsecureTransport (false) conflicts' "${SSO_UMBRELLA[@]}" --set sso.allowInsecureTransport=false
umbrella_fails 'ui.sso.tls.caCertSecret ("mine") conflicts' "${SSO_UMBRELLA[@]}" --set sso.tls.caCertSecret=mine
umbrella_fails 'ui.sso.roleMappings ({' "${SSO_UMBRELLA[@]}" --set sso.roleMappings.agent_memory.x=viewer
umbrella_fails 'ui.publicURL ("https://other.example") conflicts' "${SSO_UMBRELLA[@]}" --set publicURL=https://other.example
umbrella_fails 'ui.ingress.className ("nginx") conflicts' "${SSO_UMBRELLA[@]}" --set ingress.className=nginx
echo "OK"
