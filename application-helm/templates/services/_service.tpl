{{- define "fyno.service" -}}
{{- $serviceName := .serviceName -}}
{{- $serviceConfig := index .Values.services $serviceName -}}
{{- $serviceNameNormalized := $serviceName | replace "_" "-" -}}
{{- if eq $serviceConfig.enabled "true" }}
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-{{ $serviceNameNormalized }}-svc
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "fyno.labels" . | nindent 4 }}
    service: {{ $serviceName }}
spec:
  type: ClusterIP
  {{- if $serviceConfig.svcPorts }}
  ports:
  {{- range $i, $sp := $serviceConfig.svcPorts }}
  - name: {{ if $sp.name }}{{ $sp.name }}{{ else }}http{{ if gt (len $serviceConfig.svcPorts) 1 }}-{{ $i }}{{ end }}{{ end }}
    port: {{ $sp.port }}
    targetPort: {{ $sp.targetPort }}
    protocol: TCP
  {{- end }}
  {{- else if $serviceConfig.ports }}
  ports:
  - name: http
    port: 80
    targetPort: {{ (index $serviceConfig.ports 0) }}
    protocol: TCP
  {{- end }}
  selector:
    app: {{ .Release.Name }}-{{ $serviceNameNormalized }}-service
    service: {{ $serviceName }}
{{- end }}
{{- end }}
