{{/*
Server TLS in the pod (MOD-20903). The Go server ends TLS when its config has
server.tls, and it verifies client certificates when server.tls has
client_ca_file. These helpers turn one product value, tls.server, into that
config, the Secret volumes, the mounts and the HTTPS probes.

Every helper takes the tls.server dict of the product (nil is off):
  certSecret     -- a kubernetes.io/tls Secret with tls.crt and tls.key; empty keeps plain HTTP
  clientCASecret -- optional: a Secret with the roots that may sign a client certificate
  clientCAKey    -- the key in clientCASecret (default ca.crt)

A chart that renders its pods with redis-onprem.deployment passes the dict as
serverTLS, and gets the volumes, the mounts and the probe scheme from it. The
chart adds the config to its own config body with redis-onprem.serverTLS.config.
The Secrets are mounted as whole volumes, so a rotated certificate reaches the
pod, and the server reads it again (no restart).
*/}}

{{- define "redis-onprem.serverTLS.enabled" -}}
{{- $tls := default (dict) . -}}
{{- if and $tls.clientCASecret (not $tls.certSecret) -}}
{{- fail "tls.server.clientCASecret needs tls.server.certSecret: the server verifies client certificates only when it ends TLS" -}}
{{- end -}}
{{- if $tls.certSecret }}true{{ end -}}
{{- end }}

{{- define "redis-onprem.serverTLS.scheme" -}}
{{- if include "redis-onprem.serverTLS.enabled" . }}https{{ else }}http{{ end -}}
{{- end }}

{{/* The server.tls block of the Go config, as JSON; {} when TLS is off. */}}
{{- define "redis-onprem.serverTLS.config" -}}
{{- $tls := default (dict) . -}}
{{- $out := dict -}}
{{- if include "redis-onprem.serverTLS.enabled" $tls -}}
{{- $out = dict "cert_file" "/etc/iris/server-tls/tls.crt" "key_file" "/etc/iris/server-tls/tls.key" -}}
{{- if $tls.clientCASecret -}}
{{- $_ := set $out "client_ca_file" (printf "/etc/iris/client-ca/%s" (default "ca.crt" $tls.clientCAKey)) -}}
{{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end }}

{{- define "redis-onprem.serverTLS.volumeMounts" -}}
{{- $tls := default (dict) . -}}
{{- if include "redis-onprem.serverTLS.enabled" $tls }}
- name: server-tls
  mountPath: /etc/iris/server-tls
  readOnly: true
{{- if $tls.clientCASecret }}
- name: server-client-ca
  mountPath: /etc/iris/client-ca
  readOnly: true
{{- end }}
{{- end }}
{{- end }}

{{- define "redis-onprem.serverTLS.volumes" -}}
{{- $tls := default (dict) . -}}
{{- if include "redis-onprem.serverTLS.enabled" $tls }}
- name: server-tls
  secret:
    secretName: {{ $tls.certSecret }}
    items:
      - key: tls.crt
        path: tls.crt
      - key: tls.key
        path: tls.key
{{- with $tls.clientCASecret }}
- name: server-client-ca
  secret:
    secretName: {{ . }}
    items:
      - key: {{ default "ca.crt" $tls.clientCAKey }}
        path: {{ default "ca.crt" $tls.clientCAKey }}
{{- end }}
{{- end }}
{{- end }}

{{/* The probe with scheme HTTPS when TLS is on, as YAML. Takes dict "tls" "probe". */}}
{{- define "redis-onprem.serverTLS.probe" -}}
{{- $probe := deepCopy (default (dict) .probe) -}}
{{- if and (include "redis-onprem.serverTLS.enabled" .tls) $probe.httpGet -}}
{{- $_ := set $probe.httpGet "scheme" "HTTPS" -}}
{{- end -}}
{{- if $probe }}{{ toYaml $probe }}{{ end -}}
{{- end }}
