{{/*
Common on-prem Helm mechanics shared by Redis AI product charts. Product charts
own config bodies, commands, credentials, product routes, support tooling, and
smoke tests; this library renders only the bounded workload/service/test shapes.
*/}}

{{- define "redis-onprem.godebugValue" -}}
{{- if eq (default "" .) "fips" -}}fips140=on{{- else -}}fips140=off{{- end -}}
{{- end }}

{{- define "redis-onprem.commonEnv" -}}
- name: GODEBUG
  value: {{ include "redis-onprem.godebugValue" .securityProfile | quote }}
{{- if .tlsCaCertSecret }}
- name: SSL_CERT_DIR
  value: "/etc/ssl/custom"
{{- end }}
{{- end }}

{{- define "redis-onprem.serviceAccount" -}}
{{- $root := .root -}}
{{- if .create -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .name }}
  labels:
    {{- include .labelsTemplate $root | nindent 4 }}
  {{- with .annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
automountServiceAccountToken: {{ .automount }}
{{- end }}
{{- end }}

{{- define "redis-onprem.deployment" -}}
{{- $root := .root -}}
{{- $annotations := "" -}}
{{- if .annotationsTemplate }}{{- $annotations = include .annotationsTemplate $root -}}{{- end -}}
{{- $args := include .argsTemplate $root -}}
{{- $env := "" -}}
{{- if .envTemplate }}{{- $env = include .envTemplate $root -}}{{- end -}}
{{- $volumeMounts := "" -}}
{{- if .volumeMountsTemplate }}{{- $volumeMounts = include .volumeMountsTemplate $root -}}{{- end -}}
{{- $volumes := "" -}}
{{- if .volumesTemplate }}{{- $volumes = include .volumesTemplate $root -}}{{- end -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .name }}
  labels:
    {{- include .labelsTemplate $root | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
spec:
  {{- if not .autoscalingEnabled }}
  replicas: {{ .replicas }}
  {{- end }}
  selector:
    matchLabels:
      {{- include .selectorLabelsTemplate $root | nindent 6 }}
      app.kubernetes.io/component: {{ .component }}
  template:
    metadata:
      annotations:
        {{- with ($annotations | trim) }}
        {{- . | nindent 8 }}
        {{- end }}
        {{- with .podAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      labels:
        {{- include .labelsTemplate $root | nindent 8 }}
        app.kubernetes.io/component: {{ .component }}
        {{- with .podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    spec:
      {{- with .imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      serviceAccountName: {{ .serviceAccountName }}
      {{- if hasKey . "automountServiceAccountToken" }}
      automountServiceAccountToken: {{ .automountServiceAccountToken }}
      {{- end }}
      {{- with .podSecurityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}

      containers:
        - name: {{ .containerName }}
          {{- with .command }}
          command:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          args:
            {{- $args | nindent 12 }}
          {{- with .containerSecurityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          image: "{{ .image.repository }}:{{ .image.tag }}"
          imagePullPolicy: {{ .image.pullPolicy }}
          {{- with ($env | trim) }}
          env:
            {{- . | nindent 12 }}
          {{- end }}
          ports:
            - name: http
              containerPort: {{ default .port .containerPort }}
              protocol: TCP
          {{- with .livenessProbe }}
          livenessProbe:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .readinessProbe }}
          readinessProbe:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with ($volumeMounts | trim) }}
          volumeMounts:
            {{- . | nindent 12 }}
          {{- end }}

      {{- with ($volumes | trim) }}
      volumes:
        {{- . | nindent 8 }}
      {{- end }}
      {{- with .nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end }}

{{- define "redis-onprem.dataplane.deployment" -}}
{{- include "redis-onprem.deployment" . -}}
{{- end }}

{{- define "redis-onprem.controlplane.deployment" -}}
{{- include "redis-onprem.deployment" . -}}
{{- end }}

{{- define "redis-onprem.identityService.deployment" -}}
{{- include "redis-onprem.deployment" . -}}
{{- end }}

{{- define "redis-onprem.service" -}}
{{- $root := .root -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ .name }}
  labels:
    {{- include .labelsTemplate $root | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
spec:
  type: {{ .type }}
  ports:
    - port: {{ .port }}
      targetPort: http
      protocol: TCP
      name: http
  selector:
    {{- include .selectorLabelsTemplate $root | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "redis-onprem.dataplane.service" -}}
{{- include "redis-onprem.service" . -}}
{{- end }}

{{- define "redis-onprem.controlplane.service" -}}
{{- include "redis-onprem.service" . -}}
{{- end }}

{{- define "redis-onprem.identityService.service" -}}
{{- include "redis-onprem.service" . -}}
{{- end }}

{{- define "redis-onprem.dataplane.hpa" -}}
{{- $root := .root -}}
{{- if .enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ .name }}
  labels:
    {{- include .labelsTemplate $root | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ .targetName }}
  minReplicas: {{ .minReplicas }}
  maxReplicas: {{ .maxReplicas }}
  metrics:
    {{- if .targetCPUUtilizationPercentage }}
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .targetCPUUtilizationPercentage }}
    {{- end }}
    {{- if .targetMemoryUtilizationPercentage }}
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: {{ .targetMemoryUtilizationPercentage }}
    {{- end }}
{{- end }}
{{- end }}

{{- define "redis-onprem.dataplane.ingress" -}}
{{- $root := .root -}}
{{- if .enabled -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .name }}
  labels:
    {{- include .labelsTemplate $root | nindent 4 }}
  {{- with .annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- with .className }}
  ingressClassName: {{ . }}
  {{- end }}
  {{- if .tls }}
  tls:
    {{- range .tls }}
    - hosts:
        {{- range .hosts }}
        - {{ . | quote }}
        {{- end }}
      secretName: {{ .secretName }}
    {{- end }}
  {{- end }}
  rules:
    {{- range .hosts }}
    - host: {{ .host | quote }}
      http:
        paths:
          {{- range .paths }}
          - path: {{ .path }}
            pathType: {{ .pathType | default "Prefix" }}
            backend:
              service:
                name: {{ $.serviceName }}
                port:
                  number: {{ $.servicePort }}
          {{- end }}
    {{- end }}
{{- end }}
{{- end }}

{{- define "redis-onprem.securityProfileTest" -}}
{{- $root := .root -}}
{{- if .enabled -}}
apiVersion: v1
kind: Pod
metadata:
  name: "{{ .name }}-test-security-profile"
  labels:
    {{- include .labelsTemplate $root | nindent 4 }}
    app.kubernetes.io/component: test
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": before-hook-creation
spec:
  serviceAccountName: {{ .serviceAccountName }}
  restartPolicy: Never
  containers:
    - name: assert
      image: {{ default "alpine/k8s:1.35.4" .image | quote }}
      imagePullPolicy: {{ default "IfNotPresent" .imagePullPolicy }}
      command:
        - /bin/bash
        - -euo
        - pipefail
        - -c
        - |
          EXPECTED='{{ include "redis-onprem.godebugValue" .securityProfile }}'
          DEPLOY='{{ .deploymentName }}'
          NS='{{ $root.Release.Namespace }}'

          echo "Asserting GODEBUG on Deployment $DEPLOY in ns $NS"
          echo "Expected value: '$EXPECTED'"

          ACTUAL=$(kubectl -n "$NS" get deploy "$DEPLOY" \
            -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="GODEBUG")].value}')

          echo "Actual value:   '$ACTUAL'"

          if [ "$ACTUAL" != "$EXPECTED" ]; then
            echo "FAIL: GODEBUG mismatch. The chart is not wiring"
            echo "      security.profile through to the container correctly."
            exit 1
          fi

          echo "OK: security profile plumbing verified."
{{- end }}
{{- end }}

{{- define "redis-onprem.tests.rbac" -}}
{{- $root := .root -}}
{{- if .enabled -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: "{{ .name }}-test-reader"
  labels:
    {{- include .labelsTemplate $root | nindent 4 }}
    app.kubernetes.io/component: test
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get"]
    resourceNames:
      {{- range .resourceNames }}
      - {{ . | quote }}
      {{- end }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: "{{ .name }}-test-reader"
  labels:
    {{- include .labelsTemplate $root | nindent 4 }}
    app.kubernetes.io/component: test
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: "{{ .name }}-test-reader"
subjects:
  - kind: ServiceAccount
    name: {{ .serviceAccountName }}
    namespace: {{ $root.Release.Namespace }}
{{- end }}
{{- end }}
