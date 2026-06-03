{{/*
Expand the name of the chart.
*/}}
{{- define "redis-queue.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "redis-queue.fullname" -}}
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
{{- define "redis-queue.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "redis-queue.labels" -}}
helm.sh/chart: {{ include "redis-queue.chart" . }}
{{ include "redis-queue.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "redis-queue.selectorLabels" -}}
app.kubernetes.io/name: {{ include "redis-queue.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service Account name
*/}}
{{- define "redis-queue.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (printf "%s-failover-sa" (include "redis-queue.name" .)) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Role name
*/}}
{{- define "redis-queue.roleName" -}}
{{- default (printf "%s-failover-role" (include "redis-queue.name" .)) .Values.rbac.roleName }}
{{- end }}

{{/*
RoleBinding name
*/}}
{{- define "redis-queue.roleBindingName" -}}
{{- default (printf "%s-failover-rb" (include "redis-queue.name" .)) .Values.rbac.roleBindingName }}
{{- end }}

{{/*
ConfigMap name
*/}}
{{- define "redis-queue.configMapName" -}}
{{- default (printf "%s-ha-scripts" (include "redis-queue.name" .)) .Values.configMap.name }}
{{- end }}

{{/*
Secret name
*/}}
{{- define "redis-queue.secretName" -}}
{{- default (printf "%s-secret" (include "redis-queue.name" .)) .Values.secrets.name }}
{{- end }}

{{/*
Job name
*/}}
{{- define "redis-queue.jobName" -}}
{{- default (printf "%s-replication-init" (include "redis-queue.name" .)) .Values.job.name }}
{{- end }}

{{/*
Service name
*/}}
{{- define "redis-queue.serviceName" -}}
{{- default (include "redis-queue.name" .) .Values.service.name }}
{{- end }}

{{/*
Lease name for HA controller
*/}}
{{- define "redis-queue.leaseName" -}}
{{- default (printf "%s-ha-controller-lease" (include "redis-queue.name" .)) .Values.lease.name }}
{{- end }}

{{/*
Primary host
*/}}
{{- define "redis-queue.primaryHost" -}}
{{- printf "%s-0-0.%s-0.%s.svc.cluster.local" (include "redis-queue.name" .) (include "redis-queue.name" .) .Release.Namespace }}
{{- end }}
