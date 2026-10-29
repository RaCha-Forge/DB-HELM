{{- define "fyno.service" -}}
{{- $serviceName := .serviceName -}}
{{- $serviceConfig := index .Values.services $serviceName -}}
{{- $serviceNameNormalized := $serviceName | replace "_" "-" -}}
{{- if eq ($serviceConfig.enabled | toString | lower) "true" }}
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
  {{- range $i, $p := $serviceConfig.ports }}
  - name: http{{ if gt (len $serviceConfig.ports) 1 }}-{{ $i }}{{ end }}
    port: {{ if $serviceConfig.svcPorts }}{{ (index $serviceConfig.svcPorts $i).port }}{{ else }}80{{ end }}
    targetPort: {{ $p }}
    protocol: TCP
  {{- end }}
  {{- end }}
  selector:
    app: {{ .Release.Name }}-{{ $serviceNameNormalized }}-service
    service: {{ $serviceName }}
{{- end }}
{{- end }}
