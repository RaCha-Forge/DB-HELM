{{/*
  Shared helpers for the monitoring chart.
  Workload names are fixed (grafana, prometheus, loki ...) on purpose: they match
  the objects already running in the cluster so `helm upgrade` can adopt them in place.
*/}}

{{/* Chart label value */}}
{{- define "monitoring.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
  Standard labels. Call: include "monitoring.labels" (dict "root" $ "name" "grafana" "component" "visualization")
*/}}
{{- define "monitoring.labels" -}}
app: {{ .name }}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/part-of: fyno-monitoring
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ include "monitoring.chart" .root }}
{{- with .root.Values.global.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* Immutable selector labels (kept identical to the original manifests). */}}
{{- define "monitoring.selector" -}}
app: {{ . }}
{{- end -}}

{{/* Full image reference. Call: include "monitoring.image" (dict "root" $ "image" .Values.x.image) */}}
{{- define "monitoring.image" -}}
{{- $reg := .root.Values.global.imageRegistry -}}
{{- if $reg -}}
{{- printf "%s/%s:%s" $reg .image.repository (toString .image.tag) -}}
{{- else -}}
{{- printf "%s:%s" .image.repository (toString .image.tag) -}}
{{- end -}}
{{- end -}}

{{/* imagePullSecrets block (empty when none configured) */}}
{{- define "monitoring.pullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range . }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

{{/* In-cluster URLs */}}
{{- define "monitoring.prometheusUrl" -}}
{{- printf "http://prometheus.%s.svc.cluster.local:9090" .Release.Namespace -}}
{{- end -}}
{{- define "monitoring.lokiUrl" -}}
{{- printf "http://loki.%s.svc.cluster.local:3100" .Release.Namespace -}}
{{- end -}}

{{/* Escape "$" so Grafana provisioning does not treat it as env interpolation */}}
{{- define "monitoring.gfEscape" -}}
{{- . | toString | replace "$" "$$" -}}
{{- end -}}

{{/*
  Dashboard sets that should be provisioned (comma separated).
  A set is on when its integration is enabled AND its `dashboard` switch is true.
*/}}
{{- define "monitoring.dashboardSets" -}}
{{- $i := .Values.integrations -}}
{{- $s := list -}}
{{- if and .Values.loki.enabled .Values.loki.dashboard }}{{ $s = append $s "logs" }}{{ end -}}
{{- if and $i.kafka.enabled $i.kafka.dashboard }}{{ $s = append $s "kafka" }}{{ end -}}
{{- if and $i.mariadb.enabled $i.mariadb.dashboard }}{{ $s = append $s "mariadb" }}{{ end -}}
{{- if and $i.mongodb.enabled $i.mongodb.dashboard }}{{ $s = append $s "mongodb" }}{{ end -}}
{{- if and $i.minio.enabled $i.minio.dashboard }}{{ $s = append $s "minio" }}{{ end -}}
{{- if and $i.redis.enabled $i.redis.dashboard }}{{ $s = append $s "redis" }}{{ end -}}
{{- if and $i.kubernetes.enabled $i.kubernetes.dashboard }}{{ $s = append $s "kubernetes" }}{{ end -}}
{{- join "," $s -}}
{{- end -}}

{{/* "true" when at least one MinIO site has a bearer token (site-level overrides the integration-level default) */}}
{{- define "monitoring.minioHasToken" -}}
{{- $m := .Values.integrations.minio -}}
{{- $has := false -}}
{{- if $m.enabled -}}
{{- range $m.sites -}}
{{- if or .bearerToken $m.bearerToken }}{{ $has = true }}{{ end -}}
{{- end -}}
{{- end -}}
{{- if $has }}true{{ end -}}
{{- end -}}

{{/* Grafana folder title for a dashboard set */}}
{{- define "monitoring.dashboardFolder" -}}
{{- get (dict "logs" "Logs" "kafka" "Kafka" "mariadb" "MariaDB" "mongodb" "MongoDB" "minio" "MinIO" "redis" "Redis" "kubernetes" "Kubernetes") . -}}
{{- end -}}

{{/* Fail fast on invalid combinations so a bad values file never reaches the cluster. */}}
{{- define "monitoring.validate" -}}
{{- $i := .Values.integrations -}}
{{- if and (or $i.kafka.enabled $i.mariadb.enabled $i.mongodb.enabled $i.minio.enabled $i.kubernetes.enabled) (not .Values.prometheus.enabled) -}}
{{- fail "prometheus.enabled must be true when the kafka, mariadb, mongodb, minio or kubernetes integration is enabled" -}}
{{- end -}}
{{- if and .Values.promtail.enabled (not .Values.loki.enabled) -}}
{{- fail "promtail.enabled requires loki.enabled=true (Promtail ships to the in-chart Loki)" -}}
{{- end -}}
{{- if and $i.kafka.enabled (not $i.kafka.host) -}}
{{- fail "integrations.kafka.host is required when integrations.kafka.enabled=true" -}}
{{- end -}}
{{- if and $i.mariadb.enabled (not $i.mariadb.host) -}}
{{- fail "integrations.mariadb.host is required when integrations.mariadb.enabled=true" -}}
{{- end -}}
{{- if and $i.mongodb.enabled (not $i.mongodb.hosts) -}}
{{- fail "integrations.mongodb.hosts must list at least one host:port when integrations.mongodb.enabled=true" -}}
{{- end -}}
{{- if and $i.minio.enabled (not $i.minio.sites) -}}
{{- fail "integrations.minio.sites must list at least one site when integrations.minio.enabled=true" -}}
{{- end -}}
{{- if and $i.kubernetes.enabled (not (has $i.kubernetes.cadvisor.mode (list "kubelet" "apiserver-proxy"))) -}}
{{- fail "integrations.kubernetes.cadvisor.mode must be 'kubelet' or 'apiserver-proxy'" -}}
{{- end -}}
{{- if and $i.redis.enabled (not $i.redis.host) -}}
{{- fail "integrations.redis.host is required when integrations.redis.enabled=true" -}}
{{- end -}}
{{- if and .Values.grafana.enabled (not .Values.grafana.admin.existingSecret) (not .Values.grafana.admin.password) -}}
{{- fail "grafana.admin.password is required (or point grafana.admin.existingSecret at a Secret with keys admin-user / admin-password)" -}}
{{- end -}}
{{- end -}}
