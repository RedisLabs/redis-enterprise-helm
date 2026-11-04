{{- define "redis-intent-router.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "redis-intent-router.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "redis-intent-router.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "redis-intent-router.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "redis-intent-router.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "redis-intent-router.selectorLabels" -}}
app.kubernetes.io/name: {{ include "redis-intent-router.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "redis-intent-router.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "redis-intent-router.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- required "serviceAccount.name is required when serviceAccount.create=false" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "redis-intent-router.controlplaneName" -}}
{{- printf "%s-controlplane" (include "redis-intent-router.fullname" . | trunc 50 | trimSuffix "-") -}}
{{- end -}}

{{- define "redis-intent-router.dataplaneName" -}}
{{- printf "%s-dataplane" (include "redis-intent-router.fullname" . | trunc 53 | trimSuffix "-") -}}
{{- end -}}

{{- /*
  Credential Secret names. A BYO existingSecret wins; otherwise the chart owns a
  Secret named for the workload and the credential.
*/ -}}
{{- define "redis-intent-router.controlplaneAdminTokenSecretName" -}}
{{- default (printf "%s-admin-token" (include "redis-intent-router.controlplaneName" . | trunc 51 | trimSuffix "-")) .Values.controlplane.adminToken.existingSecret -}}
{{- end -}}

{{- define "redis-intent-router.controlplaneInternalTokenSecretName" -}}
{{- default (printf "%s-internal-token" (include "redis-intent-router.controlplaneName" . | trunc 48 | trimSuffix "-")) (include "redis-intent-router.suite" . | fromJson).internalToken.existingSecret -}}
{{- end -}}

{{- define "redis-intent-router.testServiceAccountName" -}}
{{- printf "%s-test" (include "redis-intent-router.fullname" . | trunc 58 | trimSuffix "-") -}}
{{- end -}}

{{- define "redis-intent-router.testRBACName" -}}
{{- include "redis-intent-router.fullname" . | trunc 51 | trimSuffix "-" -}}
{{- end -}}

{{- define "redis-intent-router.controlplaneSecurityTestName" -}}
{{- printf "%s-controlplane" (include "redis-intent-router.fullname" . | trunc 28 | trimSuffix "-") -}}
{{- end -}}

{{- define "redis-intent-router.dataplaneSecurityTestName" -}}
{{- printf "%s-dataplane" (include "redis-intent-router.fullname" . | trunc 31 | trimSuffix "-") -}}
{{- end -}}

{{- /*
  The liveness probe of both planes, shared by the Deployments and the startupBudget
  guard in validation.yaml, so the guard cannot drift from the probe it protects. Each
  plane converges its Routers before it listens (the data plane within startupBudget, the
  control plane within reconcile.startup_budget, 20s by default), so the kubelet must not
  probe, and restart after three failures, before that pass can have ended.
*/}}
{{- define "redis-intent-router.liveness" -}}
{{- dict "initialDelaySeconds" 30 "periodSeconds" 10 "failureThreshold" 3 | toJson -}}
{{- end -}}

{{- /*
  global.* fallbacks, so one value set on an umbrella chart reaches Intent and
  the Identity Service release alike. A local value wins.
*/}}
{{- define "redis-intent-router.securityProfile" -}}
{{- include "redis-onprem.suite.securityProfile" . -}}
{{- end -}}

{{- define "redis-intent-router.tlsCaCertSecret" -}}
{{- include "redis-onprem.suite.caCertSecret" . -}}
{{- end -}}

{{- define "redis-intent-router.imagePullSecrets" -}}
{{- include "redis-onprem.suite.imagePullSecrets" . -}}
{{- end -}}

{{- /* "intent." under redis-iris, so failures name the umbrella path; else "". */ -}}
{{- define "redis-intent-router.at" -}}
{{- if include "redis-onprem.suite.enabled" . -}}intent.{{- end -}}
{{- end -}}

{{- /*
  Suite-wide settings, resolved once as JSON (redis-onprem.suite.*). Standalone they are the local
  values with the chart defaults. Under redis-iris (global.iris present) they come from global.iris,
  and a local value that differs fails, naming intent.<path>:
    tenantId, license {existingSecret, secretKey}, audience
    identityServiceBaseURL, allowInsecureTransport  the suite's in-cluster Identity Service
    credential     identityService.credential: the suite's intent-dp credential
    internalToken  controlplane.internalToken: the suite's intent token (suite: true, never generated)
    dataplaneOIDC  dataplane.oidc; from global.iris.auth when an issuer is set and the intent role
                   mappings are not empty: the access-token issuer, JWKS, role claims, the mappings,
                   and the suite tenant as staticTenantID
    controlplaneOIDC  controlplane.oidc.enabled; on with the derived dataplaneOIDC
  Standalone, dataplaneOIDC keeps the shape of dataplane.oidc, so the config checksums do not move.
*/}}
{{- define "redis-intent-router.suite" -}}
{{- $p := "intent." -}}
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
  "dataplaneOIDC" (dict "enabled" (not (not $dpo.enabled)) "issuer" (default "" $dpo.issuer) "jwksURI" (default "" $dpo.jwksURI) "tenantIDClaim" (default "" $dpo.tenantIDClaim) "staticTenantID" (default "" $dpo.staticTenantID) "roleClaims" (default (list) $dpo.roleClaims) "roleMappings" (default (dict) $dpo.roleMappings) "allowInsecureTransport" (not (not $dpo.allowInsecureTransport)))
  "controlplaneOIDC" (not (not $v.controlplane.oidc.enabled)) -}}
{{- if include "redis-onprem.suite.enabled" . -}}
{{- $suiteIds := include "redis-onprem.suite.identityService" (dict "root" .) | fromJson -}}
{{- $_ := set $out "identityServiceBaseURL" (include "redis-onprem.suite.owned" (dict "prefix" $p "path" "dataplane.identityServiceBaseURL" "local" $v.dataplane.identityServiceBaseURL "derived" $suiteIds.baseURL) | fromJson).value -}}
{{- $_ := set $out "allowInsecureTransport" (include "redis-onprem.suite.owned" (dict "prefix" $p "path" "identityService.allowInsecureTransport" "local" $ids.allowInsecureTransport "derived" $suiteIds.allowInsecureTransport) | fromJson).value -}}
{{- range $key, $c := dict "credential" (list "dataplane" "identityService.credential" $ids.credential) "internalToken" (list "controlplane" "controlplane.internalToken" $v.controlplane.internalToken) -}}
{{- $r := include "redis-onprem.suite.credential" (dict "root" $ "product" "intent" "credential" (index $c 0) "local" (index $c 2).existingSecret "field" (printf "%s%s.existingSecret" $p (index $c 1))) | fromJson -}}
{{- $_ := set $r "suite" true -}}
{{- $_ := set $out $key $r -}}
{{- end -}}
{{- $mappings := include "redis-onprem.suite.roleMappings" (dict "root" . "product" "intent") | fromJson -}}
{{- $derived := dict -}}
{{- if and $oidc.issuer $mappings -}}
{{- $derived = dict "enabled" true "issuer" $oidc.accessTokenIssuer "jwksURI" $oidc.jwksURI "tenantIDClaim" "" "staticTenantID" $tenant "roleClaims" $oidc.roleClaims "roleMappings" $mappings "allowInsecureTransport" $oidc.allowInsecureTransport -}}
{{- $_ := set $out "dataplaneOIDC" $derived -}}
{{- end -}}
{{- /* A boolean is compared whenever it is set; another field only when it is not empty. */ -}}
{{- range $f := list "enabled" "issuer" "jwksURI" "tenantIDClaim" "staticTenantID" "roleClaims" "roleMappings" "allowInsecureTransport" -}}
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
  The Identity Service release this chart connects to and deploys none of. The
  data plane introspects agent keys there.
*/}}
{{- define "redis-intent-router.identityServiceBaseURL" -}}
{{- (include "redis-intent-router.suite" . | fromJson).identityServiceBaseURL -}}
{{- end -}}

{{- define "redis-intent-router.commonEnv" -}}
{{ include "redis-onprem.commonEnv" (dict "securityProfile" (include "redis-intent-router.securityProfile" .) "tlsCaCertSecret" (include "redis-intent-router.tlsCaCertSecret" .)) }}
{{- end -}}

{{- define "redis-intent-router.commonTLSMount" -}}
{{- if include "redis-intent-router.tlsCaCertSecret" . }}
- name: custom-ca
  mountPath: /etc/ssl/custom
  readOnly: true
{{- end }}
{{- end -}}

{{- define "redis-intent-router.commonTLSVolume" -}}
{{- with include "redis-intent-router.tlsCaCertSecret" . }}
- name: custom-ca
  secret:
    secretName: {{ . }}
{{- end }}
{{- end -}}

{{- /*
  OIDC validation settings shared by the data plane and the control plane. Each
  caller adds the audience. Operators sign in to the console through the IdP and
  the same access token reaches both planes; only explicitly mapped roles count.
*/}}
{{- define "redis-intent-router.oidcValidation" -}}
{{- $s := include "redis-intent-router.suite" . | fromJson -}}
{{- $oidc := $s.dataplaneOIDC -}}
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
audience:
  {{- toYaml (list (trim $s.audience)) | nindent 2 }}
{{- end -}}
