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
{{- if .Values.controlplane.enabled -}}
{{- if not .Values.controlplane.image.tag -}}
{{- fail "controlplane.image.tag is required when controlplane.enabled=true" -}}
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
{{- fail "controlplane.config.secretKey is required when controlplane.enabled=true" -}}
{{- end -}}
{{- if and (not .Values.controlplane.adminToken.existingSecret) (not .Values.controlplane.adminToken.autoGenerate) -}}
{{- fail "controlplane.adminToken: set adminToken.existingSecret (BYO) or adminToken.autoGenerate=true" -}}
{{- end -}}
{{- if and .Values.airgap.enabled (eq .Values.controlplane.image.repository "redislabs/agent-memory-control-plane") -}}
{{- fail "airgap.enabled=true requires controlplane.image.repository to point to a mirrored registry reachable from the cluster" -}}
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
Carries MEM_SECURITY_PROFILE (see plan: "FIPS posture for on-prem Agent
Memory") plus SSL_CERT_DIR when a TLS CA bundle is mounted.
*/}}
{{- define "redis-agent-memory.commonEnv" -}}
- name: MEM_SECURITY_PROFILE
  value: {{ if .Values.security }}{{ default "" .Values.security.profile | quote }}{{ else }}""{{ end }}
{{- if and .Values.tls .Values.tls.caCertSecret }}
- name: SSL_CERT_DIR
  value: "/etc/ssl/custom"
{{- end }}
{{- end }}

{{/*
Full container env for the server and worker. Credentials are no longer injected
as env vars — they arrive inside the mounted secret overlays (see
overlayVolumes / overlayConfigArgs) — so this is just the common env
(MEM_SECURITY_PROFILE, SSL_CERT_DIR). Kept as a named partial so the three
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
just serialization. metadata.stores is a native map keyed by store id, so no
expansion is needed — Helm deep-merges base/region store maps directly. Secrets
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
{{- include "redis-agent-memory.renderConfig" (dict "Values" .Values "body" .Values.memory) -}}
{{- end }}

{{/* Rendered control-plane config body (.Values.controlplane.configData). See renderConfig. */}}
{{- define "redis-agent-memory.controlplaneConfig" -}}
{{- include "redis-agent-memory.renderConfig" (dict "Values" .Values "body" .Values.controlplane.configData) -}}
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
