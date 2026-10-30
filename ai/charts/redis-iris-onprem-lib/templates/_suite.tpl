{{/*
redis-iris suite helpers (TDD MOD-19479 "Values precedence"). A product chart resolves every
suite-wide field through these so one global.iris block configures the whole suite while a
standalone install renders exactly as before.

Precedence:
  standalone (no global.iris)  the local value when set, else the per-call default
  umbrella (global.iris set)   the global value, else its contract default; a set local value
                               that differs fails the render, naming <prefix><path>
Unset markers: nil (absent or null) and "" mean unset. An explicit [] / {} / false is a value.

Every helper takes a dict with root (the chart root) and, where a local value can conflict,
prefix (the umbrella alias with a trailing dot, e.g. "memory."). Lists and maps come back as
JSON; read them with fromJson / fromJsonArray (both in Helm v3.10).
*/}}

{{- define "redis-onprem.suite.iris" -}}
{{- toJson (default (dict) (default (dict) .Values.global).iris) -}}
{{- end }}

{{/* "true" under the redis-iris umbrella, else "". Call with the chart root. */}}
{{- define "redis-onprem.suite.enabled" -}}
{{- if (default (dict) .Values.global).iris -}}true{{- end -}}
{{- end }}

{{/*
Core resolution. Returns JSON {"value": <resolved>}.
  root, prefix
  path           local field path, relative to the chart (e.g. tenantId)
  local          the chart's local value
  globalPath     list of keys under global.iris (e.g. (list "auth" "oidc" "audience"))
  globalDefault  contract default under the umbrella when the global key is unset
  default        standalone default when the local value is unset
*/}}
{{- define "redis-onprem.suite.value" -}}
{{- if include "redis-onprem.suite.enabled" .root -}}
{{- $g := include "redis-onprem.suite.iris" .root | fromJson -}}
{{- range $k := .globalPath -}}
{{- $g = index ((kindIs "map" $g) | ternary $g (dict)) $k -}}
{{- end -}}
{{- if or (kindIs "invalid" $g) (and (kindIs "string" $g) (eq $g "")) -}}
{{- $g = .globalDefault -}}
{{- end -}}
{{- include "redis-onprem.suite.owned" (dict "prefix" .prefix "path" .path "local" .local "derived" $g "source" (printf "global.iris.%s" (join "." .globalPath))) -}}
{{- else -}}
{{- $set := not (or (kindIs "invalid" .local) (and (kindIs "string" .local) (eq .local ""))) -}}
{{- toJson (dict "value" ($set | ternary .local .default)) -}}
{{- end -}}
{{- end }}

{{/*
A value the suite owns under the umbrella: returns JSON {"value": derived}, and fails, naming
<prefix><path>, when the local value is set and differs. Call it only under the umbrella.
  prefix, path, local, derived
  source  what derived comes from (default "the value redis-iris derives from global.iris")
*/}}
{{- define "redis-onprem.suite.owned" -}}
{{- $set := not (or (kindIs "invalid" .local) (and (kindIs "string" .local) (eq .local ""))) -}}
{{- if and $set (ne (toJson .local) (toJson .derived)) -}}
{{- fail (printf "%s%s (%s) conflicts with %s (%s); remove the product value" (default "" .prefix) .path (toJson .local) (default "the value redis-iris derives from global.iris" .source) (toJson .derived)) -}}
{{- end -}}
{{- toJson (dict "value" .derived) -}}
{{- end }}

{{/* Tenant. Takes root, prefix, path (default tenantId), local, default (standalone). */}}
{{- define "redis-onprem.suite.tenantId" -}}
{{- (include "redis-onprem.suite.value" (dict "root" .root "prefix" .prefix "path" (default "tenantId" .path) "local" .local "globalPath" (list "tenantId") "globalDefault" "default" "default" (default "" .default)) | fromJson).value -}}
{{- end }}

{{/* Cluster DNS domain. Takes root, prefix, path (default clusterDomain), local. */}}
{{- define "redis-onprem.suite.clusterDomain" -}}
{{- (include "redis-onprem.suite.value" (dict "root" .root "prefix" .prefix "path" (default "clusterDomain" .path) "local" .local "globalPath" (list "clusterDomain") "globalDefault" "cluster.local" "default" "cluster.local") | fromJson).value -}}
{{- end }}

{{/* <name>.<namespace>.svc.<clusterDomain>. Takes root, name, and the clusterDomain args. */}}
{{- define "redis-onprem.suite.fqdn" -}}
{{- printf "%s.%s.svc.%s" .name .root.Release.Namespace (include "redis-onprem.suite.clusterDomain" .) -}}
{{- end }}

{{/*
License Secret reference as JSON {existingSecret, secretKey}. Takes root, prefix, path (default
license), local (the chart's license map), defaultSecretKey (standalone).
*/}}
{{- define "redis-onprem.suite.license" -}}
{{- $local := default (dict) .local -}}
{{- $path := default "license" .path -}}
{{- $secret := include "redis-onprem.suite.value" (dict "root" .root "prefix" .prefix "path" (printf "%s.existingSecret" $path) "local" $local.existingSecret "globalPath" (list "license" "existingSecret") "globalDefault" "iris-license" "default" "") | fromJson -}}
{{- $key := include "redis-onprem.suite.value" (dict "root" .root "prefix" .prefix "path" (printf "%s.secretKey" $path) "local" $local.secretKey "globalPath" (list "license" "secretKey") "globalDefault" "license.key" "default" (default "" .defaultSecretKey)) | fromJson -}}
{{- toJson (dict "existingSecret" $secret.value "secretKey" $key.value) -}}
{{- end }}

{{/*
global.* fallbacks outside global.iris, unchanged from the per-chart helpers they replace: the
local value wins, then global.<field>. Call with the chart root.
*/}}
{{- define "redis-onprem.suite.securityProfile" -}}
{{- $global := default (dict) (default (dict) .Values.global).security -}}
{{- default (default "" $global.profile) (default (dict) .Values.security).profile -}}
{{- end }}

{{- define "redis-onprem.suite.caCertSecret" -}}
{{- $global := default (dict) (default (dict) .Values.global).tls -}}
{{- default (default "" $global.caCertSecret) (default (dict) .Values.tls).caCertSecret -}}
{{- end }}

{{- define "redis-onprem.suite.imagePullSecrets" -}}
{{- toJson (default (default (list) (default (dict) .Values.global).imagePullSecrets) .Values.imagePullSecrets) -}}
{{- end }}

{{/*
OIDC validation inputs as JSON {issuer, accessTokenIssuer, jwksURI, audience, roleClaims,
allowInsecureTransport}. Takes root, prefix,
  local     map of the chart's local values keyed by the names above (any subset)
  paths     map of their local field paths, same keys
  defaults  standalone defaults, same keys (audience and roleClaims typically)
accessTokenIssuer falls back to issuer. allowInsecureTransport is true when the effective
access-token issuer is http:// and the security profile is not fips.
*/}}
{{- define "redis-onprem.suite.oidc" -}}
{{- $local := default (dict) .local -}}
{{- $paths := default (dict) .paths -}}
{{- $defaults := mergeOverwrite (dict "issuer" "" "accessTokenIssuer" "" "jwksURI" "" "audience" "") (default (dict) .defaults) -}}
{{- $globalDefaults := dict "issuer" "" "accessTokenIssuer" "" "jwksURI" "" "audience" "api://redis-iris" "roleClaims" (list "groups") -}}
{{- $out := dict -}}
{{- range $f := list "issuer" "accessTokenIssuer" "jwksURI" "audience" "roleClaims" -}}
{{- $r := include "redis-onprem.suite.value" (dict "root" $.root "prefix" $.prefix "path" (default $f (index $paths $f)) "local" (index $local $f) "globalPath" (list "auth" "oidc" $f) "globalDefault" (index $globalDefaults $f) "default" (index $defaults $f)) | fromJson -}}
{{- $_ := set $out $f $r.value -}}
{{- end -}}
{{- $_ := set $out "accessTokenIssuer" (default (default "" $out.issuer) $out.accessTokenIssuer) -}}
{{- $_ := set $out "allowInsecureTransport" (and (hasPrefix "http://" $out.accessTokenIssuer) (ne (include "redis-onprem.suite.securityProfile" .root) "fips")) -}}
{{- toJson $out -}}
{{- end }}

{{/*
ServiceAccount token issuer for workload identity as JSON {issuer, jwksURI}. Defaults:
https://kubernetes.default.svc.<clusterDomain> and <issuer>/openid/v1/jwks. Takes root.
*/}}
{{- define "redis-onprem.suite.workloadIdentity" -}}
{{- $wi := default (dict) (include "redis-onprem.suite.iris" .root | fromJson).workloadIdentity -}}
{{- $issuer := default (printf "https://kubernetes.default.svc.%s" (include "redis-onprem.suite.clusterDomain" (dict "root" .root))) $wi.issuer -}}
{{- toJson (dict "issuer" $issuer "jwksURI" (default (printf "%s/openid/v1/jwks" $issuer) $wi.jwksURI)) -}}
{{- end }}

{{/*
"true" when global.iris.products.<product>.enabled. Takes root, product: the products key
(memory, playbook, lens, contextGateway) or the canonical id (agent_memory, context_gateway).
*/}}
{{- define "redis-onprem.suite.productEnabled" -}}
{{- $key := index (dict "agent_memory" "memory" "context_gateway" "contextGateway") .product | default .product -}}
{{- $products := default (dict) (include "redis-onprem.suite.iris" .root | fromJson).products -}}
{{- if dig $key "enabled" false $products -}}true{{- end -}}
{{- end }}

{{- define "redis-onprem.suite.roleBindings.raw" -}}
{{- toJson (default (list) (dig "auth" "roleBindings" (list) (include "redis-onprem.suite.iris" .root | fromJson))) -}}
{{- end }}

{{/*
group -> role for one canonical product id (agent_memory, playbook, lens, context_gateway,
identity): that product's bindings plus suite scope. A group bound to two roles fails. JSON map.
Takes root, product.
*/}}
{{- define "redis-onprem.suite.roleMappings" -}}
{{- $out := dict -}}
{{- range $b := include "redis-onprem.suite.roleBindings.raw" . | fromJsonArray -}}
{{- if or (not $b.product) (eq $b.product $.product) -}}
{{- if and (hasKey $out $b.group) (ne (index $out $b.group) $b.role) -}}
{{- fail (printf "global.iris.auth.roleBindings: group %q is bound to both %q and %q for %s" $b.group (index $out $b.group) $b.role $.product) -}}
{{- end -}}
{{- $_ := set $out $b.group $b.role -}}
{{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end }}

{{/*
UI sso.roleMappings: product -> group -> role for every enabled product and identity (always),
suite scope copied under each. JSON map. Takes root.
*/}}
{{- define "redis-onprem.suite.ui.roleMappings" -}}
{{- $out := dict -}}
{{- range $p := list "agent_memory" "playbook" "lens" "context_gateway" "identity" -}}
{{- if or (eq $p "identity") (include "redis-onprem.suite.productEnabled" (dict "root" $.root "product" $p)) -}}
{{- $_ := set $out $p (include "redis-onprem.suite.roleMappings" (dict "root" $.root "product" $p) | fromJson) -}}
{{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end }}

{{/*
Identity Service controlAuth.roleBindings: {claim_value, role, scope, product}. Suite scope ->
scope global; product scope -> scope product with the IdS product id, only for enabled products;
identity bindings are UI-only and dropped. JSON list. Takes root.
*/}}
{{- define "redis-onprem.suite.ids.roleBindings" -}}
{{- $ids := dict "agent_memory" "memory" "playbook" "playbook" "lens" "lens" "context_gateway" "context-gateway" -}}
{{- $out := list -}}
{{- range $b := include "redis-onprem.suite.roleBindings.raw" . | fromJsonArray -}}
{{- if not $b.product -}}
{{- $out = append $out (dict "claim_value" $b.group "role" $b.role "scope" "global") -}}
{{- else if and (hasKey $ids $b.product) (include "redis-onprem.suite.productEnabled" (dict "root" $.root "product" $b.product)) -}}
{{- $out = append $out (dict "claim_value" $b.group "role" $b.role "scope" "product" "product" (index $ids $b.product)) -}}
{{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end }}

{{/*
Identity Service credential under the umbrella as JSON {existingSecret, secretKey}: the supplied
aggregate Secret, else the product's generated one, with the key named after the credential:
  dataplane     global.iris.secrets.dataplaneServiceCredentials (generated:
                iris-<product>-dataplane-credential), key <product>-dp
  controlplane  global.iris.secrets.controlplaneInternalTokens (generated:
                iris-<product>-internal-token), key <product>
Takes root, product (memory, playbook, ...), credential (dataplane|controlplane), and optionally
local + field: a local existingSecret naming another Secret fails, naming field. Standalone
returns {}.
*/}}
{{- define "redis-onprem.suite.credential" -}}
{{- if not (include "redis-onprem.suite.enabled" .root) -}}
{}
{{- else -}}
{{- $c := index (dict
  "dataplane" (dict "aggregate" "dataplaneServiceCredentials" "generated" (printf "iris-%s-dataplane-credential" .product) "key" (printf "%s-dp" .product))
  "controlplane" (dict "aggregate" "controlplaneInternalTokens" "generated" (printf "iris-%s-internal-token" .product) "key" .product)) .credential -}}
{{- $secret := default $c.generated (dig "secrets" $c.aggregate "existingSecret" "" (include "redis-onprem.suite.iris" .root | fromJson)) -}}
{{- if and .local (ne .local $secret) -}}
{{- fail (printf "%s (%q) conflicts with the suite's %q (global.iris.secrets.%s.existingSecret): under redis-iris the suite supplies this credential; unset %s" .field .local $secret $c.aggregate .field) -}}
{{- end -}}
{{- toJson (dict "existingSecret" $secret "secretKey" $c.key) -}}
{{- end -}}
{{- end }}

{{/*
The suite's Identity Service Runtime as JSON {baseURL, allowInsecureTransport}: plain http inside
the cluster at 1.0. Takes root.
*/}}
{{- define "redis-onprem.suite.identityService" -}}
{{- /* Product charts render before the umbrella's own guard, which would name this. */ -}}
{{- if and (include "redis-onprem.suite.enabled" .root) (eq (include "redis-onprem.suite.securityProfile" .root) "fips") -}}
{{- fail "global.security.profile: fips is not supported by redis-iris 0.1; FIPS support is planned for redis-iris 1.1" -}}
{{- end -}}
{{- toJson (dict "baseURL" (printf "http://%s:9200" (include "redis-onprem.suite.fqdn" (dict "root" .root "name" "iris-identity-service"))) "allowInsecureTransport" true) -}}
{{- end }}
