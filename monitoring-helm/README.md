# monitoring

One Helm chart for the whole Fyno observability stack on the on-prem VKS cluster.
Turn a data source on in `values.yaml` and the chart wires it up end to end:

```
integrations.<x>.enabled: true
        │
        ├── exporter Deployment + Service + Secret      (Kafka, MariaDB, MongoDB)
        ├── Prometheus scrape job                       (all but Redis)
        ├── Grafana datasource, fixed UID               (prometheus / loki / redis-timeseries)
        └── Grafana dashboard from dashboards/<x>/*.json, in its own folder
```

## What is in the box

| Switch | Renders | Dashboard folder |
|---|---|---|
| `grafana.enabled` | Grafana StatefulSet, Service, admin Secret, provisioning | – |
| `prometheus.enabled` | Prometheus StatefulSet, Service, scrape config | – |
| `loki.enabled` + `promtail.enabled` | Loki StatefulSet, Promtail DaemonSet (+ least-privilege RBAC) | Logs |
| `integrations.kafka.enabled` | kafka-exporter | Kafka |
| `integrations.mariadb.enabled` | mysqld-exporter | MariaDB |
| `integrations.mongodb.enabled` | mongodb-exporter | MongoDB |
| `integrations.minio.enabled` | scrape jobs only (MinIO exposes its own metrics) | MinIO |
| `integrations.redis.enabled` | Grafana Redis datasource only (no exporter) | Redis |
| `integrations.kubernetes.enabled` | kube-state-metrics, cAdvisor scrape, workload recording rules, least-privilege RBAC | Kubernetes |

All switches are real booleans. `values.schema.json` rejects `"true"` strings and other typos before anything is applied.
Every integration is **off by default**; the example file turns them on.

## Quick start

```bash
cp examples/values-fyno-prod.yaml my-values.yaml      # fill in the CHANGE_ME values, keep this file out of git
helm upgrade --install monitoring . -n fyno-vks-prod -f my-values.yaml
```

Credentials are optional everywhere. Leave `user` / `password` empty and the chart omits the auth settings
(no `--sasl.*` flags for Kafka, no `user=` / `password=` lines in `.my.cnf`, no credentials in the Mongo URI,
no bearer token for MinIO, no password for the Redis datasource).

## Typical edits

```yaml
integrations:
  kafka:
    enabled: true
    host: 10.240.57.204
    port: 9092
    user: ""            # set both to switch SASL on
    password: ""
  mongodb:
    enabled: true
    hosts: ["mongo-0.mongo.fyno-vks-prod.svc:28128", "mongo-1.mongo.fyno-vks-prod.svc:28128"]
    user: exporter
    password: "..."
  minio:
    enabled: true
    bearerToken: ""     # default token; empty when MINIO_PROMETHEUS_AUTH_TYPE=public
    sites:
      - { name: minio-a, targets: ["minio-a-headless:9000"], bearerToken: "..." }   # per-site token overrides the default
      - { name: minio-b, targets: ["minio-b-headless:9000"], bearerToken: "..." }
  kubernetes:
    enabled: true
    namespaces: []      # empty = release namespace
    cadvisor:
      mode: kubelet     # or "apiserver-proxy" (needs nodes/proxy RBAC)
```

### Kubernetes workload monitoring

`integrations.kubernetes.enabled: true` adds per-workload and per-pod visibility (replicas desired/available per
Deployment, StatefulSet and DaemonSet, CPU and memory against requests and limits, throttling, restarts, network, HPA state)
in the **Kubernetes** dashboard folder (`fyno-workloads`). It renders:

* `kube-state-metrics`, scoped to the release namespace through a namespaced Role plus a small cluster-scoped role for nodes;
* a Prometheus ServiceAccount with `nodes/metrics` read access, a `kubernetes-cadvisor` scrape job and a `kube-state-metrics` job;
* the recording rules from `files/fyno-workloads-rules.yml`, mounted at `/etc/prometheus-rules`.

If the kubelet endpoint is not reachable from Prometheus, set `cadvisor.mode: apiserver-proxy`. Mirror the kube-state-metrics image into your registry first
(`integrations.kubernetes.kubeStateMetrics.image`).

Per-site MinIO tokens are stored in a Secret (`prometheus-minio-token`, one key per site) and referenced with `credentials_file`, so tokens never appear in the ConfigMap.
Keep them in an untracked values file.

Turn something off by flipping its switch to `false`; its exporter, scrape job, datasource and dashboard all disappear on the next upgrade.
To keep a data source but hide its dashboard, set `dashboard: false` on that block.

## Taking over the running cluster (no downtime)

Object names, selectors, PVC templates and storage sizes match the manifests that are live today,
so Helm can adopt them in place.

```bash
./scripts/adopt-existing.sh monitoring fyno-vks-prod      # annotates/labels existing objects for Helm; deletes nothing
helm upgrade --install monitoring . -n fyno-vks-prod -f my-values.yaml --dry-run
helm upgrade --install monitoring . -n fyno-vks-prod -f my-values.yaml
```

Things to know on the first upgrade:

* Grafana datasources now come from a Secret (`grafana-datasources`). The old ConfigMap `grafana-datasource` is no longer mounted; delete it once Grafana is healthy.
* `grafana.replaceExistingDatasources: true` removes UI-created datasources named Prometheus, Loki and Redis so the provisioned ones (fixed UIDs) can take over. Dashboards reference those UIDs only.
* Dashboards are provisioned read-only. Change the JSON under `dashboards/` and upgrade; UI edits are not persisted.
* Exporter Services and the Promtail ServiceAccount were not in the original manifests; the chart now owns them.
* If the kubernetes integration was first applied by hand, `adopt-existing.sh` also adopts its objects, including the cluster-scoped RBAC.
* The chart regenerates `prometheus-config` from values. Inline tokens or passwords in the live ConfigMap are not carried over, so supply them in your secrets file before upgrading.
* PVCs are never touched (`volumeClaimTemplates` are identical to the running StatefulSets).

## Layout

```
monitoring/
├── Chart.yaml
├── values.yaml                 every switch and setting, commented
├── values.schema.json          type checking for values
├── dashboards/                 dashboard JSON, one folder per Grafana folder
├── examples/values-fyno-prod.yaml
├── scripts/adopt-existing.sh
└── templates/
    ├── _helpers.tpl            labels, images, validation, dashboard selection
    ├── grafana/  prometheus/  loki/  promtail/  exporters/
    └── validate.yaml           fails fast on invalid combinations
```

## Guard rails

* Exporters need Prometheus (`prometheus.enabled`); Promtail needs Loki. Violations fail at render time with a clear message.
* A required host is checked per integration (`kafka.host`, `mariadb.host`, `mongodb.hosts`, `redis.host`, `minio.sites`).
* Pods restart automatically when their ConfigMap or Secret content changes (checksum annotations).
* Secrets are generated from values. For GitOps, keep credentials in an untracked file and pass it last: `-f values.yaml -f secrets.yaml`.

## Verify

```bash
helm lint . -f examples/values-fyno-prod.yaml
helm template monitoring . -n fyno-vks-prod -f my-values.yaml | kubectl apply --dry-run=server -f -
kubectl -n fyno-vks-prod get pods
# Prometheus targets: kubectl -n fyno-vks-prod port-forward svc/prometheus 9090  ->  /targets
```
