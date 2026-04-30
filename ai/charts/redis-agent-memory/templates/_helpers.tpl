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
Create the name of the shared config Secret to use.
*/}}
{{- define "redis-agent-memory.configSecretName" -}}
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
{{- if not .Values.config.existingSecret -}}
{{- fail "config.existingSecret is required" -}}
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
