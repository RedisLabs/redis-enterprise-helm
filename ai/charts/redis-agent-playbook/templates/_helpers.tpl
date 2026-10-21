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

{{- define "redis-agent-playbook.workerName" -}}
{{- printf "%s-worker" (include "redis-agent-playbook.fullname" . | trunc 56 | trimSuffix "-") -}}
{{- end -}}

{{- define "redis-agent-playbook.workerServiceAccountName" -}}
{{- if .Values.extraction.connection.enabled -}}
{{- include "redis-agent-playbook.workerName" . -}}
{{- else -}}
{{- include "redis-agent-playbook.serviceAccountName" . -}}
{{- end -}}

{{- end -}}

{{- define "redis-agent-playbook.workerSubject" -}}
{{- printf "system:serviceaccount:%s:%s" .Release.Namespace (include "redis-agent-playbook.workerServiceAccountName" .) -}}
{{- end -}}

{{- define "redis-agent-playbook.workerSourceURL" -}}
{{- required "worker.sourceURL is required" .Values.worker.sourceURL -}}
{{- end -}}

{{- define "redis-agent-playbook.controlplaneName" -}}
{{- printf "%s-controlplane" (include "redis-agent-playbook.fullname" . | trunc 50 | trimSuffix "-") -}}
{{- end -}}

{{- define "redis-agent-playbook.dataplaneName" -}}
{{- printf "%s-dataplane" (include "redis-agent-playbook.fullname" . | trunc 53 | trimSuffix "-") -}}
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

{{- /*
  global.* fallbacks, so one value set on an umbrella chart reaches Playbook and
  the Identity Service release alike. A local value wins.
*/}}
{{- define "redis-agent-playbook.securityProfile" -}}
{{- $global := default (dict) (default (dict) .Values.global).security -}}
{{- default (default "" $global.profile) (default (dict) .Values.security).profile -}}
{{- end -}}

{{- define "redis-agent-playbook.tlsCaCertSecret" -}}
{{- $global := default (dict) (default (dict) .Values.global).tls -}}
{{- default (default "" $global.caCertSecret) (default (dict) .Values.tls).caCertSecret -}}
{{- end -}}

{{- define "redis-agent-playbook.imagePullSecrets" -}}
{{- toJson (default (default (list) (default (dict) .Values.global).imagePullSecrets) .Values.imagePullSecrets) -}}
{{- end -}}

{{- /*
  The Identity Service release this chart connects to and deploys none of. The
  data plane introspects agent keys and looks up worker grants there; the
  extraction connection's Identity Service URLs default to it.
*/}}
{{- define "redis-agent-playbook.identityServiceBaseURL" -}}
{{- trim .Values.dataplane.identityServiceBaseURL -}}
{{- end -}}

{{- /* The Identity Service RAM uses for source grants; empty means the same release. */}}
{{- define "redis-agent-playbook.sourceIdentityServiceBaseURL" -}}
{{- default (include "redis-agent-playbook.identityServiceBaseURL" .) (trim .Values.extraction.connection.identityServiceBaseURL) -}}
{{- end -}}

{{- /* The control plane's Identity Service for destination grants; empty means the data plane's. */}}
{{- define "redis-agent-playbook.destinationIdentityServiceBaseURL" -}}
{{- default (include "redis-agent-playbook.identityServiceBaseURL" .) (trim .Values.extraction.connection.destinationIdentityServiceBaseURL) -}}
{{- end -}}

{{- /*
  OIDC validation settings shared by the data plane and the control plane. Each
  caller adds its own audience.
*/}}
{{- define "redis-agent-playbook.oidcValidation" -}}
enabled: true
issuer: {{ .Values.dataplane.oidc.issuer | quote }}
jwks_uri: {{ .Values.dataplane.oidc.jwksURI | quote }}
{{- with (trim .Values.dataplane.oidc.tenantIDClaim) }}
tenant_id_claim: {{ . | quote }}
{{- end }}
{{- with (trim .Values.dataplane.oidc.staticTenantID) }}
static_tenant_id: {{ . | quote }}
{{- end }}
{{- with .Values.dataplane.oidc.roleClaims }}
role_claims:
  {{- toYaml . | nindent 2 }}
{{- end }}
role_mappings:
  {{- toYaml .Values.dataplane.oidc.roleMappings | nindent 2 }}
allow_unmapped_roles: false
{{- if .Values.dataplane.oidc.allowInsecureTransport }}
allow_insecure_transport: true
{{- end }}
{{- end -}}

{{- define "redis-agent-playbook.extractionSubjects" -}}
{{- $subjects := .Values.extraction.connection.workerSubjects -}}
{{- if .Values.worker.enabled -}}
{{- $subjects = append $subjects (include "redis-agent-playbook.workerSubject" .) -}}
{{- end -}}
{{- uniq $subjects | toYaml -}}
{{- end -}}

{{- /*
  With a connection, the control plane gets its own ServiceAccount: the
  Identity Services trust its subject as subject_grant_admin, so the data plane
  must not share it.
*/}}
{{- define "redis-agent-playbook.controlplaneServiceAccountName" -}}
{{- if .Values.extraction.connection.enabled -}}
{{- include "redis-agent-playbook.controlplaneName" . -}}
{{- else -}}
{{- include "redis-agent-playbook.serviceAccountName" . -}}
{{- end -}}
{{- end -}}

{{- define "redis-agent-playbook.commonEnv" -}}
{{ include "redis-onprem.commonEnv" (dict "securityProfile" (include "redis-agent-playbook.securityProfile" .) "tlsCaCertSecret" (include "redis-agent-playbook.tlsCaCertSecret" .)) }}
{{- end -}}

{{- define "redis-agent-playbook.commonTLSMount" -}}
{{- if include "redis-agent-playbook.tlsCaCertSecret" . }}
- name: custom-ca
  mountPath: /etc/ssl/custom
  readOnly: true
{{- end }}
{{- end -}}

{{- define "redis-agent-playbook.commonTLSVolume" -}}
{{- with include "redis-agent-playbook.tlsCaCertSecret" . }}
- name: custom-ca
  secret:
    secretName: {{ . }}
{{- end }}
{{- end -}}
