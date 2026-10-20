{{- define "iris-identity-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name, truncated to the 63-character DNS label limit. A
release name that already contains the chart name is used as is.
*/}}
{{- define "iris-identity-service.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := include "iris-identity-service.name" . }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "iris-identity-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "iris-identity-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "iris-identity-service.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "iris-identity-service.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Generated Secret name: the fullname, truncated so that it plus .suffix fits
the 63-character limit.
*/}}
{{- define "iris-identity-service.generatedSecretName" -}}
{{- printf "%s%s" (include "iris-identity-service.fullname" .root | trunc (int (sub 63 (len .suffix))) | trimSuffix "-") .suffix -}}
{{- end }}

{{/*
Every Secret reference, as JSON, so guards, config, volumes, annotations and
NOTES all see the same names:
  metadata:    {secret, key, checksum}
  control:     {secret, key, generated, checksum}
  credentials: [{name, subject, operations, products, secret, key, generated, checksum}]
  validators:  {<product>: {baseURL, secret, key, checksum}}, enabled only
*/}}
{{- define "iris-identity-service.resolved" -}}
{{- $root := . -}}
{{- $metadata := .Values.metadata -}}
{{- $control := .Values.control -}}
{{- $controlSecret := toString (default "" $control.existingSecret) -}}
{{- $controlGenerated := and (not $controlSecret) $control.autoGenerate -}}
{{- if $controlGenerated }}{{- $controlSecret = include "iris-identity-service.generatedSecretName" (dict "root" $root "suffix" "-control-token") -}}{{- end -}}
{{- $credentials := list -}}
{{- range (default (dict) .Values.runtime).serviceCredentials }}
{{- $secret := toString (default "" .existingSecret) -}}
{{- $generated := and (not $secret) .autoGenerate -}}
{{- if and $generated .generatedSecretName }}{{- $secret = toString .generatedSecretName -}}
{{- else if and $generated .name }}{{- $secret = include "iris-identity-service.generatedSecretName" (dict "root" $root "suffix" (printf "-runtime-%s" .name)) -}}{{- end -}}
{{- $credentials = append $credentials (dict
  "name" (toString (default "" .name))
  "subject" (default "" .subject)
  "operations" (default (list) .allowedOperations)
  "products" (default (list) .allowedProducts)
  "secret" $secret
  "key" (default "token" .secretKey)
  "generated" (not (not $generated))
  "checksum" (default "" .existingSecretChecksum)) -}}
{{- end }}
{{- $validators := dict -}}
{{- range $product, $v := (default (dict) .Values.productValidation).products }}
{{- if or (not (hasKey $v "enabled")) $v.enabled }}
{{- $credential := default (dict) $v.credential -}}
{{- $_ := set $validators $product (dict
  "baseURL" (toString (default "" $v.baseURL))
  "secret" (toString (default "" $credential.existingSecret))
  "key" (default "token" $credential.secretKey)
  "checksum" (default "" $credential.existingSecretChecksum)) -}}
{{- end }}
{{- end }}
{{- toJson (dict
  "metadata" (dict "secret" (toString (default "" $metadata.existingSecret)) "key" (default "metadata.yaml" $metadata.secretKey) "checksum" (default "" $metadata.existingSecretChecksum))
  "control" (dict "secret" $controlSecret "key" (default "token" $control.secretKey) "generated" (not (not $controlGenerated)) "checksum" (default "" $control.existingSecretChecksum))
  "credentials" $credentials
  "validators" $validators) -}}
{{- end }}

{{- define "iris-identity-service.securityProfile" -}}
{{- $global := default (dict) (default (dict) .Values.global).security -}}
{{- default (default "" $global.profile) (default (dict) .Values.security).profile -}}
{{- end }}

{{- define "iris-identity-service.caCertSecret" -}}
{{- $global := default (dict) (default (dict) .Values.global).tls -}}
{{- default (default "" $global.caCertSecret) (default (dict) .Values.tls).caCertSecret -}}
{{- end }}

{{- define "iris-identity-service.imagePullSecrets" -}}
{{- toJson (default (default (list) (default (dict) .Values.global).imagePullSecrets) .Values.imagePullSecrets) -}}
{{- end }}

{{/*
runtime.cache and runtime.apiKeyTenant with their defaults, as JSON, so
values that set a block to null get the defaults, not a nil-pointer error.
singleTenantID is trimmed to a string.
*/}}
{{- define "iris-identity-service.runtimeValues" -}}
{{- $runtime := default (dict) .Values.runtime -}}
{{- $cache := default (dict) $runtime.cache -}}
{{- $tenant := default (dict) $runtime.apiKeyTenant -}}
{{- toJson (dict
  "unscopedGrantsProduct" (default "" $runtime.unscopedGrantsProduct)
  "cache" (dict "softTtlSeconds" (int (dig "softTtlSeconds" 180 $cache)) "hardTtlSeconds" (int (dig "hardTtlSeconds" 300 $cache)))
  "apiKeyTenant" (dict "singleTenantID" (trim (toString (default "" $tenant.singleTenantID))))) -}}
{{- end }}

{{/*
Render-time guards (G3 #14). The schema is the first gate; these hold when it
is skipped and cover what a schema cannot express.
*/}}
{{- define "iris-identity-service.validate" -}}
{{- $r := include "iris-identity-service.resolved" . | fromJson -}}
{{- if not $r.metadata.secret -}}
{{- fail "metadata.existingSecret is required: the chart never deploys Redis; supply the metadata Redis config as an existing Secret" -}}
{{- end -}}
{{- if not $r.control.secret -}}
{{- fail "control: set control.existingSecret or control.autoGenerate=true" -}}
{{- end -}}
{{- $refs := dict (printf "%s/%s" $r.control.secret $r.control.key) "control" -}}
{{- if not $r.credentials -}}
{{- fail "runtime.serviceCredentials must contain at least one credential" -}}
{{- end -}}
{{- $names := dict -}}
{{- range $i, $c := $r.credentials -}}
{{- $path := printf "runtime.serviceCredentials[%d]" $i -}}
{{- if not (regexMatch "^[a-z0-9-]{0,43}[a-z0-9]$" $c.name) -}}
{{- fail (printf "%s.name %q must match ^[a-z0-9-]{0,43}[a-z0-9]$" $path $c.name) -}}
{{- end -}}
{{- if hasKey $names $c.name -}}
{{- fail (printf "%s.name %q duplicates %s" $path $c.name (index $names $c.name)) -}}
{{- end -}}
{{- $_ := set $names $c.name $path -}}
{{- if not $c.subject }}{{- fail (printf "%s.subject is required" $path) -}}{{- end -}}
{{- if not $c.operations }}{{- fail (printf "%s.allowedOperations is required" $path) -}}{{- end -}}
{{- if not $c.products }}{{- fail (printf "%s.allowedProducts is required" $path) -}}{{- end -}}
{{- $raw := index $.Values.runtime.serviceCredentials $i -}}
{{- if $raw.generatedSecretName -}}
{{- if $raw.existingSecret -}}
{{- fail (printf "%s.generatedSecretName must not be set with existingSecret" $path) -}}
{{- else if not $raw.autoGenerate -}}
{{- fail (printf "%s.generatedSecretName requires autoGenerate=true" $path) -}}
{{- end -}}
{{- end -}}
{{- if not $c.secret -}}
{{- fail (printf "%s: set existingSecret or autoGenerate=true" $path) -}}
{{- end -}}
{{- if and (not $c.generated) $raw.autoGenerate -}}
{{- fail (printf "%s: set existingSecret or autoGenerate=true, not both" $path) -}}
{{- end -}}
{{- $ref := printf "%s/%s" $c.secret $c.key -}}
{{- if hasKey $refs $ref -}}
{{- fail (printf "%s must not use the same Secret/key (%s) as %s" $path $ref (index $refs $ref)) -}}
{{- end -}}
{{- $_ := set $refs $ref $path -}}
{{- end -}}
{{- if not $r.validators -}}
{{- fail "productValidation.products must contain at least one enabled product" -}}
{{- end -}}
{{- range $product, $v := $r.validators -}}
{{- $path := printf "productValidation.products.%s" $product -}}
{{- if not (regexMatch "^https?://[^/?#]+" $v.baseURL) -}}
{{- fail (printf "%s.baseURL %q must be an absolute http:// or https:// URL" $path $v.baseURL) -}}
{{- end -}}
{{- if regexMatch "^[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*@" $v.baseURL -}}
{{- fail (printf "%s.baseURL must not include user info" $path) -}}
{{- end -}}
{{- if contains "?" $v.baseURL -}}
{{- fail (printf "%s.baseURL must not include query parameters" $path) -}}
{{- end -}}
{{- if contains "#" $v.baseURL -}}
{{- fail (printf "%s.baseURL must not include a fragment" $path) -}}
{{- end -}}
{{- if not $v.secret -}}
{{- fail (printf "%s.credential.existingSecret is required: validator credentials are owned by the product control plane" $path) -}}
{{- end -}}
{{- $ref := printf "%s/%s" $v.secret $v.key -}}
{{- if hasKey $refs $ref -}}
{{- fail (printf "%s.credential must not use the same Secret/key (%s) as %s" $path $ref (index $refs $ref)) -}}
{{- end -}}
{{- $_ := set $refs $ref (printf "%s.credential" $path) -}}
{{- end -}}
{{- /* A generated Secret replaces any Secret with its name, so no other
reference may use that name, whatever the key. */ -}}
{{- $_ := set $refs (printf "%s/%s" $r.metadata.secret $r.metadata.key) "metadata" -}}
{{- range $i, $c := $r.credentials -}}
{{- if $c.generated -}}
{{- $path := printf "runtime.serviceCredentials[%d]" $i -}}
{{- range $ref, $user := $refs -}}
{{- if and (ne $user $path) (hasPrefix (printf "%s/" $c.secret) $ref) -}}
{{- fail (printf "%s generates Secret %s, which %s also uses" $path $c.secret $user) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $runtime := include "iris-identity-service.runtimeValues" . | fromJson -}}
{{- if and $runtime.unscopedGrantsProduct (not (hasKey $r.validators $runtime.unscopedGrantsProduct)) -}}
{{- fail (printf "runtime.unscopedGrantsProduct %q must name an enabled productValidation product" $runtime.unscopedGrantsProduct) -}}
{{- end -}}
{{- if gt (int $runtime.cache.softTtlSeconds) (int $runtime.cache.hardTtlSeconds) -}}
{{- fail "runtime.cache.softTtlSeconds must not exceed runtime.cache.hardTtlSeconds" -}}
{{- end -}}
{{- end }}

{{/*
Rendered config: configData underneath, chart-owned keys set over it. It
carries mounted token file paths only, never secrets. Metadata Redis URLs
arrive through the metadata Secret as a second --config.
*/}}
{{- define "iris-identity-service.config" -}}
{{- $r := include "iris-identity-service.resolved" . | fromJson -}}
{{- $runtimeValues := include "iris-identity-service.runtimeValues" . | fromJson -}}
{{- $cfg := deepCopy (default (dict) .Values.configData) -}}
{{- $credentials := list -}}
{{- range $r.credentials }}
{{- $credentials = append $credentials (dict "subject" .subject "token_file" (printf "/etc/identity-service/runtime/%s/token" .name) "allowed_operations" .operations "allowed_products" .products) -}}
{{- end }}
{{- $validation := dict -}}
{{- range $product, $v := $r.validators }}
{{- $_ := set $validation $product (dict "base_url" $v.baseURL "credential" (dict "token_file" (printf "/etc/identity-service/product-validation/%s/token" $product))) -}}
{{- end }}
{{- $server := default (dict) (get $cfg "server") -}}
{{- $_ := set $server "port" (int .Values.service.port) -}}
{{- $_ := set $cfg "server" $server -}}
{{- $auth := default (dict) (get $cfg "auth") -}}
{{- $controlAuth := default (dict) .Values.controlAuth -}}
{{- if hasKey $auth "control" -}}
{{- fail "configData.auth.control is chart-owned; configure control instead" -}}
{{- end -}}
{{- if and (hasKey $auth "oidc") $controlAuth.oidc -}}
{{- fail "configure Control OIDC in either configData.auth.oidc or controlAuth.oidc, not both" -}}
{{- end -}}
{{- if and (hasKey $auth "role_bindings") $controlAuth.roleBindings -}}
{{- fail "configure Control role bindings in one source: configData.auth.role_bindings or controlAuth.roleBindings" -}}
{{- end -}}
{{- if and (hasKey $auth "workload_identity") $controlAuth.workloadIdentity -}}
{{- fail "configure Control workload identity in one source: configData.auth.workload_identity or controlAuth.workloadIdentity" -}}
{{- end -}}
{{- $_ := set $auth "type" "static-credential" -}}
{{- $_ := set $auth "control" (dict "token_file" "/etc/identity-service/control/token") -}}
{{- include "iris-identity-service.controlAuth" (dict "auth" $auth "controlAuth" $controlAuth "tenant" $runtimeValues.apiKeyTenant.singleTenantID) -}}
{{- $_ := set $cfg "auth" $auth -}}
{{- $runtime := default (dict) (get $cfg "runtime") -}}
{{- if hasKey $runtime "service_credentials" -}}
{{- fail "configData.runtime.service_credentials is chart-owned; configure runtime.serviceCredentials instead" -}}
{{- end -}}
{{- if hasKey $cfg "product_validation" -}}
{{- fail "configData.product_validation is chart-owned; configure productValidation instead" -}}
{{- end -}}
{{- $_ := set $runtime "service_credentials" $credentials -}}
{{- $_ := set $runtime "cache" (dict "soft_ttl_seconds" (int $runtimeValues.cache.softTtlSeconds) "hard_ttl_seconds" (int $runtimeValues.cache.hardTtlSeconds)) -}}
{{- $_ := unset $runtime "unscoped_grants_product" -}}
{{- with $runtimeValues.unscopedGrantsProduct }}{{- $_ := set $runtime "unscoped_grants_product" . -}}{{- end -}}
{{- $_ := unset $runtime "api_key_tenant" -}}
{{- with $runtimeValues.apiKeyTenant.singleTenantID }}
{{- $_ := set $runtime "api_key_tenant" (dict "single_tenant_id" .) -}}
{{- end }}
{{- $_ := set $cfg "runtime" $runtime -}}
{{- $_ := set $cfg "product_validation" $validation -}}
{{- $_ := unset $cfg "subject_grants" -}}
{{- with (default (dict) .Values.subjectGrants).allowed }}
{{- $allowed := list -}}
{{- range . }}
{{- $allowed = append $allowed (dict "product" .product "resource_type" .resourceType "actions" .actions) -}}
{{- end }}
{{- $_ := set $cfg "subject_grants" (dict "allowed" $allowed) -}}
{{- end }}
{{- $_ := set $cfg "api_keys" (dict "max_rotate_grace_seconds" (int64 (dig "maxRotateGraceSeconds" 604800 (default (dict) .Values.apiKeys)))) -}}
{{- toYaml $cfg -}}
{{- end }}

{{/*
Operator login for IdS Control (port of redis-agent-memory.identityServiceControlAuth
and stampOIDCTenant). Sets auth.oidc and auth.role_bindings on .auth.
The OIDC policy comes from controlAuth.oidc or configData.auth.oidc (one source
only). runtime.apiKeyTenant.singleTenantID, the deployment's one tenant, is
stamped into it as static_tenant_id. Every agent key carries a tenant
(MOD-19463). An enabled oidc needs a tenant source, or its operators could never
create a key. Without oidc the static admin token names the tenant in each grant.
*/}}
{{- define "iris-identity-service.controlAuth" -}}
{{- $src := ternary "controlAuth.oidc" "configData.auth.oidc" (not (empty .controlAuth.oidc)) -}}
{{- $oidc := deepCopy (default (default (dict) .auth.oidc) .controlAuth.oidc) -}}
{{- if and .controlAuth.roleBindings (not (default (dict) .controlAuth.oidc).enabled) -}}
{{- fail "controlAuth.roleBindings requires controlAuth.oidc.enabled" -}}
{{- end -}}
{{- $claim := trim (toString (default "" $oidc.tenant_id_claim)) -}}
{{- $static := trim (toString (default "" $oidc.static_tenant_id)) -}}
{{- if $oidc.enabled -}}
{{- if and .tenant $claim -}}
{{- fail (printf "runtime.apiKeyTenant.singleTenantID pins every agent key to one tenant; %s.tenant_id_claim is multi-tenant. Unset one of them" $src) -}}
{{- else if and .tenant $static (ne $static .tenant) -}}
{{- fail (printf "%s.static_tenant_id %q differs from runtime.apiKeyTenant.singleTenantID %q" $src $static .tenant) -}}
{{- else if .tenant -}}
{{- $_ := set $oidc "static_tenant_id" .tenant -}}
{{- end -}}
{{- end -}}
{{- if and $oidc.enabled (not (or .tenant $claim $static)) -}}
{{- fail (printf "%s needs a tenant source: set runtime.apiKeyTenant.singleTenantID, tenant_id_claim or static_tenant_id. Without one, its operators cannot create agent keys" $src) -}}
{{- end -}}
{{- with $oidc }}{{- $_ := set $.auth "oidc" . -}}{{- end -}}
{{- with .controlAuth.roleBindings }}{{- $_ := set $.auth "role_bindings" . -}}{{- end -}}
{{- $workloadSrc := ternary "controlAuth.workloadIdentity" "configData.auth.workload_identity" (not (empty .controlAuth.workloadIdentity)) -}}
{{- with (default .auth.workload_identity .controlAuth.workloadIdentity) }}
{{- $workload := deepCopy . -}}
{{- $subjects := list -}}
{{- range $subject := (default (list) $workload.subjects) -}}
{{- $subject = deepCopy $subject -}}
{{- $own := trim (toString (default "" $subject.tenant)) -}}
{{- if and $.tenant $own (ne $own $.tenant) -}}
{{- fail (printf "%s subject %q has tenant %q, which differs from runtime.apiKeyTenant.singleTenantID %q" $workloadSrc (toString $subject.subject) $own $.tenant) -}}
{{- end -}}
{{- if and $.tenant (not $own) -}}{{- $_ := set $subject "tenant" $.tenant -}}{{- end -}}
{{- $subjects = append $subjects $subject -}}
{{- end -}}
{{- if $workload.subjects }}{{- $_ := set $workload "subjects" $subjects -}}{{- end -}}
{{- $_ := set $.auth "workload_identity" $workload -}}
{{- end -}}
{{- end }}

{{/*
Final config file: reapplies the mounted credentials and product callbacks
after the policy overlays, so an overlay cannot redirect them.
*/}}
{{- define "iris-identity-service.wiringConfig" -}}
{{- $cfg := include "iris-identity-service.config" . | fromYaml -}}
{{- toYaml (dict "auth" (dict "type" "static-credential" "control" $cfg.auth.control) "runtime" (dict "service_credentials" $cfg.runtime.service_credentials) "product_validation" $cfg.product_validation) -}}
{{- end }}

{{- define "iris-identity-service.overlayNames" -}}
{{- include "redis-onprem.overlaySecretNames" .Values.secrets -}}
{{- end }}

{{/* Config order: rendered base, metadata, policy overlays in order, wiring. */}}
{{- define "iris-identity-service.args" -}}
- "--config"
- "/etc/identity-service/config/identity-service.yaml"
- "--config"
- {{ printf "/etc/identity-service/metadata/%s" (include "iris-identity-service.resolved" . | fromJson).metadata.key | quote }}
{{ include "redis-onprem.overlayConfigArgs" (dict "names" (include "iris-identity-service.overlayNames" .) "mountBase" "/etc/identity-service/overlays") }}
- "--config"
- "/etc/identity-service/config/wiring.yaml"
{{- end }}

{{- define "iris-identity-service.env" -}}
{{- $profile := include "iris-identity-service.securityProfile" . -}}
- name: IDS_SECURITY_PROFILE
  value: {{ $profile | quote }}
{{ include "redis-onprem.commonEnv" (dict "securityProfile" $profile "tlsCaCertSecret" (include "iris-identity-service.caCertSecret" .)) }}
{{- end }}

{{- define "iris-identity-service.volumeMounts" -}}
{{- $r := include "iris-identity-service.resolved" . | fromJson -}}
{{ include "redis-onprem.overlayVolumeMounts" (dict "names" (include "iris-identity-service.overlayNames" .) "volumePrefix" "identity-policy" "mountBase" "/etc/identity-service/overlays") }}
- name: config
  mountPath: /etc/identity-service/config
  readOnly: true
- name: metadata
  mountPath: /etc/identity-service/metadata
  readOnly: true
- name: control-token
  mountPath: /etc/identity-service/control
  readOnly: true
{{- range $r.credentials }}
- name: runtime-{{ .name }}
  mountPath: /etc/identity-service/runtime/{{ .name }}
  readOnly: true
{{- end }}
{{- range $product, $_ := $r.validators }}
- name: product-validation-{{ $product }}
  mountPath: /etc/identity-service/product-validation/{{ $product }}
  readOnly: true
{{- end }}
{{- if include "iris-identity-service.caCertSecret" . }}
- name: tls-ca-cert
  mountPath: /etc/ssl/custom
  readOnly: true
{{- end }}
{{- with .Values.volumeMounts }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "iris-identity-service.volumes" -}}
{{- $r := include "iris-identity-service.resolved" . | fromJson -}}
{{ include "redis-onprem.overlayVolumes" (dict "names" (include "iris-identity-service.overlayNames" .) "volumePrefix" "identity-policy" "key" .Values.secrets.overlayKey) }}
- name: config
  configMap:
    name: {{ include "iris-identity-service.fullname" . }}
    items:
      - key: identity-service.yaml
        path: identity-service.yaml
      - key: wiring.yaml
        path: wiring.yaml
- name: metadata
  secret:
    secretName: {{ $r.metadata.secret }}
    items:
      - key: {{ $r.metadata.key }}
        path: {{ $r.metadata.key }}
- name: control-token
  secret:
    secretName: {{ $r.control.secret }}
    items:
      - key: {{ $r.control.key }}
        path: token
{{- range $r.credentials }}
- name: runtime-{{ .name }}
  secret:
    secretName: {{ .secret }}
    items:
      - key: {{ .key }}
        path: token
{{- end }}
{{- range $product, $v := $r.validators }}
- name: product-validation-{{ $product }}
  secret:
    secretName: {{ $v.secret }}
    items:
      - key: {{ $v.key }}
        path: token
{{- end }}
{{- with include "iris-identity-service.caCertSecret" . }}
- name: tls-ca-cert
  secret:
    secretName: {{ . }}
    items:
      - key: {{ (default (dict) $.Values.tls).caCertKey | default "ca.crt" }}
        path: {{ (default (dict) $.Values.tls).caCertKey | default "ca.crt" }}
{{- end }}
{{- with .Values.volumes }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
One generated Secret. Takes a dict with root, name, key and token (already
base64, from a single lookup-or-generate call).
*/}}
{{- define "iris-identity-service.generatedSecret" -}}
apiVersion: v1
kind: Secret
metadata:
  name: {{ .name }}
  labels:
    {{- include "iris-identity-service.labels" .root | nindent 4 }}
    app.kubernetes.io/component: identity-service
  annotations:
    "helm.sh/resource-policy": keep
type: Opaque
data:
  {{ .key }}: {{ .token }}
{{- end }}

{{- define "iris-identity-service.podAnnotations" -}}
checksum/policy-overlays: {{ toJson (dict "secrets" .Values.secrets) | sha256sum | quote }}
checksum/config: {{ include "iris-identity-service.config" . | sha256sum | quote }}
{{- end }}
