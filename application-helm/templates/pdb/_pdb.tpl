{{- define "fyno.pdb" -}}
{{- $serviceName := .serviceName -}}
{{- $serviceNameNormalized := $serviceName | replace "_" "-" -}}
{{- $serviceConfig := index .Values.services $serviceName -}}
{{- if and (eq $serviceConfig.enabled "true") (gt ($serviceConfig.replicas | int) 1) }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ .Release.Name }}-{{ $serviceNameNormalized }}-pdb
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "fyno.labels" . | nindent 4 }}
    service: {{ $serviceName }}
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: {{ .Release.Name }}-{{ $serviceNameNormalized }}-service
      service: {{ $serviceName }}
{{- end }}
{{- end }}
