{{- define "fyno.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "fyno.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "fyno.serviceLabels" }}
app: {{ include "fyno.fullname" . }}-{{ .serviceName }}-service
service: {{ .serviceName }}
{{- include "fyno.labels" . | nindent 0 }}
{{- end }}

{{- define "fyno.fullname" -}}
{{- .Release.Name -}}
{{- end }}

{{- define "fyno.podSecurityContext" -}}
securityContext:
  runAsNonRoot: true 
  runAsUser: 65532
  runAsGroup: 65532
  fsGroup: 65532
  fsGroupChangePolicy: OnRootMismatch
  seccompProfile:
    type: RuntimeDefault
{{- end }}

{{- define "fyno.containerSecurityContext" -}}
securityContext:
  allowPrivilegeEscalation: false
  runAsNonRoot: true
  readOnlyRootFilesystem: false
  capabilities:
    drop:
      - ALL
{{- end }}

{{- define "fyno.resources" -}}
{{- if eq .resources.enabled "true" }}
resources:
  limits:
    cpu: {{ .resources.limits.cpu }}
    memory: {{ .resources.limits.memory }}
  requests:
    cpu: {{ .resources.requests.cpu }}
    memory: {{ .resources.requests.memory }}
{{- end }}
{{- end }}

{{- define "fyno.imagePullSecrets" -}}
{{- if eq .Values.imagePullSecret.enabled "true" }}
imagePullSecrets:
  - name: {{ .Values.imagePullSecret.value }}
{{- end }}
{{- end }}

{{- define "fyno.configMapName" -}}
{{- $serviceName := .serviceName -}}
{{- $normalized := $serviceName | replace "_" "-" -}}
{{- if or (eq $serviceName "aiservice") }}
{{- printf "%s-ai-service-config" .Release.Name }}
{{- else if or (eq $serviceName "analytics") }}
{{- printf "%s-analytics-config" .Release.Name }}
{{- else if or (eq $serviceName "api_service") (eq $serviceName "apiservice") (eq $serviceName "automationservice") (eq $serviceName "backend") (eq $serviceName "callback") (eq $serviceName "dlr") (eq $serviceName "eventservice") (eq $serviceName "log") (eq $serviceName "transporter") (eq $serviceName "logstream") }}
{{- printf "%s-backend-config" .Release.Name }}
{{- else if or (eq $serviceName "c_api") (eq $serviceName "c_event") (eq $serviceName "c_log") (eq $serviceName "c_transporter") }}
{{- printf "%s-backend-config" .Release.Name }}
{{- else if eq $serviceName "monitor" }}
{{- printf "%s-monitor-config" .Release.Name }}
{{- else if eq $serviceName "frontend" }}
{{- printf "%s-frontend-service-config" .Release.Name }}
{{- else if eq $serviceName "docs" }}
{{- printf "%s-fynodocs-service-config" .Release.Name }}
{{- else if eq $serviceName "inapp" }}
{{- printf "%s-inappservice-config" .Release.Name }}
{{- else if eq $serviceName "smart" }}
{{- printf "%s-smart-service-config" .Release.Name }}
{{- else }}
{{- printf "%s-%s-config" .Release.Name $normalized }}
{{- end }}
{{- end }}

{{- define "fyno.secretName" -}}
{{- $serviceName := .serviceName -}}
{{- $normalized := $serviceName | replace "_" "-" -}}
{{- if or (eq $serviceName "aiservice") }}
{{- printf "%s-ai-service-secret" .Release.Name }}
{{- else if or (eq $serviceName "analytics") }}
{{- printf "%s-analytics-secret" .Release.Name }}
{{- else if or (eq $serviceName "api_service") (eq $serviceName "apiservice") (eq $serviceName "automationservice") (eq $serviceName "backend") (eq $serviceName "callback") (eq $serviceName "dlr") (eq $serviceName "eventservice") (eq $serviceName "log") (eq $serviceName "transporter") (eq $serviceName "logstream") }}
{{- printf "%s-backend-secret" .Release.Name }}
{{- else if eq $serviceName "monitor" }}
{{- printf "%s-monitor-secret" .Release.Name }}
{{- else if or (eq $serviceName "analytics") }}
{{- else if or (eq $serviceName "c_api") (eq $serviceName "c_event") (eq $serviceName "c_log") (eq $serviceName "c_transporter") }}
{{- printf "%s-backend-secret" .Release.Name }}
{{- else if eq $serviceName "frontend" }}
{{- printf "%s-frontend-service-secret" .Release.Name }}
{{- else if eq $serviceName "docs" }}
{{- printf "%s-fynodocs-service-secret" .Release.Name }}
{{- else if eq $serviceName "inapp" }}
{{- printf "%s-inappservice-service-secret" .Release.Name }}
{{- else if eq $serviceName "smart" }}
{{- printf "%s-smartservice-service-secret" .Release.Name }}
{{- else }}
{{- printf "%s-%s-secret" .Release.Name $normalized }}
{{- end }}
{{- end }}
