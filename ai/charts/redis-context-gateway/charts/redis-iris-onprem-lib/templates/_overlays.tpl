{{/*
Ordered configuration-overlay rendering, shared by the Iris on-prem product
charts. Each product owns which Secrets carry its overlays and where they mount;
only the mechanics live here.

Every helper takes an explicit dict rather than the chart context, so a consumer
can render overlays for more than one workload in the same chart (LangCache
renders a Data Plane and a Control Plane set) without the helper guessing which
values sub-tree it is looking at.

Overlays are mounted as whole volumes rather than with subPath, so Kubernetes'
atomic ..data swap propagates a rotated Secret; subPath mounts would pin the
original inode and silently serve stale configuration.
*/}}

{{/*
Ordered list of overlay Secret NAMES, JSON-encoded so callers can fromJsonArray
it and iterate with a stable 0-based index.

Input: the product's own secrets dict (may be nil), with optional keys
  secretName        -- first overlay, when non-empty
  additionalSecrets -- further overlays, appended in order (later wins)

Returns "[]" when neither is set, so callers render no volumes, no mounts and no
--config arguments.
*/}}
{{- define "redis-onprem.overlaySecretNames" -}}
{{- $names := list -}}
{{- if . }}
{{- if .secretName }}{{- $names = append $names .secretName -}}{{- end }}
{{- range .additionalSecrets }}{{- $names = append $names . -}}{{- end }}
{{- end }}
{{- $names | toJson -}}
{{- end }}

{{/*
Read-only Secret volumes, one per overlay.

Input dict:
  names        -- JSON list from redis-onprem.overlaySecretNames
  volumePrefix -- volume name prefix; the i-th overlay is <volumePrefix>-<i>
  key          -- key within each Secret holding the overlay document
  path         -- filename to project the key as (defaults to overlay.yaml)
*/}}
{{- define "redis-onprem.overlayVolumes" -}}
{{- $names := fromJsonArray .names -}}
{{- $path := .path | default "overlay.yaml" -}}
{{- range $i, $name := $names }}
- name: {{ $.volumePrefix }}-{{ $i }}
  secret:
    secretName: {{ $name | quote }}
    items:
      - key: {{ $.key | quote }}
        path: {{ $path | quote }}
{{- end }}
{{- end }}

{{/*
Read-only volumeMounts, one per overlay, at <mountBase>/<i>.

Input dict:
  names        -- JSON list from redis-onprem.overlaySecretNames
  volumePrefix -- must match the prefix passed to redis-onprem.overlayVolumes
  mountBase    -- directory under which each overlay is mounted by index
*/}}
{{- define "redis-onprem.overlayVolumeMounts" -}}
{{- $names := fromJsonArray .names -}}
{{- range $i, $name := $names }}
- name: {{ $.volumePrefix }}-{{ $i }}
  mountPath: {{ $.mountBase }}/{{ $i }}
  readOnly: true
{{- end }}
{{- end }}

{{/*
Repeated --config arguments, one pair per overlay, in list order so the config
loader deep-merges later overlays over earlier ones.

Input dict:
  names     -- JSON list from redis-onprem.overlaySecretNames
  mountBase -- must match the base passed to redis-onprem.overlayVolumeMounts
  path      -- filename within each mount (defaults to overlay.yaml)
*/}}
{{- define "redis-onprem.overlayConfigArgs" -}}
{{- $names := fromJsonArray .names -}}
{{- $path := .path | default "overlay.yaml" -}}
{{- range $i, $name := $names }}
- "--config"
- {{ printf "%s/%d/%s" $.mountBase $i $path | quote }}
{{- end }}
{{- end }}

{{/*
Checksum over the ordered Secret names, for a pod annotation. It deliberately
does not read Secret contents -- those are pre-created out of band and may not
be visible at render time -- but rolling on a name or ordering change is a cheap
correctness win.

Input: the JSON list from redis-onprem.overlaySecretNames.
*/}}
{{- define "redis-onprem.overlayChecksum" -}}
{{- . | sha256sum -}}
{{- end }}
