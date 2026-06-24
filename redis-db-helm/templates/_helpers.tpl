{{/*
Expand the name of the chart.
*/}}
{{- define "redis-db.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "redis-db.fullname" -}}
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
{{- define "redis-db.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "redis-db.labels" -}}
helm.sh/chart: {{ include "redis-db.chart" . }}
{{ include "redis-db.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "redis-db.selectorLabels" -}}
app.kubernetes.io/name: {{ include "redis-db.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service Account name
*/}}
{{- define "redis-db.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (printf "%s-failover-sa" (include "redis-db.name" .)) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Role name
*/}}
{{- define "redis-db.roleName" -}}
{{- default (printf "%s-failover-role" (include "redis-db.name" .)) .Values.rbac.roleName }}
{{- end }}

{{/*
RoleBinding name
*/}}
{{- define "redis-db.roleBindingName" -}}
{{- default (printf "%s-failover-rb" (include "redis-db.name" .)) .Values.rbac.roleBindingName }}
{{- end }}

{{/*
ConfigMap name
*/}}
{{- define "redis-db.configMapName" -}}
{{- default (printf "%s-ha-scripts" (include "redis-db.name" .)) .Values.configMap.name }}
{{- end }}

{{/*
Secret name
*/}}
{{- define "redis-db.secretName" -}}
{{- default (printf "%s-secret" (include "redis-db.name" .)) .Values.secrets.name }}
{{- end }}

{{/*
Job name
*/}}
{{- define "redis-db.jobName" -}}
{{- default (printf "%s-replication-init" (include "redis-db.name" .)) .Values.job.name }}
{{- end }}

{{/*
Service name
*/}}
{{- define "redis-db.serviceName" -}}
{{- default (include "redis-db.name" .) .Values.service.name }}
{{- end }}

{{/*
Envoy service name
*/}}
{{- define "redis-db.envoyServiceName" -}}
{{- default (include "redis-db.serviceName" .) .Values.services.Envoy.serviceName }}
{{- end }}

{{/*
Redis master service name
*/}}
{{- define "redis-db.masterServiceName" -}}
{{- default (printf "%s-master" (include "redis-db.serviceName" .)) .Values.services.Envoy.masterServiceName }}
{{- end }}

{{/*
Lease name for HA controller
*/}}
{{- define "redis-db.leaseName" -}}
{{- default (printf "%s-ha-controller-lease" (include "redis-db.name" .)) .Values.lease.name }}
{{- end }}

{{/*
Primary host
*/}}
{{- define "redis-db.primaryHost" -}}
{{- printf "%s-0-0.%s-0.%s.svc.cluster.local" (include "redis-db.name" .) (include "redis-db.name" .) .Release.Namespace }}
{{- end }}
