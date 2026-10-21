{{/*
Expand the name of the chart.
*/}}
{{- define "redis-agent-memory.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "redis-agent-memory.fullname" -}}
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
Fully qualified name for the worker Deployment and its resources.
*/}}
{{- define "redis-agent-memory.workerFullname" -}}
{{- printf "%s-worker" (include "redis-agent-memory.fullname" . | trunc 56 | trimSuffix "-") }}
{{- end }}

{{/*
Fully qualified name for the support-only worker Service.
*/}}
{{- define "redis-agent-memory.workerSupportServiceName" -}}
{{- printf "%s-worker-support" (include "redis-agent-memory.fullname" . | trunc 48 | trimSuffix "-") }}
{{- end }}

{{/*
Fully qualified name for the control-plane Deployment and its resources.
*/}}
{{- define "redis-agent-memory.controlplaneFullname" -}}
{{- printf "%s-controlplane" (include "redis-agent-memory.fullname" . | trunc 48 | trimSuffix "-") }}
{{- end }}

{{/*
Fully qualified name for the optional Asynqmon queue monitor.
*/}}
{{- define "redis-agent-memory.queueMonitorFullname" -}}
{{- printf "%s-asynqmon" (include "redis-agent-memory.fullname" . | trunc 54 | trimSuffix "-") }}
{{- end }}

{{/*
Create the name of the control-plane config carrier to use. When
controlplane.config.existingSecret is set it names that BYO Secret; otherwise it
names the chart-rendered config ConfigMap.
*/}}
{{- define "redis-agent-memory.controlplaneConfigName" -}}
{{- if .Values.controlplane.config.existingSecret }}
{{- .Values.controlplane.config.existingSecret }}
{{- else }}
{{- printf "%s-config" (include "redis-agent-memory.controlplaneFullname" .) }}
{{- end }}
{{- end }}

{{/*
Create the name of the control-plane admin-token Secret to use.
*/}}
{{- define "redis-agent-memory.controlplaneAdminTokenSecretName" -}}
{{- if .Values.controlplane.adminToken.existingSecret }}
{{- .Values.controlplane.adminToken.existingSecret }}
{{- else }}
{{- printf "%s-admin-token" (include "redis-agent-memory.controlplaneFullname" .) }}
{{- end }}
{{- end }}

{{/*
Create the name of the control-plane internal-token Secret to use.
*/}}
{{- define "redis-agent-memory.controlplaneInternalTokenSecretName" -}}
{{- if .Values.controlplane.internalToken.existingSecret }}
{{- .Values.controlplane.internalToken.existingSecret }}
{{- else }}
{{- printf "%s-internal-token" (include "redis-agent-memory.controlplaneFullname" .) }}
{{- end }}
{{- end }}

{{/*
The Secret/key the data plane presents to the Identity Service release, as
JSON {secret, key, checksum}, from identityService.credential.
*/}}
{{- define "redis-agent-memory.dpCredential" -}}
{{- $credential := default (dict) (default (dict) .Values.identityService).credential -}}
{{- toJson (dict "secret" (default "" $credential.existingSecret) "key" (default "token" $credential.secretKey) "checksum" (default "" $credential.existingSecretChecksum)) -}}
{{- end }}

{{/*
global.* fallbacks, so one value set on an umbrella chart reaches Memory and
the Identity Service release alike. A local value wins.
*/}}
{{- define "redis-agent-memory.securityProfile" -}}
{{- $global := default (dict) (default (dict) .Values.global).security -}}
{{- default (default "" $global.profile) (default (dict) .Values.security).profile -}}
{{- end }}

{{- define "redis-agent-memory.tlsCaCertSecret" -}}
{{- $global := default (dict) (default (dict) .Values.global).tls -}}
{{- default (default "" $global.caCertSecret) (default (dict) .Values.tls).caCertSecret -}}
{{- end }}

{{/* The CA bundle key in that Secret; a null local tls block keeps ca.crt. */}}
{{- define "redis-agent-memory.tlsCaCertKey" -}}
{{- default "ca.crt" (default (dict) .Values.tls).caCertKey -}}
{{- end }}

{{- define "redis-agent-memory.imagePullSecrets" -}}
{{- toJson (default (default (list) (default (dict) .Values.global).imagePullSecrets) .Values.imagePullSecrets) -}}
{{- end }}

{{/*
Guards for the connection to the Identity Service release. They check this
chart's own settings only: consistency with the Identity Service release
(credential registration, validator, tenant) is the deployment automation's
job.
*/}}
{{- define "redis-agent-memory.validateIdentityService" -}}
{{- $ids := default (dict) .Values.identityService -}}
{{- $fips := eq (include "redis-agent-memory.securityProfile" .) "fips" -}}
{{- $url := (default (dict) .Values.dataplane).identityServiceBaseURL -}}
{{- /* shared merges under memory in the rendered config, so both are guarded. */ -}}
{{- range $source := list "shared" "memory" -}}
{{- $auth := default (dict) (index (default (dict) (index $.Values $source)) "auth") -}}
{{- $introspection := default (dict) (index (default (dict) (index $auth "agent_keys")) "introspection") -}}
{{- range $field := list "base_url" "credential" "allow_insecure_transport" -}}
{{- if hasKey $introspection $field -}}
{{- fail (printf "%s.auth.agent_keys.introspection.%s is chart-owned: set dataplane.identityServiceBaseURL and identityService.{allowInsecureTransport,credential} instead" $source $field) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and $fips $ids.allowInsecureTransport -}}
{{- fail "identityService.allowInsecureTransport=true is refused under the fips security profile: dataplane.identityServiceBaseURL must be https://" -}}
{{- end -}}
{{- if and $url (not (hasPrefix "https://" $url)) (not $ids.allowInsecureTransport) -}}
{{- fail (printf "dataplane.identityServiceBaseURL %q must be https:// (an http:// URL is accepted only with identityService.allowInsecureTransport=true and no fips security profile)" $url) -}}
{{- end -}}
{{- if and .Values.config.render (include "redis-agent-memory.dataplaneUsesIdentityService" .) -}}
{{- if not $url -}}
{{- fail "agent-key auth (memory.auth.method agent_key or agent_keys.enabled, or unset with no other auth flavour), or a service subject with the identity_service authority, requires dataplane.identityServiceBaseURL, the Identity Service release's Runtime URL; or, for development only, set memory.auth.method=none with memory.profile=dev" -}}
{{- end -}}
{{- if not (default (dict) $ids.credential).existingSecret -}}
{{- fail "agent-key auth, or a service subject with the identity_service authority, requires identityService.credential.existingSecret, the data plane's runtime credential registered on the Identity Service release" -}}
{{- end -}}
{{- $agentKeys := default (dict) (index (default (dict) (index (include "redis-agent-memory.dataplaneMergedConfig" . | mustFromJson) "auth")) "agent_keys") -}}
{{- if and (hasKey $agentKeys "enabled") (not $agentKeys.enabled) -}}
{{- fail "a service subject with the identity_service authority requires auth.agent_keys.enabled: grants are looked up through its Identity Service client. Remove memory.auth.agent_keys.enabled=false" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Data-plane config as the binary reads it: .Values.shared merged under
.Values.memory, as renderConfig does. Renders JSON; read it with mustFromJson.
*/}}
{{- define "redis-agent-memory.dataplaneMergedConfig" -}}
{{- mergeOverwrite (deepCopy (default (dict) .Values.shared)) (deepCopy (default (dict) .Values.memory)) | mustToJson -}}
{{- end }}

{{/*
Effective data-plane auth.method, lower-cased and trimmed as the binary's
normalizeAuthMethod does. Empty when unset.
*/}}
{{- define "redis-agent-memory.dataplaneAuthMethod" -}}
{{- $auth := default (dict) (index (include "redis-agent-memory.dataplaneMergedConfig" . | mustFromJson) "auth") -}}
{{- lower (trim (toString (default "" (index $auth "method")))) -}}
{{- end }}

{{/*
Effective data-plane profile, verbatim: the binary compares it exactly (an
empty profile is prod), so normalizing here would accept a value it refuses.
*/}}
{{- define "redis-agent-memory.dataplaneProfile" -}}
{{- toString (default "" (index (include "redis-agent-memory.dataplaneMergedConfig" . | mustFromJson) "profile")) -}}
{{- end }}

{{/*
Whether the rendered data-plane config authenticates with agent keys. Mirrors
the data plane's applyAuthDefaults: method agent_key or agent_keys.enabled, or
an unset method with no other auth flavour on. Renders "true" or nothing.
*/}}
{{- define "redis-agent-memory.dataplaneUsesAgentKeys" -}}
{{- $auth := default (dict) (index (include "redis-agent-memory.dataplaneMergedConfig" . | mustFromJson) "auth") -}}
{{- $method := include "redis-agent-memory.dataplaneAuthMethod" . -}}
{{- $flavour := or (index $auth "enabled") (index $auth "jwt_subjects") -}}
{{- range $block := list "sm_cloud" "oidc" "worker_identity" "service_subjects" -}}
{{- $flavour = or $flavour (index (default (dict) (index $auth $block)) "enabled") -}}
{{- end -}}
{{- $agentKeysEnabled := index (default (dict) (index $auth "agent_keys")) "enabled" -}}
{{- if and (ne $method "none") (or (eq $method "agent_key") $agentKeysEnabled (and (eq $method "") (not $flavour))) -}}true{{- end -}}
{{- end }}

{{/*
Whether the data plane calls the Identity Service: agent-key auth, or a trusted
subject whose grants come from it (the identity_service authority, which every
legacy service_subjects entry uses). Mirrors the binary's usesSubjectAuthority:
both look grants up through auth.agent_keys.introspection. Renders "true" or
nothing.
*/}}
{{- define "redis-agent-memory.dataplaneUsesIdentityService" -}}
{{- $auth := default (dict) (index (include "redis-agent-memory.dataplaneMergedConfig" . | mustFromJson) "auth") -}}
{{- $uses := include "redis-agent-memory.dataplaneUsesAgentKeys" . -}}
{{- $serviceSubjects := default (dict) (index $auth "service_subjects") -}}
{{- if and (index $serviceSubjects "enabled") (index $serviceSubjects "subjects") -}}{{- $uses = "true" -}}{{- end -}}
{{- range $issuer := (default (list) (index $auth "jwt_subjects")) -}}
{{- range $subject := (default (list) (index (default (dict) $issuer) "subjects")) -}}
{{- if eq (toString (index (default (dict) $subject) "authority")) "identity_service" -}}{{- $uses = "true" -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- $uses -}}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "redis-agent-memory.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "redis-agent-memory.labels" -}}
helm.sh/chart: {{ include "redis-agent-memory.chart" . }}
{{ include "redis-agent-memory.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "redis-agent-memory.selectorLabels" -}}
app.kubernetes.io/name: {{ include "redis-agent-memory.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "redis-agent-memory.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "redis-agent-memory.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the name of the worker service account to use.
*/}}
{{- define "redis-agent-memory.workerServiceAccountName" -}}
{{- if .Values.worker.serviceAccount.name }}
{{- .Values.worker.serviceAccount.name }}
{{- else if or .Values.worker.serviceAccount.create .Values.workerAuth.enabled }}
{{- include "redis-agent-memory.workerFullname" . }}
{{- else }}
{{- include "redis-agent-memory.serviceAccountName" . }}
{{- end }}
{{- end }}

{{/*
Whether to render a projected service-account token for the worker.
*/}}
{{- define "redis-agent-memory.workerServiceAccountTokenEnabled" -}}
{{- if or .Values.worker.serviceAccount.token.enabled .Values.workerAuth.enabled -}}true{{- end }}
{{- end }}

{{/*
Default Kubernetes service-account subject to trust in auth.worker_identity.
*/}}
{{- define "redis-agent-memory.workerAuthSubject" -}}
{{- printf "system:serviceaccount:%s:%s" .Release.Namespace (include "redis-agent-memory.workerServiceAccountName" .) }}
{{- end }}

{{/*
Create the name of the shared data-plane config carrier to use. When
config.existingSecret is set it names that BYO Secret; otherwise it names the
chart-rendered config ConfigMap.
*/}}
{{- define "redis-agent-memory.configName" -}}
{{- if .Values.config.existingSecret }}
{{- .Values.config.existingSecret }}
{{- else }}
{{- printf "%s-config" (include "redis-agent-memory.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Create the name of the license Secret to use.
*/}}
{{- define "redis-agent-memory.licenseSecretName" -}}
{{- if .Values.license.existingSecret }}
{{- .Values.license.existingSecret }}
{{- else }}
{{- printf "%s-license" (include "redis-agent-memory.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Validate required enterprise inputs.
*/}}
{{- define "redis-agent-memory.validate" -}}
{{- if not .Values.image.tag -}}
{{- fail "image.tag is required and must be set explicitly to the RAM version being deployed" -}}
{{- end -}}
{{- if not .Values.license.existingSecret -}}
{{- fail "license.existingSecret is required" -}}
{{- end -}}
{{- if and (not .Values.config.existingSecret) (not .Values.config.render) -}}
{{- fail "config: set config.existingSecret (bring your own config Secret) or config.render=true (chart renders it from .Values.memory / .Values.shared)" -}}
{{- end -}}
{{- if and .Values.config.existingSecret .Values.config.render -}}
{{- fail "config: existingSecret (BYO Secret) and render (chart-rendered ConfigMap) are mutually exclusive; existingSecret silently wins over render, so pick one" -}}
{{- end -}}
{{- if and .Values.config.render (not .Values.memory) (not .Values.shared) -}}
{{- fail "config.render=true requires a config body: set .Values.memory (and optionally .Values.shared)" -}}
{{- end -}}
{{- if not .Values.config.secretKey -}}
{{- fail "config.secretKey is required" -}}
{{- end -}}
{{- if eq .Values.image.repository "redislabs/memory-dataplane" -}}
{{- fail "image.repository=redislabs/memory-dataplane is reserved for cloud releases; use redislabs/agent-memory or a mirrored on-prem registry" -}}
{{- end -}}
{{- if .Values.airgap.enabled -}}
{{- if eq .Values.image.repository "redislabs/agent-memory" -}}
{{- fail "airgap.enabled=true requires image.repository to point to a mirrored registry reachable from the cluster" -}}
{{- end -}}
{{- end -}}
{{- $profile := include "redis-agent-memory.securityProfile" . -}}
{{- if and (ne $profile "") (ne $profile "fips") -}}
{{- fail (printf "security.profile=%q is not supported (valid values: \"\", \"fips\"). See the chart README section \"FIPS-oriented posture\"." $profile) -}}
{{- end -}}
{{- if not .Values.controlplane.image.tag -}}
{{- fail "controlplane.image.tag is required" -}}
{{- end -}}
{{- if lt (int .Values.controlplane.replicaCount) 1 -}}
{{- fail "controlplane.replicaCount must be at least 1" -}}
{{- end -}}
{{- if and (not .Values.controlplane.config.existingSecret) (not .Values.controlplane.config.render) -}}
{{- fail "controlplane.config: set controlplane.config.existingSecret (BYO) or controlplane.config.render=true (chart renders it from .Values.controlplane.configData / .Values.shared)" -}}
{{- end -}}
{{- if and .Values.controlplane.config.existingSecret .Values.controlplane.config.render -}}
{{- fail "controlplane.config: existingSecret (BYO Secret) and render (chart-rendered ConfigMap) are mutually exclusive; existingSecret silently wins over render, so pick one" -}}
{{- end -}}
{{- if and .Values.controlplane.config.render (not .Values.controlplane.configData) (not .Values.shared) -}}
{{- fail "controlplane.config.render=true requires a config body: set .Values.controlplane.configData (and optionally .Values.shared)" -}}
{{- end -}}
{{- if not .Values.controlplane.config.secretKey -}}
{{- fail "controlplane.config.secretKey is required" -}}
{{- end -}}
{{- if and (not .Values.controlplane.adminToken.existingSecret) (not .Values.controlplane.adminToken.autoGenerate) -}}
{{- fail "controlplane.adminToken: set adminToken.existingSecret (BYO) or adminToken.autoGenerate=true" -}}
{{- end -}}
{{- if and (not .Values.controlplane.internalToken.existingSecret) (not .Values.controlplane.internalToken.autoGenerate) -}}
{{- fail "controlplane.internalToken: set internalToken.existingSecret (BYO) or internalToken.autoGenerate=true" -}}
{{- end -}}
{{- if and (eq (include "redis-agent-memory.controlplaneAdminTokenSecretName" .) (include "redis-agent-memory.controlplaneInternalTokenSecretName" .)) (eq .Values.controlplane.adminToken.secretKey .Values.controlplane.internalToken.secretKey) -}}
{{- fail "controlplane.internalToken must not use the same Secret/key as controlplane.adminToken" -}}
{{- end -}}
{{- if and .Values.airgap.enabled (eq .Values.controlplane.image.repository "redislabs/agent-memory-control-plane") -}}
{{- fail "airgap.enabled=true requires controlplane.image.repository to point to a mirrored registry reachable from the cluster" -}}
{{- end -}}
{{- include "redis-agent-memory.validateIdentityService" . -}}
{{- $queueMonitor := .Values.controlplane.queueMonitor -}}
{{- if and $queueMonitor $queueMonitor.enabled -}}
{{- if not $queueMonitor.image.repository -}}
{{- fail "controlplane.queueMonitor.image.repository is required when controlplane.queueMonitor.enabled=true" -}}
{{- end -}}
{{- if not $queueMonitor.image.tag -}}
{{- fail "controlplane.queueMonitor.image.tag is required when controlplane.queueMonitor.enabled=true" -}}
{{- end -}}
{{- if and .Values.airgap.enabled (eq $queueMonitor.image.repository "hibiken/asynqmon") -}}
{{- fail "airgap.enabled=true requires controlplane.queueMonitor.image.repository to point to a mirrored registry reachable from the cluster" -}}
{{- end -}}
{{- if not $queueMonitor.redis.existingSecret -}}
{{- fail "controlplane.queueMonitor.redis.existingSecret is required when controlplane.queueMonitor.enabled=true" -}}
{{- end -}}
{{- if not $queueMonitor.redis.urlKey -}}
{{- fail "controlplane.queueMonitor.redis.urlKey is required when controlplane.queueMonitor.enabled=true" -}}
{{- end -}}
{{- if $queueMonitor.ingress.enabled -}}
{{- if ne (default "basic" $queueMonitor.auth.type) "basic" -}}
{{- fail "controlplane.queueMonitor.auth.type must be \"basic\" when controlplane.queueMonitor.ingress.enabled=true" -}}
{{- end -}}
{{- if not $queueMonitor.auth.existingSecret -}}
{{- fail "controlplane.queueMonitor.auth.existingSecret is required when controlplane.queueMonitor.ingress.enabled=true" -}}
{{- end -}}
{{- if not $queueMonitor.auth.secretKey -}}
{{- fail "controlplane.queueMonitor.auth.secretKey is required when controlplane.queueMonitor.ingress.enabled=true" -}}
{{- end -}}
{{- if ne $queueMonitor.auth.secretKey "auth" -}}
{{- fail "controlplane.queueMonitor.auth.secretKey must be \"auth\" for ingress-nginx Basic Auth" -}}
{{- end -}}
{{- if not $queueMonitor.ingress.host -}}
{{- fail "controlplane.queueMonitor.ingress.host is required when controlplane.queueMonitor.ingress.enabled=true" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Common container env entries applied to both the server and worker
Deployments. Centralizing env vars here avoids the classic Helm mistake
of remembering to add a new env var to one Deployment but not the other.
Carries the Go runtime's FIPS setting plus SSL_CERT_DIR when a TLS CA bundle
is mounted.
*/}}
{{- define "redis-agent-memory.commonEnv" -}}
{{ include "redis-onprem.commonEnv" (dict "securityProfile" (include "redis-agent-memory.securityProfile" .) "tlsCaCertSecret" (include "redis-agent-memory.tlsCaCertSecret" .)) }}
{{- end }}

{{/*
Full container env for the server and worker. Credentials are no longer injected
as env vars — they arrive inside the mounted secret overlays (see
overlayVolumes / overlayConfigArgs) — so this is just the common env
(GODEBUG, SSL_CERT_DIR). Kept as a named partial so the three
Deployments stay in sync if service-wide env is added later.
*/}}
{{- define "redis-agent-memory.env" -}}
{{ include "redis-agent-memory.commonEnv" . }}
{{- end }}

{{/*
Rendered component config body. Deep-merges the shared blocks (.Values.shared)
under the given component config tree (.body), so overlapping config
(embedders structure, store metadata structure, endpoints) is defined once and
reused by both the data plane and control plane. .body wins over shared.* on key
conflicts. Takes a dict with "Values" (root .Values, for .Values.shared) and
"body" (the component-specific config tree).

The component body IS the on-prem config file body in snake_case; Helm has
already deep-merged base-values + region overrides before this runs, so this is
just serialization. Secrets
(API keys, Redis connection URLs) are never present here — they arrive via the
mounted secret overlays and are merged by the config loader at runtime.
*/}}
{{- define "redis-agent-memory.renderConfig" -}}
{{- $shared := deepCopy (default (dict) .Values.shared) -}}
{{- $cfg := mergeOverwrite $shared (deepCopy (default (dict) .body)) -}}
{{- $oidc := index (default (dict) (index $cfg "auth")) "oidc" -}}
{{- if kindIs "map" $oidc -}}
{{- include "redis-agent-memory.stampOIDCTenant" (dict "oidc" $oidc "tenant" .Values.tenantId "path" "auth.oidc") -}}
{{- include "redis-agent-memory.stampOIDCAudience" (dict "oidc" $oidc "audience" (dig "oidc" "audience" "" (default (dict) .Values.auth))) -}}
{{- end -}}
{{- toYaml $cfg -}}
{{- end }}

{{/*
Central tenant (MOD-19153 decision 4): one tenantId value (single-tenant
deployments only) is the static tenant of every enabled auth.oidc block. The
Identity Service release's singleTenantID must match it; deployment automation
keeps the two releases consistent.

stampOIDCTenant sets tenantId as the static_tenant_id of an enabled oidc dict,
in place, rendering nothing. tenantId conflicts with a tenant_id_claim
(multi-tenant) and with a different static_tenant_id.
*/}}
{{- define "redis-agent-memory.stampOIDCTenant" -}}
{{- if .oidc.enabled -}}
{{- $tenant := trim (toString (default "" .tenant)) -}}
{{- $claim := trim (toString (default "" .oidc.tenant_id_claim)) -}}
{{- $static := trim (toString (default "" .oidc.static_tenant_id)) -}}
{{- if and $tenant $claim -}}
{{- fail (printf "tenantId is for single-tenant deployments and pins every agent key to it; %s.tenant_id_claim is multi-tenant. Unset one of them" .path) -}}
{{- else if and $tenant $static (ne $static $tenant) -}}
{{- fail (printf "%s.static_tenant_id %q differs from tenantId %q" .path $static $tenant) -}}
{{- else if $tenant -}}
{{- $_ := set .oidc "static_tenant_id" $tenant -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Sets auth.oidc.audience (default api://redis-iris) as the audience of an enabled
oidc dict, in place, rendering nothing. An audience already written in that dict
(memory.auth.oidc.audience, controlplane.configData.auth.oidc.audience) must
equal it, otherwise the render fails, so services cannot drift apart. The
Identity Service control auth block is not touched.
*/}}
{{- define "redis-agent-memory.stampOIDCAudience" -}}
{{- if .oidc.enabled -}}
{{- $audience := trim (toString (default "" .audience)) -}}
{{- if not $audience -}}
{{- fail "auth.oidc.audience is required when auth.oidc is enabled: set the audience the IdP issues for the Iris API" -}}
{{- end -}}
{{- if contains "*" $audience -}}
{{- fail "auth.oidc.audience must not contain a wildcard" -}}
{{- end -}}
{{- $raw := default (list) .oidc.audience -}}
{{- if kindIs "string" $raw -}}{{- $raw = list $raw -}}{{- end -}}
{{- $explicit := compact (mustToJson $raw | mustFromJson | default (list)) -}}
{{- if and $explicit (ne (toJson $explicit) (toJson (list $audience))) -}}
{{- fail (printf "the rendered auth.oidc.audience %s differs from auth.oidc.audience %q: every Iris service accepts the one audience in auth.oidc.audience. Remove audience from memory.auth.oidc / controlplane.configData.auth.oidc, or set auth.oidc.audience to that value (for example api://memory-dp if your IdP still issues it)" (toJson $explicit) $audience) -}}
{{- end -}}
{{- $_ := set .oidc "audience" (list $audience) -}}
{{- end -}}
{{- end }}

{{/*
Rendered data-plane config body (.Values.memory). See renderConfig. Whenever
the data plane calls the Identity Service (see dataplaneUsesIdentityService)
the chart owns auth.agent_keys.introspection's endpoint and credential and
defaults agent_keys.enabled; only agent-key auth also sets auth.method.
validateIdentityService has already refused anything that cannot start.
*/}}
{{- define "redis-agent-memory.dataplaneConfig" -}}
{{- $body := deepCopy (default (dict) .Values.memory) -}}
{{- /* The data plane refuses auth.method=none outside profile dev; fail at render time instead. */ -}}
{{- if and .Values.config.render (not .Values.config.existingSecret) -}}
{{- if and (eq (include "redis-agent-memory.dataplaneAuthMethod" .) "none") (ne (include "redis-agent-memory.dataplaneProfile" .) "dev") -}}
{{- fail "memory.auth.method=none is allowed only with memory.profile=dev, and the data plane refuses to start otherwise. Use agent-key auth for a deployment that keeps data, or set memory.profile=dev for development." -}}
{{- end -}}
{{- end -}}
{{- if include "redis-agent-memory.dataplaneUsesIdentityService" . -}}
{{- $auth := default (dict) (index $body "auth") -}}
{{- $agentKeys := default (dict) (index $auth "agent_keys") -}}
{{- if include "redis-agent-memory.dataplaneUsesAgentKeys" . -}}
{{- $_ := set $auth "method" "agent_key" -}}
{{- end -}}
{{- /* identity_service subjects look grants up through the agent-key client, which the binary builds only when enabled. */ -}}
{{- if not (hasKey $agentKeys "enabled") -}}
{{- $_ := set $agentKeys "enabled" true -}}
{{- end -}}
{{- $introspection := default (dict) (index $agentKeys "introspection") -}}
{{- $_ := set $introspection "base_url" (default "" (default (dict) .Values.dataplane).identityServiceBaseURL) -}}
{{- $_ := set $introspection "allow_insecure_transport" (not (hasPrefix "https://" $introspection.base_url)) -}}
{{- if not (hasKey $introspection "product") -}}
{{- $_ := set $introspection "product" "memory" -}}
{{- end -}}
{{- $_ := set $introspection "credential" (dict "token_file" "/etc/identity-service/runtime/memory-dp/token") -}}
{{- $_ := set $agentKeys "introspection" $introspection -}}
{{- $_ := set $auth "agent_keys" $agentKeys -}}
{{- $_ := set $body "auth" $auth -}}
{{- end -}}
{{- include "redis-agent-memory.renderConfig" (dict "Values" .Values "body" $body) -}}
{{- end }}

{{/*
Rendered control-plane config body (.Values.controlplane.configData). See
renderConfig. The internal token is wired unconditionally: the Identity Service
release calls this control plane's grant validator with it.
*/}}
{{- define "redis-agent-memory.controlplaneConfig" -}}
{{- $body := deepCopy (default (dict) .Values.controlplane.configData) -}}
{{- $auth := default (dict) (index $body "auth") -}}
{{- $internalToken := default (dict) (index $auth "internal_token") -}}
{{- if not (or (index $internalToken "token_file") (index $internalToken "token")) -}}
{{- $_ := set $internalToken "token_file" "/etc/controlplane-onprem/internal/token" -}}
{{- end -}}
{{- $_ := set $auth "internal_token" $internalToken -}}
{{- /* tenantId owns admin-token resources too; a differing explicit value fails like static_tenant_id. */ -}}
{{- $tenant := trim (toString (default "" .Values.tenantId)) -}}
{{- $adminTenant := trim (toString (default "" (index $auth "admin_tenant_id"))) -}}
{{- if and $tenant $adminTenant (ne $adminTenant $tenant) -}}
{{- fail (printf "controlplane.configData.auth.admin_tenant_id %q differs from tenantId %q" $adminTenant $tenant) -}}
{{- else if $tenant -}}
{{- $_ := set $auth "admin_tenant_id" $tenant -}}
{{- end -}}
{{- $_ := set $body "auth" $auth -}}
{{- include "redis-agent-memory.renderConfig" (dict "Values" .Values "body" $body) -}}
{{- end }}

{{/*
Ordered list of overlay Secret NAMES to mount, in merge order (later wins).
Built as (secrets.secretName if non-empty) followed by each entry of
secrets.additionalSecrets in order. Returns a JSON-encoded list so callers can
`fromJsonArray` it and iterate with a stable 0-based index. For most (single
region) deployments this is just [secretName]; multi-region adds per-region
Secrets via additionalSecrets. Empty when no secretName and no additionalSecrets
(e.g. a BYO existingSecret deployment with credentials embedded in the URLs) —
callers then render no overlay volumes/mounts and no overlay --config args.
*/}}
{{- define "redis-agent-memory.overlaySecretNames" -}}
{{- include "redis-onprem.overlaySecretNames" .Values.secrets -}}
{{- end }}

{{/*
Overlay Secret volumes. Renders a read-only Secret volume for each overlay in the
ordered list (secretName, then additionalSecrets). Each Secret is pre-created and
holds a single YAML overlay file under secrets.overlayKey. Mounted as a volume
(NOT subPath) so Kubernetes' atomic ..data swap propagates rotations on pod
restart. The i-th overlay (0-based) gets volume name config-overlay-<i>. Renders
nothing when the ordered list is empty. Mirrors the tlsVolume pattern so the
three Deployments stay in sync.
*/}}
{{- define "redis-agent-memory.overlayVolumes" -}}
{{- $key := "overlay.yaml" -}}
{{- if .Values.secrets }}{{- $key = .Values.secrets.overlayKey | default "overlay.yaml" -}}{{- end }}
{{- include "redis-onprem.overlayVolumes" (dict "names" (include "redis-agent-memory.overlaySecretNames" .) "volumePrefix" "config-overlay" "key" $key) -}}
{{- end }}

{{/*
Overlay Secret volumeMounts. Mounts the i-th overlay (0-based) read-only at
/etc/ai/overlays/<i>. The overlay.yaml file inside each is what its overlay
--config arg points at.
*/}}
{{- define "redis-agent-memory.overlayVolumeMounts" -}}
{{- include "redis-onprem.overlayVolumeMounts" (dict "names" (include "redis-agent-memory.overlaySecretNames" .) "volumePrefix" "config-overlay" "mountBase" "/etc/ai/overlays") -}}
{{- end }}

{{/*
The overlay --config container args. The binary takes a repeatable --config flag:
the base config is passed first (in .Values.args for the data plane, inline for the
control plane), and this partial appends one "--config <path>" pair per mounted
overlay, in ordered-list order (secretName first, then additionalSecrets), so the
loader deep-merges them over the base in order (later wins) before MEM_* env
overrides. Emits nothing when the ordered list is empty.
*/}}
{{- define "redis-agent-memory.overlayConfigArgs" -}}
{{- include "redis-onprem.overlayConfigArgs" (dict "names" (include "redis-agent-memory.overlaySecretNames" .) "mountBase" "/etc/ai/overlays") -}}
{{- end }}

{{/*
Checksum of the ordered list of overlay Secret names, for a pod annotation. This
does not see the Secret contents (they are pre-created out of band), but rolling
on a name (or ordering) change is a cheap correctness win.
*/}}
{{- define "redis-agent-memory.overlayChecksum" -}}
{{- include "redis-onprem.overlayChecksum" (include "redis-agent-memory.overlaySecretNames" .) -}}
{{- end }}

{{/*
TLS CA certificate volume. Renders a projected Secret volume when
tls.caCertSecret (or global.tls.caCertSecret) is configured.
*/}}
{{- define "redis-agent-memory.tlsVolume" -}}
{{- with include "redis-agent-memory.tlsCaCertSecret" . }}
- name: tls-ca-cert
  secret:
    secretName: {{ . }}
    items:
      - key: {{ include "redis-agent-memory.tlsCaCertKey" $ }}
        path: {{ include "redis-agent-memory.tlsCaCertKey" $ }}
{{- end }}
{{- end }}

{{/*
TLS CA certificate volumeMount. Mounts the CA bundle at /etc/ssl/custom/
when tls.caCertSecret (or global.tls.caCertSecret) is configured.
*/}}
{{- define "redis-agent-memory.tlsVolumeMount" -}}
{{- if include "redis-agent-memory.tlsCaCertSecret" . }}
- name: tls-ca-cert
  mountPath: /etc/ssl/custom
  readOnly: true
{{- end }}
{{- end }}
