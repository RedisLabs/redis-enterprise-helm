{{/*
Redis client certificates (MOD-14536). Every helper takes the chart's
redisClientTLS values map (nil or empty renders nothing):

  redisClientTLS:
    existingSecret: ""      # Secret with tls.crt and tls.key: the process default
    extraCertificates: []   # [{name, existingSecret}]: per-connection overrides

All Secrets are projected into one read-only volume at /etc/redis-client-tls
without subPath, so the kubelet's atomic ..data swap delivers a renewed pair and
the service reloads it without a restart. The default pair is at
/etc/redis-client-tls/tls.{crt,key}; an extra one at
/etc/redis-client-tls/<name>/tls.{crt,key}, which a connection block's own tls:
names in the service config.
*/}}

{{- define "redis-onprem.redisClientTLS.mountPath" -}}/etc/redis-client-tls{{- end }}

{{/* The validated entries as a JSON list of {dir, existingSecret}; dir "" is the default pair. */}}
{{- define "redis-onprem.redisClientTLS.entries" -}}
{{- $values := default (dict) . -}}
{{- $entries := list -}}
{{- with $values.existingSecret -}}
{{- $entries = append $entries (dict "dir" "" "existingSecret" (toString .)) -}}
{{- end -}}
{{- $names := dict -}}
{{- range $i, $extra := default (list) $values.extraCertificates -}}
{{- $path := printf "redisClientTLS.extraCertificates[%d]" $i -}}
{{- $name := toString (default "" $extra.name) -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$" $name) -}}
{{- fail (printf "%s.name must be a lowercase DNS label (it names the directory /etc/redis-client-tls/<name>)" $path) -}}
{{- end -}}
{{- if hasKey $names $name -}}
{{- fail (printf "%s.name %q is used twice" $path $name) -}}
{{- end -}}
{{- $_ := set $names $name true -}}
{{- if not $extra.existingSecret -}}
{{- fail (printf "%s.existingSecret must name a Secret with tls.crt and tls.key" $path) -}}
{{- end -}}
{{- $entries = append $entries (dict "dir" (printf "%s/" $name) "existingSecret" (toString $extra.existingSecret)) -}}
{{- end -}}
{{- toJson $entries -}}
{{- end }}

{{- define "redis-onprem.redisClientTLS.volume" -}}
{{- $entries := include "redis-onprem.redisClientTLS.entries" . | fromJsonArray -}}
{{- if $entries }}
- name: redis-client-tls
  projected:
    sources:
      {{- range $entries }}
      - secret:
          name: {{ .existingSecret | quote }}
          items:
            - key: tls.crt
              path: {{ printf "%stls.crt" .dir }}
            - key: tls.key
              path: {{ printf "%stls.key" .dir }}
      {{- end }}
{{- end }}
{{- end }}

{{- define "redis-onprem.redisClientTLS.volumeMount" -}}
{{- if include "redis-onprem.redisClientTLS.entries" . | fromJsonArray }}
- name: redis-client-tls
  mountPath: {{ include "redis-onprem.redisClientTLS.mountPath" . }}
  readOnly: true
{{- end }}
{{- end }}

{{/* The redis_client_tls value as JSON: the default pair's paths, or {} without existingSecret. */}}
{{- define "redis-onprem.redisClientTLS.config" -}}
{{- $values := default (dict) . -}}
{{- if $values.existingSecret -}}
{{- $dir := include "redis-onprem.redisClientTLS.mountPath" . -}}
{{- toJson (dict "cert_path" (printf "%s/tls.crt" $dir) "key_path" (printf "%s/tls.key" $dir)) -}}
{{- else -}}
{}
{{- end -}}
{{- end }}
