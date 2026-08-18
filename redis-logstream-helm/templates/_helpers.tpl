{{/*
Expand the name of the chart.
*/}}
{{- define "redis-logstream.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "redis-logstream.fullname" -}}
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
{{- define "redis-logstream.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "redis-logstream.labels" -}}
helm.sh/chart: {{ include "redis-logstream.chart" . }}
{{ include "redis-logstream.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "redis-logstream.selectorLabels" -}}
app.kubernetes.io/name: {{ include "redis-logstream.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service Account name
*/}}
{{- define "redis-logstream.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (printf "%s-failover-sa" (include "redis-logstream.name" .)) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Role name
*/}}
{{- define "redis-logstream.roleName" -}}
{{- default (printf "%s-failover-role" (include "redis-logstream.name" .)) .Values.rbac.roleName }}
{{- end }}

{{/*
RoleBinding name
*/}}
{{- define "redis-logstream.roleBindingName" -}}
{{- default (printf "%s-failover-rb" (include "redis-logstream.name" .)) .Values.rbac.roleBindingName }}
{{- end }}

{{/*
ConfigMap name
*/}}
{{- define "redis-logstream.configMapName" -}}
{{- default (printf "%s-ha-scripts" (include "redis-logstream.name" .)) .Values.configMap.name }}
{{- end }}

{{/*
Secret name
*/}}
{{- define "redis-logstream.secretName" -}}
{{- default (printf "%s-secret" (include "redis-logstream.name" .)) .Values.secrets.name }}
{{- end }}

{{/*
Job name
*/}}
{{- define "redis-logstream.jobName" -}}
{{- default (printf "%s-replication-init" (include "redis-logstream.name" .)) .Values.job.name }}
{{- end }}

{{/*
Service name
*/}}
{{- define "redis-logstream.serviceName" -}}
{{- default (include "redis-logstream.name" .) .Values.service.name }}
{{- end }}

{{/*
Envoy service name
*/}}
{{- define "redis-logstream.envoyServiceName" -}}
{{- default (include "redis-logstream.serviceName" .) .Values.services.Envoy.serviceName }}
{{- end }}

{{/*
Redis master service name
*/}}
{{- define "redis-logstream.masterServiceName" -}}
{{- default (printf "%s-master" (include "redis-logstream.serviceName" .)) .Values.services.Envoy.masterServiceName }}
{{- end }}

{{/*
Lease name for HA controller
*/}}
{{- define "redis-logstream.leaseName" -}}
{{- default (printf "%s-ha-controller-lease" (include "redis-logstream.name" .)) .Values.lease.name }}
{{- end }}

{{/*
Primary host
*/}}
{{- define "redis-logstream.primaryHost" -}}
{{- printf "%s-0-0.%s-0.%s.svc.cluster.local" (include "redis-logstream.name" .) (include "redis-logstream.name" .) .Release.Namespace }}
{{- end }}
