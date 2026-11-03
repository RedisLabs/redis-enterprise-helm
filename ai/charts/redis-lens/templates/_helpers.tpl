{{- define "redis-lens.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "redis-lens.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "redis-lens.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "redis-lens.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "redis-lens.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "redis-lens.selectorLabels" -}}
app.kubernetes.io/name: {{ include "redis-lens.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "redis-lens.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "redis-lens.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- required "serviceAccount.name is required when serviceAccount.create=false" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "redis-lens.dataplaneName" -}}
{{- printf "%s-dataplane" (include "redis-lens.fullname" . | trunc 53 | trimSuffix "-") -}}
{{- end -}}

{{- define "redis-lens.workerName" -}}
{{- printf "%s-worker" (include "redis-lens.fullname" . | trunc 56 | trimSuffix "-") -}}
{{- end -}}

{{- define "redis-lens.controlplaneName" -}}
{{- printf "%s-controlplane" (include "redis-lens.fullname" . | trunc 50 | trimSuffix "-") -}}
{{- end -}}

{{- define "redis-lens.controlplaneAdminTokenSecretName" -}}
{{- if .Values.controlplane.adminToken.existingSecret -}}
{{- .Values.controlplane.adminToken.existingSecret -}}
{{- else -}}
{{- printf "%s-admin-token" (include "redis-lens.controlplaneName" . | trunc 51 | trimSuffix "-") -}}
{{- end -}}
{{- end -}}

{{- define "redis-lens.controlplaneInternalTokenSecretName" -}}
{{- with (include "redis-lens.suite" . | fromJson).internalToken.existingSecret -}}
{{- . -}}
{{- else -}}
{{- printf "%s-internal-token" (include "redis-lens.controlplaneName" . | trunc 48 | trimSuffix "-") -}}
{{- end -}}
{{- end -}}

{{- /* "lens." under redis-iris, so failures name the umbrella path; else "". */ -}}
{{- define "redis-lens.at" -}}
{{- if include "redis-onprem.suite.enabled" . -}}lens.{{- end -}}
{{- end -}}

{{- /*
  Suite-wide settings, resolved once as JSON (redis-onprem.suite.*). Standalone they are the local
  values with the chart defaults. Under redis-iris (global.iris present) they come from global.iris,
  and a local value that differs fails, naming lens.<path>:
    tenantId, license {existingSecret, secretKey}, audience
    identityServiceBaseURL, allowInsecureTransport  the suite's in-cluster Identity Service
    credential     identityService.credential: the suite's lens-dp credential
    internalToken  controlplane.internalToken: the suite's lens token (suite: true, never generated)
    caCertSecret, imagePullSecrets, securityProfile  the local value, else global.*
    dataplaneOIDC  dataplane.oidc; from global.iris.auth when an issuer is set and the lens role
                   mappings are not empty: the access-token issuer, JWKS, role claims, the mappings
    controlplaneOIDC  controlplane.oidc.enabled; on with the derived dataplaneOIDC
  Lens reads stay read-only by construction (MOD-20312): ingest is agent-key only.
*/}}
{{- define "redis-lens.suite" -}}
{{- $p := "lens." -}}
{{- $v := .Values -}}
{{- $ids := $v.identityService -}}
{{- $dpo := $v.dataplane.oidc -}}
{{- $oidc := include "redis-onprem.suite.oidc" (dict "root" . "prefix" $p "local" (dict "audience" (trim (default "" $v.auth.oidc.audience))) "paths" (dict "audience" "auth.oidc.audience") "defaults" (dict "audience" "api://redis-iris")) | fromJson -}}
{{- $tenant := include "redis-onprem.suite.tenantId" (dict "root" . "prefix" $p "local" $v.tenantId) -}}
{{- $out := dict
  "tenantId" $tenant
  "license" (include "redis-onprem.suite.license" (dict "root" . "prefix" $p "local" $v.license "defaultSecretKey" "license") | fromJson)
  "audience" $oidc.audience
  "identityServiceBaseURL" (trim (default "" $v.dataplane.identityServiceBaseURL))
  "allowInsecureTransport" (not (not $ids.allowInsecureTransport))
  "credential" (dict "existingSecret" (default "" $ids.credential.existingSecret) "secretKey" $ids.credential.secretKey)
  "internalToken" (dict "existingSecret" (default "" $v.controlplane.internalToken.existingSecret) "secretKey" $v.controlplane.internalToken.secretKey "suite" false)
  "caCertSecret" (include "redis-onprem.suite.caCertSecret" .)
  "imagePullSecrets" (include "redis-onprem.suite.imagePullSecrets" . | fromJsonArray)
  "securityProfile" (include "redis-onprem.suite.securityProfile" .)
  "dataplaneOIDC" (dict "enabled" (not (not $dpo.enabled)) "issuer" (default "" $dpo.issuer) "jwksURI" (default "" $dpo.jwksURI) "tenantIDClaim" (default "" $dpo.tenantIDClaim) "roleClaims" (default (list) $dpo.roleClaims) "roleMappings" (default (dict) $dpo.roleMappings) "allowInsecureTransport" (not (not $dpo.allowInsecureTransport)))
  "controlplaneOIDC" (not (not $v.controlplane.oidc.enabled)) -}}
{{- if include "redis-onprem.suite.enabled" . -}}
{{- $suiteIds := include "redis-onprem.suite.identityService" (dict "root" .) | fromJson -}}
{{- $_ := set $out "identityServiceBaseURL" (include "redis-onprem.suite.owned" (dict "prefix" $p "path" "dataplane.identityServiceBaseURL" "local" $v.dataplane.identityServiceBaseURL "derived" $suiteIds.baseURL) | fromJson).value -}}
{{- $_ := set $out "allowInsecureTransport" (include "redis-onprem.suite.owned" (dict "prefix" $p "path" "identityService.allowInsecureTransport" "local" $ids.allowInsecureTransport "derived" $suiteIds.allowInsecureTransport) | fromJson).value -}}
{{- range $key, $c := dict "credential" (list "dataplane" "identityService.credential" $ids.credential) "internalToken" (list "controlplane" "controlplane.internalToken" $v.controlplane.internalToken) -}}
{{- $r := include "redis-onprem.suite.credential" (dict "root" $ "product" "lens" "credential" (index $c 0) "local" (index $c 2).existingSecret "field" (printf "%s%s.existingSecret" $p (index $c 1))) | fromJson -}}
{{- $_ := set $r "suite" true -}}
{{- $_ := set $out $key $r -}}
{{- end -}}
{{- $mappings := include "redis-onprem.suite.roleMappings" (dict "root" . "product" "lens") | fromJson -}}
{{- $derived := dict -}}
{{- if and $oidc.issuer $mappings -}}
{{- $derived = dict "enabled" true "issuer" $oidc.accessTokenIssuer "jwksURI" $oidc.jwksURI "tenantIDClaim" "" "roleClaims" $oidc.roleClaims "roleMappings" $mappings "allowInsecureTransport" $oidc.allowInsecureTransport -}}
{{- $_ := set $out "dataplaneOIDC" $derived -}}
{{- end -}}
{{- /* A boolean is compared whenever it is set; another field only when it is not empty. */ -}}
{{- range $f := list "enabled" "issuer" "jwksURI" "tenantIDClaim" "roleClaims" "roleMappings" "allowInsecureTransport" -}}
{{- $local := index $dpo $f -}}
{{- if or (kindIs "bool" $local) (not (empty $local)) -}}
{{- $_ := include "redis-onprem.suite.owned" (dict "prefix" $p "path" (printf "dataplane.oidc.%s" $f) "local" $local "derived" (index $derived $f)) -}}
{{- end -}}
{{- end -}}
{{- $_ := set $out "controlplaneOIDC" (include "redis-onprem.suite.owned" (dict "prefix" $p "path" "controlplane.oidc.enabled" "local" $v.controlplane.oidc.enabled "derived" (not (empty $derived))) | fromJson).value -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{- /*
  The Identity Service release this chart connects to and deploys none of. Only
  the data plane calls it, to introspect agent keys.
*/}}
{{- define "redis-lens.identityServiceBaseURL" -}}
{{- (include "redis-lens.suite" . | fromJson).identityServiceBaseURL -}}
{{- end -}}

{{- /*
  Falls back to global.tls.caCertSecret, so one value set on an umbrella chart
  reaches Lens and the Identity Service release alike. A local value wins.
*/}}
{{- define "redis-lens.tlsCaCertSecret" -}}
{{- include "redis-onprem.suite.caCertSecret" . -}}
{{- end -}}

{{- define "redis-lens.commonEnv" -}}
{{ include "redis-onprem.commonEnv" (dict "securityProfile" (include "redis-onprem.suite.securityProfile" .) "tlsCaCertSecret" (include "redis-lens.tlsCaCertSecret" .)) }}
{{- end -}}

{{- define "redis-lens.tlsCaMount" -}}
{{- if include "redis-lens.tlsCaCertSecret" . }}
- name: custom-ca
  mountPath: /etc/ssl/custom
  readOnly: true
{{- end }}
{{- end -}}

{{- define "redis-lens.tlsCaVolume" -}}
{{- with include "redis-lens.tlsCaCertSecret" . }}
- name: custom-ca
  secret:
    secretName: {{ . }}
{{- end }}
{{- end -}}

{{- define "redis-lens.tlsCaAnnotation" -}}
{{- if and (include "redis-lens.tlsCaCertSecret" .) .Values.tls.caCertSecretChecksum }}
checksum/tls-ca: {{ .Values.tls.caCertSecretChecksum | quote }}
{{- end }}
{{- end -}}

{{- define "redis-lens.licenseMount" -}}
- name: license
  mountPath: /etc/lens/license
  readOnly: true
{{- end -}}

{{- define "redis-lens.licenseVolume" -}}
{{- $license := (include "redis-lens.suite" . | fromJson).license -}}
- name: license
  secret:
    secretName: {{ required (printf "%slicense.existingSecret is required" (include "redis-lens.at" .)) $license.existingSecret }}
    items:
      - key: {{ $license.secretKey }}
        path: {{ $license.secretKey }}
{{- end -}}

{{- /*
The IdP token validation both planes share, rendered from dataplane.oidc so they cannot disagree on issuer,
tenant source or role mappings. With no tenant claim every token is the installation's single tenant.
*/}}
{{- define "redis-lens.oidcValidation" -}}
{{- $s := include "redis-lens.suite" . | fromJson -}}
{{- $oidc := $s.dataplaneOIDC -}}
enabled: true
issuer: {{ $oidc.issuer | quote }}
jwks_uri: {{ $oidc.jwksURI | quote }}
audience:
  {{- toYaml (list (trim $s.audience)) | nindent 2 }}
{{- with (trim $oidc.tenantIDClaim) }}
tenant_id_claim: {{ . | quote }}
{{- else }}
static_tenant_id: {{ $s.tenantId | quote }}
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
