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
Fully qualified name for the optional suite-level Identity Service Deployment
and resources. The RAM chart packages the first deployment path, but the service
itself is shared across Iris products.
*/}}
{{- define "redis-agent-memory.identityServiceFullname" -}}
{{- printf "%s-identity-service" (include "redis-agent-memory.fullname" . | trunc 46 | trimSuffix "-") }}
{{- end }}

{{/*
Create the name of the Identity Service config carrier to use. When
identityService.config.existingSecret is set it names that BYO Secret; otherwise
it names the chart-rendered config ConfigMap.
*/}}
{{- define "redis-agent-memory.identityServiceConfigName" -}}
{{- if .Values.identityService.config.existingSecret }}
{{- .Values.identityService.config.existingSecret }}
{{- else }}
{{- printf "%s-config" (include "redis-agent-memory.identityServiceFullname" . | trunc 56 | trimSuffix "-") }}
{{- end }}
{{- end }}

{{/*
Create the name of the Identity Service Control admin-token Secret to use.
*/}}
{{- define "redis-agent-memory.identityServiceControlTokenSecretName" -}}
{{- if .Values.identityService.controlToken.existingSecret }}
{{- .Values.identityService.controlToken.existingSecret }}
{{- else }}
{{- printf "%s-control-token" (include "redis-agent-memory.identityServiceFullname" . | trunc 49 | trimSuffix "-") }}
{{- end }}
{{- end }}

{{/*
Stable name for one Identity Service Runtime service credential. The value is
operator-provided because generated Secret names and mounted token_file paths
must not depend on list position once multiple products share IdS.
Takes a dict with credential.
*/}}
{{- define "redis-agent-memory.identityServiceRuntimeCredentialName" -}}
{{- default "" .credential.name -}}
{{- end }}

{{/*
Create the name of one Identity Service Runtime service-credential Secret.
Takes a dict with root and credential.
*/}}
{{- define "redis-agent-memory.identityServiceRuntimeCredentialSecretName" -}}
{{- $root := .root -}}
{{- $credential := .credential -}}
{{- if $credential.existingSecret -}}
{{- $credential.existingSecret -}}
{{- else -}}
{{- $name := include "redis-agent-memory.identityServiceRuntimeCredentialName" (dict "credential" $credential) -}}
{{- $suffix := printf "-runtime-%s" $name -}}
{{- printf "%s%s" (include "redis-agent-memory.identityServiceFullname" $root | trunc (int (sub 63 (len $suffix))) | trimSuffix "-") $suffix -}}
{{- end -}}
{{- end }}

{{/*
Stable runtime credential name used by the packaged RAM data plane when it calls
IdS Runtime for API-key introspection.
*/}}
{{- define "redis-agent-memory.identityServiceMemoryRuntimeCredentialExpectedName" -}}
{{- default "memory-dp" .Values.identityService.runtime.memoryCredentialName -}}
{{- end }}

{{- define "redis-agent-memory.identityServiceMemoryRuntimeCredentialName" -}}
{{- $name := "" -}}
{{- $expectedName := include "redis-agent-memory.identityServiceMemoryRuntimeCredentialExpectedName" . -}}
{{- range $credential := (default (list) .Values.identityService.runtime.serviceCredentials) }}
{{- $credentialName := include "redis-agent-memory.identityServiceRuntimeCredentialName" (dict "credential" $credential) -}}
{{- if eq $credentialName $expectedName -}}
{{- $name = $credentialName -}}
{{- end -}}
{{- end -}}
{{- $name -}}
{{- end }}

{{- define "redis-agent-memory.identityServiceMemoryRuntimeCredentialSecretName" -}}
{{- $secretName := "" -}}
{{- $expectedName := include "redis-agent-memory.identityServiceMemoryRuntimeCredentialExpectedName" . -}}
{{- range $credential := (default (list) .Values.identityService.runtime.serviceCredentials) }}
{{- $credentialName := include "redis-agent-memory.identityServiceRuntimeCredentialName" (dict "credential" $credential) -}}
{{- if eq $credentialName $expectedName -}}
{{- $secretName = include "redis-agent-memory.identityServiceRuntimeCredentialSecretName" (dict "root" $ "credential" $credential) -}}
{{- end -}}
{{- end -}}
{{- $secretName -}}
{{- end }}

{{- define "redis-agent-memory.identityServiceMemoryRuntimeCredentialSecretKey" -}}
{{- $secretKey := "" -}}
{{- $expectedName := include "redis-agent-memory.identityServiceMemoryRuntimeCredentialExpectedName" . -}}
{{- range $credential := (default (list) .Values.identityService.runtime.serviceCredentials) }}
{{- $credentialName := include "redis-agent-memory.identityServiceRuntimeCredentialName" (dict "credential" $credential) -}}
{{- if eq $credentialName $expectedName -}}
{{- $secretKey = $credential.secretKey -}}
{{- end -}}
{{- end -}}
{{- $secretKey -}}
{{- end }}

{{- define "redis-agent-memory.identityServiceMemoryRuntimeCredentialTokenFile" -}}
{{- $credentialName := include "redis-agent-memory.identityServiceMemoryRuntimeCredentialName" . -}}
{{- if $credentialName -}}
{{- printf "/etc/identity-service/runtime/%s/token" $credentialName -}}
{{- end -}}
{{- end }}

{{- define "redis-agent-memory.identityServiceMemoryRuntimeCredentialMountPath" -}}
{{- $credentialName := include "redis-agent-memory.identityServiceMemoryRuntimeCredentialName" . -}}
{{- if $credentialName -}}
{{- printf "/etc/identity-service/runtime/%s" $credentialName -}}
{{- end -}}
{{- end }}

{{- define "redis-agent-memory.identityServiceMemoryRuntimeCredentialVolumeName" -}}
identity-service-runtime-memory-dp
{{- end }}

{{/*
Base URL used by IdS product-validation calls.
Takes a dict with root, product, and config. The memory product defaults to the
RAM control-plane Service because this chart can deploy that product CP today.
All other products must provide an explicit baseURL.
*/}}
{{- define "redis-agent-memory.identityServiceProductValidationBaseURL" -}}
{{- $root := .root -}}
{{- $product := .product -}}
{{- $cfg := default (dict) .config -}}
{{- if $cfg.baseURL -}}
{{- $cfg.baseURL -}}
{{- else if eq $product "memory" -}}
{{- printf "http://%s:%v" (include "redis-agent-memory.controlplaneFullname" $root) $root.Values.controlplane.service.port -}}
{{- end -}}
{{- end }}

{{/*
Secret name used by one IdS product-validation credential.
Takes a dict with root, product, and config.
*/}}
{{- define "redis-agent-memory.identityServiceProductValidationSecretName" -}}
{{- $root := .root -}}
{{- $product := .product -}}
{{- $cfg := default (dict) .config -}}
{{- $credential := default (dict) $cfg.credential -}}
{{- if $credential.existingSecret -}}
{{- $credential.existingSecret -}}
{{- else if eq $product "memory" -}}
{{- include "redis-agent-memory.controlplaneInternalTokenSecretName" $root -}}
{{- end -}}
{{- end }}

{{/*
Secret key used by one IdS product-validation credential.
Takes a dict with root, product, and config.

For the packaged memory product with no existingSecret, the chart is pointing IdS
at the control plane's own internal-token Secret, so the key has to be the one
that Secret publishes — controlplane.internalToken.secretKey. The operator is not
supplying that Secret and therefore does not name its key; honouring
credential.secretKey here would mount a key the Secret does not contain, leaving
the container unable to start once controlplane.internalToken.secretKey was
changed from its default. credential.secretKey applies when the operator brings
their own Secret, which is the only case where they own the key name.
*/}}
{{- define "redis-agent-memory.identityServiceProductValidationSecretKey" -}}
{{- $root := .root -}}
{{- $product := .product -}}
{{- $cfg := default (dict) .config -}}
{{- $credential := default (dict) $cfg.credential -}}
{{- if and (eq $product "memory") (not $credential.existingSecret) -}}
{{- $root.Values.controlplane.internalToken.secretKey -}}
{{- else if $credential.secretKey -}}
{{- $credential.secretKey -}}
{{- else -}}token{{- end -}}
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
{{- if .Values.security -}}
{{- $profile := default "" .Values.security.profile -}}
{{- if and (ne $profile "") (ne $profile "fips") -}}
{{- fail (printf "security.profile=%q is not supported (valid values: \"\", \"fips\"). See the chart README section \"FIPS-oriented posture\"." $profile) -}}
{{- end -}}
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
{{- $ids := default (dict) .Values.identityService -}}
{{- if and $ids $ids.enabled -}}
{{- if not $ids.image.tag -}}
{{- fail "identityService.image.tag is required when identityService.enabled=true" -}}
{{- end -}}
{{- if and (not $ids.config.existingSecret) (not $ids.config.render) -}}
{{- fail "identityService.config: set identityService.config.existingSecret (BYO) or identityService.config.render=true" -}}
{{- end -}}
{{- if and $ids.config.existingSecret $ids.config.render -}}
{{- fail "identityService.config: existingSecret (BYO Secret) and render (chart-rendered ConfigMap) are mutually exclusive; pick one" -}}
{{- end -}}
{{- if not $ids.config.secretKey -}}
{{- fail "identityService.config.secretKey is required when identityService.enabled=true" -}}
{{- end -}}
{{- if and $ids.config.render (not $ids.metadata.existingSecret) -}}
{{- fail "identityService.metadata.existingSecret is required when identityService.config.render=true" -}}
{{- end -}}
{{- if and $ids.metadata.existingSecret (not $ids.metadata.secretKey) -}}
{{- fail "identityService.metadata.secretKey is required when identityService.metadata.existingSecret is set" -}}
{{- end -}}
{{- if and (not $ids.controlToken.existingSecret) (not $ids.controlToken.autoGenerate) -}}
{{- fail "identityService.controlToken: set controlToken.existingSecret (BYO) or controlToken.autoGenerate=true" -}}
{{- end -}}
{{- if not $ids.controlToken.secretKey -}}
{{- fail "identityService.controlToken.secretKey is required when identityService.enabled=true" -}}
{{- end -}}
{{- $runtime := default (dict) $ids.runtime -}}
{{- $cache := default (dict) $runtime.cache -}}
{{- $softTTL := int (default 180 $cache.softTtlSeconds) -}}
{{- $hardTTL := int (default 300 $cache.hardTtlSeconds) -}}
{{- if lt $softTTL 0 -}}
{{- fail "identityService.runtime.cache.softTtlSeconds must not be negative" -}}
{{- end -}}
{{- if lt $hardTTL 0 -}}
{{- fail "identityService.runtime.cache.hardTtlSeconds must not be negative" -}}
{{- end -}}
{{- if lt $hardTTL $softTTL -}}
{{- fail "identityService.runtime.cache.hardTtlSeconds must be greater than or equal to identityService.runtime.cache.softTtlSeconds" -}}
{{- end -}}
{{- $runtimeCredentials := default (list) $runtime.serviceCredentials -}}
{{- if not $runtimeCredentials -}}
{{- fail "identityService.runtime.serviceCredentials is required when identityService.enabled=true" -}}
{{- end -}}
{{- $idsControlSecret := include "redis-agent-memory.identityServiceControlTokenSecretName" . -}}
{{- $runtimeCredentialRefs := dict -}}
{{- $runtimeCredentialNames := dict -}}
{{- $memoryRuntimeCredentialName := include "redis-agent-memory.identityServiceMemoryRuntimeCredentialExpectedName" . -}}
{{- if not (regexMatch "^[a-z0-9-]{1,44}$" $memoryRuntimeCredentialName) -}}
{{- fail "identityService.runtime.memoryCredentialName must match ^[a-z0-9-]{1,44}$" -}}
{{- end -}}
{{- $memoryAuth := default (dict) .Values.memory.auth -}}
{{- $memoryAuthMethod := default "agent_key" $memoryAuth.method -}}
{{- $chartManagedMemoryIntrospection := and .Values.config.render (not .Values.config.existingSecret) (eq $memoryAuthMethod "agent_key") -}}
{{- if and (eq $idsControlSecret (include "redis-agent-memory.controlplaneAdminTokenSecretName" .)) (eq $ids.controlToken.secretKey .Values.controlplane.adminToken.secretKey) -}}
{{- fail "identityService.controlToken must not use the same Secret/key as controlplane.adminToken" -}}
{{- end -}}
{{- if and (eq $idsControlSecret (include "redis-agent-memory.controlplaneInternalTokenSecretName" .)) (eq $ids.controlToken.secretKey .Values.controlplane.internalToken.secretKey) -}}
{{- fail "identityService.controlToken must not use the same Secret/key as controlplane.internalToken" -}}
{{- end -}}
{{- range $i, $credential := $runtimeCredentials -}}
{{- $credentialName := include "redis-agent-memory.identityServiceRuntimeCredentialName" (dict "credential" $credential) -}}
{{- if not $credentialName -}}
{{- fail (printf "identityService.runtime.serviceCredentials[%d].name is required" $i) -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9-]{1,44}$" $credentialName) -}}
{{- fail (printf "identityService.runtime.serviceCredentials[%d].name must match ^[a-z0-9-]{1,44}$" $i) -}}
{{- end -}}
{{- if hasKey $runtimeCredentialNames $credentialName -}}
{{- fail (printf "identityService.runtime.serviceCredentials[%d].name duplicates %s" $i (index $runtimeCredentialNames $credentialName)) -}}
{{- end -}}
{{- $_ := set $runtimeCredentialNames $credentialName (printf "identityService.runtime.serviceCredentials[%d].name" $i) -}}
{{- if not $credential.subject -}}
{{- fail (printf "identityService.runtime.serviceCredentials[%d].subject is required" $i) -}}
{{- end -}}
{{- if and (not $credential.existingSecret) (not $credential.autoGenerate) -}}
{{- fail (printf "identityService.runtime.serviceCredentials[%d]: set existingSecret (BYO) or autoGenerate=true" $i) -}}
{{- end -}}
{{- if not $credential.secretKey -}}
{{- fail (printf "identityService.runtime.serviceCredentials[%d].secretKey is required" $i) -}}
{{- end -}}
{{- if not $credential.allowedOperations -}}
{{- fail (printf "identityService.runtime.serviceCredentials[%d].allowedOperations is required" $i) -}}
{{- end -}}
{{- if not $credential.allowedProducts -}}
{{- fail (printf "identityService.runtime.serviceCredentials[%d].allowedProducts is required" $i) -}}
{{- end -}}
{{- if and $chartManagedMemoryIntrospection (eq $credentialName $memoryRuntimeCredentialName) -}}
{{- /*
  The chart is wiring the RAM data plane to introspect against this credential,
  so the credential has to actually carry that reach. Omitting it is otherwise
  indistinguishable from a deliberate choice, and the failure surfaces only at
  request time as a 403 naming no cause.

  Matching is case-insensitive on purpose, even though values.schema.json admits
  only canonical lowercase: the schema is the gate that enforces canonical form,
  and this check is the fallback behind it (schema validation can be skipped).
  A fallback must not be stricter than the service it guards — the Identity
  Service compares operations and products case-insensitively, so rejecting a
  value it would accept would turn this guard into its own outage.
*/ -}}
{{- $hasMemoryIntrospectionOperation := false -}}
{{- range $operation := $credential.allowedOperations -}}
{{- if eq (lower (trim (toString $operation))) "api-key-introspect" -}}
{{- $hasMemoryIntrospectionOperation = true -}}
{{- end -}}
{{- end -}}
{{- if not $hasMemoryIntrospectionOperation -}}
{{- fail (printf "identityService.runtime.serviceCredentials[%d].allowedOperations must include api-key-introspect for chart-rendered RAM data-plane IdS introspection" $i) -}}
{{- end -}}
{{- $hasMemoryProduct := false -}}
{{- range $product := $credential.allowedProducts -}}
{{- if eq (lower (trim (toString $product))) "memory" -}}
{{- $hasMemoryProduct = true -}}
{{- end -}}
{{- end -}}
{{- if not $hasMemoryProduct -}}
{{- fail (printf "identityService.runtime.serviceCredentials[%d].allowedProducts must include memory for chart-rendered RAM data-plane IdS introspection" $i) -}}
{{- end -}}
{{- end -}}
{{- $runtimeSecretName := include "redis-agent-memory.identityServiceRuntimeCredentialSecretName" (dict "root" $ "credential" $credential) -}}
{{- if and (eq $runtimeSecretName $idsControlSecret) (eq $credential.secretKey $.Values.identityService.controlToken.secretKey) -}}
{{- fail (printf "identityService.runtime.serviceCredentials[%d] must not use the same Secret/key as identityService.controlToken" $i) -}}
{{- end -}}
{{- $runtimeCredentialRefKey := printf "%s/%s" $runtimeSecretName $credential.secretKey -}}
{{- $runtimeCredentialRef := index $runtimeCredentialRefs $runtimeCredentialRefKey -}}
{{- if $runtimeCredentialRef -}}
{{- fail (printf "identityService.runtime.serviceCredentials[%d] must not use the same Secret/key as %s" $i $runtimeCredentialRef) -}}
{{- end -}}
{{- $_ := set $runtimeCredentialRefs $runtimeCredentialRefKey (printf "identityService.runtime.serviceCredentials[%d]" $i) -}}
{{- end -}}
{{- if and $chartManagedMemoryIntrospection (not (hasKey $runtimeCredentialNames $memoryRuntimeCredentialName)) -}}
{{- fail (printf "identityService.runtime.serviceCredentials must include a credential named %s for chart-rendered RAM data-plane IdS introspection; set identityService.runtime.memoryCredentialName to the RAM credential name or provide matching serviceCredentials" $memoryRuntimeCredentialName) -}}
{{- end -}}
{{- $productValidationValues := default (dict) $ids.productValidation -}}
{{- $validationProducts := default (dict) $productValidationValues.products -}}
{{- if not $validationProducts -}}
{{- fail "identityService.productValidation.products is required when identityService.enabled=true" -}}
{{- end -}}
{{- $enabledValidationProducts := 0 -}}
{{- range $product, $validation := $validationProducts -}}
{{- $enabled := true -}}
{{- if hasKey $validation "enabled" }}{{- $enabled = $validation.enabled -}}{{- end -}}
{{- if $enabled -}}
{{- $enabledValidationProducts = add $enabledValidationProducts 1 -}}
{{- if not (regexMatch "^[a-z0-9-]{1,44}$" $product) -}}
{{- fail (printf "identityService.productValidation.products.%s: product names must match ^[a-z0-9-]{1,44}$" $product) -}}
{{- end -}}
{{- $baseURL := include "redis-agent-memory.identityServiceProductValidationBaseURL" (dict "root" $ "product" $product "config" $validation) -}}
{{- if not $baseURL -}}
{{- fail (printf "identityService.productValidation.products.%s.baseURL is required" $product) -}}
{{- end -}}
{{- if not (regexMatch "^https?://[^/?#]+" $baseURL) -}}
{{- fail (printf "identityService.productValidation.products.%s.baseURL must be an absolute http:// or https:// URL" $product) -}}
{{- end -}}
{{- if regexMatch "^[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*@" $baseURL -}}
{{- fail (printf "identityService.productValidation.products.%s.baseURL must not include user info" $product) -}}
{{- end -}}
{{- if contains "?" $baseURL -}}
{{- fail (printf "identityService.productValidation.products.%s.baseURL must not include query parameters" $product) -}}
{{- end -}}
{{- if contains "#" $baseURL -}}
{{- fail (printf "identityService.productValidation.products.%s.baseURL must not include a fragment" $product) -}}
{{- end -}}
{{- $credential := default (dict) $validation.credential -}}
{{- $secretName := include "redis-agent-memory.identityServiceProductValidationSecretName" (dict "root" $ "product" $product "config" $validation) -}}
{{- $secretKey := include "redis-agent-memory.identityServiceProductValidationSecretKey" (dict "root" $ "product" $product "config" $validation) -}}
{{- if not $secretName -}}
{{- fail (printf "identityService.productValidation.products.%s.credential.existingSecret is required" $product) -}}
{{- end -}}
{{- if not $secretKey -}}
{{- fail (printf "identityService.productValidation.products.%s.credential.secretKey is required" $product) -}}
{{- end -}}
{{- if and (eq $secretName $idsControlSecret) (eq $secretKey $.Values.identityService.controlToken.secretKey) -}}
{{- fail (printf "identityService.productValidation.products.%s.credential must not use the same Secret/key as identityService.controlToken" $product) -}}
{{- end -}}
{{- $runtimeCredentialRef := index $runtimeCredentialRefs (printf "%s/%s" $secretName $secretKey) -}}
{{- if $runtimeCredentialRef -}}
{{- fail (printf "identityService.productValidation.products.%s.credential must not use the same Secret/key as %s" $product $runtimeCredentialRef) -}}
{{- end -}}
{{- if and (eq $product "memory") (eq $secretName (include "redis-agent-memory.controlplaneAdminTokenSecretName" $)) (eq $secretKey $.Values.controlplane.adminToken.secretKey) -}}
{{- fail "identityService.productValidation.products.memory.credential must not use the same Secret/key as controlplane.adminToken" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if eq (int $enabledValidationProducts) 0 -}}
{{- fail "identityService.productValidation.products must contain at least one enabled product" -}}
{{- end -}}
{{- if and .Values.airgap.enabled (eq $ids.image.repository "redislabs/iris-identity-service") -}}
{{- fail "airgap.enabled=true requires identityService.image.repository to point to a mirrored registry reachable from the cluster" -}}
{{- end -}}
{{- end -}}
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
{{ include "redis-onprem.commonEnv" (dict "securityProfile" (default "" .Values.security.profile) "tlsCaCertSecret" .Values.tls.caCertSecret) }}
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
{{- toYaml $cfg -}}
{{- end }}

{{/* Rendered data-plane config body (.Values.memory). See renderConfig. */}}
{{- define "redis-agent-memory.dataplaneConfig" -}}
{{- $body := deepCopy (default (dict) .Values.memory) -}}
{{- $ids := default (dict) .Values.identityService -}}
{{- $runtimeCredentialName := include "redis-agent-memory.identityServiceMemoryRuntimeCredentialName" . -}}
{{/*
  Turning the Identity Service off does not turn agent-key auth off. The data
  plane defaults an unspecified auth method to agent_key on purpose, so that the
  secure posture is what you get by not deciding. With IdS enabled the block
  below writes the introspection endpoint that default needs; with IdS disabled
  nothing writes it, and the pod dies at startup demanding
  agent_keys.introspection.* fields the operator never wrote.

  Make the operator say what they meant, at render time and in their own terms,
  rather than at CrashLoopBackOff in ours. Anyone who has chosen a method -- or
  enabled any auth flavour, including pointing agent keys at an Identity Service
  this chart does not own -- passes straight through.
*/}}
{{- if and (not $ids.enabled) .Values.config.render (not .Values.config.existingSecret) -}}
{{- $auth := default (dict) (index $body "auth") -}}
{{- $agentKeys := default (dict) (index $auth "agent_keys") -}}
{{- $workerIdentity := default (dict) (index $auth "worker_identity") -}}
{{- $oidc := default (dict) (index $auth "oidc") -}}
{{- $flavourEnabled := or (index $auth "enabled") (index $agentKeys "enabled") (index $workerIdentity "enabled") (index $oidc "enabled") -}}
{{- if and (not (index $auth "method")) (not $flavourEnabled) -}}
{{- fail "identityService.enabled=false leaves memory.auth.method unset, and the data plane defaults that to agent_key -- which then fails to start because no Identity Service introspection endpoint was rendered for it. Choose one: set memory.auth.method=none to run behind an infrastructure access boundary; or keep agent-key auth and set memory.auth.agent_keys.introspection.base_url (plus product and credential) to an Identity Service this chart does not manage; or re-enable identityService.enabled." -}}
{{- end -}}
{{/*
  Choosing agent-key auth (explicitly or via agent_keys.enabled) is not the
  same as it being renderable: with the Identity Service disabled, nothing
  supplies agent_keys.introspection.base_url, and the data plane crashes at
  startup demanding it.
*/}}
{{- $agentKeyMethod := or (eq (default "" (index $auth "method")) "agent_key") (index $agentKeys "enabled") -}}
{{- $introspection := default (dict) (index $agentKeys "introspection") -}}
{{- if and $agentKeyMethod (not (index $introspection "base_url")) -}}
{{- fail "identityService.enabled=false leaves memory.auth resolving to agent-key auth (method=agent_key or agent_keys.enabled=true), but memory.auth.agent_keys.introspection.base_url is not set -- with the Identity Service disabled nothing will supply that endpoint and the data plane will crash at startup. Set memory.auth.agent_keys.introspection.base_url (plus product and credential) to an Identity Service this chart does not manage, or choose memory.auth.method=none instead." -}}
{{- end -}}
{{- end -}}
{{- if and $ids.enabled .Values.config.render (not .Values.config.existingSecret) $runtimeCredentialName -}}
{{- $auth := deepCopy (default (dict) (index $body "auth")) -}}
{{- $methodWasSet := hasKey $auth "method" -}}
{{- if not $methodWasSet -}}
{{- $_ := set $auth "method" "agent_key" -}}
{{- end -}}
{{- if eq (default "" (index $auth "method")) "agent_key" -}}
{{- $agentKeys := deepCopy (default (dict) (index $auth "agent_keys")) -}}
{{- if not (hasKey $agentKeys "enabled") -}}
{{- $_ := set $agentKeys "enabled" true -}}
{{- end -}}
{{- $introspection := deepCopy (default (dict) (index $agentKeys "introspection")) -}}
{{- if not (hasKey $introspection "base_url") -}}
{{/*
  The in-cluster default is plaintext, and the chart pairs it with
  allow_insecure_transport so the data plane accepts the http:// scheme. Under
  the FIPS-oriented profile that combination is exactly what the profile exists
  to forbid: agent-key material would travel to the Identity Service in the
  clear. Refuse to default it rather than render a config the data plane will
  reject at startup with a flag the operator never wrote.
*/}}
{{- if and .Values.security (eq (default "" .Values.security.profile) "fips") -}}
{{- fail "security.profile=fips requires a TLS endpoint for Identity Service introspection; the chart will not default memory.auth.agent_keys.introspection.base_url to the in-cluster http:// address. Set memory.auth.agent_keys.introspection.base_url to an https:// URL and leave allow_insecure_transport unset." -}}
{{- end -}}
{{- $_ := set $introspection "base_url" (printf "http://%s:%v" (include "redis-agent-memory.identityServiceFullname" .) .Values.identityService.service.port) -}}
{{- if not (hasKey $introspection "allow_insecure_transport") -}}
{{- $_ := set $introspection "allow_insecure_transport" true -}}
{{- end -}}
{{- end -}}
{{- if not (hasKey $introspection "product") -}}
{{- $_ := set $introspection "product" "memory" -}}
{{- end -}}
{{- $credential := deepCopy (default (dict) (index $introspection "credential")) -}}
{{- if not (or (index $credential "token_file") (index $credential "token")) -}}
{{- $_ := set $credential "token_file" (include "redis-agent-memory.identityServiceMemoryRuntimeCredentialTokenFile" .) -}}
{{- end -}}
{{- $_ := set $introspection "credential" $credential -}}
{{- $_ := set $agentKeys "introspection" $introspection -}}
{{- $_ := set $auth "agent_keys" $agentKeys -}}
{{- end -}}
{{- $_ := set $body "auth" $auth -}}
{{- end -}}
{{- include "redis-agent-memory.renderConfig" (dict "Values" .Values "body" $body) -}}
{{- end }}

{{/* Rendered control-plane config body (.Values.controlplane.configData). See renderConfig. */}}
{{- define "redis-agent-memory.controlplaneConfig" -}}
{{- $body := deepCopy (default (dict) .Values.controlplane.configData) -}}
{{- $ids := default (dict) .Values.identityService -}}
{{- if and $ids.enabled .Values.controlplane.config.render (not .Values.controlplane.config.existingSecret) -}}
{{- $auth := deepCopy (default (dict) (index $body "auth")) -}}
{{- $internalToken := deepCopy (default (dict) (index $auth "internal_token")) -}}
{{- if not (or (index $internalToken "token_file") (index $internalToken "token")) -}}
{{- $_ := set $internalToken "token_file" "/etc/controlplane-onprem/internal/token" -}}
{{- end -}}
{{- $_ := set $auth "internal_token" $internalToken -}}
{{- $_ := set $body "auth" $auth -}}
{{- end -}}
{{- include "redis-agent-memory.renderConfig" (dict "Values" .Values "body" $body) -}}
{{- end }}

{{/*
Rendered Identity Service config body. The chart owns mounted credential paths,
so this rendered ConfigMap carries structure only. Metadata Redis URLs arrive
through identityService.metadata.existingSecret as a Secret overlay.
*/}}
{{- define "redis-agent-memory.identityServiceConfig" -}}
{{- $ids := default (dict) .Values.identityService -}}
{{- $runtime := default (dict) $ids.runtime -}}
{{- $cache := default (dict) $runtime.cache -}}
{{- $apiKeys := default (dict) $ids.apiKeys -}}
{{- $cfg := deepCopy (default (dict) $ids.configData) -}}
{{- $_ := set $cfg "auth" (dict "type" "static-credential" "control" (dict "token_file" "/etc/identity-service/control/token")) -}}
{{- $runtimeCredentials := list -}}
{{- range $i, $credential := (default (list) $runtime.serviceCredentials) }}
{{- $credentialName := include "redis-agent-memory.identityServiceRuntimeCredentialName" (dict "credential" $credential) -}}
{{- $runtimeCredentials = append $runtimeCredentials (dict "subject" $credential.subject "token_file" (printf "/etc/identity-service/runtime/%s/token" $credentialName) "allowed_operations" $credential.allowedOperations "allowed_products" $credential.allowedProducts) -}}
{{- end }}
{{- $runtimeCfg := dict "service_credentials" $runtimeCredentials "cache" (dict "soft_ttl_seconds" (int (default 180 $cache.softTtlSeconds)) "hard_ttl_seconds" (int (default 300 $cache.hardTtlSeconds))) -}}
{{- $productValidationValues := default (dict) $ids.productValidation -}}
{{- $validationProducts := default (dict) $productValidationValues.products -}}
{{- $productValidation := dict -}}
{{- range $product, $validation := $validationProducts }}
{{- $enabled := true -}}
{{- if hasKey $validation "enabled" }}{{- $enabled = $validation.enabled -}}{{- end -}}
{{- if $enabled -}}
{{- $entry := dict "base_url" (include "redis-agent-memory.identityServiceProductValidationBaseURL" (dict "root" $ "product" $product "config" $validation)) "credential" (dict "token_file" (printf "/etc/identity-service/product-validation/%s/token" $product)) -}}
{{- $_ := set $productValidation $product $entry -}}
{{- end -}}
{{- end }}
{{- $_ := set $cfg "product_validation" $productValidation -}}
{{/*
  Claim pre-product grants only for a product this release actually configures.
  The default names `memory` because RAM is the only product that can hold
  legacy on-prem keys, but the same chart can be rendered with the memory
  validator disabled — and IdS rejects an owner that is not a configured
  product, so emitting it unconditionally would render a config the service
  refuses to start with.

  Dropping it here is only safe because a *typo* can no longer reach this point:
  values.schema.json holds unscopedGrantsProduct to the closed product set, so a
  misspelling fails the render instead of silently denying every legacy key.
  What is dropped here is a real product name this deployment does not
  configure — the default "memory" in a langcache-only install — which is the
  intended behaviour.
*/}}
{{- if and $runtime.unscopedGrantsProduct (hasKey $productValidation $runtime.unscopedGrantsProduct) -}}
{{- $_ := set $runtimeCfg "unscoped_grants_product" $runtime.unscopedGrantsProduct -}}
{{- end -}}
{{- $_ := set $cfg "runtime" $runtimeCfg -}}
{{- $_ := set $cfg "api_keys" (dict "max_rotate_grace_seconds" (int (default 604800 $apiKeys.maxRotateGraceSeconds))) -}}
{{- toYaml $cfg -}}
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
{{- $names := list -}}
{{- if .Values.secrets }}
{{- if .Values.secrets.secretName }}{{- $names = append $names .Values.secrets.secretName -}}{{- end }}
{{- range .Values.secrets.additionalSecrets }}{{- $names = append $names . -}}{{- end }}
{{- end }}
{{- $names | toJson -}}
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
{{- $names := include "redis-agent-memory.overlaySecretNames" . | fromJsonArray -}}
{{- range $i, $name := $names }}
- name: config-overlay-{{ $i }}
  secret:
    secretName: {{ $name }}
    items:
      - key: {{ $key }}
        path: overlay.yaml
{{- end }}
{{- end }}

{{/*
Overlay Secret volumeMounts. Mounts the i-th overlay (0-based) read-only at
/etc/ai/overlays/<i>. The overlay.yaml file inside each is what its overlay
--config arg points at.
*/}}
{{- define "redis-agent-memory.overlayVolumeMounts" -}}
{{- $names := include "redis-agent-memory.overlaySecretNames" . | fromJsonArray -}}
{{- range $i, $name := $names }}
- name: config-overlay-{{ $i }}
  mountPath: /etc/ai/overlays/{{ $i }}
  readOnly: true
{{- end }}
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
{{- $names := include "redis-agent-memory.overlaySecretNames" . | fromJsonArray -}}
{{- range $i, $name := $names }}
- "--config"
- {{ printf "/etc/ai/overlays/%d/overlay.yaml" $i | quote }}
{{- end }}
{{- end }}

{{/*
Checksum of the ordered list of overlay Secret names, for a pod annotation. This
does not see the Secret contents (they are pre-created out of band), but rolling
on a name (or ordering) change is a cheap correctness win.
*/}}
{{- define "redis-agent-memory.overlayChecksum" -}}
{{- include "redis-agent-memory.overlaySecretNames" . | sha256sum -}}
{{- end }}

{{/*
TLS CA certificate volume. Renders a projected Secret volume when
tls.caCertSecret is configured.
*/}}
{{- define "redis-agent-memory.tlsVolume" -}}
{{- if and .Values.tls .Values.tls.caCertSecret }}
- name: tls-ca-cert
  secret:
    secretName: {{ .Values.tls.caCertSecret }}
    items:
      - key: {{ .Values.tls.caCertKey }}
        path: {{ .Values.tls.caCertKey }}
{{- end }}
{{- end }}

{{/*
TLS CA certificate volumeMount. Mounts the CA bundle at /etc/ssl/custom/
when tls.caCertSecret is configured.
*/}}
{{- define "redis-agent-memory.tlsVolumeMount" -}}
{{- if and .Values.tls .Values.tls.caCertSecret }}
- name: tls-ca-cert
  mountPath: /etc/ssl/custom
  readOnly: true
{{- end }}
{{- end }}
