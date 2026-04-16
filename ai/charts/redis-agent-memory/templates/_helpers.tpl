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
{{- if .Values.airgap.enabled -}}
{{- if eq .Values.image.repository "redislabs/agent-memory" -}}
{{- fail "airgap.enabled=true requires image.repository to point to a mirrored registry reachable from the cluster" -}}
{{- end -}}
{{- end -}}
{{- end }}
