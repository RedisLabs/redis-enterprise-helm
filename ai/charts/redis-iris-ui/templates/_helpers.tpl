{{- define "ui.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ui.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "ui.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "ui.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "ui.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "ui.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ui.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "ui.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "ui.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- required "serviceAccount.name is required when serviceAccount.create=false" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "ui.nginxConfigName" -}}
{{- printf "%s-nginx" (include "ui.fullname" . | trunc 57 | trimSuffix "-") -}}
{{- end -}}

{{- define "ui.runtimeConfigName" -}}
{{- printf "%s-runtime-config" (include "ui.fullname" . | trunc 48 | trimSuffix "-") -}}
{{- end -}}

{{- define "ui.healthTestName" -}}
{{- printf "%s-health-test" (include "ui.fullname" . | trunc 51 | trimSuffix "-") -}}
{{- end -}}

{{/*
A product's upstream host. An explicit upstream.host wins; otherwise upstream.service is completed
to <service>.<release namespace>.svc.<clusterDomain>, so a release can point at a Service of its
own namespace (the redis-iris umbrella) without knowing the namespace up front.
Takes (dict "root" $ "upstream" .upstream).
*/}}
{{- define "ui.upstreamHost" -}}
{{- if .upstream.host -}}
{{- .upstream.host -}}
{{- else -}}
{{- printf "%s.%s.svc.%s" .upstream.service .root.Release.Namespace (include "ui.resolved" .root | fromJson).clusterDomain -}}
{{- end -}}
{{- end -}}

{{/*
The values the redis-iris umbrella owns, resolved once as JSON (redis-onprem.suite.*):
  products       the routes. Standalone: products as given. Under redis-iris: the routes of the
                 enabled products (memory; playbook and playbook-dp; lens; context-gateway and
                 context-gateway-dp; intent and intent-data; always api-keys), with
                 explicit products entries merged by key. An entry may change label,
                 showInNavigation and maxRequestBodyBytes; any other differing field, a duplicate
                 or unknown key fails. An entry for a disabled product is kept and adds no route.
  sso            issuer, accessTokenIssuer, audience, roleClaims, allowInsecureTransport,
                 caCertSecret and roleMappings, from global.iris.auth and global.tls under redis-iris
  clusterDomain, publicURL, ingress {host, className, tlsSecretName}
Under redis-iris a local value that differs from the derived one fails, naming ui.<path>.
*/}}
{{- define "ui.resolved" -}}
{{- $p := "ui." -}}
{{- $sso := .Values.sso -}}
{{- $oidc := include "redis-onprem.suite.oidc" (dict "root" . "prefix" $p
  "local" (dict "issuer" $sso.issuer "accessTokenIssuer" $sso.accessTokenIssuer "audience" $sso.audience "roleClaims" $sso.roleClaims)
  "paths" (dict "issuer" "sso.issuer" "accessTokenIssuer" "sso.accessTokenIssuer" "audience" "sso.audience" "roleClaims" "sso.roleClaims")
  "defaults" (dict "audience" "api://redis-iris" "roleClaims" (list "roles" "groups"))) | fromJson -}}
{{- $out := dict
  "products" (default (list) .Values.products)
  "sso" (dict "issuer" $oidc.issuer "accessTokenIssuer" (default "" $sso.accessTokenIssuer) "audience" $oidc.audience "roleClaims" $oidc.roleClaims
    "allowInsecureTransport" (not (not $sso.allowInsecureTransport)) "caCertSecret" (default "" $sso.tls.caCertSecret) "roleMappings" (default (dict) $sso.roleMappings))
  "clusterDomain" (include "redis-onprem.suite.clusterDomain" (dict "root" . "prefix" $p "local" .Values.clusterDomain))
  "publicURL" (default "" .Values.publicURL)
  "ingress" (dict "host" (default "" .Values.ingress.host) "className" (default "" .Values.ingress.className) "tlsSecretName" (default "" .Values.ingress.tls.secretName)) -}}
{{- if include "redis-onprem.suite.enabled" . -}}
{{- $iris := include "redis-onprem.suite.iris" . | fromJson -}}
{{- $s := $out.sso -}}
{{- $_ := set $s "accessTokenIssuer" $oidc.accessTokenIssuer -}}
{{- $_ := set $s "allowInsecureTransport" (include "redis-onprem.suite.owned" (dict "prefix" $p "path" "sso.allowInsecureTransport" "local" $sso.allowInsecureTransport "derived" (or $oidc.allowInsecureTransport (hasPrefix "http://" (default "" $oidc.issuer)))) | fromJson).value -}}
{{- $_ := set $s "caCertSecret" (include "redis-onprem.suite.owned" (dict "prefix" $p "path" "sso.tls.caCertSecret" "local" $sso.tls.caCertSecret "derived" (dig "tls" "caCertSecret" "" (default (dict) .Values.global))) | fromJson).value -}}
{{- $_ := set $s "roleMappings" (include "redis-onprem.suite.owned" (dict "prefix" $p "path" "sso.roleMappings" "local" $sso.roleMappings "derived" (include "redis-onprem.suite.ui.roleMappings" (dict "root" .) | fromJson)) | fromJson).value -}}
{{- $publicURL := default "" $iris.publicURL -}}
{{- $_ := set $out "publicURL" (include "redis-onprem.suite.owned" (dict "prefix" $p "path" "publicURL" "local" .Values.publicURL "derived" $publicURL) | fromJson).value -}}
{{- $ingress := default (dict) $iris.ingress -}}
{{- $_ := set $out "ingress" (dict
  "host" (include "redis-onprem.suite.owned" (dict "prefix" $p "path" "ingress.host" "local" .Values.ingress.host "derived" (ternary (urlParse $publicURL).hostname "" (ne $publicURL ""))) | fromJson).value
  "className" (include "redis-onprem.suite.owned" (dict "prefix" $p "path" "ingress.className" "local" .Values.ingress.className "derived" (default "" $ingress.className)) | fromJson).value
  "tlsSecretName" (include "redis-onprem.suite.owned" (dict "prefix" $p "path" "ingress.tls.secretName" "local" .Values.ingress.tls.secretName "derived" (dig "tls" "secretName" "" $ingress)) | fromJson).value) -}}
{{- $route := dict "authScheme" "bearer" "healthPath" "/health/readiness" -}}
{{- $known := dict
  "memory" (merge (dict "key" "memory" "label" "Agent Memory" "product" "agent_memory" "upstream" (dict "service" "redis-agent-memory-controlplane" "port" 9100 "basePath" "" "scheme" "http")) $route)
  "api-keys" (merge (dict "key" "api-keys" "label" "Access & Identity" "product" "identity" "upstream" (dict "service" "iris-identity-service" "port" 9200 "basePath" "" "scheme" "http")) $route)
  "playbook" (merge (dict "key" "playbook" "label" "Agent Playbooks" "product" "playbook" "upstream" (dict "service" "redis-agent-playbook-controlplane" "port" 9200 "basePath" "" "scheme" "http")) $route)
  "playbook-dp" (merge (dict "key" "playbook-dp" "label" "Agent Playbooks DP" "product" "playbook" "showInNavigation" false "maxRequestBodyBytes" 8388608 "upstream" (dict "service" "redis-agent-playbook-dataplane" "port" 9201 "basePath" "" "scheme" "http")) $route)
  "lens" (merge (dict "key" "lens" "label" "Lens" "product" "lens" "instanceId" "default" "upstream" (dict "service" "redis-lens-dataplane" "port" 9000 "basePath" "" "scheme" "http")) $route)
  "context-gateway" (merge (dict "key" "context-gateway" "label" "Context Gateway" "product" "context_gateway" "upstream" (dict "service" "redis-context-gateway-controlplane" "port" 9100 "basePath" "" "scheme" "http")) $route)
  "context-gateway-dp" (merge (dict "key" "context-gateway-dp" "label" "Context Gateway DP" "product" "context_gateway" "healthPath" "/health/liveness" "showInNavigation" false "protectedResourceMetadata" true "upstream" (dict "service" "redis-context-gateway-dataplane" "port" 8083 "basePath" "" "scheme" "http")) $route)
  "intent" (merge (dict "key" "intent" "label" "Intent Router" "product" "intent" "upstream" (dict "service" "redis-intent-router-controlplane" "port" 9400 "basePath" "" "scheme" "http")) $route)
  "intent-data" (merge (dict "key" "intent-data" "label" "Intent Router DP" "product" "intent" "showInNavigation" false "upstream" (dict "service" "redis-intent-router-dataplane" "port" 9401 "basePath" "" "scheme" "http")) $route) -}}
{{- $overrides := dict -}}
{{- range $i, $o := default (list) .Values.products -}}
{{- $at := printf "%sproducts[%d]" $p $i -}}
{{- if hasKey $overrides (toString $o.key) -}}
{{- fail (printf "%s.key %q is declared more than once" $at (toString $o.key)) -}}
{{- end -}}
{{- if not (hasKey $known (toString $o.key)) -}}
{{- fail (printf "%s.key %q is not a redis-iris route; the keys are memory, playbook, playbook-dp, lens, context-gateway, context-gateway-dp, intent, intent-data and api-keys" $at (toString $o.key)) -}}
{{- end -}}
{{- $d := index $known $o.key -}}
{{- range $field, $v := $o -}}
{{- if and (not (has $field (list "key" "label" "showInNavigation" "maxRequestBodyBytes"))) (ne (toJson $v) (toJson (index $d $field))) -}}
{{- fail (printf "%s.%s (%s) differs from the redis-iris route (%s); only label, showInNavigation and maxRequestBodyBytes may be overridden" $at $field (toJson $v) (toJson (index $d $field))) -}}
{{- end -}}
{{- end -}}
{{- $_ := set $overrides $o.key $o -}}
{{- end -}}
{{- /* Route order: products in suite order, then api-keys. */ -}}
{{- $keys := list -}}
{{- range $r := list (list "memory" "memory") (list "playbook" "playbook" "playbook-dp") (list "lens" "lens") (list "contextGateway" "context-gateway" "context-gateway-dp") (list "intent" "intent" "intent-data") -}}
{{- if include "redis-onprem.suite.productEnabled" (dict "root" $ "product" (first $r)) -}}{{- $keys = concat $keys (rest $r) -}}{{- end -}}
{{- end -}}
{{- $keys = append $keys "api-keys" -}}
{{- $routes := list -}}
{{- range $key := $keys -}}
{{- $routes = append $routes (merge (deepCopy (default (dict) (index $overrides $key))) (index $known $key)) -}}
{{- end -}}
{{- $_ := set $out "products" $routes -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{- define "ui.caSecretVolumeName" -}}
{{- printf "ca-%s" . | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
UI auth service names. They hang off ui.fullname, so a release "iris" gets iris-redis-iris-ui-auth,
iris-redis-iris-ui-auth-config and iris-redis-iris-ui-auth-session-key. Each suffix length is subtracted from the
63-character limit.
*/}}
{{- define "ui.auth.fullname" -}}
{{- printf "%s-auth" (include "ui.fullname" . | trunc 58 | trimSuffix "-") -}}
{{- end -}}

{{- define "ui.auth.configName" -}}
{{- printf "%s-config" (include "ui.auth.fullname" . | trunc 53 | trimSuffix "-") -}}
{{- end -}}

{{- define "ui.auth.sessionSecretName" -}}
{{- if .Values.sso.session.existingSecret -}}
{{- .Values.sso.session.existingSecret -}}
{{- else -}}
{{- printf "%s-session-key" (include "ui.auth.fullname" . | trunc 48 | trimSuffix "-") -}}
{{- end -}}
{{- end -}}

{{- define "ui.auth.selectorLabels" -}}
{{ include "ui.selectorLabels" . }}
app.kubernetes.io/component: ui-auth
{{- end -}}

{{- define "ui.auth.image" -}}
{{- dict "repository" .Values.uiAuth.image.repository "tag" (default .Values.image.tag .Values.uiAuth.image.tag) "pullPolicy" .Values.uiAuth.image.pullPolicy | toJson -}}
{{- end -}}

{{/*
The UI auth service's non-secret configuration. Secret material is never rendered here: the
client credential and the session key are mounted as files, and the Redis URL (which carries
credentials) is injected from a Secret as an environment variable. Only keys the service reads
today are rendered. The role claims and role mappings are what the service reads to turn the
signed-in user's IdP groups into permissions: a product with no mapping lists none, so its users
get no access in the UI (the backends enforce access either way).
*/}}
{{- define "ui.auth.config" -}}
public_url: {{ (include "ui.resolved" $ | fromJson).publicURL | quote }}
oidc:
  issuer_url: {{ (include "ui.resolved" $ | fromJson).sso.issuer | quote }}
  {{- if (include "ui.resolved" $ | fromJson).sso.allowInsecureTransport }}
  allow_insecure_transport: true
  {{- end }}
  client_id: {{ .Values.sso.clientId | quote }}
  {{- if .Values.sso.clientCredential.privateKeyKey }}
  private_key_file: {{ printf "/etc/ui-auth/client/%s" .Values.sso.clientCredential.privateKeyKey | quote }}
  {{- with .Values.sso.clientCredential.privateKeyID }}
  private_key_id: {{ . | quote }}
  {{- end }}
  {{- else }}
  client_secret_file: {{ printf "/etc/ui-auth/client/%s" .Values.sso.clientCredential.clientSecretKey | quote }}
  {{- end }}
  scopes:
    {{- range .Values.sso.scopes }}
    - {{ . | quote }}
    {{- end }}
  audience: {{ (include "ui.resolved" $ | fromJson).sso.audience | quote }}
  {{- if and .Values.sso.audienceParameter (ne .Values.sso.audienceParameter "none") }}
  audience_parameter: {{ .Values.sso.audienceParameter | quote }}
  {{- end }}
  {{- with (include "ui.resolved" $ | fromJson).sso.accessTokenIssuer }}
  access_token_issuer: {{ . | quote }}
  {{- end }}
  role_claims:
    {{- range (include "ui.resolved" $ | fromJson).sso.roleClaims }}
    - {{ . | quote }}
    {{- end }}
  name_claim: {{ .Values.sso.claims.user | quote }}
  email_claim: {{ .Values.sso.claims.email | quote }}
session:
  encryption_key_file: {{ printf "/etc/ui-auth/session/%s" .Values.sso.session.secretKey | quote }}
  idle_timeout: {{ .Values.sso.session.idleTimeout | quote }}
  absolute_lifetime: {{ .Values.sso.session.absoluteLifetime | quote }}
products:
  {{- range (include "ui.resolved" $ | fromJson).products }}
  - key: {{ .key | quote }}
    product: {{ .product | quote }}
  {{- end }}
{{- with (include "ui.resolved" $ | fromJson).sso.roleMappings }}
role_mappings: {{ . | toJson }}
{{- end }}
{{- end -}}

{{- define "ui.auth.args" -}}
- --config
- /etc/ui-auth/config/config.yaml
{{- end -}}

{{- define "ui.auth.annotations" -}}
checksum/ui-auth-config: {{ include "ui.auth.config" . | sha256sum | quote }}
{{- end -}}

{{- define "ui.auth.env" -}}
{{ include "redis-onprem.commonEnv" (dict "securityProfile" "" "tlsCaCertSecret" (include "ui.resolved" $ | fromJson).sso.caCertSecret) }}
- name: UIAUTH_SESSION_REDIS_URLS
  valueFrom:
    secretKeyRef:
      name: {{ .Values.sso.redis.existingSecret }}
      key: {{ .Values.sso.redis.urlsKey }}
{{- end -}}

{{- define "ui.auth.volumeMounts" -}}
- name: ui-auth-config
  mountPath: /etc/ui-auth/config
  readOnly: true
- name: ui-auth-session-key
  mountPath: /etc/ui-auth/session
  readOnly: true
- name: ui-auth-client-credential
  mountPath: /etc/ui-auth/client
  readOnly: true
{{- if (include "ui.resolved" $ | fromJson).sso.caCertSecret }}
- name: ui-auth-ca
  mountPath: /etc/ssl/custom
  readOnly: true
{{- end }}
{{- end -}}

{{- define "ui.auth.volumes" -}}
{{- $credentialKey := default .Values.sso.clientCredential.clientSecretKey .Values.sso.clientCredential.privateKeyKey }}
- name: ui-auth-config
  configMap:
    name: {{ include "ui.auth.configName" . }}
- name: ui-auth-session-key
  secret:
    secretName: {{ include "ui.auth.sessionSecretName" . }}
    items:
      - key: {{ .Values.sso.session.secretKey }}
        path: {{ .Values.sso.session.secretKey }}
- name: ui-auth-client-credential
  secret:
    secretName: {{ .Values.sso.clientCredential.existingSecret }}
    items:
      - key: {{ $credentialKey }}
        path: {{ $credentialKey }}
{{- if (include "ui.resolved" $ | fromJson).sso.caCertSecret }}
- name: ui-auth-ca
  secret:
    secretName: {{ (include "ui.resolved" $ | fromJson).sso.caCertSecret }}
    items:
      - key: {{ .Values.sso.tls.caCertKey }}
        path: {{ .Values.sso.tls.caCertKey }}
{{- end }}
{{- end -}}

{{/*
Converts an nginx size such as 16k, 2m or 8192 to bytes.
*/}}
{{- define "ui.sizeBytes" -}}
{{- $digits := first (regexFindAll "^[0-9]+" . 1) -}}
{{- $unit := lower (trimPrefix $digits .) -}}
{{- if eq $unit "k" -}}{{ mul (int64 $digits) 1024 }}
{{- else if eq $unit "m" -}}{{ mul (int64 $digits) 1048576 }}
{{- else -}}{{ int64 $digits }}{{- end -}}
{{- end -}}

{{/*
proxy_busy_buffers_size for the auth check, in bytes. nginx refuses a config unless it is at least
the larger of proxy_buffer_size and one proxy_buffers buffer, and less than all the buffers minus
one. Left unset, nginx doubles the larger of the two, which exceeds that ceiling as soon as an
operator raises proxy_buffer_size or lowers the buffer size.
*/}}
{{- define "ui.authBusyBuffersBytes" -}}
{{- $parts := splitList " " .Values.nginx.limits.authProxyBuffers -}}
{{- $bufferBytes := include "ui.sizeBytes" (index $parts 1) | int64 -}}
{{- $headerBytes := include "ui.sizeBytes" .Values.nginx.limits.authProxyBufferSize | int64 -}}
{{- max $headerBytes $bufferBytes -}}
{{- end -}}
