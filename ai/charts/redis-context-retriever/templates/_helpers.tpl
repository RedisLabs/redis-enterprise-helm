{{/*
Expand the name of the chart.
*/}}
{{- define "cs.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "cs.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "cs.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "cs.labels" -}}
helm.sh/chart: {{ include "cs.chart" . }}
{{ include "cs.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "cs.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cs.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "cs.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "cs.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Config secret name
*/}}
{{- define "cs.configSecretName" -}}
{{- if .Values.secrets.existingSecret }}
{{- .Values.secrets.existingSecret }}
{{- else }}
{{- include "cs.fullname" . }}-config
{{- end }}
{{- end }}

{{/*
License secret name
*/}}
{{- define "cs.licenseSecretName" -}}
{{- if .Values.license.existingSecret }}
{{- .Values.license.existingSecret }}
{{- else }}
{{- include "cs.fullname" . }}-license
{{- end }}
{{- end }}

{{/*
Redis TLS CA volumes — one secret volume per entry in redis.tlsCA.existingSecrets.
Emits the list items only (no `volumes:` key); the caller supplies the key and indent.
*/}}
{{- define "cs.redisTLSCAVolumes" -}}
{{- range $i, $ca := .Values.redis.tlsCA.existingSecrets }}
- name: redis-tls-ca-{{ $i }}
  secret:
    secretName: {{ required "redis.tlsCA.existingSecrets[].secretName is required" $ca.secretName }}
{{- end }}
{{- end }}

{{/*
Redis TLS CA volume mounts — mounts each CA as a separate file under the system trust
path so Go's default cert pool picks it up alongside the public CA bundle. The on-disk
filename is auto-indexed (irrelevant to trust); subPath selects the cert key within the
secret (default: ca.crt). Emits the list items only (no `volumeMounts:` key).
*/}}
{{- define "cs.redisTLSCAVolumeMounts" -}}
{{- range $i, $ca := .Values.redis.tlsCA.existingSecrets }}
- name: redis-tls-ca-{{ $i }}
  mountPath: /etc/ssl/certs/redis-ca_{{ $i }}.crt
  subPath: {{ $ca.key | default "ca.crt" }}
  readOnly: true
{{- end }}
{{- end }}

