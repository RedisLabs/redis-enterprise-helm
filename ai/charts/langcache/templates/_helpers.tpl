{{/*
Expand the name of the chart.
*/}}
{{- define "langcache.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this
(by the DNS naming spec). If release name contains chart name it will be used
as a full name.
*/}}
{{- define "langcache.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Fully qualified name for the Control Plane Deployment and its resources.
*/}}
{{- define "langcache.controlplaneFullname" -}}
{{- printf "%s-controlplane" (include "langcache.fullname" . | trunc 48 | trimSuffix "-") }}
{{- end }}

{{/*
Fully qualified name for the bundled Identity Service Deployment and its
resources. Only rendered when identityService.mode=bundled.
*/}}
{{- define "langcache.identityServiceFullname" -}}
{{- printf "%s-identity-service" (include "langcache.fullname" . | trunc 46 | trimSuffix "-") }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "langcache.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "langcache.labels" -}}
helm.sh/chart: {{ include "langcache.chart" . }}
{{ include "langcache.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "langcache.selectorLabels" -}}
app.kubernetes.io/name: {{ include "langcache.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the (single, shared) service account to use.
*/}}
{{- define "langcache.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "langcache.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the name of the data-plane config carrier to use. When
dataplane.config.existingSecret is set it names that BYO Secret; otherwise it
names the chart-rendered config ConfigMap.
*/}}
{{- define "langcache.dataplaneConfigName" -}}
{{- if .Values.dataplane.config.existingSecret }}
{{- .Values.dataplane.config.existingSecret }}
{{- else }}
{{- printf "%s-config" (include "langcache.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Create the name of the control-plane config carrier to use.
*/}}
{{- define "langcache.controlplaneConfigName" -}}
{{- if .Values.controlplane.config.existingSecret }}
{{- .Values.controlplane.config.existingSecret }}
{{- else }}
{{- printf "%s-config" (include "langcache.controlplaneFullname" .) }}
{{- end }}
{{- end }}

{{/*
Create the name of the bundled Identity Service config carrier to use.
*/}}
{{- define "langcache.identityServiceConfigName" -}}
{{- if .Values.identityService.bundled.config.existingSecret }}
{{- .Values.identityService.bundled.config.existingSecret }}
{{- else }}
{{- printf "%s-config" (include "langcache.identityServiceFullname" . | trunc 56 | trimSuffix "-") }}
{{- end }}
{{- end }}

{{/*
Create the name of the license Secret to use.
*/}}
{{- define "langcache.licenseSecretName" -}}
{{- if .Values.dataplane.license.existingSecret }}
{{- .Values.dataplane.license.existingSecret }}
{{- else }}
{{- printf "%s-license" (include "langcache.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Create the name of the Control Plane admin-token Secret to use.
*/}}
{{- define "langcache.controlplaneAdminTokenSecretName" -}}
{{- if .Values.controlplane.adminToken.existingSecret }}
{{- .Values.controlplane.adminToken.existingSecret }}
{{- else }}
{{- printf "%s-admin-token" (include "langcache.controlplaneFullname" .) }}
{{- end }}
{{- end }}

{{/*
Create the name of the Control Plane internal-token Secret to use.
*/}}
{{- define "langcache.controlplaneInternalTokenSecretName" -}}
{{- if .Values.controlplane.internalToken.existingSecret }}
{{- .Values.controlplane.internalToken.existingSecret }}
{{- else }}
{{- printf "%s-internal-token" (include "langcache.controlplaneFullname" .) }}
{{- end }}
{{- end }}

{{/*
Create the name of the bundled Identity Service control-token Secret to use.
*/}}
{{- define "langcache.identityServiceControlTokenSecretName" -}}
{{- if .Values.identityService.bundled.controlToken.existingSecret }}
{{- .Values.identityService.bundled.controlToken.existingSecret }}
{{- else }}
{{- printf "%s-control-token" (include "langcache.identityServiceFullname" . | trunc 49 | trimSuffix "-") }}
{{- end }}
{{- end }}

{{/*
Create the name of the Data Plane's own Identity Service runtime credential
Secret to use, in bundled mode.
*/}}
{{- define "langcache.identityServiceDataplaneCredentialSecretName" -}}
{{- if .Values.identityService.bundled.runtime.dataplaneCredential.existingSecret }}
{{- .Values.identityService.bundled.runtime.dataplaneCredential.existingSecret }}
{{- else }}
{{- printf "%s-dp-credential" (include "langcache.identityServiceFullname" . | trunc 49 | trimSuffix "-") }}
{{- end }}
{{- end }}

{{/*
Whether the Data Plane's Identity Service introspection is chart-managed:
mode=bundled and no top-level dataplane.identityServiceCredentialOverride is
in play. Kept as a named partial for readability at call sites.
*/}}
{{- define "langcache.identityServiceBundled" -}}
{{- if eq .Values.identityService.mode "bundled" }}true{{- end }}
{{- end }}

{{/*
Ordered list of Data Plane overlay Secret NAMES to mount (merge order, later
wins), JSON-encoded so callers can `fromJsonArray` and iterate with a stable
0-based index. Built as (dataplane.secrets.secretName if non-empty) followed
by each entry of dataplane.secrets.additionalSecrets. Each Secret holds
metadata.urls, databases, and (when embedding.credentials.type=static)
embedding.credentials.api_key.
*/}}
{{- define "langcache.dataplaneOverlaySecretNames" -}}
{{- $names := list -}}
{{- if .Values.dataplane.secrets }}
{{- if .Values.dataplane.secrets.secretName }}{{- $names = append $names .Values.dataplane.secrets.secretName -}}{{- end }}
{{- range .Values.dataplane.secrets.additionalSecrets }}{{- $names = append $names . -}}{{- end }}
{{- end }}
{{- $names | toJson -}}
{{- end }}

{{/*
Data Plane overlay Secret volumes. Mounted as a volume (NOT subPath) so
Kubernetes' atomic ..data swap propagates rotations on pod restart. The i-th
overlay (0-based) gets volume name dp-config-overlay-<i>.
*/}}
{{- define "langcache.dataplaneOverlayVolumes" -}}
{{- $key := "overlay.yaml" -}}
{{- if .Values.dataplane.secrets }}{{- $key = .Values.dataplane.secrets.overlayKey | default "overlay.yaml" -}}{{- end }}
{{- $names := include "langcache.dataplaneOverlaySecretNames" . | fromJsonArray -}}
{{- range $i, $name := $names }}
- name: dp-config-overlay-{{ $i }}
  secret:
    secretName: {{ $name }}
    items:
      - key: {{ $key }}
        path: overlay.yaml
{{- end }}
{{- end }}

{{/*
Data Plane overlay Secret volumeMounts. Mounts the i-th overlay (0-based)
read-only at /etc/langcache/overlays/<i>.
*/}}
{{- define "langcache.dataplaneOverlayVolumeMounts" -}}
{{- $names := include "langcache.dataplaneOverlaySecretNames" . | fromJsonArray -}}
{{- range $i, $name := $names }}
- name: dp-config-overlay-{{ $i }}
  mountPath: /etc/langcache/overlays/{{ $i }}
  readOnly: true
{{- end }}
{{- end }}

{{/*
Data Plane overlay --config container args: one "--config <path>" pair per
mounted overlay, ordered so the loader deep-merges them over the base config
in order (later wins).
*/}}
{{- define "langcache.dataplaneOverlayConfigArgs" -}}
{{- $names := include "langcache.dataplaneOverlaySecretNames" . | fromJsonArray -}}
{{- range $i, $name := $names }}
- "--config"
- {{ printf "/etc/langcache/overlays/%d/overlay.yaml" $i | quote }}
{{- end }}
{{- end }}

{{/*
Same overlay mechanics as above, for the Control Plane. Its overlay carries
metadata.urls and databases only — the Control Plane never receives an
embedding credential.
*/}}
{{- define "langcache.controlplaneOverlaySecretNames" -}}
{{- $names := list -}}
{{- if .Values.controlplane.secrets }}
{{- if .Values.controlplane.secrets.secretName }}{{- $names = append $names .Values.controlplane.secrets.secretName -}}{{- end }}
{{- range .Values.controlplane.secrets.additionalSecrets }}{{- $names = append $names . -}}{{- end }}
{{- end }}
{{- $names | toJson -}}
{{- end }}

{{- define "langcache.controlplaneOverlayVolumes" -}}
{{- $key := "overlay.yaml" -}}
{{- if .Values.controlplane.secrets }}{{- $key = .Values.controlplane.secrets.overlayKey | default "overlay.yaml" -}}{{- end }}
{{- $names := include "langcache.controlplaneOverlaySecretNames" . | fromJsonArray -}}
{{- range $i, $name := $names }}
- name: cp-config-overlay-{{ $i }}
  secret:
    secretName: {{ $name }}
    items:
      - key: {{ $key }}
        path: overlay.yaml
{{- end }}
{{- end }}

{{- define "langcache.controlplaneOverlayVolumeMounts" -}}
{{- $names := include "langcache.controlplaneOverlaySecretNames" . | fromJsonArray -}}
{{- range $i, $name := $names }}
- name: cp-config-overlay-{{ $i }}
  mountPath: /etc/langcache-controlplane/overlays/{{ $i }}
  readOnly: true
{{- end }}
{{- end }}

{{- define "langcache.controlplaneOverlayConfigArgs" -}}
{{- $names := include "langcache.controlplaneOverlaySecretNames" . | fromJsonArray -}}
{{- range $i, $name := $names }}
- "--config"
- {{ printf "/etc/langcache-controlplane/overlays/%d/overlay.yaml" $i | quote }}
{{- end }}
{{- end }}

{{/*
TLS CA certificate volume. Renders a projected Secret volume when
tls.caCertSecret is configured. Shared by all three workloads.
*/}}
{{- define "langcache.tlsVolume" -}}
{{- if and .Values.tls .Values.tls.caCertSecret }}
- name: tls-ca-cert
  secret:
    secretName: {{ .Values.tls.caCertSecret }}
    items:
      - key: {{ .Values.tls.caCertKey }}
        path: {{ .Values.tls.caCertKey }}
{{- end }}
{{- end }}

{{- define "langcache.tlsVolumeMount" -}}
{{- if and .Values.tls .Values.tls.caCertSecret }}
- name: tls-ca-cert
  mountPath: /etc/ssl/custom
  readOnly: true
{{- end }}
{{- end }}

{{/*
Common container env entries (GODEBUG + optional SSL_CERT_DIR), applied to
every LangCache container. Centralizing this avoids adding a new workload and
forgetting to wire its security posture.
*/}}
{{- define "langcache.commonEnv" -}}
{{ include "redis-onprem.commonEnv" (dict "securityProfile" (default "" .Values.security.profile) "tlsCaCertSecret" .Values.tls.caCertSecret) }}
{{- end }}

{{/*
Rendered Data Plane config body (.Values.dataplane.configData), with the
Identity Service introspection block filled in for bundled mode. Credentials
(metadata.urls, databases, embedding.credentials.api_key) are never present
here — they arrive via the mounted overlay Secrets.
*/}}
{{- define "langcache.dataplaneConfig" -}}
{{- $body := deepCopy (default (dict) .Values.dataplane.configData) -}}
{{- $embedding := deepCopy (default (dict) $body.embedding) -}}
{{- $_ := set $embedding "provider" .Values.dataplane.embedding.provider -}}
{{- $_ := set $embedding "endpoint" (dict "base_url" .Values.dataplane.embedding.endpoint.baseURL) -}}
{{- $_ := set $embedding "credentials" (dict "type" .Values.dataplane.embedding.credentials.type) -}}
{{- $_ := set $embedding "models" (dict "default_embedding_model" .Values.dataplane.embedding.models.defaultEmbeddingModel "dimensions" (int .Values.dataplane.embedding.models.dimensions)) -}}
{{- $_ := set $body "embedding" $embedding -}}
{{- $_ := set $body "license" (dict "license_path" (printf "%s/%s" .Values.dataplane.license.mountDir .Values.dataplane.license.fileName)) -}}
{{- $auth := dict "method" "agent_key" "agent_keys" (dict "enabled" true "introspection" (dict)) -}}
{{- $introspection := dict -}}
{{- if eq .Values.identityService.mode "bundled" }}
{{/*
  The bundled Identity Service Deployment/Service this chart renders has no
  TLS termination of its own, so its in-cluster address is always http://.
  security.profile=fips refuses this combination in langcache.validate
  (checked unconditionally, unlike this config body which BYO-config
  installs skip entirely) — allow_insecure_transport here just lets the
  non-fips default path start at all.
*/}}
{{- $_ := set $introspection "base_url" (printf "http://%s:%v" (include "langcache.identityServiceFullname" .) .Values.identityService.bundled.service.port) -}}
{{- $_ := set $introspection "credential" (dict "token_file" "/etc/langcache/identity-service-credential/token") -}}
{{- $_ := set $introspection "allow_insecure_transport" true -}}
{{- else }}
{{- $_ := set $introspection "base_url" .Values.identityService.external.baseURL -}}
{{- $_ := set $introspection "credential" (dict "token_file" "/etc/langcache/identity-service-credential/token") -}}
{{- if .Values.identityService.external.allowInsecureTransport }}
{{- $_ := set $introspection "allow_insecure_transport" true -}}
{{- end }}
{{- end }}
{{- $_ := set $introspection "product" "langcache" -}}
{{- $agentKeys := set (index $auth "agent_keys") "introspection" $introspection -}}
{{- $_ := set $auth "agent_keys" $agentKeys -}}
{{- $_ := set $body "auth" $auth -}}
{{- toYaml $body -}}
{{- end }}

{{/*
Rendered Control Plane config body (.Values.controlplane.configData), with
the internal-token file path and public embedding facts filled in.
*/}}
{{- define "langcache.controlplaneConfig" -}}
{{- $body := deepCopy (default (dict) .Values.controlplane.configData) -}}
{{- $embedders := dict .Values.dataplane.embedding.provider (dict "authorized" false "models" (list (dict "model" .Values.dataplane.embedding.models.defaultEmbeddingModel "dimensions" (int .Values.dataplane.embedding.models.dimensions)))) -}}
{{- $_ := set $body "embedders" $embedders -}}
{{- $_ := set $body "license" (dict "license_path" (printf "%s/%s" .Values.dataplane.license.mountDir .Values.dataplane.license.fileName)) -}}
{{- $_ := set $body "auth" (dict "type" "admin-token" "admin_token" (dict "token_file" "/etc/langcache-controlplane/admin/token") "internal_token" (dict "token_file" "/etc/langcache-controlplane/internal/token")) -}}
{{- toYaml $body -}}
{{- end }}

{{/*
Rendered bundled Identity Service config body. The chart owns every mounted
credential's token_file path, so this rendered ConfigMap carries structure
only — the metadata Redis URL arrives via identityService.bundled.metadata as
a Secret overlay.
*/}}
{{- define "langcache.identityServiceConfig" -}}
{{- $bundled := .Values.identityService.bundled -}}
{{- $cfg := deepCopy (default (dict) $bundled.configData) -}}
{{- $_ := set $cfg "auth" (dict "type" "static-credential" "control" (dict "token_file" "/etc/identity-service/control/token")) -}}
{{- $cache := default (dict) $bundled.runtime.cache -}}
{{- $runtime := dict
  "service_credentials" (list (dict "subject" "langcache-dataplane" "token_file" "/etc/identity-service/runtime/langcache-dp/token" "allowed_operations" (list "api-key-introspect") "allowed_products" (list "langcache")))
  "cache" (dict "soft_ttl_seconds" (int (default 180 $cache.softTtlSeconds)) "hard_ttl_seconds" (int (default 300 $cache.hardTtlSeconds)))
-}}
{{- $_ := set $cfg "runtime" $runtime -}}
{{- $_ := set $cfg "product_validation" (dict "langcache" (dict
  "base_url" (printf "http://%s:%v" (include "langcache.controlplaneFullname" .) .Values.controlplane.service.port)
  "credential" (dict "token_file" "/etc/identity-service/product-validation/langcache/token")
)) -}}
{{- toYaml $cfg -}}
{{- end }}

{{/*
Validate required inputs. Included at the top of every workload template so a
missing or conflicting value fails `helm template`/`helm install` with an
actionable message instead of a pod crash loop.
*/}}
{{- define "langcache.validate" -}}
{{- if not .Values.dataplane.image.tag -}}
{{- fail "dataplane.image.tag is required and must be set explicitly to the LangCache Data Plane version being deployed" -}}
{{- end -}}
{{- if and (not .Values.dataplane.config.existingSecret) (not .Values.dataplane.config.render) -}}
{{- fail "dataplane.config: set dataplane.config.existingSecret (bring your own config Secret) or dataplane.config.render=true (chart renders it from dataplane.configData)" -}}
{{- end -}}
{{- if and .Values.dataplane.config.existingSecret .Values.dataplane.config.render -}}
{{- fail "dataplane.config: existingSecret (BYO Secret) and render (chart-rendered ConfigMap) are mutually exclusive; pick one" -}}
{{- end -}}
{{- if not .Values.dataplane.config.secretKey -}}
{{- fail "dataplane.config.secretKey is required" -}}
{{- end -}}
{{- if not .Values.dataplane.secrets.secretName -}}
{{- fail "dataplane.secrets.secretName is required: a pre-created Secret holding an overlay with metadata.urls and databases (and embedding.credentials.api_key when dataplane.embedding.credentials.type=static)" -}}
{{- end -}}
{{- if not (or (eq .Values.dataplane.embedding.credentials.type "static") (eq .Values.dataplane.embedding.credentials.type "none")) -}}
{{- fail "dataplane.embedding.credentials.type must be \"static\" or \"none\"" -}}
{{- end -}}
{{- if not .Values.dataplane.embedding.endpoint.baseURL -}}
{{- fail "dataplane.embedding.endpoint.baseURL is required" -}}
{{- end -}}
{{- if not .Values.dataplane.embedding.models.defaultEmbeddingModel -}}
{{- fail "dataplane.embedding.models.defaultEmbeddingModel is required" -}}
{{- end -}}
{{- if not (gt (int .Values.dataplane.embedding.models.dimensions) 0) -}}
{{- fail "dataplane.embedding.models.dimensions must be greater than 0" -}}
{{- end -}}
{{- if not .Values.dataplane.license.existingSecret -}}
{{- fail "dataplane.license.existingSecret is required" -}}
{{- end -}}
{{- if not .Values.controlplane.image.tag -}}
{{- fail "controlplane.image.tag is required" -}}
{{- end -}}
{{- if lt (int .Values.controlplane.replicaCount) 1 -}}
{{- fail "controlplane.replicaCount must be at least 1" -}}
{{- end -}}
{{- if and (not .Values.controlplane.config.existingSecret) (not .Values.controlplane.config.render) -}}
{{- fail "controlplane.config: set controlplane.config.existingSecret (BYO) or controlplane.config.render=true" -}}
{{- end -}}
{{- if and .Values.controlplane.config.existingSecret .Values.controlplane.config.render -}}
{{- fail "controlplane.config: existingSecret (BYO Secret) and render (chart-rendered ConfigMap) are mutually exclusive; pick one" -}}
{{- end -}}
{{- if not .Values.controlplane.config.secretKey -}}
{{- fail "controlplane.config.secretKey is required" -}}
{{- end -}}
{{- if not .Values.controlplane.secrets.secretName -}}
{{- fail "controlplane.secrets.secretName is required: a pre-created Secret holding an overlay with metadata.urls and databases" -}}
{{- end -}}
{{- if and (not .Values.controlplane.adminToken.existingSecret) (not .Values.controlplane.adminToken.autoGenerate) -}}
{{- fail "controlplane.adminToken: set adminToken.existingSecret (BYO) or adminToken.autoGenerate=true" -}}
{{- end -}}
{{- if and (not .Values.controlplane.internalToken.existingSecret) (not .Values.controlplane.internalToken.autoGenerate) -}}
{{- fail "controlplane.internalToken: set internalToken.existingSecret (BYO) or internalToken.autoGenerate=true" -}}
{{- end -}}
{{- if and (eq (include "langcache.controlplaneAdminTokenSecretName" .) (include "langcache.controlplaneInternalTokenSecretName" .)) (eq .Values.controlplane.adminToken.secretKey .Values.controlplane.internalToken.secretKey) -}}
{{- fail "controlplane.internalToken must not use the same Secret/key as controlplane.adminToken" -}}
{{- end -}}
{{- if .Values.security -}}
{{- $profile := default "" .Values.security.profile -}}
{{- if and (ne $profile "") (ne $profile "fips") -}}
{{- fail (printf "security.profile=%q is not supported (valid values: \"\", \"fips\"). See the chart README section \"FIPS-oriented posture\"." $profile) -}}
{{- end -}}
{{- end -}}
{{- if eq .Values.identityService.mode "bundled" -}}
{{- $bundled := .Values.identityService.bundled -}}
{{- if not $bundled.image.tag -}}
{{- fail "identityService.bundled.image.tag is required when identityService.mode=bundled" -}}
{{- end -}}
{{- if and (not $bundled.config.existingSecret) (not $bundled.config.render) -}}
{{- fail "identityService.bundled.config: set config.existingSecret (BYO) or config.render=true" -}}
{{- end -}}
{{- if and $bundled.config.existingSecret $bundled.config.render -}}
{{- fail "identityService.bundled.config: existingSecret (BYO Secret) and render (chart-rendered ConfigMap) are mutually exclusive; pick one" -}}
{{- end -}}
{{- if not $bundled.config.secretKey -}}
{{- fail "identityService.bundled.config.secretKey is required when identityService.mode=bundled" -}}
{{- end -}}
{{- if and $bundled.config.render (not $bundled.metadata.existingSecret) -}}
{{- fail "identityService.bundled.metadata.existingSecret is required when identityService.bundled.config.render=true" -}}
{{- end -}}
{{- if and $bundled.metadata.existingSecret (not $bundled.metadata.secretKey) -}}
{{- fail "identityService.bundled.metadata.secretKey is required when identityService.bundled.metadata.existingSecret is set" -}}
{{- end -}}
{{- if and (not $bundled.controlToken.existingSecret) (not $bundled.controlToken.autoGenerate) -}}
{{- fail "identityService.bundled.controlToken: set existingSecret (BYO) or autoGenerate=true" -}}
{{- end -}}
{{- if and (not $bundled.runtime.dataplaneCredential.existingSecret) (not $bundled.runtime.dataplaneCredential.autoGenerate) -}}
{{- fail "identityService.bundled.runtime.dataplaneCredential: set existingSecret (BYO) or autoGenerate=true" -}}
{{- end -}}
{{- $softTTL := int (default 180 $bundled.runtime.cache.softTtlSeconds) -}}
{{- $hardTTL := int (default 300 $bundled.runtime.cache.hardTtlSeconds) -}}
{{- if lt $hardTTL $softTTL -}}
{{- fail "identityService.bundled.runtime.cache.hardTtlSeconds must be greater than or equal to softTtlSeconds" -}}
{{- end -}}
{{- if and .Values.security (eq (default "" .Values.security.profile) "fips") -}}
{{/*
  The bundled Identity Service Deployment/Service this chart renders has no
  TLS termination of its own, so its in-cluster address is always http://.
  Checked here (not just in the rendered dataplaneConfig body) so a
  BYO-config install (dataplane.config.existingSecret set) can't silently
  skip this refusal.
*/}}
{{- fail "security.profile=fips is not supported with identityService.mode=bundled: the bundled Identity Service has no TLS termination, so its introspection endpoint is always http://. Use identityService.mode=external with an https:// Identity Service." -}}
{{- end -}}
{{- else if eq .Values.identityService.mode "external" -}}
{{- $ext := .Values.identityService.external -}}
{{- if not $ext.baseURL -}}
{{- fail "identityService.external.baseURL is required when identityService.mode=external" -}}
{{- end -}}
{{- if and (not (hasPrefix "https://" $ext.baseURL)) (not $ext.allowInsecureTransport) -}}
{{- fail "identityService.external.baseURL must be https:// (or set identityService.external.allowInsecureTransport=true)" -}}
{{- end -}}
{{- if not $ext.credential.existingSecret -}}
{{- fail "identityService.external.credential.existingSecret is required when identityService.mode=external — this is the Data Plane's pre-existing runtime credential for that Identity Service, minted by the suite-level Identity Service owner" -}}
{{- end -}}
{{- else -}}
{{- fail (printf "identityService.mode=%q is not supported (valid values: \"bundled\", \"external\")" .Values.identityService.mode) -}}
{{- end -}}
{{- end }}
