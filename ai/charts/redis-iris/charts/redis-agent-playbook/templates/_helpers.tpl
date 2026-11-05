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
{{- if (include "redis-agent-playbook.suite" . | fromJson).extraction.connection.enabled -}}
{{- include "redis-agent-playbook.workerName" . -}}
{{- else -}}
{{- include "redis-agent-playbook.serviceAccountName" . -}}
{{- end -}}

{{- end -}}

{{- define "redis-agent-playbook.workerSubject" -}}
{{- printf "system:serviceaccount:%s:%s" .Release.Namespace (include "redis-agent-playbook.workerServiceAccountName" .) -}}
{{- end -}}

{{- define "redis-agent-playbook.workerSourceURL" -}}
{{- required "worker.sourceURL is required" (include "redis-agent-playbook.suite" . | fromJson).worker.sourceURL -}}
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
{{- $suite := include "redis-agent-playbook.suiteCredential" (dict "root" . "credential" "controlplane") | fromJson -}}
{{- if $suite.secret -}}
{{- $suite.secret -}}
{{- else if .Values.controlplane.internalToken.existingSecret -}}
{{- .Values.controlplane.internalToken.existingSecret -}}
{{- else -}}
{{- printf "%s-internal-token" (include "redis-agent-playbook.controlplaneName" . | trunc 48 | trimSuffix "-") -}}
{{- end -}}
{{- end -}}

{{/* "true" when the chart generates the internal-token Secret: no suite aggregate, no existingSecret, autoGenerate. */}}
{{- define "redis-agent-playbook.controlplaneInternalTokenGenerated" -}}
{{- $suite := include "redis-agent-playbook.suiteCredential" (dict "root" . "credential" "controlplane") | fromJson -}}
{{- if and (not $suite.secret) (not .Values.controlplane.internalToken.existingSecret) .Values.controlplane.internalToken.autoGenerate -}}true{{- end -}}
{{- end -}}

{{/* The key of the internal token in that Secret. */}}
{{- define "redis-agent-playbook.controlplaneInternalTokenSecretKey" -}}
{{- $suite := include "redis-agent-playbook.suiteCredential" (dict "root" . "credential" "controlplane") | fromJson -}}
{{- default .Values.controlplane.internalToken.secretKey $suite.key -}}
{{- end -}}

{{/*
The Secret/key the data plane presents to the Identity Service release, as JSON
{secret, key}, from identityService.credential, or from the redis-iris suite
(redis-agent-playbook.suiteCredential).
*/}}
{{- define "redis-agent-playbook.dpCredential" -}}
{{- $credential := .Values.identityService.credential -}}
{{- $suite := include "redis-agent-playbook.suiteCredential" (dict "root" . "credential" "dataplane") | fromJson -}}
{{- toJson (dict "secret" (default (default "" $credential.existingSecret) $suite.secret) "key" (default $credential.secretKey $suite.key)) -}}
{{- end -}}

{{- define "redis-agent-playbook.suiteCredential" -}}
{{- $local := index (dict
  "dataplane" (dict "field" "identityService.credential.existingSecret" "local" .root.Values.identityService.credential.existingSecret)
  "controlplane" (dict "field" "controlplane.internalToken.existingSecret" "local" .root.Values.controlplane.internalToken.existingSecret)) .credential -}}
{{- $c := include "redis-onprem.suite.credential" (dict "root" .root "product" "playbook" "credential" .credential "local" $local.local "field" $local.field) | fromJson -}}
{{- if $c -}}{{- toJson (dict "secret" $c.existingSecret "key" $c.secretKey) -}}{{- else -}}{}{{- end -}}
{{- end -}}

{{- /*
  Suite-wide settings, resolved once as JSON (redis-onprem.suite.*). Standalone they are the local
  values with the chart defaults. Under redis-iris (global.iris present) they come from global.iris,
  and a local value that differs fails, naming playbook.<path>:
    tenantId, license {existingSecret, secretKey}, audience
    identityServiceBaseURL, allowInsecureTransport  the suite's in-cluster Identity Service
    dataplaneOIDC     dataplane.oidc; from global.iris.auth when an issuer is set: the access-token
                      issuer, staticTenantID = tenantId, roleMappings for playbook plus suite scope
    controlplaneOIDC  controlplane.oidc; enabled when the derived roleMappings are not empty
    extraction, worker  .Values.extraction and .Values.worker with their null booleans false; with
                      global.iris.extraction.enabled and Memory enabled, the connection to the
                      suite's Memory: the enabled flags, the workload-identity issuer and JWKS, and
                      the Memory control-plane and data-plane URLs
*/}}
{{- define "redis-agent-playbook.suite" -}}
{{- $p := "playbook." -}}
{{- $ids := default (dict) .Values.identityService -}}
{{- $dpo := default (dict) .Values.dataplane.oidc -}}
{{- $cpo := deepCopy (default (dict) .Values.controlplane.oidc) -}}
{{- $oidc := include "redis-onprem.suite.oidc" (dict "root" . "prefix" $p "local" (dict "audience" (dig "oidc" "audience" "" (default (dict) .Values.auth))) "paths" (dict "audience" "auth.oidc.audience") "defaults" (dict "audience" "api://redis-iris")) | fromJson -}}
{{- $tenant := include "redis-onprem.suite.tenantId" (dict "root" . "prefix" $p "local" .Values.tenantId) -}}
{{- $dataplaneOIDC := dict "enabled" (not (not $dpo.enabled)) "issuer" (default "" $dpo.issuer) "jwksURI" (default "" $dpo.jwksURI) "tenantIDClaim" (default "" $dpo.tenantIDClaim) "staticTenantID" (default "" $dpo.staticTenantID) "roleClaims" (default (list) $dpo.roleClaims) "roleMappings" (default (dict) $dpo.roleMappings) "allowInsecureTransport" (not (not $dpo.allowInsecureTransport)) -}}
{{- $_ := set $cpo "enabled" (not (not $cpo.enabled)) -}}
{{- $out := dict
  "tenantId" $tenant
  "license" (include "redis-onprem.suite.license" (dict "root" . "prefix" $p "local" .Values.license "defaultSecretKey" "license") | fromJson)
  "audience" $oidc.audience
  "identityServiceBaseURL" (trim (default "" .Values.dataplane.identityServiceBaseURL))
  "allowInsecureTransport" (not (not $ids.allowInsecureTransport))
  "dataplaneOIDC" $dataplaneOIDC
  "controlplaneOIDC" $cpo -}}
{{- $extraction := deepCopy .Values.extraction -}}
{{- $connection := $extraction.connection -}}
{{- $worker := deepCopy .Values.worker -}}
{{- $_ := set $extraction "enabled" (not (not $extraction.enabled)) -}}
{{- $_ := set $connection "enabled" (not (not $connection.enabled)) -}}
{{- $_ := set $connection "allowInsecureTransport" (not (not $connection.allowInsecureTransport)) -}}
{{- $_ := set $worker "enabled" (not (not $worker.enabled)) -}}
{{- if include "redis-onprem.suite.enabled" . -}}
{{- $suiteIds := include "redis-onprem.suite.identityService" (dict "root" .) | fromJson -}}
{{- $_ := set $out "identityServiceBaseURL" (include "redis-onprem.suite.owned" (dict "prefix" $p "path" "dataplane.identityServiceBaseURL" "local" .Values.dataplane.identityServiceBaseURL "derived" $suiteIds.baseURL) | fromJson).value -}}
{{- $_ := set $out "allowInsecureTransport" (include "redis-onprem.suite.owned" (dict "prefix" $p "path" "identityService.allowInsecureTransport" "local" $ids.allowInsecureTransport "derived" $suiteIds.allowInsecureTransport) | fromJson).value -}}
{{- $derived := dict -}}
{{- if $oidc.issuer -}}
{{- $derived = dict "enabled" true "issuer" $oidc.accessTokenIssuer "jwksURI" $oidc.jwksURI "tenantIDClaim" "" "staticTenantID" $tenant "roleClaims" $oidc.roleClaims "roleMappings" (include "redis-onprem.suite.roleMappings" (dict "root" . "product" "playbook") | fromJson) "allowInsecureTransport" $oidc.allowInsecureTransport -}}
{{- $_ := set $out "dataplaneOIDC" $derived -}}
{{- end -}}
{{- range $field := list "enabled" "issuer" "jwksURI" "tenantIDClaim" "staticTenantID" "roleClaims" "roleMappings" "allowInsecureTransport" -}}
{{- $_ := include "redis-onprem.suite.owned" (dict "prefix" $p "path" (printf "dataplane.oidc.%s" $field) "local" (index $dpo $field) "derived" (index $derived $field)) -}}
{{- end -}}
{{- $cpEnabled := and $oidc.issuer (not (empty $derived.roleMappings)) -}}
{{- $_ := set $cpo "enabled" (include "redis-onprem.suite.owned" (dict "prefix" $p "path" "controlplane.oidc.enabled" "local" (default (dict) .Values.controlplane.oidc).enabled "derived" (not (not $cpEnabled))) | fromJson).value -}}
{{- if and (eq (toString (dig "extraction" "enabled" false (include "redis-onprem.suite.iris" . | fromJson))) "true") (include "redis-onprem.suite.productEnabled" (dict "root" . "product" "memory")) -}}
{{- $wi := include "redis-onprem.suite.workloadIdentity" (dict "root" .) | fromJson -}}
{{- $ramCP := printf "http://%s:9100" (include "redis-onprem.suite.fqdn" (dict "root" . "name" "redis-agent-memory-controlplane")) -}}
{{- $lc := .Values.extraction.connection -}}
{{- /* path: (resolved map, key, unnormalized local value, derived value); a null local is unset, an explicit false conflicts. */ -}}
{{- $derived := dict
  "extraction.enabled" (list $extraction "enabled" .Values.extraction.enabled true)
  "extraction.connection.enabled" (list $connection "enabled" $lc.enabled true)
  "extraction.connection.issuer" (list $connection "issuer" $lc.issuer $wi.issuer)
  "extraction.connection.jwksURI" (list $connection "jwksURI" $lc.jwksURI $wi.jwksURI)
  "extraction.connection.ramControlPlaneBaseURL" (list $connection "ramControlPlaneBaseURL" $lc.ramControlPlaneBaseURL $ramCP)
  "extraction.connection.allowInsecureTransport" (list $connection "allowInsecureTransport" $lc.allowInsecureTransport (and (hasPrefix "http://" $ramCP) (ne (include "redis-agent-playbook.securityProfile" .) "fips")))
  "worker.enabled" (list $worker "enabled" .Values.worker.enabled true)
  "worker.sourceURL" (list $worker "sourceURL" .Values.worker.sourceURL (printf "http://%s:9000" (include "redis-onprem.suite.fqdn" (dict "root" . "name" "redis-agent-memory")))) -}}
{{- range $path, $d := $derived -}}
{{- $_ := set (index $d 0) (index $d 1) (include "redis-onprem.suite.owned" (dict "prefix" $p "path" $path "local" (index $d 2) "derived" (index $d 3)) | fromJson).value -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $_ := set $out "extraction" $extraction -}}
{{- $_ := set $out "worker" $worker -}}
{{- toJson $out -}}
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

{{- define "redis-agent-playbook.securityProfile" -}}
{{- include "redis-onprem.suite.securityProfile" . -}}
{{- end -}}

{{- define "redis-agent-playbook.tlsCaCertSecret" -}}
{{- include "redis-onprem.suite.caCertSecret" . -}}
{{- end -}}

{{- define "redis-agent-playbook.imagePullSecrets" -}}
{{- include "redis-onprem.suite.imagePullSecrets" . -}}
{{- end -}}

{{- /*
  The Identity Service release this chart connects to and deploys none of. The
  data plane introspects customer agent keys and ordinary service subjects there.
*/}}
{{- define "redis-agent-playbook.identityServiceBaseURL" -}}
{{- (include "redis-agent-playbook.suite" . | fromJson).identityServiceBaseURL -}}
{{- end -}}

{{- /*
  OIDC validation settings shared by the data plane and the control plane. Each
  caller adds its own audience.
*/}}
{{- define "redis-agent-playbook.oidcValidation" -}}
{{- $oidc := (include "redis-agent-playbook.suite" . | fromJson).dataplaneOIDC -}}
enabled: true
issuer: {{ $oidc.issuer | quote }}
jwks_uri: {{ $oidc.jwksURI | quote }}
{{- with (trim $oidc.tenantIDClaim) }}
tenant_id_claim: {{ . | quote }}
{{- end }}
{{- with (trim $oidc.staticTenantID) }}
static_tenant_id: {{ . | quote }}
{{- end }}
{{- with $oidc.roleClaims }}
role_claims:
  {{- toYaml . | nindent 2 }}
{{- end }}
role_mappings:
  {{- toYaml $oidc.roleMappings | nindent 2 }}
allow_unmapped_roles: false
{{- if $oidc.allowInsecureTransport }}
allow_insecure_transport: true
{{- end }}
{{- end -}}

{{- /* RAM CP trusts this dedicated ServiceAccount as a tenant-confined viewer. */}}
{{- define "redis-agent-playbook.controlplaneServiceAccountName" -}}
{{- if (include "redis-agent-playbook.suite" . | fromJson).extraction.connection.enabled -}}
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
