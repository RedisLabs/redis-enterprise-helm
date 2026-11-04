#!/usr/bin/env bash

# Artifact-level chart smoke on a real KinD cluster: proves the chart's real
# Deployment/Service/ConfigMap/Secret objects install and serve traffic through
# actual `kubectl port-forward`, not just that `helm template` renders correctly
# (that part is already covered by ui-ci.yml's helm-chart-test and
# gateway-lifecycle jobs, which run on every push without a cluster).
# It stays off the PR critical path (see .github/workflows/ui-helm-e2e.yml).
#
# A second stage turns SSO on against the self-hosted test IdP (development/test-idp) and a
# session Redis, signs a test user in through the gateway with a real authorization-code + PKCE
# flow, and checks what nginx does with the session. It needs the cluster to publish the IdP on the
# host (create it with development/test-idp/kind/cluster.yaml) and the UI auth service image loaded
# as ${UI_KIND_AUTH_IMAGE_REPO}:${UI_KIND_AUTH_IMAGE_TAG}, plus the development image
# iris-context-gateway-controlplane-onprem:local and context-gateway-ts-upstream:helm-test
# for real Gateway administration and catalog discovery.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
NAMESPACE="${UI_KIND_NAMESPACE:-ui-kind-smoke}"
RELEASE="${UI_KIND_RELEASE:-ui-smoke}"
GATEWAY_PORT="${UI_KIND_GATEWAY_PORT:-39300}"
CONTEXT="${UI_KIND_CONTEXT:-kind-ui}"
IMAGE_REPO="${UI_KIND_IMAGE_REPO:-ui-gateway}"
IMAGE_TAG="${UI_KIND_IMAGE_TAG:-latest}"
AUTH_IMAGE_REPO="${UI_KIND_AUTH_IMAGE_REPO:-ui-auth}"
AUTH_IMAGE_TAG="${UI_KIND_AUTH_IMAGE_TAG:-latest}"
# The test IdP's client registers http://localhost:<port>/auth/callback for 5173, 8080 and 18080 (the
# end-to-end suite's port), so the SSO stage's port-forward must use one of those ports.
SSO_PORT="${UI_KIND_SSO_PORT:-8080}"
FORWARDS=()
NAMESPACE_CREATED=false
RESTARTS_DUMPED=false
LOG_DIR=""

# Pin every Kubernetes and Helm operation to the explicitly selected test cluster.
if [[ "$CONTEXT" != kind-* ]] || [ "$(kubectl config current-context)" != "$CONTEXT" ]; then
  echo "Select the intended KinD context and set UI_KIND_CONTEXT to match it" >&2
  exit 1
fi
kubectl() { command kubectl --context "$CONTEXT" "$@"; }
helm() { command helm --kube-context "$CONTEXT" "$@"; }

# Prints the last terminated state and the previous container log of every pod in the namespace
# that restarted, so a restart check explains the crash instead of only counting it. Each lookup
# is best effort: a missing previous log must never hide the failure being reported.
dump_restarted_pods() {
  local pod container count
  # The restart check dumps before it fails, and the exit trap must not print the same logs again.
  "$RESTARTS_DUMPED" && return 0
  RESTARTS_DUMPED=true
  while IFS=$'\t' read -r pod container count; do
    [ -n "$pod" ] || continue
    echo "--- $pod/$container restarted (restart count: $count); last terminated state:" >&2
    kubectl -n "$NAMESPACE" get pod "$pod" \
      -o jsonpath='{range .status.containerStatuses[*]}{.name}: exit={.lastState.terminated.exitCode} reason={.lastState.terminated.reason} started={.lastState.terminated.startedAt} finished={.lastState.terminated.finishedAt}{"\n"}{end}' >&2 || true
    echo "--- $pod/$container previous container log:" >&2
    kubectl -n "$NAMESPACE" logs "$pod" -c "$container" --previous --tail=200 >&2 || true
  done < <(kubectl -n "$NAMESPACE" get pods -o json 2>/dev/null |
    jq -r '.items[] | .metadata.name as $pod | .status.containerStatuses[]? | select(.restartCount > 0) | [$pod, .name, .restartCount] | @tsv' || true)
}

cleanup() {
  local exit_status=$?
  if "$NAMESPACE_CREATED" && [ "$exit_status" -ne 0 ]; then
    # Both releases (the plain gateway and the SSO one) share the chart's name label.
    kubectl -n "$NAMESPACE" get pods -o wide >&2 || true
    dump_restarted_pods
    kubectl -n "$NAMESPACE" logs -l "app.kubernetes.io/name=redis-iris-ui" --all-containers --tail=200 >&2 || true
    kubectl -n "$NAMESPACE" logs deployment/context-gateway --tail=200 >&2 || true
  fi
  for process in ${FORWARDS[*]:-}; do
    kill "$process" >/dev/null 2>&1 || true
    wait "$process" >/dev/null 2>&1 || true
  done
  if "$NAMESPACE_CREATED"; then
    kubectl delete namespace "$NAMESPACE" --wait=false >/dev/null 2>&1 || true
  fi
  if [ -n "$LOG_DIR" ]; then
    rm -rf "$LOG_DIR"
  fi
  return "$exit_status"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_status() {
  local want="$1"
  shift
  local body="$LOG_DIR/http-response"
  local got
  got="$(curl -sS -o "$body" -w '%{http_code}' "$@")"
  if [ "$got" != "$want" ]; then
    fail "expected HTTP ${want}, got HTTP ${got}"
  fi
}

sign_in() {
  local username="$1" login_headers authorize_url login_cookie idp_headers idp_body form_action callback_url callback_headers
  login_headers="$LOG_DIR/$username-login.headers"
  curl -sS -o /dev/null -D "$login_headers" "$SSO_BASE/auth/login?returnTo=/"
  authorize_url="$(sed -n 's/^[Ll]ocation: //p' "$login_headers" | tr -d '\r')"
  case "$authorize_url" in
    "$ISSUER/protocol/openid-connect/auth?"*) ;;
    *) fail "/auth/login must redirect to the IdP's authorization endpoint" ;;
  esac
  login_cookie="$(sed -n 's/^[Ss]et-[Cc]ookie: \(__Host-iris-login=[^;]*\).*/\1/p' "$login_headers")"
  [ -n "$login_cookie" ] || fail "/auth/login must set the __Host-iris-login cookie"

  idp_headers="$LOG_DIR/$username-idp.headers"
  idp_body="$LOG_DIR/$username-idp.body"
  curl -sS -D "$idp_headers" -o "$idp_body" "$authorize_url"
  grep -q 'kc-form-login' "$idp_body" || fail "the IdP did not present its login form"
  form_action="$(grep -o 'action="[^"]*"' "$idp_body" | head -n1 | sed 's/^action="//;s/"$//;s/&amp;/\&/g' || true)"
  [ -n "$form_action" ] || fail "the IdP's login form has no action URL"
  callback_url="$(curl -sS -o /dev/null -w '%{redirect_url}' -H "Cookie: $(cookie_header "$idp_headers")" \
    --data-urlencode "username=$username" --data-urlencode "password=$USER_PASSWORD" "$form_action")"
  case "$callback_url" in
    "$SSO_BASE/auth/callback?"*) ;;
    *) fail "the IdP must redirect back to $SSO_BASE/auth/callback" ;;
  esac

  callback_headers="$LOG_DIR/$username-callback.headers"
  curl -sS -o /dev/null -D "$callback_headers" -H "Cookie: $login_cookie" "$callback_url"
  session_cookie="$(sed -n 's/^[Ss]et-[Cc]ookie: \(__Host-iris-session=[^;]*\).*/\1/p' "$callback_headers")"
  [ -n "$session_cookie" ] || fail "/auth/callback must set the __Host-iris-session cookie"
}

gateway_request() {
  local want="$1" method="$2" path="$3" got
  shift 3
  got="$(curl -sS -o "$LOG_DIR/gateway-response" -w '%{http_code}' -X "$method" \
    -H "Cookie: $session_cookie" -H "X-CSRF-Token: $csrf_token" -H "Origin: $SSO_BASE" \
    -H 'Content-Type: application/json' "$@" "$SSO_BASE/api/context-gateway$path")"
  [ "$got" = "$want" ] || fail "$role $method $path: expected HTTP $want, got HTTP $got"
}

gateway_snapshot() {
  local destination="$1" path
  : >"$destination"
  for path in /iris/v1/context-gateway/gateways "$gateway_path" "$empty_gateway_path" "$gateway_path/upstreams" "$upstream_path" "$upstream_path/tools"; do
    gateway_request 200 GET "$path"
    jq -cS 'if has("items") then .items |= sort_by(.gatewayId // .upstreamId // .name) else . end' \
      "$LOG_DIR/gateway-response" >>"$destination"
  done
}

gateway_denied_write() {
  gateway_snapshot "$LOG_DIR/gateway-before"
  gateway_request 403 "$@"
  gateway_snapshot "$LOG_DIR/gateway-after"
  cmp -s "$LOG_DIR/gateway-before" "$LOG_DIR/gateway-after" || fail "$role $1 $2 changed Gateway administration state"
  echo "PASS: $role $1 $2 denied with unchanged Gateway, Upstream and catalog state"
}

kubectl create namespace "$NAMESPACE"
NAMESPACE_CREATED=true
LOG_DIR="$(mktemp -d)"

# --- self-signed CA + server cert for the https stub, mounted below as real
# Kubernetes Secrets -- unlike the docker-only lifecycle smoke, this proves the
# actual Secret-volume path a real caSecretName reference goes through.
HTTPS_ECHO_FQDN="https-echo.$NAMESPACE.svc.cluster.local"
openssl req -x509 -newkey rsa:2048 -days 1 -nodes \
  -keyout "$LOG_DIR/ca.key" -out "$LOG_DIR/ca.crt" -subj "/CN=ui-kind-smoke-ca" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$LOG_DIR/server.key" -out "$LOG_DIR/server.csr" \
  -subj "/CN=$HTTPS_ECHO_FQDN" >/dev/null 2>&1
openssl x509 -req -in "$LOG_DIR/server.csr" -CA "$LOG_DIR/ca.crt" -CAkey "$LOG_DIR/ca.key" -CAcreateserial \
  -out "$LOG_DIR/server.crt" -days 1 -extfile <(printf "subjectAltName=DNS:%s" "$HTTPS_ECHO_FQDN") >/dev/null 2>&1

# A second, unrelated CA that never signed the server cert above -- the
# negative control proving proxy_ssl_verify actually rejects an untrusted
# chain, not just that the positive (trusted) case happens to pass.
openssl req -x509 -newkey rsa:2048 -days 1 -nodes \
  -keyout "$LOG_DIR/wrong-ca.key" -out "$LOG_DIR/wrong-ca.crt" -subj "/CN=ui-kind-smoke-wrong-ca" >/dev/null 2>&1

kubectl -n "$NAMESPACE" create secret generic https-echo-tls \
  --from-file=tls.crt="$LOG_DIR/server.crt" --from-file=tls.key="$LOG_DIR/server.key"
kubectl -n "$NAMESPACE" create secret generic https-echo-ca --from-file=ca.crt="$LOG_DIR/ca.crt"
kubectl -n "$NAMESPACE" create secret generic https-echo-wrong-ca --from-file=ca.crt="$LOG_DIR/wrong-ca.crt"

# --- stub upstreams: traefik/whoami echoes the request line and headers it
# received, which is exactly what proves prefix rewrite and header passthrough.
kubectl -n "$NAMESPACE" apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: http-echo
spec:
  replicas: 1
  selector:
    matchLabels: {app: http-echo}
  template:
    metadata:
      labels: {app: http-echo}
    spec:
      containers:
        - name: whoami
          image: traefik/whoami:latest
          imagePullPolicy: Never
          args: ["-port", "8080"]
          ports: [{name: http, containerPort: 8080}]
---
apiVersion: v1
kind: Service
metadata:
  name: http-echo
spec:
  selector: {app: http-echo}
  ports: [{name: http, port: 8080, targetPort: http}]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: https-echo
spec:
  replicas: 1
  selector:
    matchLabels: {app: https-echo}
  template:
    metadata:
      labels: {app: https-echo}
    spec:
      containers:
        - name: whoami
          image: traefik/whoami:latest
          imagePullPolicy: Never
          args: ["-port", "8443", "-cert", "/certs/tls.crt", "-key", "/certs/tls.key"]
          ports: [{name: https, containerPort: 8443}]
          volumeMounts:
            - name: certs
              mountPath: /certs
              readOnly: true
      volumes:
        - name: certs
          secret:
            secretName: https-echo-tls
---
apiVersion: v1
kind: Service
metadata:
  name: https-echo
spec:
  selector: {app: https-echo}
  ports: [{name: https, port: 8443, targetPort: https}]
YAML

kubectl -n "$NAMESPACE" rollout status deployment/http-echo --timeout=2m
kubectl -n "$NAMESPACE" rollout status deployment/https-echo --timeout=2m

# One product per upstream shape: plain http, https trusting the mounted CA
# (AC4's primary path), and https with the documented insecure-skip escape
# hatch (AC4's alternate path) -- both https products share the same stub
# server, just verified two different ways.
helm upgrade --install "$RELEASE" "$ROOT/iris/ui/helm" \
  --namespace "$NAMESPACE" \
  --set image.repository="$IMAGE_REPO" \
  --set image.tag="$IMAGE_TAG" \
  --set image.pullPolicy=Never \
  --set 'products[0].key=http-test' \
  --set 'products[0].label=HTTP Test' \
  --set 'products[0].product=agent_memory' \
  --set 'products[0].authScheme=bearer' \
  --set 'products[0].healthPath=/ready' \
  --set "products[0].upstream.host=http-echo.$NAMESPACE.svc.cluster.local" \
  --set 'products[0].upstream.port=8080' \
  --set 'products[0].upstream.basePath=/v1' \
  --set 'products[0].upstream.scheme=http' \
  --set 'products[1].key=https-ca-test' \
  --set 'products[1].label=HTTPS CA Test' \
  --set 'products[1].product=agent_memory' \
  --set 'products[1].authScheme=apiKey' \
  --set 'products[1].healthPath=/ready' \
  --set "products[1].upstream.host=$HTTPS_ECHO_FQDN" \
  --set 'products[1].upstream.port=8443' \
  --set 'products[1].upstream.basePath=/api' \
  --set 'products[1].upstream.scheme=https' \
  --set 'products[1].upstream.caSecretName=https-echo-ca' \
  --set 'products[2].key=https-insecure-test' \
  --set 'products[2].label=HTTPS Insecure Test' \
  --set 'products[2].product=agent_memory' \
  --set 'products[2].authScheme=apiKey' \
  --set 'products[2].healthPath=/ready' \
  --set "products[2].upstream.host=$HTTPS_ECHO_FQDN" \
  --set 'products[2].upstream.port=8443' \
  --set 'products[2].upstream.basePath=/insecure' \
  --set 'products[2].upstream.scheme=https' \
  --set 'products[2].upstream.insecureSkipVerify=true' \
  --set 'products[3].key=https-untrusted-test' \
  --set 'products[3].label=HTTPS Untrusted CA Test' \
  --set 'products[3].product=agent_memory' \
  --set 'products[3].authScheme=apiKey' \
  --set 'products[3].healthPath=/health' \
  --set "products[3].upstream.host=$HTTPS_ECHO_FQDN" \
  --set 'products[3].upstream.port=8443' \
  --set 'products[3].upstream.basePath=/wrong-ca' \
  --set 'products[3].upstream.scheme=https' \
  --set 'products[3].upstream.caSecretName=https-echo-wrong-ca' \
  --wait --timeout=3m

kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 "service/${RELEASE}-redis-iris-ui" "$GATEWAY_PORT:8080" \
  >"$LOG_DIR/gateway.log" 2>&1 &
FORWARDS+=("$!")

BASE="http://127.0.0.1:$GATEWAY_PORT"
ready=false
for _ in $(seq 1 30); do
  if curl -sf "$BASE/healthz" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 0.5
done
"$ready" || fail "gateway never became reachable through kubectl port-forward"

expect_status 200 "$BASE/healthz"
expect_status 200 "$BASE/some/deep/link" # SPA history fallback, per AC2

config_json="$(curl -sS "$BASE/config.json")"
for key in http-test https-ca-test https-insecure-test https-untrusted-test; do
  echo "$config_json" | grep -q "\"key\": \"${key}\"" || fail "config.json missing the ${key} product"
done
echo "$config_json" | grep -qi "upstream" && fail "config.json must never leak upstream details to the SPA"

# Reverse proxy + header passthrough against the plain http upstream (AC3/AC5).
http_body="$(curl -sS -H "Authorization: Bearer kind-smoke-token" "$BASE/api/http-test/foo/bar?x=1")"
echo "$http_body" | grep -q "^GET /v1/foo/bar?x=1 " || fail "http upstream did not receive the rewritten path"
echo "$http_body" | grep -q "^Authorization: Bearer kind-smoke-token" || fail "Authorization header was not forwarded unchanged"

# Health probe bypasses basePath through a real Service. Not literally
# "/health" -- traefik/whoami reserves that path with its own empty 200
# instead of echoing the request.
health_body="$(curl -sS "$BASE/api/http-test/ready")"
echo "$health_body" | grep -q "^GET /ready " || fail "http upstream health probe did not bypass basePath"

# https + a real Secret-mounted CA actually establishes trust (AC4).
https_ca_body="$(curl -sS -H "X-API-Key: kind-smoke-api-key" "$BASE/api/https-ca-test/baz")"
echo "$https_ca_body" | grep -q "^GET /api/baz " || fail "https (CA-trusted) upstream did not receive the rewritten path"
echo "$https_ca_body" | grep -qi "^X-Api-Key: kind-smoke-api-key" || fail "X-API-Key header was not forwarded unchanged (CA-trusted https)"

# https + insecureSkipVerify reaches the same (otherwise-untrusted-by-default) upstream (AC4's alternate path).
https_insecure_body="$(curl -sS -H "X-API-Key: kind-smoke-api-key" "$BASE/api/https-insecure-test/qux")"
echo "$https_insecure_body" | grep -q "^GET /insecure/qux " || fail "https (insecureSkipVerify) upstream did not receive the rewritten path"

# Negative control: an untrusted CA (one that never signed the server's real
# cert) must be rejected, not silently pass -- proves proxy_ssl_verify is
# actually checking the chain, not merely configured. Without this, the
# positive https-ca-test case above would pass just as well with
# certificate verification accidentally disabled entirely.
expect_status 502 "$BASE/api/https-untrusted-test/foo"

# --- Stage 2: SSO on, against the test IdP (MOD-19451) ---------------------------------------
SSO_RELEASE="${RELEASE}-sso"
SSO_BASE="http://localhost:$SSO_PORT"

# The test IdP: Keycloak in the cluster, with CoreDNS answering idp.localhost for pods. The host
# reaches the same issuer through the port mapping in development/test-idp/kind/cluster.yaml.
bash "$ROOT/development/test-idp/kind/install.sh"
# shellcheck source=/dev/null
REDIRECT_URI="$SSO_BASE/auth/callback" source "$ROOT/development/test-idp/lib.sh"
# The rollout is done but the node port can take a moment to answer from the host, so retry before failing.
idp_ready=false
for _ in $(seq 1 60); do
  if curl -sf "$ISSUER/.well-known/openid-configuration" >/dev/null 2>&1; then
    idp_ready=true
    break
  fi
  sleep 2
done
"$idp_ready" ||
  fail "the test IdP is not reachable from the host at $ISSUER: create the KinD cluster with development/test-idp/kind/cluster.yaml"

# The session store. No persistence: losing it only signs users out.
kubectl -n "$NAMESPACE" apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ui-auth-redis
spec:
  replicas: 1
  selector:
    matchLabels: {app: ui-auth-redis}
  template:
    metadata:
      labels: {app: ui-auth-redis}
    spec:
      containers:
        - name: redis
          image: redis:8
          args: ["redis-server", "--save", "", "--appendonly", "no"]
          ports: [{name: redis, containerPort: 6379}]
---
apiVersion: v1
kind: Service
metadata:
  name: ui-auth-redis
spec:
  selector: {app: ui-auth-redis}
  ports: [{name: redis, port: 6379, targetPort: redis}]
YAML
kubectl -n "$NAMESPACE" rollout status deployment/ui-auth-redis --timeout=3m

kubectl -n "$NAMESPACE" create secret generic idp-client --from-literal=client-secret="$CLIENT_SECRET"
kubectl -n "$NAMESPACE" create secret generic ui-auth-redis \
  --from-literal=urls="redis://ui-auth-redis.$NAMESPACE.svc.cluster.local:6379"

# Administration needs metadata and credential storage, but no data plane or Identity Service.
openssl rand -hex 24 >"$LOG_DIR/admin-token"
openssl rand -hex 24 >"$LOG_DIR/internal-token"
printf '%s' "$(openssl rand -hex 24)" >"$LOG_DIR/upstream-token"
openssl rand -base64 32 >"$LOG_DIR/k1"
printf '%s' development-build-only >"$LOG_DIR/license"
kubectl -n "$NAMESPACE" create secret generic context-gateway-secrets \
  --from-file=admin-token="$LOG_DIR/admin-token" --from-file=internal-token="$LOG_DIR/internal-token" \
  --from-file=upstream-token="$LOG_DIR/upstream-token" \
  --from-file=k1="$LOG_DIR/k1" --from-file=license="$LOG_DIR/license"
# A static tenant overrides JWT claims, so leave it empty to exercise tenant isolation.
jq -n --arg issuer "$ISSUER" '{
  profile: "prod", tenant_id: "development-tenant", server: {host: "0.0.0.0", port: 9100},
  license: {license_path: "/etc/context-gateway/secrets/license"},
  auth: {
    type: "admin-token", admin_token: {token_file: "/etc/context-gateway/secrets/admin-token"},
    internal_token: {token_file: "/etc/context-gateway/secrets/internal-token"},
    oidc: {
      enabled: true, issuer: $issuer, jwks_uri: ($issuer + "/protocol/openid-connect/certs"),
      audience: ["api://redis-iris"], allow_insecure_transport: true,
      static_tenant_id: "", tenant_id_claim: "tenant_id", role_claims: ["roles"], role_mappings: {
        viewer: "viewer", "memory-operator": "operator", "memory-admin": "product_admin", "suite-admin": "suite_admin"
      }
    }
  },
  metadata_db: {urls: ["redis://context-gateway-storage:6379"]},
  credential_storage: {provider: "redis", redis: {
    urls: ["redis://context-gateway-storage:6380"],
    encryption: {active_key_id: "k1", key_files: {k1: "/etc/context-gateway/secrets/k1"}}
  }},
  dataplane: {public_base_url: "http://unused-dataplane.example.test"}
}' >"$LOG_DIR/context-gateway-config.json"
kubectl -n "$NAMESPACE" create configmap context-gateway-config \
  --from-file=config.yaml="$LOG_DIR/context-gateway-config.json"
kubectl -n "$NAMESPACE" apply -f "$ROOT/iris/ui/helm/tests/context-gateway.yaml"
kubectl -n "$NAMESPACE" rollout status deployment/context-gateway-storage --timeout=3m
kubectl -n "$NAMESPACE" rollout status deployment/ts-upstream --timeout=3m
kubectl -n "$NAMESPACE" rollout status deployment/context-gateway --timeout=3m

# --wait also proves the UI auth service becomes ready, which needs the IdP's discovery document.
helm upgrade --install "$SSO_RELEASE" "$ROOT/iris/ui/helm" \
  --namespace "$NAMESPACE" \
  --set image.repository="$IMAGE_REPO" \
  --set image.tag="$IMAGE_TAG" \
  --set image.pullPolicy=Never \
  --set uiAuth.image.repository="$AUTH_IMAGE_REPO" \
  --set uiAuth.image.tag="$AUTH_IMAGE_TAG" \
  --set uiAuth.image.pullPolicy=Never \
  --set-string publicURL="$SSO_BASE" \
  --set sso.enabled=true \
  --set-string sso.issuer="$ISSUER" \
  --set sso.allowInsecureTransport=true \
  --set-string sso.clientId="$CLIENT_ID" \
  --set sso.clientCredential.existingSecret=idp-client \
  --set sso.redis.existingSecret=ui-auth-redis \
  --set 'sso.scopes={openid,offline_access,iris}' \
  --set-string sso.audience=api://redis-iris \
  --set 'sso.roleClaims={roles}' \
  --set 'sso.roleMappings.context_gateway.viewer=viewer' \
  --set 'sso.roleMappings.context_gateway.memory-operator=operator' \
  --set 'sso.roleMappings.context_gateway.memory-admin=product_admin' \
  --set 'sso.roleMappings.context_gateway.suite-admin=suite_admin' \
  --set 'products[0].key=http-test' \
  --set 'products[0].label=HTTP Test' \
  --set 'products[0].product=agent_memory' \
  --set 'products[0].authScheme=bearer' \
  --set 'products[0].healthPath=/ready' \
  --set "products[0].upstream.host=http-echo.$NAMESPACE.svc.cluster.local" \
  --set 'products[0].upstream.port=8080' \
  --set 'products[0].upstream.basePath=/v1' \
  --set 'products[0].upstream.scheme=http' \
  --set 'products[1].key=context-gateway' \
  --set 'products[1].label=Context Gateway' \
  --set 'products[1].product=context_gateway' \
  --set 'products[1].authScheme=bearer' \
  --set 'products[1].healthPath=/health/readiness' \
  --set 'products[1].showInNavigation=false' \
  --set "products[1].upstream.host=context-gateway.$NAMESPACE.svc.cluster.local" \
  --set 'products[1].upstream.port=9100' \
  --set-string 'products[1].upstream.basePath=' \
  --set 'products[1].upstream.scheme=http' \
  --wait --timeout=5m

kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 "service/${SSO_RELEASE}-redis-iris-ui" "$SSO_PORT:8080" \
  >"$LOG_DIR/gateway-sso.log" 2>&1 &
FORWARDS+=("$!")
ready=false
for _ in $(seq 1 30); do
  if curl -sf "$SSO_BASE/healthz" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 0.5
done
"$ready" || fail "SSO gateway never became reachable through kubectl port-forward"

# The shell is told SSO is on, and the console needs no session.
curl -sS "$SSO_BASE/config.json" | grep -q '"enabled": true' || fail "config.json must report sso.enabled: true"
curl -sS "$SSO_BASE/config.json" | jq -e 'all(.products[]; .key != "context-gateway")' >/dev/null ||
  fail "Context Gateway must stay out of navigation until its management screen exists"
expect_status 200 "$SSO_BASE/some/deep/link"

# Without a session a product call is refused by nginx's auth_request. This also proves the nginx
# image has the auth_request module. A product's health route needs no session.
expect_status 401 "$SSO_BASE/api/http-test/foo"
expect_status 401 -X POST -H "Origin: $SSO_BASE" "$SSO_BASE/api/http-test/foo"
expect_status 200 "$SSO_BASE/api/http-test/ready"
expect_status 401 "$SSO_BASE/auth/me"
expect_status 401 "$SSO_BASE/api/context-gateway/iris/v1/context-gateway/gateways"
echo "PASS: real Gateway administration refuses a request without a UI session"

# Sign in through the gateway: /auth/login -> IdP form -> /auth/callback. Cookies are carried by
# hand because the service's __Host- cookies are Secure and curl's jar will not keep them over http.
sign_in suite-admin

me="$(curl -sS -H "Cookie: $session_cookie" "$SSO_BASE/auth/me")"
csrf_token="$(jq -r .csrfToken <<<"$me")"
[ -n "$csrf_token" ] && [ "$csrf_token" != "null" ] || fail "/auth/me must return the session's csrfToken, got: $me"

# A read passes with the session. The product sees the session's access token, not the browser's
# credentials, and never the session cookie or the CSRF token.
sso_body="$(curl -sS -H "Cookie: $session_cookie" -H "X-CSRF-Token: $csrf_token" -H "Authorization: Bearer browser-credential" \
  "$SSO_BASE/api/http-test/foo/bar?x=1")"
echo "$sso_body" | grep -q "^GET /v1/foo/bar?x=1 " || fail "the product did not receive the rewritten path with a session"
echo "$sso_body" | grep -q "^Authorization: Bearer ey" || fail "the product must receive the session's access token as a bearer"
echo "$sso_body" | grep -q "browser-credential" && fail "the browser's own Authorization header must not reach the product"
echo "$sso_body" | grep -qi "^Cookie:" && fail "the session cookie must not reach the product"
echo "$sso_body" | grep -qi "^X-Csrf-Token:" && fail "the CSRF token must not reach the product"

# A write needs the CSRF token and a same-origin request: this is what proves nginx forwards the
# browser's X-CSRF-Token and Origin to the check (a dropped header would refuse every write).
expect_status 403 -X POST -H "Cookie: $session_cookie" -H "Origin: $SSO_BASE" "$SSO_BASE/api/http-test/foo"
expect_status 403 -X POST -H "Cookie: $session_cookie" -H "X-CSRF-Token: $csrf_token" -H "Origin: http://evil.example" "$SSO_BASE/api/http-test/foo"
expect_status 200 -X POST -H "Cookie: $session_cookie" -H "X-CSRF-Token: $csrf_token" -H "Origin: $SSO_BASE" -d 'payload' "$SSO_BASE/api/http-test/foo"

# Sign out ends the session: the same cookie is refused afterwards.
expect_status 403 -X POST -H "Cookie: $session_cookie" -H "Origin: $SSO_BASE" "$SSO_BASE/auth/logout"
expect_status 200 -X POST -H "Cookie: $session_cookie" -H "X-CSRF-Token: $csrf_token" -H "Origin: $SSO_BASE" "$SSO_BASE/auth/logout"
expect_status 401 -H "Cookie: $session_cookie" "$SSO_BASE/api/http-test/foo"

kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 service/context-gateway :9100 \
  >"$LOG_DIR/context-gateway-forward.log" 2>&1 &
FORWARDS+=("$!")
context_gateway_base=""
for _ in $(seq 1 30); do
  context_gateway_port="$(sed -n 's/.*127\.0\.0\.1:\([0-9]*\) ->.*/\1/p' "$LOG_DIR/context-gateway-forward.log" | head -n1)"
  if [ -n "$context_gateway_port" ]; then
    context_gateway_base="http://127.0.0.1:$context_gateway_port"
    break
  fi
  sleep 0.5
done
[ -n "$context_gateway_base" ] || fail "Context Gateway port-forward did not start"
expect_status 201 -H "Authorization: Bearer $(cat "$LOG_DIR/admin-token")" -H 'Content-Type: application/json' \
  -d '{"name":"Gateway visible through UI session"}' "$context_gateway_base/iris/v1/context-gateway/gateways"
gateway_id="$(jq -er .gatewayId "$LOG_DIR/http-response")"

sign_in viewer
for credential in absent invalid; do
  browser_headers=()
  if [ "$credential" = invalid ]; then
    browser_headers=(-H 'Authorization: Bearer browser-invalid-token')
  fi
  expect_status 200 -H "Cookie: $session_cookie" "${browser_headers[@]}" "$SSO_BASE/api/context-gateway/iris/v1/context-gateway/gateways"
  jq -e --arg id "$gateway_id" \
    'any(.items[]; .gatewayId == $id and .name == "Gateway visible through UI session")' \
    "$LOG_DIR/http-response" >/dev/null || fail "signed-in viewer did not read the seeded Gateway with $credential browser credentials"
done
echo "PASS: signed-in viewer reads real Gateway administration through nginx without a bearer token"

while IFS='|' read -r expiry timestamp_field; do
  sign_in viewer
  expect_status 200 -H "Cookie: $session_cookie" "$SSO_BASE/api/context-gateway/iris/v1/context-gateway/gateways"
  jq -e --arg id "$gateway_id" 'any(.items[]; .gatewayId == $id)' "$LOG_DIR/http-response" >/dev/null ||
    fail "$expiry expiry control must read the seeded Gateway before the session expires"

  session_key="iris-ui-auth:session:$(printf '%s' "${session_cookie#*=}" | openssl dgst -sha256 -r | cut -d' ' -f1)"
  [ "$(kubectl -n "$NAMESPACE" exec deployment/ui-auth-redis -- redis-cli --raw EXISTS "$session_key")" = 1 ] ||
    fail "$expiry expiry fixture requires the real viewer session in Redis"
  # Preserve the real cookie, encrypted tokens and Redis TTL so UI Auth's expiry check rejects the session.
  [ "$(kubectl -n "$NAMESPACE" exec deployment/ui-auth-redis -- \
    redis-cli --raw HSET "$session_key" "$timestamp_field" '2000-01-01T00:00:00Z')" = 0 ] ||
    fail "$expiry expiry fixture must update an existing session timestamp"

  expect_status 401 -H "Cookie: $session_cookie" "$SSO_BASE/api/context-gateway/iris/v1/context-gateway/gateways"
  expect_status 401 -H "Cookie: $session_cookie" "$SSO_BASE/auth/me"
  echo "PASS: $expiry expiry rejects the same viewer cookie at real Gateway administration and /auth/me"
done <<'CASES'
idle|last_seen_at
absolute|expires_at
CASES

sign_in viewer
expect_status 200 -H "Cookie: $session_cookie" "$SSO_BASE/auth/me"
csrf_token="$(jq -er '.csrfToken | select(type == "string" and length > 0)' "$LOG_DIR/http-response")"
expect_status 200 -H "Cookie: $session_cookie" "$SSO_BASE/api/context-gateway/iris/v1/context-gateway/gateways"
jq -e --arg id "$gateway_id" 'any(.items[]; .gatewayId == $id)' "$LOG_DIR/http-response" >/dev/null ||
  fail "refresh control must read the seeded Gateway before the access token expires"
expect_status 200 -H "Cookie: $session_cookie" "$SSO_BASE/api/http-test/before-refresh"
access_token_before_refresh="$(sed -n 's/^Authorization: Bearer //p' "$LOG_DIR/http-response" | tr -d '\r')"
[ -n "$access_token_before_refresh" ] || fail "refresh control must forward the session access token"

session_key="iris-ui-auth:session:$(printf '%s' "${session_cookie#*=}" | openssl dgst -sha256 -r | cut -d' ' -f1)"
[ "$(kubectl -n "$NAMESPACE" exec deployment/ui-auth-redis -- redis-cli --raw EXISTS "$session_key")" = 1 ] ||
  fail "refresh fixture requires the real viewer session in Redis"
# Keep the real refresh token and session lifetime so the Gateway request must refresh through Keycloak.
[ "$(kubectl -n "$NAMESPACE" exec deployment/ui-auth-redis -- \
  redis-cli --raw HSET "$session_key" access_token_expires_at '2000-01-01T00:00:00Z')" = 0 ] ||
  fail "refresh fixture must update an existing access-token expiry"

expect_status 200 -H "Cookie: $session_cookie" "$SSO_BASE/api/context-gateway/iris/v1/context-gateway/gateways"
jq -e --arg id "$gateway_id" 'any(.items[]; .gatewayId == $id)' "$LOG_DIR/http-response" >/dev/null ||
  fail "the refreshed session must still read the seeded Gateway"
refreshed_expiry="$(kubectl -n "$NAMESPACE" exec deployment/ui-auth-redis -- redis-cli --raw HGET "$session_key" access_token_expires_at)"
[ -n "$refreshed_expiry" ] && [ "$refreshed_expiry" != '2000-01-01T00:00:00Z' ] ||
  fail "the Gateway request must refresh before the echo probe"
expect_status 200 -H "Cookie: $session_cookie" "$SSO_BASE/api/http-test/after-refresh"
access_token_after_refresh="$(sed -n 's/^Authorization: Bearer //p' "$LOG_DIR/http-response" | tr -d '\r')"
[ -n "$access_token_after_refresh" ] && [ "$access_token_after_refresh" != "$access_token_before_refresh" ] ||
  fail "Keycloak refresh must replace the forwarded access token"
unset access_token_before_refresh access_token_after_refresh
echo "PASS: the same viewer session reads real Gateway administration after an actual Keycloak token refresh"

expect_status 200 -X POST -H "Cookie: $session_cookie" -H "X-CSRF-Token: $csrf_token" -H "Origin: $SSO_BASE" "$SSO_BASE/auth/logout"
expect_status 401 -H "Cookie: $session_cookie" "$SSO_BASE/api/context-gateway/iris/v1/context-gateway/gateways"
echo "PASS: logout rejects the same refreshed viewer cookie at real Gateway administration"

upstream_payload="$(jq -cn --rawfile token "$LOG_DIR/upstream-token" '{
  name: "Browser Orders", namespace: "browser-orders", kind: "MCP",
  mcp: {
    endpoint: "http://ts-upstream:8080/mcp", transport: "streamable-http",
    authentication: {methods: [{bearer: {value: ($token | rtrimstr("\n"))}}]}
  }
}')"

while IFS='|' read -r role username permissions; do
  sign_in "$username"
  expect_status 200 -H "Cookie: $session_cookie" "$SSO_BASE/auth/me"
  jq -e --argjson expected "$permissions" \
    '(.permissions.context_gateway | sort) == ($expected | sort)' "$LOG_DIR/http-response" >/dev/null ||
    fail "$role session must contain exactly its Context Gateway permissions"
  csrf_token="$(jq -er '.csrfToken | select(type == "string" and length > 0)' "$LOG_DIR/http-response")"
  echo "PASS: $role session has the exact Context Gateway permissions"

  gateway_payload="$(jq -cn --arg name "$role Gateway" '{name: $name}')"
  # An empty Gateway keeps delete denials independent of the non-empty Gateway constraint.
  empty_gateway_payload="$(jq -cn --arg name "$role Empty Gateway" '{name: $name}')"
  if [ "$role" = viewer ]; then
    expect_status 201 -H "Authorization: Bearer $(cat "$LOG_DIR/admin-token")" -H 'Content-Type: application/json' \
      -d "$gateway_payload" "$context_gateway_base/iris/v1/context-gateway/gateways"
    gateway_id="$(jq -er .gatewayId "$LOG_DIR/http-response")"
    expect_status 201 -H "Authorization: Bearer $(cat "$LOG_DIR/admin-token")" -H 'Content-Type: application/json' \
      -d "$empty_gateway_payload" "$context_gateway_base/iris/v1/context-gateway/gateways"
    empty_gateway_id="$(jq -er .gatewayId "$LOG_DIR/http-response")"
    expect_status 201 -H "Authorization: Bearer $(cat "$LOG_DIR/admin-token")" -H 'Content-Type: application/json' \
      -d "$upstream_payload" "$context_gateway_base/iris/v1/context-gateway/gateways/$gateway_id/upstreams"
    upstream_id="$(jq -er .upstreamId "$LOG_DIR/http-response")"
  else
    gateway_request 201 POST /iris/v1/context-gateway/gateways -d "$gateway_payload"
    gateway_id="$(jq -er .gatewayId "$LOG_DIR/gateway-response")"
    gateway_request 201 POST /iris/v1/context-gateway/gateways -d "$empty_gateway_payload"
    empty_gateway_id="$(jq -er .gatewayId "$LOG_DIR/gateway-response")"
    gateway_request 201 POST "/iris/v1/context-gateway/gateways/$gateway_id/upstreams" -d "$upstream_payload"
    upstream_id="$(jq -er .upstreamId "$LOG_DIR/gateway-response")"
  fi
  gateway_path="/iris/v1/context-gateway/gateways/$gateway_id"
  empty_gateway_path="/iris/v1/context-gateway/gateways/$empty_gateway_id"
  upstream_path="$gateway_path/upstreams/$upstream_id"

  gateway_request 200 GET /iris/v1/context-gateway/gateways
  jq -e --arg id "$gateway_id" --arg name "$role Gateway" \
    'any(.items[]; .gatewayId == $id and .name == $name)' "$LOG_DIR/gateway-response" >/dev/null ||
    fail "$role must list its Gateway"
  gateway_request 200 GET "$gateway_path"
  jq -e --arg name "$role Gateway" '.name == $name' "$LOG_DIR/gateway-response" >/dev/null ||
    fail "$role must read its Gateway"
  gateway_revision="$(jq -er .revision "$LOG_DIR/gateway-response")"
  gateway_request 200 GET "$empty_gateway_path"
  empty_gateway_revision="$(jq -er .revision "$LOG_DIR/gateway-response")"
  gateway_request 200 GET "$gateway_path/upstreams"
  jq -e --arg id "$upstream_id" '(.items | length) == 1 and .items[0].upstreamId == $id' \
    "$LOG_DIR/gateway-response" >/dev/null || fail "$role must list its Upstream"
  gateway_request 200 GET "$upstream_path"
  jq -e '.name == "Browser Orders" and .activeCatalog.toolCount == 1 and .initialCatalogFailure == null' \
    "$LOG_DIR/gateway-response" >/dev/null || fail "$role must read its Upstream with a discovered catalog"
  upstream_revision="$(jq -er .revision "$LOG_DIR/gateway-response")"
  gateway_request 200 GET "$upstream_path/tools"
  jq -e '[.items[].name] == ["echo_region"]' "$LOG_DIR/gateway-response" >/dev/null ||
    fail "$role must read the real MCP tool catalog"
  echo "PASS: $role reads Gateway, Upstream and real MCP catalog through nginx"

  gateway_update="$(jq -cn --arg revision "$gateway_revision" \
    '{name: "Updated Browser Gateway", expectedRevision: $revision}')"
  upstream_update="$(jq -cn --arg revision "$upstream_revision" \
    '{name: "Updated Browser Orders", expectedRevision: $revision}')"
  if [ "$role" = viewer ]; then
    gateway_denied_write POST /iris/v1/context-gateway/gateways -d '{"name":"Refused Browser Gateway"}'
    gateway_denied_write PATCH "$gateway_path" -d "$gateway_update"
    gateway_denied_write POST "$gateway_path/upstreams" -d "$(jq '.namespace = "refused-orders"' <<<"$upstream_payload")"
    gateway_denied_write PATCH "$upstream_path" -d "$upstream_update"
    gateway_denied_write POST "$upstream_path/refresh"
  else
    gateway_request 200 PATCH "$gateway_path" -d "$gateway_update"
    gateway_request 200 GET "$gateway_path"
    jq -e --arg revision "$gateway_revision" '.name == "Updated Browser Gateway" and .revision != $revision' \
      "$LOG_DIR/gateway-response" >/dev/null || fail "$role Gateway update must persist and change the revision"
    gateway_revision="$(jq -er .revision "$LOG_DIR/gateway-response")"
    gateway_request 200 PATCH "$upstream_path" -d "$upstream_update"
    gateway_request 200 GET "$upstream_path"
    jq -e --arg revision "$upstream_revision" '.name == "Updated Browser Orders" and .revision != $revision' \
      "$LOG_DIR/gateway-response" >/dev/null || fail "$role Upstream update must persist and change the revision"
    gateway_request 200 POST "$upstream_path/refresh"
    jq -e '.activeCatalog.toolCount == 1' "$LOG_DIR/gateway-response" >/dev/null ||
      fail "$role refresh must publish the real MCP catalog"
    gateway_request 200 GET "$upstream_path/tools"
    jq -e '[.items[].name] == ["echo_region"]' "$LOG_DIR/gateway-response" >/dev/null ||
      fail "$role refreshed catalog must remain readable"
    gateway_request 200 GET "$upstream_path"
    upstream_revision="$(jq -er .revision "$LOG_DIR/gateway-response")"
    echo "PASS: $role creates, updates and refreshes real Gateway administration through nginx"
  fi

  if [ "$role" = viewer ] || [ "$role" = operator ]; then
    gateway_denied_write DELETE "$upstream_path?expectedRevision=$upstream_revision"
    gateway_denied_write DELETE "$empty_gateway_path?expectedRevision=$empty_gateway_revision"
  else
    gateway_request 204 DELETE "$upstream_path?expectedRevision=$upstream_revision"
    gateway_request 404 GET "$upstream_path"
    gateway_request 200 GET "$gateway_path/upstreams"
    jq -e '.items == []' "$LOG_DIR/gateway-response" >/dev/null || fail "$role deletion must remove the Upstream"
    gateway_request 204 DELETE "$gateway_path?expectedRevision=$gateway_revision"
    gateway_request 404 GET "$gateway_path"
    gateway_request 204 DELETE "$empty_gateway_path?expectedRevision=$empty_gateway_revision"
    gateway_request 404 GET "$empty_gateway_path"
    gateway_request 200 GET /iris/v1/context-gateway/gateways
    jq -e --arg id "$gateway_id" --arg empty "$empty_gateway_id" \
      'all(.items[]; .gatewayId != $id and .gatewayId != $empty)' "$LOG_DIR/gateway-response" >/dev/null ||
      fail "$role deletion must remove both Gateways"
    echo "PASS: $role deletes Upstreams and Gateways through nginx"
  fi
done <<'CASES'
viewer|viewer|["context_gateway_get"]
operator|memory-operator|["context_gateway_get","context_gateway_create","context_gateway_update"]
product_admin|memory-admin|["context_gateway_get","context_gateway_create","context_gateway_update","context_gateway_delete","context_gateway_token_update"]
suite_admin|suite-admin|["context_gateway_get","context_gateway_create","context_gateway_update","context_gateway_delete","context_gateway_token_update"]
CASES

role=unmapped-claims
expect_status 201 -H "Authorization: Bearer $(cat "$LOG_DIR/admin-token")" -H 'Content-Type: application/json' \
  -d '{"name":"Gateway protected from unmapped claims"}' "$context_gateway_base/iris/v1/context-gateway/gateways"
gateway_path="/iris/v1/context-gateway/gateways/$(jq -er .gatewayId "$LOG_DIR/http-response")"
expect_status 201 -H "Authorization: Bearer $(cat "$LOG_DIR/admin-token")" -H 'Content-Type: application/json' \
  -d '{"name":"Empty Gateway protected from unmapped claims"}' "$context_gateway_base/iris/v1/context-gateway/gateways"
empty_gateway_path="/iris/v1/context-gateway/gateways/$(jq -er .gatewayId "$LOG_DIR/http-response")"
expect_status 201 -H "Authorization: Bearer $(cat "$LOG_DIR/admin-token")" -H 'Content-Type: application/json' \
  -d "$upstream_payload" "$context_gateway_base$gateway_path/upstreams"
upstream_path="$gateway_path/upstreams/$(jq -er .upstreamId "$LOG_DIR/http-response")"

# Unmapped callers cannot inspect state, so a mapped viewer observes the denial's effects.
sign_in viewer
observer_session_cookie="$session_cookie"
expect_status 200 -H "Cookie: $session_cookie" "$SSO_BASE/auth/me"
csrf_token="$(jq -er '.csrfToken | select(type == "string" and length > 0)' "$LOG_DIR/http-response")"
observer_csrf_token="$csrf_token"
gateway_request 200 GET "$gateway_path"
gateway_update="$(jq -c '{name: "Refused unmapped update", expectedRevision: .revision}' "$LOG_DIR/gateway-response")"
gateway_snapshot "$LOG_DIR/unmapped-before"

while IFS='|' read -r username claims; do
  role="$username"
  sign_in "$username"
  expect_status 200 -H "Cookie: $session_cookie" "$SSO_BASE/auth/me"
  jq -e '.permissions.context_gateway == []' "$LOG_DIR/http-response" >/dev/null ||
    fail "$username session must not grant Context Gateway permissions"
  csrf_token="$(jq -er '.csrfToken | select(type == "string" and length > 0)' "$LOG_DIR/http-response")"

  expect_status 200 -H "Cookie: $session_cookie" "$SSO_BASE/api/http-test/unmapped-claims"
  jwt_payload "$(sed -n 's/^Authorization: Bearer //p' "$LOG_DIR/http-response" | tr -d '\r')" |
    jq -e --argjson expected "$claims" '((.roles // []) | sort) == ($expected | sort)' >/dev/null ||
    fail "$username must present the expected unmapped role claims"

  for path in /iris/v1/context-gateway/gateways "$gateway_path" "$gateway_path/upstreams" "$upstream_path" "$upstream_path/tools"; do
    gateway_request 403 GET "$path"
  done
  gateway_request 403 PATCH "$gateway_path" -d "$gateway_update"
  (
    session_cookie="$observer_session_cookie"
    csrf_token="$observer_csrf_token"
    gateway_snapshot "$LOG_DIR/unmapped-after"
  )
  cmp -s "$LOG_DIR/unmapped-before" "$LOG_DIR/unmapped-after" ||
    fail "$username changed Gateway administration state without a mapped role"
  echo "PASS: $username signs in with no Gateway permissions; reads and a valid update are denied with unchanged state"
done <<'CASES'
no-role|[]
unmapped-suite-admin|["suite_admin"]
CASES

role=tenant-observer
session_cookie="$observer_session_cookie"
csrf_token="$observer_csrf_token"
gateway_request 200 GET "$gateway_path"
gateway_update="$(jq -c '{name: "Refused foreign-tenant update", expectedRevision: .revision}' "$LOG_DIR/gateway-response")"
gateway_request 200 GET "$upstream_path"
upstream_update="$(jq -c '{name: "Refused foreign-tenant update", expectedRevision: .revision}' "$LOG_DIR/gateway-response")"
gateway_snapshot "$LOG_DIR/foreign-tenant-before"

while IFS='|' read -r username claims permissions; do
  role="$username"
  sign_in "$username"
  expect_status 200 -H "Cookie: $session_cookie" "$SSO_BASE/auth/me"
  jq -e --argjson expected "$permissions" \
    '(.permissions.context_gateway | sort) == ($expected | sort)' "$LOG_DIR/http-response" >/dev/null ||
    fail "$username session must contain its mapped Context Gateway permissions"
  csrf_token="$(jq -er '.csrfToken | select(type == "string" and length > 0)' "$LOG_DIR/http-response")"

  expect_status 200 -H "Cookie: $session_cookie" "$SSO_BASE/api/http-test/foreign-tenant-claims"
  jwt_payload "$(sed -n 's/^Authorization: Bearer //p' "$LOG_DIR/http-response" | tr -d '\r')" |
    jq -e --argjson expected "$claims" \
      '.tenant_id == "foreign-tenant" and (((.roles // []) | sort) == ($expected | sort))' >/dev/null ||
    fail "$username must present a foreign tenant and the expected mapped role claims"

  for path in /iris/v1/context-gateway/gateways "$gateway_path" "$empty_gateway_path" "$gateway_path/upstreams" "$upstream_path" "$upstream_path/tools"; do
    gateway_request 403 GET "$path"
  done
  gateway_request 403 PATCH "$gateway_path" -d "$gateway_update"
  gateway_request 403 PATCH "$upstream_path" -d "$upstream_update"
  (
    session_cookie="$observer_session_cookie"
    csrf_token="$observer_csrf_token"
    gateway_snapshot "$LOG_DIR/foreign-tenant-after"
  )
  cmp -s "$LOG_DIR/foreign-tenant-before" "$LOG_DIR/foreign-tenant-after" ||
    fail "$username changed another tenant's Gateway administration state"
  echo "PASS: $username signs in with mapped permissions; foreign-tenant reads and valid updates are denied with unchanged state"
done <<'CASES'
foreign-viewer|["viewer"]|["context_gateway_get"]
foreign-suite-admin|["suite-admin"]|["context_gateway_get","context_gateway_create","context_gateway_update","context_gateway_delete","context_gateway_token_update"]
CASES

role=csrf-operator
sign_in memory-operator
expect_status 200 -H "Cookie: $session_cookie" "$SSO_BASE/auth/me"
jq -e '.permissions.context_gateway | index("context_gateway_create") != null' "$LOG_DIR/http-response" >/dev/null ||
  fail "CSRF protection must be tested with an operator allowed to create Gateways"
csrf_token="$(jq -er '.csrfToken | select(type == "string" and length > 0)' "$LOG_DIR/http-response")"
csrf_gateway_payload='{"name":"Gateway created with valid CSRF and origin"}'

while IFS='|' read -r protection request_csrf request_origin; do
  csrf_headers=()
  if [ -n "$request_csrf" ]; then
    csrf_headers=(-H "X-CSRF-Token: $request_csrf")
  fi
  gateway_snapshot "$LOG_DIR/csrf-before"
  expect_status 403 -X POST -H "Cookie: $session_cookie" "${csrf_headers[@]}" -H "Origin: $request_origin" \
    -H 'Content-Type: application/json' -d "$csrf_gateway_payload" "$SSO_BASE/api/context-gateway/iris/v1/context-gateway/gateways"
  gateway_snapshot "$LOG_DIR/csrf-after"
  cmp -s "$LOG_DIR/csrf-before" "$LOG_DIR/csrf-after" ||
    fail "$protection changed Gateway administration state"
  echo "PASS: $protection denies an authorized operator's Gateway creation with unchanged state"
done <<CASES
missing CSRF||$SSO_BASE
wrong CSRF|incorrect-csrf-token|$SSO_BASE
hostile Origin|$csrf_token|http://evil.example
CASES

gateway_request 201 POST /iris/v1/context-gateway/gateways -d "$csrf_gateway_payload"
csrf_gateway_id="$(jq -er .gatewayId "$LOG_DIR/gateway-response")"
gateway_request 200 GET "/iris/v1/context-gateway/gateways/$csrf_gateway_id"
jq -e --arg id "$csrf_gateway_id" --argjson expected "$csrf_gateway_payload" \
  '.gatewayId == $id and .name == $expected.name' "$LOG_DIR/gateway-response" >/dev/null ||
  fail "valid CSRF and same-origin Gateway creation must persist the same payload"
echo "PASS: valid CSRF and same origin let the same operator create and read the Gateway with the same payload"

# A cold install must not leave nginx restarting on the auth upstream's hostname.
restarts="$(kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/instance=$SSO_RELEASE" \
  -o jsonpath='{range .items[*]}{.metadata.name}={.status.containerStatuses[*].restartCount} {end}')"
echo "pod restarts: $restarts"
[ -n "$restarts" ] || fail "could not read the SSO release's pod restart counts"
for count in $(tr ' ' '\n' <<<"$restarts" | sed -n 's/^.*=//p'); do
  [ "$count" = "0" ] || {
    dump_restarted_pods
    fail "a pod restarted during the SSO install: $restarts"
  }
done

echo "OK"
