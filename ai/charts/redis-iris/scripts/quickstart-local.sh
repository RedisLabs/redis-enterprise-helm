#!/usr/bin/env bash
# Local quickstart for the redis-iris suite (examples/quickstart-local.yaml).
#
#   quickstart-local.sh setup    create the namespace, local Redis, and every Secret the preset names
#   quickstart-local.sh tokens   print every admin token, then port-forward the UI on localhost:8080
#
# Environment: NAMESPACE (redis-ai), RELEASE (iris), LICENSE_FILE (a signed suite license, default
# ./license.key; required), DEV_LICENSE=1 (use a placeholder license; only the development images accept
# it, the published images enforce the license), OPENAI_API_KEY (stored only in the Memory Secret; unset means noop models),
# ALLOW_CONTEXT=1 (run against a context that is not kind-*), UI_PORT (8080).
# The chart names the generated token Secrets and the UI Service with a fixed iris- prefix, whatever RELEASE is.
# `setup` is idempotent. It binds system:service-account-issuer-discovery cluster-wide, so it
# refuses any context but kind-* unless ALLOW_CONTEXT=1.
set -euo pipefail

NAMESPACE="${NAMESPACE:-redis-ai}"
RELEASE="${RELEASE:-iris}"
LICENSE_FILE="${LICENSE_FILE-./license.key}"
UI_PORT="${UI_PORT:-8080}"
# Every command runs against the context validated at the start, whatever the caller switches meanwhile.
CTX=""
kubectl() { if [ -n "$CTX" ]; then command kubectl --context "$CTX" "$@"; else command kubectl "$@"; fi; }
k() { kubectl -n "$NAMESPACE" "$@"; }
apply() { kubectl apply -f - >/dev/null; }
rand() { head -c 36 /dev/urandom | base64 | tr -d '\n'; }
# once <secret> <kubectl create secret generic arguments>: create the Secret unless it exists.
once() { local name="$1"; shift; k get secret "$name" >/dev/null 2>&1 || k create secret generic "$name" "$@" >/dev/null; }
# The preset and the chart version sit next to this script, in a repository checkout and in an unpacked chart.
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# pin_context: refuse any context but kind-* unless ALLOW_CONTEXT=1, then pin every later kubectl to it.
pin_context() {
  CTX="$(kubectl config current-context)"
  case "$CTX" in kind-*) ;; *)
    [ "${ALLOW_CONTEXT:-}" = 1 ] || { echo "refusing context $CTX: not kind-* (set ALLOW_CONTEXT=1 to override)" >&2; exit 1; } ;;
  esac
}

setup() {
  cat <<EOF
This script prepares a local cluster for the redis-iris quickstart. It will:
  1. create the namespace $NAMESPACE and a cluster-wide binding for service-account issuer discovery;
  2. start five single-replica Redis Deployments (metadata, Playbook content, telemetry, gateway secrets, Intent);
  3. create the Secrets examples/quickstart-local.yaml names: product storage, the license, and every
     credential and admin token (created once, never replaced on a rerun).
It does not install the chart; the last line shows that command. Safe to rerun.

EOF
  pin_context
  # The published images enforce the license: fail before changing the cluster.
  [ -f "$LICENSE_FILE" ] || [ "${DEV_LICENSE:-}" = 1 ] || {
    echo "no license file at '$LICENSE_FILE': set LICENSE_FILE to a signed suite license (DEV_LICENSE=1 is for the development images only)" >&2
    exit 1
  }
  echo "==> Setup in namespace $NAMESPACE (context $CTX)"
  # Only a namespace this script created (label iris-quickstart=owned) receives fixtures: another
  # demo's namespace has Secrets and Redis Deployments with the same names, and setup would replace them.
  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    [ "$(kubectl get namespace "$NAMESPACE" -o 'jsonpath={.metadata.labels.iris-quickstart}')" = owned ] || {
      echo "refusing namespace $NAMESPACE: it exists and was not created by this script (use another NAMESPACE or delete it)" >&2
      exit 1
    }
  else
    # One call creates the namespace with its ownership label, so a failure cannot leave an unlabelled one.
    kubectl create -f - >/dev/null <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
  labels:
    iris-quickstart: owned
YAML
  fi

  # The Memory worker's identity is verified against the cluster's issuer: its discovery
  # documents need anonymous access and the cluster CA.
  kubectl create clusterrolebinding "$NAMESPACE-issuer-discovery" \
    --clusterrole=system:service-account-issuer-discovery --group=system:unauthenticated \
    --dry-run=client -o yaml | apply
  local ca="" attempt
  for attempt in $(seq 60); do # the controller publishes the ConfigMap just after the namespace exists
    ca="$(k get configmap kube-root-ca.crt -o 'jsonpath={.data.ca\.crt}' 2>/dev/null || true)"
    [ -z "$ca" ] || break
    sleep 1
  done
  [ -n "$ca" ] || { echo "kube-root-ca.crt not published in $NAMESPACE" >&2; exit 1; }
  k create secret generic cluster-ca \
    --from-literal=ca.crt="$ca" \
    --dry-run=client -o yaml | apply

  # metadata-db holds every keyspace but Playbook content (Playbook refuses to keep its content
  # beside its metadata); Lens, Context Gateway credentials and Intent Router get their own.
  local redis
  for redis in metadata-db playbook-content telemetry-db gateway-secrets intent-db; do
    k apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: $redis}
spec:
  replicas: 1
  selector: {matchLabels: {app: $redis}}
  template:
    metadata: {labels: {app: $redis}}
    spec:
      containers:
        - name: redis
          image: redis:8
          ports: [{name: redis, containerPort: 6379}]
          readinessProbe: {exec: {command: ["redis-cli", "ping"]}, periodSeconds: 1}
---
apiVersion: v1
kind: Service
metadata: {name: $redis}
spec:
  selector: {app: $redis}
  ports: [{name: redis, port: 6379, targetPort: redis}]
YAML
  done

  local meta="redis://metadata-db:6379" key="${OPENAI_API_KEY:-sk-test-dummy}" openai=""
  # The openai embedder entry must be complete (a base URL is required), and the noop preset has no use for one.
  [ -z "${OPENAI_API_KEY:-}" ] || openai="embedders_connection_details: {openai: {base_url: https://api.openai.com, credentials: {type: static, api_key: $key}}}"
  k create secret generic ids-metadata --from-literal=metadata.yaml="metadata: {urls: [\"$meta\"]}" \
    --dry-run=client -o yaml | apply
  # The key only reaches this Secret (never an argument list or the output).
  # A rerun without OPENAI_API_KEY keeps the Secret, so an installed OpenAI key is never replaced by the dummy.
  if [ -n "${OPENAI_API_KEY:-}" ] || ! k get secret mem-secrets >/dev/null 2>&1; then
    k create secret generic mem-secrets --from-file=overlay.yaml=/dev/stdin --dry-run=client -o yaml <<YAML | apply
metadata: {urls: ["$meta"]}
databases: {"1": {urls: ["$meta"]}}
background_jobs:
  redis: {urls: ["$meta"]}
  idempotency: {urls: ["$meta"]}
$openai
classification: {llm: {credentials: {api_key: $key}}}
promote_session_memory: {strategies: {instruct: {llm: {credentials: {api_key: $key}}}}}
YAML
  fi
  k create secret generic playbook-storage --from-file=playbook-storage.yaml=/dev/stdin --dry-run=client -o yaml <<YAML | apply
storage:
  metadata: {urls: ["$meta"]}
  content: {urls: ["redis://playbook-content:6379"]}
YAML
  k create secret generic lens-storage \
    --from-literal=lens-dataplane-storage.yaml="storage: {streams: {urls: [redis://telemetry-db:6379]}, content: {urls: [redis://telemetry-db:6379]}, index: {urls: [redis://telemetry-db:6379]}, metadata: {urls: [\"$meta\"]}}" \
    --from-literal=lens-controlplane-storage.yaml="{storage: {metadata: {urls: [\"$meta\"]}}, dram: {urls: [redis://telemetry-db:6379]}}" \
    --dry-run=client -o yaml | apply
  k create secret generic intent-storage \
    --from-literal=intent-controlplane-storage.yaml="storage: {metadata: {urls: [\"$meta\"]}}" \
    --from-literal=intent-dataplane-storage.yaml="{storage: {redis: {urls: [redis://intent-db:6379]}}, runtime: {redis: {urls: [\"$meta\"]}}}" \
    --dry-run=client -o yaml | apply
  k create secret generic gateway-metadata --from-literal=config.yaml="{\"metadata_db\":{\"urls\":[\"$meta\"]}}" \
    --dry-run=client -o yaml | apply
  k create secret generic gateway-credential-redis \
    --from-literal=config.yaml='{"credential_storage":{"redis":{"urls":["redis://gateway-secrets:6379"]}}}' \
    --dry-run=client -o yaml | apply
  # A rerun must keep the keyring: a new key could not decrypt stored Upstream credentials.
  if ! k get secret gateway-keyring >/dev/null 2>&1; then
    k create secret generic gateway-keyring --from-literal=k1="$(head -c 32 /dev/urandom | base64)" >/dev/null
  fi

  # The preset sets secrets.generate: false, so the chart makes no credential. Create each one once and never
  # overwrite it (a rerun keeps every token). The names are the ones the chart reads and `tokens` prints.
  # Declare, then assign: the portable form for Bash 3.2 (macOS /bin/bash).
  local products="memory playbook lens context-gateway intent" product
  local -a dataplane internal
  dataplane=()
  internal=()
  for product in $products; do
    dataplane+=("--from-literal=$product-dp=$(rand)")
    internal+=("--from-literal=$product=$(rand)")
  done
  once iris-dataplane-credentials "${dataplane[@]}"
  once iris-internal-tokens "${internal[@]}"
  for product in $products; do
    once "iris-$product-admin-token" "--from-literal=token=$(rand)"
  done
  once iris-identity-service-control-token "--from-literal=token=$(rand)"

  if [ -f "$LICENSE_FILE" ]; then
    k create secret generic iris-license --from-file="license=$LICENSE_FILE" --dry-run=client -o yaml | apply
  else
    echo "warning: using a placeholder license; only the development images accept it" >&2
    k create secret generic iris-license --from-literal=license=dev-license-not-enforced --dry-run=client -o yaml | apply
  fi

  for redis in metadata-db playbook-content telemetry-db gateway-secrets intent-db; do
    k rollout status "deployment/$redis" --timeout=3m
  done
  local chart_version
  chart_version="$(sed -n 's/^version: *//p' "$CHART_DIR/Chart.yaml" 2>/dev/null | head -n 1)"
  cat <<EOF

Setup done. Next, install the chart (this is the command you want now):
  helm upgrade --install $RELEASE redis-ai/redis-iris${chart_version:+ --version $chart_version} -n $NAMESPACE --wait -f $CHART_DIR/examples/quickstart-local.yaml
Then verify and sign in:
  helm test $RELEASE -n $NAMESPACE
  bash $0 tokens
EOF
}

tokens() {
  pin_context
  # Same guard as setup: another install's namespace must not have its admin tokens printed.
  [ "$(kubectl get namespace "$NAMESPACE" -o 'jsonpath={.metadata.labels.iris-quickstart}' 2>/dev/null || true)" = owned ] || {
    echo "namespace $NAMESPACE in context $CTX is missing or was not created by this script: run setup first, or check NAMESPACE and the current context" >&2
    exit 1
  }
  echo "==> Reading tokens from namespace $NAMESPACE (context $CTX)"
  local out="" product secret value
  for product in memory playbook lens context-gateway intent identity-service-control; do
    secret="iris-$product-admin-token"
    [ "$product" != identity-service-control ] || secret="iris-identity-service-control-token"
    value="$(k get secret "$secret" -o 'go-template={{.data.token | base64decode}}')" && [ -n "$value" ] || {
      echo "Secret $secret is missing or empty in namespace $NAMESPACE: run setup first" >&2
      exit 1
    }
    out+="$product: $value"$'\n'
  done
  printf '%s' "$out"
  echo "UI on http://localhost:$UI_PORT (Admin Token mode: paste a token above); Ctrl-C stops the port-forward"
  k port-forward svc/iris-ui "$UI_PORT:8080"
}

case "${1:-}" in
  setup) setup ;;
  tokens) tokens ;;
  *) echo "usage: $0 setup|tokens" >&2; exit 2 ;;
esac
