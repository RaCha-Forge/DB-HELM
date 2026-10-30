# monitoring

One Helm chart for the whole Fyno observability stack on the on-prem VKS cluster.
Turn a data source on in your environment file (`values-<env>.yaml`) and the chart wires it up end to end:

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
| `integrations.apm.enabled` | OpenTelemetry Collector, Tempo, Tempo datasource, trace, span-metric, service-graph and runtime-metric scraping (see `docs/apm-instrumentation.md`) | APM (Overview, Application, Topology, Traces) |
| `integrations.kubernetes.enabled` | kube-state-metrics, cAdvisor scrape, workload recording rules, least-privilege RBAC | Kubernetes |

All switches are real booleans. `values.schema.json` rejects `"true"` strings and other typos before anything is applied.
Every integration is **off by default**; the example file turns them on.

## Quick start: one values file per environment

`values.yaml` holds the defaults and is never edited. Each environment has exactly one file that holds everything
that differs there: registry, storage class, hosts, ports, switches and passwords.

```bash
cp values-example.yaml values-prod.yaml        # new environment: fill in the CHANGE_ME values
helm upgrade --install monitoring . -n <namespace> -f values-prod.yaml
```

| File | Purpose | In git? |
|---|---|---|
| `values.yaml` | defaults for every setting, commented | yes, do not edit |
| `values-example.yaml` | blank template to copy | yes |
| `values-esaf-uat.yaml` | the ESAF UAT environment, including its passwords | no (ignored) |

Environment files hold passwords, so `.gitignore` excludes every `values-*.yaml` except `values-example.yaml`.
Preview a change with `--dry-run=server` (Helm 3.13+), or `--dry-run` on older Helm.

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

* `kube-state-metrics`, scoped to the release namespace through a namespaced Role, plus a small cluster-scoped role for nodes only when `integrations.kubernetes.clusterRbac` is true;
* a Prometheus ServiceAccount with `nodes/metrics` read access, a `kubernetes-cadvisor` scrape job and a `kube-state-metrics` job;
* the recording rules from `files/fyno-workloads-rules.yml`, mounted at `/etc/prometheus-rules`.

If the kubelet endpoint is not reachable from Prometheus, set `cadvisor.mode: apiserver-proxy`. Mirror the kube-state-metrics image into your registry first
(`integrations.kubernetes.kubeStateMetrics.image`).

Per-site MinIO tokens are stored in a Secret (`prometheus-minio-token`, one key per site) and referenced with `credentials_file`, so tokens never appear in the ConfigMap.
Keep them in an untracked values file.

Turn something off by flipping its switch to `false`; its exporter, scrape job, datasource and dashboard all disappear on the next upgrade.
To keep a data source but hide its dashboard, set `dashboard: false` on that block.

## APM (traces and application metrics)

`integrations.apm.enabled: true` deploys an OpenTelemetry Collector and Tempo (4-day trace retention), adds the Tempo datasource with
trace-to-logs and trace-to-metrics links, and provisions four dashboards in the **APM** folder (Overview, Application, Topology, Traces). Applications opt in individually through the
`otel-app-config` ConfigMap the chart creates. Everything, including the application side (package versions, MariaDB wrapper,
env vars for the application chart), is in [`docs/apm-instrumentation.md`](docs/apm-instrumentation.md).

## Dashboards: switch each one on or off

Every dashboard has its own switch in `values.yaml`:

```yaml
dashboards:
  redis:
    redis: true                                     # "Redis"           (from the Grafana Redis plugin)
    redis-streaming-v8: true                        # "Redis Streaming" (from the Grafana Redis plugin)
    redis-timeseries-notifications: true
    redis-timeseries-notifications-today-vs-yesterday: false   # hidden
```

* Format: `dashboards.<set>.<file name without .json>: true | false`. The set is the folder under `dashboards/` and the Grafana folder name.
* To switch a whole folder off, use the integration switch instead (`integrations.redis.dashboard: false`).
* **Adding your own dashboard:** put the JSON in `dashboards/<set>/` and run `helm upgrade`. Anything not listed under `dashboards:` is ON, so you only list a file to turn it off.
  For a brand-new folder, add it to `monitoring.dashboardSets` and `monitoring.dashboardFolder` in `templates/_helpers.tpl`.
* **Redis plugin dashboards:** "Redis" and "Redis Streaming" are read from the Grafana Redis plugin installed in the Grafana image (`integrations.redis.pluginDashboards`).
  A small init container (`redis-plugin-dashboards`) copies them next to the chart's own Redis JSON files, so they always match the installed plugin version.
  Check it with `kubectl -n <ns> logs grafana-0 -c redis-plugin-dashboards`. Set `pluginDashboards.enabled: false` to skip it.
* If you imported these two dashboards by hand earlier, delete the UI copies once (Grafana refuses a provisioned dashboard whose UID already exists as a UI dashboard).
* Provisioned dashboards are read-only; edit the JSON and upgrade.

## Taking over the running cluster (no downtime)

Object names, selectors, PVC templates and storage sizes match the manifests that are live today,
so Helm can adopt them in place.

```bash
./scripts/adopt-existing.sh monitoring fyno-vks-prod      # annotates/labels existing objects for Helm; deletes nothing
helm upgrade --install monitoring . -n fyno-vks-prod -f values-prod.yaml --dry-run
helm upgrade --install monitoring . -n fyno-vks-prod -f values-prod.yaml
```

Things to know on the first upgrade:

* Grafana datasources now come from a Secret (`grafana-datasources`). The old ConfigMap `grafana-datasource` is no longer mounted; delete it once Grafana is healthy.
* `grafana.replaceExistingDatasources: true` removes UI-created datasources named Prometheus, Loki and Redis so the provisioned ones (fixed UIDs) can take over. Dashboards reference those UIDs only.
* Dashboards are provisioned read-only. Change the JSON under `dashboards/` and upgrade; UI edits are not persisted.
* Exporter Services and the Promtail ServiceAccount were not in the original manifests; the chart now owns them.
* If the kubernetes integration was first applied by hand, `adopt-existing.sh` also adopts its objects, including the cluster-scoped RBAC.
* The chart regenerates `prometheus-config` from values. Inline tokens or passwords in the live ConfigMap are not carried over, so put them in your environment file before upgrading.
* PVCs are never touched (`volumeClaimTemplates` are identical to the running StatefulSets).

## Layout

```
monitoring/
├── Chart.yaml
├── values.yaml                 every switch and setting, commented
├── values.schema.json          type checking for values
├── dashboards/                 dashboard JSON, one folder per Grafana folder
├── values-example.yaml         copy to values-<env>.yaml, one per environment
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
* Secrets are generated from values. For GitOps, keep the environment file out of git (the default) or use `grafana.admin.existingSecret` for Grafana.

## Verify

```bash
helm lint . -f values-example.yaml
helm template monitoring . -n fyno-vks-prod -f values-prod.yaml | kubectl apply --dry-run=server -f -
kubectl -n fyno-vks-prod get pods
# Prometheus targets: kubectl -n fyno-vks-prod port-forward svc/prometheus 9090  ->  /targets
```


## Namespace-only mode (no cluster-wide rights)

Set under `integrations.kubernetes`:

| Access you have | clusterRbac | cadvisor.enabled | kubeStateMetrics.nodeMetrics |
|---|---|---|---|
| Cluster-admin | true | true | true |
| Namespace only | false | false | false |

With the namespace-only settings no ClusterRole or ClusterRoleBinding is rendered. You still get replicas, restarts,
requests/limits, HPAs, services/endpoints and all other integrations; per-pod CPU/memory/network (cAdvisor) and node
state are not collected. A cluster admin can later run `kubectl apply -f files/kubernetes-cluster-rbac.yaml` and flip
the three flags to true.


## Namespace-only mode (no cluster-wide rights)

Three options under `integrations.kubernetes` decide whether anything cluster-wide is created:

| Access you have | `clusterRbac` | `cadvisor.enabled` | `kubeStateMetrics.nodeMetrics` |
|---|---|---|---|
| Cluster-admin | true | true | true |
| Namespace only | false | false | false |

Namespace-only creates no ClusterRole or ClusterRoleBinding. You keep replicas, restarts, requests/limits, HPAs and
services; you lose per-pod CPU/memory/network and node state. A cluster admin can later run
`kubectl apply -f files/kubernetes-cluster-rbac.yaml` and you flip the three options to true.

## Redis plugin and extra Redis instances

* The Grafana image can contain the Redis plugin. The data volume would hide it, so an init container copies the
  image's plugins to a scratch volume (`grafana.bundledPlugins`, on by default).
* `integrations.redis` is the main instance (datasource "Redis"). More servers go under `integrations.redis.instances`
  (one entry each); every instance shows up in the dashboard's datasource drop-down.

## Promtail and PodSecurity

Promtail reads node log files (hostPath). If the cluster default level is `baseline`, allow it for the namespace once:
`kubectl label ns <namespace> pod-security.kubernetes.io/enforce=privileged --overwrite`.
