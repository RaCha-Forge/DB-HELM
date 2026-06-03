{{/*
Expand the name of the chart.
*/}}
{{- define "redis-ts.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "redis-ts.fullname" -}}
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
{{- define "redis-ts.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "redis-ts.labels" -}}
helm.sh/chart: {{ include "redis-ts.chart" . }}
{{ include "redis-ts.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "redis-ts.selectorLabels" -}}
app.kubernetes.io/name: {{ include "redis-ts.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service Account name
*/}}
{{- define "redis-ts.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (printf "%s-failover-sa" (include "redis-ts.name" .)) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Role name
*/}}
{{- define "redis-ts.roleName" -}}
{{- default (printf "%s-failover-role" (include "redis-ts.name" .)) .Values.rbac.roleName }}
{{- end }}

{{/*
RoleBinding name
*/}}
{{- define "redis-ts.roleBindingName" -}}
{{- default (printf "%s-failover-rb" (include "redis-ts.name" .)) .Values.rbac.roleBindingName }}
{{- end }}

{{/*
ConfigMap name
*/}}
{{- define "redis-ts.configMapName" -}}
{{- default (printf "%s-ha-scripts" (include "redis-ts.name" .)) .Values.configMap.name }}
{{- end }}

{{/*
Secret name
*/}}
{{- define "redis-ts.secretName" -}}
{{- default (printf "%s-secret" (include "redis-ts.name" .)) .Values.secrets.name }}
{{- end }}

{{/*
Job name
*/}}
{{- define "redis-ts.jobName" -}}
{{- default (printf "%s-replication-init" (include "redis-ts.name" .)) .Values.job.name }}
{{- end }}

{{/*
Service name
*/}}
{{- define "redis-ts.serviceName" -}}
{{- default (include "redis-ts.name" .) .Values.service.name }}
{{- end }}

{{/*
Lease name for HA controller
*/}}
{{- define "redis-ts.leaseName" -}}
{{- default (printf "%s-ha-controller-lease" (include "redis-ts.name" .)) .Values.lease.name }}
{{- end }}

{{/*
Primary host
*/}}
{{- define "redis-ts.primaryHost" -}}
{{- printf "%s-0-0.%s-0.%s.svc.cluster.local" (include "redis-ts.name" .) (include "redis-ts.name" .) .Release.Namespace }}
{{- end }}
