{{- define "redis-agent-playbook.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "redis-agent-playbook.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "redis-agent-playbook.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "redis-agent-playbook.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "redis-agent-playbook.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "redis-agent-playbook.selectorLabels" -}}
app.kubernetes.io/name: {{ include "redis-agent-playbook.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "redis-agent-playbook.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "redis-agent-playbook.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- required "serviceAccount.name is required when serviceAccount.create=false" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "redis-agent-playbook.controlplaneName" -}}
{{- printf "%s-controlplane" (include "redis-agent-playbook.fullname" . | trunc 50 | trimSuffix "-") -}}
{{- end -}}

{{- define "redis-agent-playbook.dataplaneName" -}}
{{- printf "%s-dataplane" (include "redis-agent-playbook.fullname" . | trunc 53 | trimSuffix "-") -}}
{{- end -}}

{{- define "redis-agent-playbook.identityServiceName" -}}
{{- printf "%s-identity-service" (include "redis-agent-playbook.fullname" . | trunc 46 | trimSuffix "-") -}}
{{- end -}}

{{- define "redis-agent-playbook.controlplaneAdminTokenSecretName" -}}
{{- if .Values.controlplane.adminToken.existingSecret -}}
{{- .Values.controlplane.adminToken.existingSecret -}}
{{- else -}}
{{- printf "%s-admin-token" (include "redis-agent-playbook.controlplaneName" . | trunc 51 | trimSuffix "-") -}}
{{- end -}}
{{- end -}}

{{- define "redis-agent-playbook.controlplaneInternalTokenSecretName" -}}
{{- if .Values.controlplane.internalToken.existingSecret -}}
{{- .Values.controlplane.internalToken.existingSecret -}}
{{- else -}}
{{- printf "%s-internal-token" (include "redis-agent-playbook.controlplaneName" . | trunc 48 | trimSuffix "-") -}}
{{- end -}}
{{- end -}}

{{- define "redis-agent-playbook.identityServiceControlTokenSecretName" -}}
{{- if .Values.identityService.controlToken.existingSecret -}}
{{- .Values.identityService.controlToken.existingSecret -}}
{{- else -}}
{{- printf "%s-control-token" (include "redis-agent-playbook.identityServiceName" . | trunc 49 | trimSuffix "-") -}}
{{- end -}}
{{- end -}}

{{- define "redis-agent-playbook.identityServiceRuntimeTokenSecretName" -}}
{{- if .Values.identityService.runtimeToken.existingSecret -}}
{{- .Values.identityService.runtimeToken.existingSecret -}}
{{- else -}}
{{- printf "%s-runtime-token" (include "redis-agent-playbook.identityServiceName" . | trunc 49 | trimSuffix "-") -}}
{{- end -}}
{{- end -}}

{{- define "redis-agent-playbook.testServiceAccountName" -}}
{{- printf "%s-test" (include "redis-agent-playbook.fullname" . | trunc 58 | trimSuffix "-") -}}
{{- end -}}

{{- define "redis-agent-playbook.testRBACName" -}}
{{- include "redis-agent-playbook.fullname" . | trunc 51 | trimSuffix "-" -}}
{{- end -}}

{{- define "redis-agent-playbook.controlplaneSecurityTestName" -}}
{{- printf "%s-controlplane" (include "redis-agent-playbook.fullname" . | trunc 28 | trimSuffix "-") -}}
{{- end -}}

{{- define "redis-agent-playbook.dataplaneSecurityTestName" -}}
{{- printf "%s-dataplane" (include "redis-agent-playbook.fullname" . | trunc 31 | trimSuffix "-") -}}
{{- end -}}

{{- define "redis-agent-playbook.identityServiceSecurityTestName" -}}
{{- printf "%s-identity-service" (include "redis-agent-playbook.fullname" . | trunc 24 | trimSuffix "-") -}}
{{- end -}}

{{- define "redis-agent-playbook.identityServiceBaseURL" -}}
{{- $configured := trim .Values.dataplane.identityServiceBaseURL -}}
{{- if $configured -}}
{{- if and (eq .Values.security.profile "fips") (not (hasPrefix "https://" $configured)) -}}
{{- fail "security.profile=fips requires dataplane.identityServiceBaseURL to use https://" -}}
{{- end -}}

{{- $configured -}}
{{- else -}}
{{- if eq .Values.security.profile "fips" -}}
{{- fail "security.profile=fips requires an explicit HTTPS dataplane.identityServiceBaseURL" -}}
{{- end -}}
{{- printf "http://%s:%v" (include "redis-agent-playbook.identityServiceName" .) .Values.identityService.service.port -}}
{{- end -}}
{{- end -}}

{{- define "redis-agent-playbook.delegatedAuthOptions" -}}
{{- dict
  "values" .Values.controlplane.delegatedAuth
  "product" "playbook"
  "subject" "playbook-controlplane"
  "baseURL" (include "redis-agent-playbook.identityServiceBaseURL" .)
  "defaultSecretName" (printf "%s-auth-introspect" (include "redis-agent-playbook.controlplaneName" . | trunc 47 | trimSuffix "-"))
  "labelsTemplate" "redis-agent-playbook.labels"
  "external" false
  "reservedSecretRefs" (list
    (printf "%s/%s" (include "redis-agent-playbook.controlplaneAdminTokenSecretName" .) .Values.controlplane.adminToken.secretKey)
    (printf "%s/%s" (include "redis-agent-playbook.controlplaneInternalTokenSecretName" .) .Values.controlplane.internalToken.secretKey)
    (printf "%s/%s" (include "redis-agent-playbook.identityServiceControlTokenSecretName" .) .Values.identityService.controlToken.secretKey)
    (printf "%s/%s" (include "redis-agent-playbook.identityServiceRuntimeTokenSecretName" .) .Values.identityService.runtimeToken.secretKey))
  | toJson -}}
{{- end -}}

{{- define "redis-agent-playbook.controlplaneBaseURL" -}}
{{- $configured := trim .Values.identityService.playbookControlPlaneBaseURL -}}
{{- if $configured -}}
{{- if and (eq .Values.security.profile "fips") (not (hasPrefix "https://" $configured)) -}}
{{- fail "security.profile=fips requires identityService.playbookControlPlaneBaseURL to use https://" -}}
{{- end -}}
{{- $configured -}}
{{- else -}}
{{- if eq .Values.security.profile "fips" -}}
{{- fail "security.profile=fips requires an explicit HTTPS identityService.playbookControlPlaneBaseURL" -}}
{{- end -}}
{{- printf "http://%s:%v" (include "redis-agent-playbook.controlplaneName" .) .Values.controlplane.service.port -}}
{{- end -}}
{{- end -}}

{{- define "redis-agent-playbook.commonEnv" -}}
{{ include "redis-onprem.commonEnv" (dict "securityProfile" .Values.security.profile "tlsCaCertSecret" .Values.tls.caCertSecret) }}
{{- end -}}

{{- define "redis-agent-playbook.commonTLSMount" -}}
{{- if .Values.tls.caCertSecret }}
- name: custom-ca
  mountPath: /etc/ssl/custom
  readOnly: true
{{- end }}
{{- end -}}

{{- define "redis-agent-playbook.commonTLSVolume" -}}
{{- if .Values.tls.caCertSecret }}
- name: custom-ca
  secret:
    secretName: {{ .Values.tls.caCertSecret }}
{{- end }}
{{- end -}}
