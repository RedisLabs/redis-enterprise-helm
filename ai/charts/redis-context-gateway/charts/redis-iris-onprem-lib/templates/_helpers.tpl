{{/*
Common on-prem Helm helpers shared by Redis AI product charts.
*/}}

{{/*
Lookup-or-generate a Secret token value, already base64-encoded and ready to
place directly under a v1 Secret's `data`. Stable across `helm upgrade`: if
the target Secret and key already exist, the existing value is reused so a
live credential is never silently rotated. Otherwise a fresh random token is
generated — including under `helm lint`/`helm template` with no cluster
access, where `lookup` returns an empty (not nil) result.

Never index into the `lookup` result directly with something like
`and $existing (index $existing.data $key)`: Helm's template `and` evaluates
every argument eagerly (it does not short-circuit), so `index $existing.data
$key` still runs even when `$existing` — or its `.data` — is absent. Under
Helm's real `lookup` output for "not found" that access already yields a
nil `.data`, and indexing into nil panics with "index of untyped nil" during
render. That failure mode is Helm-version-dependent: it panics reliably on
Helm ~v3.9.x (redis-enterprise-helm's own `ai-helm-lint` pin) but happens to
render clean on newer Helm — so it can pass every check in this repo and
still fail once it reaches a chart CI running against an older pinned Helm.
`default (dict)` on every layer below removes that dependency entirely.

Call with a dict:
  namespace: .Release.Namespace (or $.Release.Namespace from inside a range)
  name:      the Secret name to look up
  key:       the data key holding the token
  length:    (optional) randAlphaNum length, default 48
*/}}
{{- define "redis-onprem.lookupOrGenerateSecretToken" -}}
{{- $existing := lookup "v1" "Secret" .namespace .name -}}
{{- $existingData := default (dict) (default (dict) $existing).data -}}
{{/*
`index $existingData .key` is safe here — unlike the panic above — because
$existingData is already guaranteed a (possibly empty) dict, never nil:
indexing a real map for a missing key returns its zero value, not an error.
Checking truthiness here (not just `hasKey`) also matters: it treats a live
empty-string value as "not really set" and regenerates rather than reusing
it forever, closing an edge case a Server-Side-Apply-owned empty Secret
value could otherwise get stuck on.
*/}}
{{- if index $existingData .key -}}
{{- index $existingData .key -}}
{{- else -}}
{{- randAlphaNum (default 48 .length) | b64enc -}}
{{- end -}}
{{- end }}

{{/*
Shared control-plane delegated-auth contract.

Call every helper with the same options dict:
  root:              the product chart root context
  values:            controlplane.delegatedAuth
  product:           canonical Iris product name
  subject:           Identity Service service-credential subject
  baseURL:           resolved Identity Service Runtime URL
  defaultSecretName: generated credential Secret name
  labelsTemplate:    product labels helper
  external:          true when Identity Service is managed outside this chart
  reservedSecretRefs: optional Secret/key strings that this credential may not reuse

The product chart owns only naming and topology. These helpers keep the
credential, mount, CP config, and IdS runtime entry identical across products.
*/}}
{{- define "redis-onprem.delegatedAuth.validate" -}}
{{- $values := default (dict) .values -}}
{{- if $values.enabled -}}
{{- $path := default "controlplane.delegatedAuth" .path -}}
{{- $credential := default (dict) $values.credential -}}
{{- if not .product -}}{{- fail (printf "%s: product is required" $path) -}}{{- end -}}
{{- if not .subject -}}{{- fail (printf "%s: subject is required" $path) -}}{{- end -}}
{{- if not .baseURL -}}{{- fail (printf "%s.baseURL is required when delegated auth is enabled" $path) -}}{{- end -}}
{{- if not $values.audience -}}{{- fail (printf "%s.audience is required when delegated auth is enabled" $path) -}}{{- end -}}
{{- if not $credential.secretKey -}}{{- fail (printf "%s.credential.secretKey is required when delegated auth is enabled" $path) -}}{{- end -}}
{{- if and .external (not $credential.existingSecret) -}}
{{- fail (printf "%s.credential.existingSecret is required with an external Identity Service" $path) -}}
{{- end -}}
{{- if and (not $credential.existingSecret) (not $credential.autoGenerate) -}}
{{- fail (printf "%s.credential: set existingSecret (BYO) or autoGenerate=true" $path) -}}
{{- end -}}
{{- $secretName := include "redis-onprem.delegatedAuth.secretName" . -}}
{{- $credentialRef := printf "%s/%s" $secretName $credential.secretKey -}}
{{- range $reserved := (default (list) .reservedSecretRefs) -}}
{{- if eq $credentialRef $reserved -}}
{{- fail (printf "%s.credential must not reuse reserved credential %s" $path $reserved) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "redis-onprem.delegatedAuth.secretName" -}}
{{- $credential := default (dict) (default (dict) .values).credential -}}
{{- if $credential.existingSecret -}}
{{- $credential.existingSecret -}}
{{- else -}}
{{- required "delegated auth defaultSecretName is required" .defaultSecretName -}}
{{- end -}}
{{- end }}

{{- define "redis-onprem.delegatedAuth.config" -}}
{{- include "redis-onprem.delegatedAuth.validate" . -}}
{{- $values := default (dict) .values -}}
{{- if $values.enabled -}}
{{- $config := dict
  "base_url" .baseURL
  "product" .product
  "audience" $values.audience
  "credential" (dict "token_file" "/etc/iris/credentials/identity-service-auth-introspect/token")
-}}
{{- if hasKey $values "allowInsecureTransport" -}}
{{- $_ := set $config "allow_insecure_transport" $values.allowInsecureTransport -}}
{{- end -}}
{{- toJson $config -}}
{{- end -}}
{{- end }}

{{- define "redis-onprem.delegatedAuth.runtimeCredential" -}}
{{- include "redis-onprem.delegatedAuth.validate" . -}}
{{- if (default (dict) .values).enabled -}}
{{- dict
  "subject" .subject
  "token_file" "/etc/iris/credentials/identity-service-auth-introspect/token"
  "allowed_operations" (list "auth-introspect")
  "allowed_products" (list .product)
  | toJson -}}
{{- end -}}
{{- end }}

{{- define "redis-onprem.delegatedAuth.volumeMount" -}}
{{- include "redis-onprem.delegatedAuth.validate" . -}}
{{- if (default (dict) .values).enabled -}}
- name: identity-service-auth-introspect
  mountPath: /etc/iris/credentials/identity-service-auth-introspect
  readOnly: true
{{- end -}}
{{- end }}

{{- define "redis-onprem.delegatedAuth.volume" -}}
{{- include "redis-onprem.delegatedAuth.validate" . -}}
{{- $values := default (dict) .values -}}
{{- if $values.enabled -}}
- name: identity-service-auth-introspect
  secret:
    secretName: {{ include "redis-onprem.delegatedAuth.secretName" . | quote }}
    items:
      - key: {{ $values.credential.secretKey | quote }}
        path: token
{{- end -}}
{{- end }}

{{- define "redis-onprem.delegatedAuth.secret" -}}
{{- include "redis-onprem.delegatedAuth.validate" . -}}
{{- $values := default (dict) .values -}}
{{- $credential := default (dict) $values.credential -}}
{{- if and $values.enabled (not $credential.existingSecret) $credential.autoGenerate -}}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "redis-onprem.delegatedAuth.secretName" . | quote }}
  annotations:
    "helm.sh/resource-policy": keep
  labels:
    {{- include .labelsTemplate .root | nindent 4 }}
type: Opaque
data:
  {{ $credential.secretKey | quote }}: {{ include "redis-onprem.lookupOrGenerateSecretToken" (dict "namespace" .root.Release.Namespace "name" (include "redis-onprem.delegatedAuth.secretName" .) "key" $credential.secretKey) }}
{{- end -}}
{{- end }}
