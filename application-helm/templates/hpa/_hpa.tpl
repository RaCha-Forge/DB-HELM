{{- define "fyno.hpa" -}}
{{- $serviceName := .serviceName -}}
{{- $serviceConfig := index .Values.services $serviceName -}}
{{- $serviceNameNormalized := $serviceName | replace "_" "-" -}}
{{- if and (eq $serviceConfig.enabled "true") (eq $serviceConfig.hpa.enabled "true") }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ .Release.Name }}-{{ $serviceNameNormalized }}-hpa
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "fyno.labels" . | nindent 4 }}
    service: {{ $serviceName }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ .Release.Name }}-{{ $serviceNameNormalized }}-service
  minReplicas: {{ $serviceConfig.hpa.minReplicas | default 1 }}
  maxReplicas: {{ $serviceConfig.hpa.maxReplicas | default 3 }}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: {{ $serviceConfig.hpa.cpuTarget | default 70 }}
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: {{ $serviceConfig.hpa.memoryTarget | default 80 }}
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 20
      policies:
      - type: Percent
        value: 100
        periodSeconds: 15
      - type: Pods
        value: 1
        periodSeconds: 15
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 120
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
      - type: Pods
        value: 1
        periodSeconds: 60
      selectPolicy: Min
{{- end }}
{{- end }}
