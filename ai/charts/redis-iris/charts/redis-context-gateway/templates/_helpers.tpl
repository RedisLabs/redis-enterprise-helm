{{- define "gateway.fullname" -}}
{{- default (printf "%s-%s" .Release.Name .Chart.Name) .Values.fullnameOverride | trunc 48 | trimSuffix "-" -}}
{{- end -}}

{{- define "gateway.labels" -}}
app.kubernetes.io/name: redis-context-gateway
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end -}}

{{- /* gateway.labels for library helpers that pass the chart root. */ -}}
{{- define "gateway.rootLabels" -}}
{{- include "gateway.labels" (dict "root" .) }}
app.kubernetes.io/component: dataplane
{{- end -}}

{{- /* "contextGateway." under redis-iris, so failures name the umbrella path; else "". */ -}}
{{- define "gateway.at" -}}
{{- if include "redis-onprem.suite.enabled" . -}}contextGateway.{{- end -}}
{{- end -}}

{{- /*
  Suite-wide settings, resolved once as JSON (redis-onprem.suite.*). Standalone they are the local
  values. Under redis-iris (global.iris present) they come from global.iris, and a local value that
  differs fails, naming contextGateway.<path>:
    tenantId, license                  the suite tenant and license Secret
    identityService                    {baseURL, allowInsecureTransport}: the suite's Identity Service
    runtimeToken, internalToken        the suite credentials context-gateway-dp and context-gateway,
                                       Kubernetes Secrets only (a CSI class fails)
    caBundle                           tls.caBundle, else global.tls.caCertSecret (key ca.crt)
    imagePullSecrets, securityProfile  the local value, else global.*
    controlplaneOIDC                   controlplane.config.auth.oidc, derived from global.iris.auth.oidc
                                       when an issuer is set (operator sign-in through the UI)
  MCP caller sign-in (dataplane.config.auth.oidc, oauth) stays operator-owned.
*/}}
{{- define "gateway.suite" -}}
{{- $p := "contextGateway." -}}
{{- $v := .Values -}}
{{- $ids := $v.identityService -}}
{{- $license := deepCopy $v.license -}}
{{- /* The former default, kept even for CSI so the file-reference checksum is unchanged. */ -}}
{{- $_ := set $license "secretKey" (default "license" $license.secretKey) -}}
{{- $ca := $v.tls.caBundle -}}
{{- $globalCA := include "redis-onprem.suite.caCertSecret" . -}}
{{- if and (not $ca.existingSecret) (not $ca.secretProviderClass) $globalCA -}}
{{- $ca = dict "existingSecret" $globalCA "secretKey" "ca.crt" -}}
{{- end -}}
{{- $out := dict
  "tenantId" $v.tenantId
  "license" $license
  "identityService" (dict "baseURL" $ids.baseURL "allowInsecureTransport" (not (not $ids.allowInsecureTransport)))
  "runtimeToken" $v.dataplane.runtimeToken
  "internalToken" $v.controlplane.internalToken
  "caBundle" $ca
  "imagePullSecrets" (include "redis-onprem.suite.imagePullSecrets" . | fromJsonArray)
  "securityProfile" (include "redis-onprem.suite.securityProfile" .) -}}
{{- if include "redis-onprem.suite.enabled" . -}}
{{- $_ := set $out "tenantId" (include "redis-onprem.suite.tenantId" (dict "root" . "prefix" $p "local" $v.tenantId)) -}}
{{- include "gateway.secretOnly" (dict "path" (printf "%slicense" $p) "reference" $v.license) -}}
{{- $_ := set $out "license" (include "redis-onprem.suite.license" (dict "root" . "prefix" $p "local" $v.license) | fromJson) -}}
{{- $suiteIds := include "redis-onprem.suite.identityService" (dict "root" .) | fromJson -}}
{{- $_ := set $out "identityService" (dict
  "baseURL" (include "redis-onprem.suite.owned" (dict "prefix" $p "path" "identityService.baseURL" "local" $ids.baseURL "derived" $suiteIds.baseURL) | fromJson).value
  "allowInsecureTransport" (include "redis-onprem.suite.owned" (dict "prefix" $p "path" "identityService.allowInsecureTransport" "local" $ids.allowInsecureTransport "derived" $suiteIds.allowInsecureTransport) | fromJson).value) -}}
{{- range $key, $c := dict "runtimeToken" (list "dataplane" "dataplane.runtimeToken") "internalToken" (list "controlplane" "controlplane.internalToken") -}}
{{- $path := printf "%s%s" $p (index $c 1) -}}
{{- $local := index (index $v (index $c 0)) $key -}}
{{- include "gateway.secretOnly" (dict "path" $path "reference" $local) -}}
{{- $_ := set $out $key (include "redis-onprem.suite.credential" (dict "root" $ "product" "context-gateway" "credential" (index $c 0) "local" $local.existingSecret "field" (printf "%s.existingSecret" $path)) | fromJson) -}}
{{- end -}}
{{- $oidc := include "redis-onprem.suite.oidc" (dict "root" . "prefix" $p) | fromJson -}}
{{- $derived := dict -}}
{{- if $oidc.issuer -}}
{{- $derived = dict "enabled" true "issuer" $oidc.accessTokenIssuer "jwks_uri" $oidc.jwksURI "audience" (list $oidc.audience) "role_claims" $oidc.roleClaims "role_mappings" (include "redis-onprem.suite.roleMappings" (dict "root" . "product" "context_gateway") | fromJson) -}}
{{- if $oidc.allowInsecureTransport -}}{{- $_ := set $derived "allow_insecure_transport" true -}}{{- end -}}
{{- end -}}
{{- $localOIDC := dig "auth" "oidc" nil (default (dict) $v.controlplane.config) -}}
{{- $_ := set $out "controlplaneOIDC" (include "redis-onprem.suite.owned" (dict "prefix" $p "path" "controlplane.config.auth.oidc" "local" $localOIDC "derived" ($derived | default nil)) | fromJson).value -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{- /* Under redis-iris the suite supplies these files as Kubernetes Secrets: a CSI class fails. */ -}}
{{- define "gateway.secretOnly" -}}
{{- if (default (dict) .reference).secretProviderClass -}}
{{- fail (printf "%s.secretProviderClass: under redis-iris the suite supplies this file as a Kubernetes Secret; unset it" .path) -}}
{{- end -}}
{{- end -}}

{{- define "gateway.file" -}}
{{- printf "/etc/context-gateway/files/%s/%s" .name .file -}}
{{- end -}}

{{- define "gateway.referencePath" -}}
{{- if .reference.existingSecret -}}
{{- include "gateway.file" (dict "name" .name "file" .reference.secretKey) -}}
{{- else -}}
{{- include "gateway.file" (dict "name" .name "file" .reference.fileName) -}}
{{- end -}}
{{- end -}}

{{- define "gateway.referenceIdentity" -}}
{{- if .existingSecret -}}
{{- printf "secret:%s/%s" .existingSecret .secretKey -}}
{{- else -}}
{{- printf "csi:%s/%s" .secretProviderClass .fileName -}}
{{- end -}}
{{- end -}}

{{- define "gateway.connectionReferences" -}}
{{- $v := .root.Values -}}
{{- $references := list -}}
{{- if or $v.metadataDB.existingSecret $v.metadataDB.secretProviderClass -}}
  {{- $references = append $references (dict "name" "metadata-db" "reference" $v.metadataDB) -}}
{{- end -}}
{{- if eq $v.credentialStorage.provider "redis" -}}
  {{- $reference := $v.credentialStorage.redis.connection -}}
  {{- if or $reference.existingSecret $reference.secretProviderClass -}}
    {{- $references = append $references (dict "name" "credential-redis" "reference" $reference) -}}
  {{- end -}}
{{- else if eq $v.credentialStorage.provider "vault" -}}
  {{- $reference := index $v.credentialStorage.vault.credentials .role -}}
  {{- if or $reference.existingSecret $reference.secretProviderClass -}}
    {{- $references = append $references (dict "name" "credential-vault" "reference" $reference) -}}
  {{- end -}}
{{- end -}}
{{- range $index, $reference := $v.databaseConnections -}}
  {{- $references = append $references (dict "name" (printf "database-connection-%d" $index) "reference" $reference) -}}
{{- end -}}
{{- toJson $references -}}
{{- end -}}

{{- define "gateway.references" -}}
{{- $v := .root.Values -}}
{{- $s := include "gateway.suite" .root | fromJson -}}
{{- $references := list (dict "name" "license" "reference" $s.license) -}}
{{- if eq $v.credentialStorage.provider "redis" -}}
{{- $keyFiles := list -}}
{{- range $id, $file := $v.credentialStorage.redis.keyFiles -}}
{{- $keyFiles = append $keyFiles $file -}}
{{- end -}}
{{- $references = append $references (dict "name" "keyring" "reference" $v.credentialStorage.redis.keyring "directory" true "files" ($keyFiles | uniq)) -}}
{{- end -}}
{{- $references = concat $references (include "gateway.connectionReferences" . | fromJsonArray) -}}
{{- range $index, $reference := $v.shared.overlays -}}
{{- $references = append $references (dict "name" (printf "shared-overlay-%d" $index) "reference" $reference) -}}
{{- end -}}
{{- range $index, $reference := .settings.overlays -}}
{{- $references = append $references (dict "name" (printf "component-overlay-%d" $index) "reference" $reference) -}}
{{- end -}}
{{- if eq .role "controlplane" -}}
{{- $references = concat $references (list (dict "name" "admin" "reference" .settings.adminToken) (dict "name" "internal" "reference" $s.internalToken)) -}}
{{- else -}}
{{- $references = append $references (dict "name" "runtime" "reference" $s.runtimeToken) -}}
{{- end -}}
{{- range $item := list (dict "name" "ca-bundle" "reference" $s.caBundle) -}}
{{- if or $item.reference.existingSecret $item.reference.secretProviderClass -}}
{{- $references = append $references $item -}}
{{- end -}}
{{- end -}}
{{- toJson $references -}}
{{- end -}}

{{- define "gateway.serviceAccount" -}}
{{- default (printf "%s-%s" (include "gateway.fullname" .root) .role) .settings.serviceAccount.name -}}
{{- end -}}

{{- define "gateway.sharedConfig" -}}
{{- $v := .Values -}}
{{- $credentialStorage := dict "provider" $v.credentialStorage.provider -}}
{{- if eq $v.credentialStorage.provider "redis" -}}
  {{- $files := dict -}}
  {{- range $id, $file := $v.credentialStorage.redis.keyFiles -}}
    {{- $_ := set $files $id (include "gateway.file" (dict "name" "keyring" "file" $file)) -}}
  {{- end -}}
  {{- $_ := set $credentialStorage "redis" (dict "base_path" $v.credentialStorage.basePath "client" $v.credentialStorage.redis.client "encryption" (dict "active_key_id" $v.credentialStorage.redis.activeKeyId "key_files" $files)) -}}
{{- else if eq $v.credentialStorage.provider "vault" -}}
  {{- $_ := set $credentialStorage "vault" (dict "address" $v.credentialStorage.vault.address "mount" $v.credentialStorage.vault.mount "base_path" $v.credentialStorage.basePath) -}}
{{- else -}}
  {{- $_ := set $credentialStorage "aws" (dict "region" $v.credentialStorage.aws.region "base_path" $v.credentialStorage.basePath "kms_key_id" $v.credentialStorage.aws.kmsKeyId "timeout" $v.credentialStorage.aws.timeout) -}}
{{- end -}}
{{- $s := include "gateway.suite" . | fromJson -}}
{{- $config := deepCopy $v.shared.config -}}
{{- $_ := set $config "tenant_id" $s.tenantId -}}
{{- $_ := set $config "profile" $v.profile -}}
{{- $_ := set $config "license" (dict "license_path" (include "gateway.referencePath" (dict "name" "license" "reference" $s.license))) -}}
{{- $_ := set $config "credential_storage" $credentialStorage -}}
{{- $defaults := dict -}}
{{- if $v.defaultDatabases.gatewayDb -}}
  {{- $_ := set $defaults "gateway" $v.defaultDatabases.gatewayDb -}}
{{- end -}}
{{- if $v.defaultDatabases.surfaceDb -}}
  {{- $_ := set $defaults "surface" $v.defaultDatabases.surfaceDb -}}
{{- end -}}
{{- if $defaults -}}
  {{- $_ := set $config "default_databases" $defaults -}}
{{- end -}}
{{- toYaml $config -}}
{{- end -}}

{{- define "gateway.componentConfig" -}}
{{- $v := .root.Values -}}
{{- $s := include "gateway.suite" .root | fromJson -}}
{{- $config := deepCopy .settings.config -}}
{{- $server := mergeOverwrite (dict "host" "0.0.0.0" "port" .settings.service.port) (deepCopy (default dict $config.server)) -}}
{{- $_ := set $config "server" $server -}}
{{- if eq .role "controlplane" -}}
  {{- $auth := deepCopy (default dict $config.auth) -}}
  {{- if hasKey $s "controlplaneOIDC" -}}
    {{- $_ := unset $auth "oidc" -}}
    {{- with $s.controlplaneOIDC }}{{- $_ := set $auth "oidc" . -}}{{- end -}}
  {{- end -}}
  {{- $_ := set $config "auth" (mergeOverwrite $auth (dict "type" "admin-token" "admin_token" (dict "token_file" (include "gateway.referencePath" (dict "name" "admin" "reference" .settings.adminToken))) "internal_token" (dict "token_file" (include "gateway.referencePath" (dict "name" "internal" "reference" $s.internalToken))))) -}}
  {{- $_ := set $config "dataplane" (dict "public_base_url" $v.publicBaseURL) -}}
{{- else -}}
  {{- $_ := set $config "auth" (mergeOverwrite (deepCopy (default dict $config.auth)) (dict "method" "agent_key" "agent_keys" (dict "enabled" true "introspection" (dict "base_url" $s.identityService.baseURL "product" "context-gateway" "allow_insecure_transport" $s.identityService.allowInsecureTransport "credential" (dict "token_file" (include "gateway.referencePath" (dict "name" "runtime" "reference" $s.runtimeToken))))))) -}}
{{- end -}}
{{- $oidc := default dict $config.auth.oidc -}}
{{- if and $oidc.enabled (empty $oidc.static_tenant_id) (empty $oidc.tenant_id_claim) -}}
  {{- $_ := set $oidc "static_tenant_id" $s.tenantId -}}
{{- end -}}
{{- if eq .role "dataplane" -}}
  {{- $oauth := deepCopy (default dict $config.oauth) -}}
  {{- $_ := set $oauth "public_base_url" (default $v.publicBaseURL $oauth.public_base_url) -}}
  {{- $_ := set $config "oauth" $oauth -}}
{{- end -}}
{{- toYaml $config -}}
{{- end -}}

{{- define "gateway.args" -}}
- --config
- /etc/context-gateway/config/shared.yaml
- --config
- /etc/context-gateway/config/component.yaml
{{- range include "gateway.connectionReferences" . | fromJsonArray }}
- --config
- {{ include "gateway.referencePath" . | quote }}
{{- end }}
{{- range $index, $reference := .root.Values.shared.overlays }}
- --config
- {{ include "gateway.referencePath" (dict "name" (printf "shared-overlay-%d" $index) "reference" $reference) | quote }}
{{- end }}
{{- range $index, $reference := .settings.overlays }}
- --config
- {{ include "gateway.referencePath" (dict "name" (printf "component-overlay-%d" $index) "reference" $reference) | quote }}
{{- end -}}
{{- end -}}

{{- define "gateway.annotations" -}}
checksum/config: {{ printf "%s\n%s" (include "gateway.sharedConfig" .root) (include "gateway.componentConfig" .) | sha256sum | quote }}
checksum/files: {{ include "gateway.references" . | sha256sum | quote }}
{{- end -}}

{{- define "gateway.mounts" -}}
- name: config
  mountPath: /etc/context-gateway/config
  readOnly: true
{{- range include "gateway.references" . | fromJsonArray }}
- name: {{ .name }}
  mountPath: /etc/context-gateway/files/{{ .name }}
  readOnly: true
{{- end }}
{{- with concat .root.Values.volumeMounts .settings.volumeMounts }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "gateway.volumes" -}}
- name: config
  configMap:
    name: {{ include "gateway.fullname" .root }}-{{ .role }}-config
{{- range include "gateway.references" . | fromJsonArray }}
- name: {{ .name }}
  {{- if .reference.existingSecret }}
  secret:
    secretName: {{ .reference.existingSecret | quote }}
    defaultMode: 0440
    items:
    {{- range $file := ternary .files (list .reference.secretKey) (default false .directory) }}
      - key: {{ $file | quote }}
        path: {{ $file | quote }}
    {{- end }}
  {{- else }}
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: true
    volumeAttributes:
      secretProviderClass: {{ .reference.secretProviderClass | quote }}
  {{- end }}
{{- end }}
{{- with concat .root.Values.volumes .settings.volumes }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "gateway.env" -}}
{{- $s := include "gateway.suite" .root | fromJson -}}
{{- include "redis-onprem.commonEnv" (dict "securityProfile" $s.securityProfile) -}}
{{- range $item := list (dict "name" "ca-bundle" "variable" "SSL_CERT_FILE" "reference" $s.caBundle) }}
{{- if or $item.reference.existingSecret $item.reference.secretProviderClass }}
- name: {{ $item.variable }}
  value: {{ include "gateway.referencePath" $item | quote }}
{{- end }}
{{- end -}}
{{- end -}}
