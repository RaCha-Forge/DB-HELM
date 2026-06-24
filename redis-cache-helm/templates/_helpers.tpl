{{/*
Expand the name of the chart.
*/}}
{{- define "redis-cache.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "redis-cache.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "redis-cache.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "redis-cache.labels" -}}
helm.sh/chart: {{ include "redis-cache.chart" . }}
{{ include "redis-cache.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "redis-cache.selectorLabels" -}}
app.kubernetes.io/name: {{ include "redis-cache.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service Account name
*/}}
{{- define "redis-cache.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (printf "%s-failover-sa" (include "redis-cache.name" .)) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Role name
*/}}
{{- define "redis-cache.roleName" -}}
{{- default (printf "%s-failover-role" (include "redis-cache.name" .)) .Values.rbac.roleName }}
{{- end }}

{{/*
RoleBinding name
*/}}
{{- define "redis-cache.roleBindingName" -}}
{{- default (printf "%s-failover-rb" (include "redis-cache.name" .)) .Values.rbac.roleBindingName }}
{{- end }}

{{/*
ConfigMap name
*/}}
{{- define "redis-cache.configMapName" -}}
{{- default (printf "%s-ha-scripts" (include "redis-cache.name" .)) .Values.configMap.name }}
{{- end }}

{{/*
Secret name
*/}}
{{- define "redis-cache.secretName" -}}
{{- default (printf "%s-secret" (include "redis-cache.name" .)) .Values.secrets.name }}
{{- end }}

{{/*
Job name
*/}}
{{- define "redis-cache.jobName" -}}
{{- default (printf "%s-replication-init" (include "redis-cache.name" .)) .Values.job.name }}
{{- end }}

{{/*
Service name
*/}}
{{- define "redis-cache.serviceName" -}}
{{- default (include "redis-cache.name" .) .Values.service.name }}
{{- end }}

{{/*
Envoy service name
*/}}
{{- define "redis-cache.envoyServiceName" -}}
{{- default (include "redis-cache.serviceName" .) .Values.services.Envoy.serviceName }}
{{- end }}

{{/*
Redis master service name
*/}}
{{- define "redis-cache.masterServiceName" -}}
{{- default (printf "%s-master" (include "redis-cache.serviceName" .)) .Values.services.Envoy.masterServiceName }}
{{- end }}

{{/*
Lease name for HA controller
*/}}
{{- define "redis-cache.leaseName" -}}
{{- default (printf "%s-ha-controller-lease" (include "redis-cache.name" .)) .Values.lease.name }}
{{- end }}

{{/*
Primary host
*/}}
{{- define "redis-cache.primaryHost" -}}
{{- printf "%s-0-0.%s-0.%s.svc.cluster.local" (include "redis-cache.name" .) (include "redis-cache.name" .) .Release.Namespace }}
{{- end }}
