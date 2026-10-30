#!/usr/bin/env bash
# -----------------------------------------------------------------------------
#  adopt-existing.sh
#  One-time migration helper: hands the monitoring objects that were applied
#  with plain `kubectl apply` over to Helm, so the first `helm upgrade --install`
#  takes them over in place - no delete, no downtime, PVCs untouched.
#
#  Usage:  ./scripts/adopt-existing.sh [release-name] [namespace]
#  Defaults: release=monitoring  namespace=fyno-vks-prod
#  Safe to re-run. Objects that do not exist are skipped. Nothing is deleted.
#  A "not found" for everything usually means kubectl points at the wrong
#  cluster / context: check `kubectl config current-context` first.
# -----------------------------------------------------------------------------
set -euo pipefail

RELEASE="${1:-monitoring}"
NS="${2:-fyno-vks-prod}"

# namespaced objects that the chart renders with the same name as the live ones
OBJECTS=(
  statefulset/grafana        service/grafana
  statefulset/prometheus     service/prometheus      configmap/prometheus-config
  statefulset/loki           service/loki            configmap/loki-config
  daemonset/promtail         configmap/promtail-config   serviceaccount/promtail
  deployment/kafka-exporter  service/kafka-exporter
  deployment/mariadb-exporter service/mariadb-exporter   secret/mariadb-exporter
  deployment/mongodb-exporter service/mongodb-exporter
  # Kubernetes (pods / workloads) integration
  serviceaccount/prometheus  configmap/prometheus-rules
  serviceaccount/kube-state-metrics  role/kube-state-metrics  rolebinding/kube-state-metrics
  deployment/kube-state-metrics      service/kube-state-metrics
)

# cluster-scoped objects (no namespace)
CLUSTER_OBJECTS=(
  clusterrole/prometheus-kubelet-metrics   clusterrolebinding/prometheus-kubelet-metrics
  clusterrole/kube-state-metrics-nodes     clusterrolebinding/kube-state-metrics-nodes
)

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

adopt() {  # adopt <kubectl-ns-args...> -- <object>
  local obj="${!#}"; local -a nsargs=("${@:1:$#-1}")
  if kubectl "${nsargs[@]}" get "$obj" >/dev/null 2>&1; then
    kubectl "${nsargs[@]}" annotate "$obj" --overwrite \
      meta.helm.sh/release-name="$RELEASE" meta.helm.sh/release-namespace="$NS" >/dev/null
    kubectl "${nsargs[@]}" label "$obj" --overwrite app.kubernetes.io/managed-by=Helm >/dev/null
    printf '  adopted   %s\n' "$obj"
  else
    printf '  skipped   %s (not found)\n' "$obj"
  fi
}

for obj in "${OBJECTS[@]}";         do adopt -n "$NS" "$obj"; done
for obj in "${CLUSTER_OBJECTS[@]}"; do adopt "$obj"; done

cat <<MSG

Done. Next:
  helm upgrade --install $RELEASE . -n $NS -f values-<env>.yaml --dry-run   # review
  helm upgrade --install $RELEASE . -n $NS -f values-<env>.yaml

Before the first upgrade, put the real values (including passwords) in your values-<env>.yaml - the chart
regenerates prometheus-config, so MinIO tokens, Mongo / MariaDB credentials etc.
must be in values (they are read from values, not from the live ConfigMap).

After a healthy rollout the old, now-unused object can be removed by hand:
  kubectl -n $NS delete configmap grafana-datasource     # replaced by Secret grafana-datasources
MSG
