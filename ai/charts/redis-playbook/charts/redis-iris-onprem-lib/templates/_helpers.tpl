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
