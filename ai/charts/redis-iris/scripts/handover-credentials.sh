#!/usr/bin/env bash
# Hand the credentials redis-iris generated (global.iris.secrets.generate: true) over to external
# references (README "Hand over generated credentials", MOD-20913). It copies each product's
# iris-<product>-dataplane-credential and iris-<product>-internal-token value, unchanged, into the two
# aggregates that generate: false reads, and prints a values overlay (generate: false and the two
# aggregates, no value) on stdout. The admin tokens, the Control token and the session key stay where
# they are, and so do the references your values (or the chart defaults) set for them: the overlay
# never changes which Secret one of them selects.
#
#   NAMESPACE=redis-ai PRODUCTS="memory playbook" bash scripts/handover-credentials.sh >handover-values.yaml
#
# PRODUCTS     every enabled product, by id: memory playbook lens context-gateway intent
# RELEASE      the release name, for the aggregates' instance label (default iris)
# DATAPLANE_SECRET, INTERNAL_SECRET   the aggregates to create (default iris-dataplane-credentials,
#              iris-internal-tokens)
# KUBECTL      the kubectl command (default kubectl), for example "kubectl --context prod"
#
# Values pass only through kubectl's output, shell variables and pipes: never a command argument,
# stdout or stderr (it turns tracing off, even under bash -x). It creates the aggregates with kubectl
# create, so an aggregate that appears meanwhile fails it. An existing aggregate with exactly the keys
# and values it would create is accepted (the retry after a partial run); any other is refused, never
# overwritten. It deletes and changes nothing: remove the per-product Secrets yourself once the suite
# works on the aggregates and you no longer roll back past the handover.
set -euo pipefail
set +x

: "${NAMESPACE:?set NAMESPACE to the release namespace}"
: "${PRODUCTS:?set PRODUCTS to the enabled products, for example PRODUCTS=\"memory playbook\"}"
RELEASE="${RELEASE:-iris}"
DATAPLANE_SECRET="${DATAPLANE_SECRET:-iris-dataplane-credentials}"
INTERNAL_SECRET="${INTERNAL_SECRET:-iris-internal-tokens}"
read -r -a KUBE <<<"${KUBECTL:-kubectl}"

die() {
  echo "handover: $*" >&2
  exit 1
}
k() { "${KUBE[@]}" -n "$NAMESPACE" "$@"; }

[ "$DATAPLANE_SECRET" != "$INTERNAL_SECRET" ] || die "DATAPLANE_SECRET and INTERNAL_SECRET must differ"
seen=" "
for product in $PRODUCTS; do
  case "$product" in
    memory | playbook | lens | context-gateway | intent) ;;
    *) die "unknown product $product (memory playbook lens context-gateway intent)" ;;
  esac
  case "$seen" in *" $product "*) die "$product is listed twice in PRODUCTS" ;; esac
  seen="$seen$product "
done
# A product left out would get no keys in the aggregates, and a rerun cannot add them.
for product in memory playbook lens context-gateway intent; do
  case "$seen" in *" $product "*) continue ;; esac
  if k get secret "iris-$product-internal-token" >/dev/null 2>&1; then
    die "Secret iris-$product-internal-token exists, but $product is not in PRODUCTS: list every enabled product (listing a disabled product's leftovers is harmless: its keys stay unused)"
  fi
done
for name in "$DATAPLANE_SECRET" "$INTERNAL_SECRET"; do
  case "$name" in
    iris-*-dataplane-credential | iris-*-internal-token | iris-*-admin-token | iris-identity-service-control-token | iris-ui-session-key)
      die "$name is a generated credential name; choose another aggregate name" ;;
  esac
done

# value <secret> <key>: the base64 value, empty when the key is missing; fails when the Secret is.
value() { k get secret "$1" -o go-template="{{ with index .data \"$2\" }}{{ . }}{{ end }}"; }

# same <aggregate> <source suffix> <key suffix>: the aggregate holds exactly one key per product, each
# equal to that product's source value. A failed read fails it (two failed reads are not equal values).
same() {
  local keys want="" product got src
  keys="$(k get secret "$1" -o go-template='{{ range $k, $v := .data }}{{ $k }} {{ end }}')" || return 1
  for product in $PRODUCTS; do want="$want$product$3 "; done
  [ "$(tr ' ' '\n' <<<"$keys" | sed '/^$/d' | sort)" = "$(tr ' ' '\n' <<<"$want" | sed '/^$/d' | sort)" ] || return 1
  for product in $PRODUCTS; do
    got="$(value "$1" "$product$3")" || return 1
    src="$(value "iris-$product-$2" "$product$3")" || return 1
    [ -n "$src" ] && [ "$got" = "$src" ] || return 1
  done
}

# aggregate <name> <source suffix> <key suffix>
aggregate() {
  local name="$1" data="" product v
  if k get secret "$name" >/dev/null 2>&1; then
    same "$@" || die "Secret $name already exists with other keys or values, or could not be read; it was not changed. Check what created it, then choose another name or remove it and run this again"
    echo "handover: $name already holds these credentials (an earlier run); unchanged" >&2
    return
  fi
  for product in $PRODUCTS; do
    v="$(value "iris-$product-$2" "$product$3")"
    data="$data${data:+,}\"$product$3\":\"$v\""
  done
  printf '{"apiVersion":"v1","kind":"Secret","type":"Opaque","metadata":{"name":"%s","labels":{"app.kubernetes.io/name":"redis-iris","app.kubernetes.io/instance":"%s","app.kubernetes.io/component":"credentials"}},"data":{%s}}' \
    "$name" "$RELEASE" "$data" | k create -f - >&2 \
    || die "could not create $name; nothing was overwritten. Run this again once the cause is fixed"
  same "$@" || die "$name does not hold the copied values; delete it and run this again"
}

# Every source must exist with a non-empty value before anything is created.
for product in $PRODUCTS; do
  for source in "dataplane-credential $product-dp" "internal-token $product"; do
    read -r suffix key <<<"$source"
    v="$(value "iris-$product-$suffix" "$key" 2>/dev/null)" || die "Secret iris-$product-$suffix is missing: is $product enabled in this namespace?"
    [ -n "$v" ] || die "Secret iris-$product-$suffix has no $key"
  done
done
aggregate "$DATAPLANE_SECRET" dataplane-credential -dp
aggregate "$INTERNAL_SECRET" internal-token ""
echo "handover: $DATAPLANE_SECRET and $INTERNAL_SECRET hold the values of: $PRODUCTS" >&2
echo "handover: the overlay leaves the admin token, Control token and session key references as your values set them (the defaults name the generated Secrets, which stay)" >&2

# The overlay: the mode and the two aggregates, no value.
echo "# scripts/handover-credentials.sh: generate: false and the handed-over aggregates, no value."
echo "global:"
echo "  iris:"
echo "    secrets:"
echo "      generate: false"
echo "      dataplaneServiceCredentials:"
echo "        existingSecret: $DATAPLANE_SECRET"
echo "      controlplaneInternalTokens:"
echo "        existingSecret: $INTERNAL_SECRET"
