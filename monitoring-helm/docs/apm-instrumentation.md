# APM: traces and application metrics (OpenTelemetry)

`integrations.apm.enabled: true` deploys the receiving side. Each application then sends its traces to it
when its own APM switch is on.

```
application pods ──OTLP/HTTP──► otel-collector ──sampled traces──► tempo (4 days) ──► Grafana
                                      │
                                      ├─ span metrics (rate / errors / latency, per endpoint and per pod, 100% of requests) ─► Prometheus ─► Grafana
                                      ├─ service graph (who calls whom, incl. databases) ─► Prometheus ─► Service map
                                      └─ Node.js runtime metrics (event loop, heap, GC) per pod ─► Prometheus ─► Grafana
application logs (winston JSON with trace_id) ─► Promtail ─► Loki ─► Grafana   (click trace_id <-> trace)
```

## 1. What the chart deploys

| Object | Purpose | Default size |
|---|---|---|
| `otel-collector` (Deployment, Service) | Receives OTLP on 4317 (gRPC) and 4318 (HTTP), turns spans into metrics, keeps all errors, all slow traces and 10% of the rest | 0.25-1 CPU, 512Mi-2Gi |
| `tempo` (StatefulSet, 60Gi PVC) | Stores traces, `retention: 96h` | 0.5-2 CPU, 1-3Gi |
| `otel-app-config` (ConfigMap) | OTEL_* variables for application pods | - |
| Grafana datasource `Tempo` | Search, trace view, links to logs and metrics | - |
| Dashboards, folder **APM** (4) | Overview, Application, Topology, Traces (see section 7) | - |
| Prometheus jobs `otel-spanmetrics`, `otel-collector`, `tempo` | Scrape the three components | - |

The Collector runs **one replica on purpose**: tail sampling must see every span of a trace.

Mirror the two images into your registry first (repository paths in `values.yaml` are prefixed with `global.imageRegistry`):

```bash
for i in otel/opentelemetry-collector-contrib:0.161.0 grafana/tempo:2.10.10; do
  docker pull --platform linux/amd64 $i
  docker tag  $i ecpxdcnprhrbr.esafhub.com/$i
  docker push     ecpxdcnprhrbr.esafhub.com/$i
done
```

## 2. Turn it on for a service (application chart)

Per service, behind your own `apm.enabled` switch:

```yaml
{{- if .Values.apm.enabled }}
envFrom:
  - configMapRef: { name: otel-app-config }          # endpoint, sampler, propagators, noisy instrumentations off
env:
  - { name: OTEL_SERVICE_NAME, value: {{ $name | quote }} }     # e.g. backend, api, transporter
  - name: POD_NAME
    valueFrom: { fieldRef: { fieldPath: metadata.name } }
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: k8s.namespace.name={{ .Release.Namespace }},k8s.pod.name=$(POD_NAME),deployment.environment={{ .Values.env | default "prod" }}
  - name: NODE_OPTIONS
    value: --require @opentelemetry/auto-instrumentations-node/register
{{- end }}
```

* The ConfigMap lives in the monitoring release namespace; use the same namespace as the application (`fyno-vks-prod`).
* `OTEL_SERVICE_NAME` is the name you will see in every panel. `k8s.pod.name` / `k8s.namespace.name` are what the trace-to-logs link uses.
* Keep `NEWRELIC_KEY` empty on services that have APM on. Your `newrelic.js` disables the agent when the key is empty, so the two agents never patch the same libraries.
* `OTEL_METRICS_EXPORTER=otlp` (in `otel-app-config`) makes each pod also send Node.js runtime metrics (event loop, heap, GC) every 30s. Switch off with `integrations.apm.runtimeMetrics.enabled: false`.
* Services with `OTEL_*` set but no collector reachable keep working; spans are simply dropped.

## 2b. No image change: inject the agent (what `scripts/apm-enable.sh` does)

If the service image does not contain the OpenTelemetry packages and cannot be rebuilt, the agent is added at deploy time,
like the OpenTelemetry Operator does, without the Operator:

1. Mirror the agent image once (a copy, no build):
   `ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-nodejs:0.78.0` -> `<registry>/fyno/autoinstrumentation-nodejs:0.78.0`
2. An init container (`otel-agent-copy`) copies `/autoinstrumentation` into an emptyDir mounted at `/otel-auto-instrumentation-nodejs`.
3. `NODE_OPTIONS=--require /otel-auto-instrumentation-nodejs/autoinstrumentation.js` loads it; an existing `NODE_OPTIONS` is kept and extended.
4. Same `OTEL_SERVICE_NAME`, `POD_NAME`, `OTEL_RESOURCE_ATTRIBUTES` and `otel-app-config` as above.

`scripts/apm-enable.sh` runs the steps in order: `precheck`, `backup`, `preview`, `apply` (one pilot first), `verify`, `rollback`.

## 3. Image / package.json changes (once)

Add to `dependencies` (prod, because the runtime image uses `npm ci --omit=dev`):

```json
"@opentelemetry/api": "1.9.0",
"@opentelemetry/auto-instrumentations-node": "0.81.2"
```

* Tested together with your existing `"overrides": { "@opentelemetry/core": "2.8.0" }`.
  Newer `auto-instrumentations-node` (0.82+) needs `@opentelemetry/core` 3.x and `@opentelemetry/api` 1.10, so with that override `npm install` fails with ERESOLVE. Remove the override first if you want the latest.
* Webpack already keeps `node_modules` out of the bundle (`nodeExternals`), which is what lets the agent hook into libraries. Nothing to change in webpack or the Dockerfile.

## 4. What is traced automatically, and what is not

| Library | Result |
|---|---|
| Express / HTTP / axios | Server and client spans, `http.route` (e.g. `/users/:id`), status, errors |
| MongoDB driver, mongoose, ioredis, AWS SDK v3 (SQS, S3, Kinesis) | Client spans, trace context travels through SQS messages |
| winston | `trace_id` / `span_id` added to every JSON log line inside a request |
| **mariadb driver** | **No automatic spans.** Wrap the pool in `helpers/mysql_pool_handler.js` (below) |
| **BullMQ queues** | Not linked automatically; a job starts a new trace unless you pass the trace context in the job data |

Database wrapper (one place, covers all queries):

```js
const { trace, SpanKind, SpanStatusCode } = require("@opentelemetry/api");
const tracer = trace.getTracer("mariadb");

async function tracedQuery(pool, sql, params) {
  return tracer.startActiveSpan("mariadb query", {
    kind: SpanKind.CLIENT,                       // CLIENT is what the DB panels in the dashboard count
    attributes: { "db.system": "mariadb", "db.statement": sql.slice(0, 200) }
  }, async (span) => {
    try { return await pool.query(sql, params); }
    catch (e) { span.recordException(e); span.setStatus({ code: SpanStatusCode.ERROR }); throw e; }
    finally { span.end(); }
  });
}
```

Do not put parameter values in span attributes (personal data); the statement text with `?` placeholders is enough.

## 5. Sampling, retention, cost

* Span metrics (the rate / error / latency panels) are computed from **all** requests before sampling.
* Traces in Tempo: every error, every trace slower than `sampling.slowThresholdMs` (1s) and `sampling.normalPercent` (10%) of the rest.
  A log line of an unsampled request has a `trace_id` whose trace does not exist; Grafana then shows "trace not found". Raise `normalPercent` for more coverage.
* `retention: 96h` deletes traces after 4 days. Change it in values; the Tempo disk size (`tempo.persistence.size`) should follow.
* Disk estimate: `spans/sec x kept share x 86400 x days x ~0.7KB`. Watch `Tempo spans ingested / sec` and the PVC usage after a week, then resize.

## 6. Verify

```bash
kubectl -n fyno-vks-prod get pods -l app.kubernetes.io/component=apm
kubectl -n fyno-vks-prod logs deploy/otel-collector | tail          # no errors, "Everything is ready"
kubectl -n fyno-vks-prod port-forward svc/prometheus 9090           # query: traces_span_metrics_calls_total
```

In Grafana: **APM > APM · Overview**. Service list empty means no application is sending yet; check `OTEL_EXPORTER_OTLP_ENDPOINT` inside a pod
(`kubectl exec <pod> -- env | grep OTEL`).

## 7. The dashboards (folder APM)

The four dashboards are linked: the buttons at the top switch between them and keep the time range and the selected application.

| Dashboard | Use it to |
|---|---|
| **APM · Overview** | See all applications: rate, errors %, avg / p95 / p99, number of pods. Click an application name to open it. Slowest and failing endpoints, latency heatmap (click a dot = open that trace), recent error and slow traces, pipeline health. |
| **APM · Application** | One application. Filters: Application, Instance (pod), Endpoint, Status. Golden signals, throughput by status class, latency percentiles, per-pod comparison, endpoints table (with *time spent %*), dependencies (who it calls / who calls it), database and cache calls, external HTTP hosts, Node.js runtime per pod, pod CPU / memory, instances table, error and slow traces, application logs. |
| **APM · Topology** | Service map (applications and databases with request rate, errors and latency) and the full caller → callee table with trends. |
| **APM · Traces** | The trace explorer. Left: traces filtered by application, status, minimum duration and a free TraceQL filter. Click a Trace ID: header (duration, spans, services, error spans, start), waterfall with span details, span table with Exec bar, logs carrying the same trace id. |

Starting points: **Overview** → click a service → **Application** → click an endpoint (opens the **Traces** list for it) or a Trace ID.

### Filter box in the Trace explorer

The `Filter (TraceQL)` box accepts a condition on the same span, for example `span.http.route = "/users/:id"`, `span.http.response.status_code >= 500`,
`resource.k8s.pod.name = "backend-7d9f-abc"`. Leave `true` for no extra filter.

### What differs from commercial APM tools

* Span table: **Exec (ms)** is shown with a bar relative to the longest span. **Exec (%)** and **Self (ms)** as separate columns are not available in Grafana; the waterfall shows each span's own bar and duration.
* **Infrastructure** (CPU, memory, restarts of the pods) comes from the kubernetes dashboards; the Application dashboard shows pod CPU and memory when the kubernetes integration is on.
* Logs and traces are linked in both directions (log line → trace, span → logs), but only for traces that were **sampled** (errors, slow, and 10% of the rest).
* Per-pod splits add a `k8s_pod_name` label to the request metrics. Set `integrations.apm.spanMetrics.perInstance: false` if Prometheus series count becomes a concern; the Instance filter and per-instance panels then show nothing.
