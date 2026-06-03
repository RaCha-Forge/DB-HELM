{{/*
Expand the name of the chart.
*/}}
{{- define "mongodb.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "mongodb.fullname" -}}
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
{{- define "mongodb.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mongodb.labels" -}}
helm.sh/chart: {{ include "mongodb.chart" . }}
{{ include "mongodb.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mongodb.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mongodb.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
MongoDB image
*/}}
{{- define "mongodb.image" -}}
{{- printf "%s/%s:%s" .Values.image.registry .Values.image.repository .Values.image.tag }}
{{- end }}

{{/*
MongoDB member FQDNs for replica set initialization
*/}}
{{- define "mongodb.replicaSetMembers" -}}
{{- $members := list -}}
{{- $namespace := .Release.Namespace -}}
{{- $serviceName := .Values.mongodb.serviceName -}}
{{- $port := .Values.replicaSet.port -}}
{{- range $i := until (int .Values.topology.mongoNodes) -}}
  {{- $fqdn := printf "%s-%d-0.%s.%s.svc.cluster.local:%d" $serviceName $i $serviceName $namespace (int $port) -}}
  {{- $members = append $members $fqdn -}}
{{- end -}}
{{- if .Values.arbiter.enabled -}}
  {{- $arbiterServiceName := .Values.arbiter.serviceName -}}
  {{- range $i := until (int .Values.topology.arbiterNodes) -}}
    {{- $fqdn := printf "%s-%d-0.%s.%s.svc.cluster.local:%d" $arbiterServiceName $i $arbiterServiceName $namespace (int $port) -}}
    {{- $members = append $members $fqdn -}}
  {{- end -}}
{{- end -}}
{{- join "," $members -}}
{{- end }}

{{/*
ServiceAccount name for HA controller
*/}}
{{- define "mongodb.serviceAccountName" -}}
{{- default "mongo-ha-controller" .Values.haController.serviceAccountName }}
{{- end }}

{{/*
HA controller role name
*/}}
{{- define "mongodb.haController.roleName" -}}
{{- default "mongo-ha-controller" .Values.haController.roleName }}
{{- end }}
