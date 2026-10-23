{{- define "gateway.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 48 | trimSuffix "-" -}}
{{- end -}}

{{- define "gateway.labels" -}}
app.kubernetes.io/name: redis-context-gateway
app.kubernetes.io/instance: {{ .root.Release.Name }}
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
{{- $references := list (dict "name" "license" "reference" $v.license) -}}
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
{{- $references = concat $references (list (dict "name" "admin" "reference" .settings.adminToken) (dict "name" "internal" "reference" .settings.internalToken)) -}}
{{- else -}}
{{- $references = append $references (dict "name" "runtime" "reference" .settings.runtimeToken) -}}
{{- end -}}
{{- range $item := list (dict "name" "ca-bundle" "reference" $v.tls.caBundle) -}}
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
{{- $config := deepCopy $v.shared.config -}}
{{- $_ := set $config "tenant_id" $v.tenantId -}}
{{- $_ := set $config "profile" $v.profile -}}
{{- $_ := set $config "license" (dict "license_path" (include "gateway.referencePath" (dict "name" "license" "reference" $v.license))) -}}
{{- $_ := set $config "credential_storage" $credentialStorage -}}
{{- toYaml $config -}}
{{- end -}}

{{- define "gateway.componentConfig" -}}
{{- $v := .root.Values -}}
{{- $config := deepCopy .settings.config -}}
{{- $server := mergeOverwrite (dict "host" "0.0.0.0" "port" .settings.service.port) (deepCopy (default dict $config.server)) -}}
{{- $_ := set $config "server" $server -}}
{{- if eq .role "controlplane" -}}
  {{- $_ := set $config "auth" (mergeOverwrite (deepCopy (default dict $config.auth)) (dict "type" "admin-token" "admin_token" (dict "token_file" (include "gateway.referencePath" (dict "name" "admin" "reference" .settings.adminToken))) "internal_token" (dict "token_file" (include "gateway.referencePath" (dict "name" "internal" "reference" .settings.internalToken))))) -}}
  {{- $_ := set $config "dataplane" (dict "public_base_url" $v.publicBaseURL) -}}
{{- else -}}
  {{- $_ := set $config "auth" (mergeOverwrite (deepCopy (default dict $config.auth)) (dict "method" "agent_key" "agent_keys" (dict "enabled" true "introspection" (dict "base_url" $v.identityService.baseURL "product" "context-gateway" "allow_insecure_transport" $v.identityService.allowInsecureTransport "credential" (dict "token_file" (include "gateway.referencePath" (dict "name" "runtime" "reference" .settings.runtimeToken))))))) -}}
{{- end -}}
{{- $oidc := default dict $config.auth.oidc -}}
{{- if and $oidc.enabled (empty $oidc.static_tenant_id) (empty $oidc.tenant_id_claim) -}}
  {{- $_ := set $oidc "static_tenant_id" $v.tenantId -}}
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
{{- include "redis-onprem.commonEnv" (dict "securityProfile" .root.Values.security.profile) -}}
{{- range $item := list (dict "name" "ca-bundle" "variable" "SSL_CERT_FILE" "reference" .root.Values.tls.caBundle) }}
{{- if or $item.reference.existingSecret $item.reference.secretProviderClass }}
- name: {{ $item.variable }}
  value: {{ include "gateway.referencePath" $item | quote }}
{{- end }}
{{- end -}}
{{- end -}}
