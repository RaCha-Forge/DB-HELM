#!/usr/bin/env bash
# =============================================================================
#  apm-enable.sh - auto-instrument RUNNING Node services with OpenTelemetry.
#  No image rebuild, no Operator: an init container (the agent image) copies the agent into the pod and
#  NODE_OPTIONS loads it - the same mechanism the OpenTelemetry Operator uses, applied by this script.
#
#  Order:   mirror-image -> precheck -> backup -> preview -> apply (ONE pilot first) -> verify
#  Undo:    rollback
#
#  Usage:   bash scripts/apm-enable.sh <detect|precheck|backup|preview|apply|verify|rollback> [deployment ...]
#           detect = read-only: shows image, start command, Node / Python / Java of every Deployment
#  Without deployment names the default list below is used.
#  Settings (env vars): NS=fyno  ENVIRONMENT=uat  BACKUP_DIR=~/apm-backup  AGENT_IMAGE=<mirrored image>
#
#  One-time, on a machine with internet and push access to the registry (no build, only copy):
#    docker pull --platform linux/amd64 ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-nodejs:0.78.0
#    docker tag  ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-nodejs:0.78.0 \
#                ecpxdcnprhrbr.esafhub.com/fyno/autoinstrumentation-nodejs:0.78.0
#    docker push ecpxdcnprhrbr.esafhub.com/fyno/autoinstrumentation-nodejs:0.78.0
# =============================================================================
set -euo pipefail

NS="${NS:-fyno}"
ENVIRONMENT="${ENVIRONMENT:-uat}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/apm-backup}"
AGENT_IMAGE="${AGENT_IMAGE:-ecpxdcnprhrbr.esafhub.com/fyno/autoinstrumentation-nodejs:0.78.0}"
AGENT_DIR="/otel-auto-instrumentation-nodejs"
NODE_REQUIRE="--require ${AGENT_DIR}/autoinstrumentation.js"

# Node services (the shared backend image, plus inapp). Python / gotenberg / trino / docs / frontend are left out.
DEFAULT_SERVICES="fyno-api-service-service fyno-apiservice-service fyno-automationservice-service fyno-backend-service
fyno-c-api-service fyno-c-event-service fyno-c-transporter-service fyno-callback-service fyno-dlr-service
fyno-eventservice-service fyno-inapp-service fyno-log-service fyno-logstream-service fyno-transporter-service"

action="${1:-help}"; [ $# -gt 0 ] && shift || true
SERVICES="${*:-$DEFAULT_SERVICES}"
K="${KUBECTL:-kubectl} -n $NS"
SPEC=/spec/template/spec

svc_name() { local n="${1#fyno-}"; echo "${n%-service}"; }                 # fyno-log-service -> log-service
jp() { $K get deploy "$1" -o jsonpath="$2" 2>/dev/null || true; }          # empty when the field is absent
already_on() { [ -n "$(jp "$1" '{.spec.template.spec.initContainers[?(@.name=="otel-agent-copy")].name}')" ]; }

# Appends to a list, creating the list first when the Deployment does not have it yet.
add_to() {   # $1 service  $2 jsonpath of the list  $3 json path of the list  $4 json element
  if [ -z "$(jp "$1" "$2")" ]; then printf '{"op":"add","path":"%s","value":[%s]}' "$3" "$4"
  else printf '{"op":"add","path":"%s/-","value":%s}' "$3" "$4"; fi
}

build_patch() {   # $1 deployment
  local s="$1" name ops node_opts idx names
  name="$(svc_name "$s")"
  ops=()
  ops+=("$(add_to "$s" '{.spec.template.spec.initContainers}' "$SPEC/initContainers" \
    '{"name":"otel-agent-copy","image":"'"$AGENT_IMAGE"'","command":["cp","-r","/autoinstrumentation/.","'"$AGENT_DIR"'/"],"volumeMounts":[{"name":"otel-agent","mountPath":"'"$AGENT_DIR"'"}],"resources":{"requests":{"cpu":"10m","memory":"32Mi"},"limits":{"memory":"128Mi"}},"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}')")
  ops+=("$(add_to "$s" '{.spec.template.spec.volumes}' "$SPEC/volumes" '{"name":"otel-agent","emptyDir":{}}')")
  ops+=("$(add_to "$s" '{.spec.template.spec.containers[0].volumeMounts}' "$SPEC/containers/0/volumeMounts" \
    '{"name":"otel-agent","mountPath":"'"$AGENT_DIR"'","readOnly":true}')")
  ops+=('{"op":"add","path":"'"$SPEC"'/containers/0/env/-","value":{"name":"OTEL_SERVICE_NAME","value":"'"$name"'"}}')
  ops+=('{"op":"add","path":"'"$SPEC"'/containers/0/env/-","value":{"name":"POD_NAME","valueFrom":{"fieldRef":{"fieldPath":"metadata.name"}}}}')
  ops+=('{"op":"add","path":"'"$SPEC"'/containers/0/env/-","value":{"name":"OTEL_RESOURCE_ATTRIBUTES","value":"k8s.namespace.name='"$NS"',k8s.pod.name=$(POD_NAME),deployment.environment='"$ENVIRONMENT"'"}}')
  # NODE_OPTIONS: keep whatever the Deployment already sets (e.g. --max-old-space-size) and append the agent
  node_opts="$(jp "$s" '{.spec.template.spec.containers[0].env[?(@.name=="NODE_OPTIONS")].value}')"
  if [ -n "$node_opts" ]; then
    names="$(jp "$s" '{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}')"
    idx=$(( $(printf '%s\n' "$names" | grep -nx NODE_OPTIONS | head -1 | cut -d: -f1) - 1 ))
    ops+=('{"op":"replace","path":"'"$SPEC"'/containers/0/env/'"$idx"'/value","value":"'"$node_opts $NODE_REQUIRE"'"}')
  else
    ops+=('{"op":"add","path":"'"$SPEC"'/containers/0/env/-","value":{"name":"NODE_OPTIONS","value":"'"$NODE_REQUIRE"'"}}')
  fi
  ops+=('{"op":"add","path":"'"$SPEC"'/containers/0/envFrom/-","value":{"configMapRef":{"name":"otel-app-config","optional":true}}}')
  local IFS=,; printf '[%s]' "${ops[*]}"
}

case "$action" in

detect)
  # Read-only. Which runtime does each Deployment really run? (decides how, or whether, to instrument it)
  ALL="${*:-$($K get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -vE '^(istio|kube-state|otel-collector|.*-exporter$|phpmyadmin)')}"
  for s in $ALL; do
    echo "=== $s"
    echo "  image:   $($K get deploy "$s" -o jsonpath='{.spec.template.spec.containers[0].image}')"
    echo "  spec:    command=$($K get deploy "$s" -o jsonpath='{.spec.template.spec.containers[0].command}') args=$($K get deploy "$s" -o jsonpath='{.spec.template.spec.containers[0].args}')"
    $K exec "deploy/$s" -c "$($K get deploy "$s" -o jsonpath='{.spec.template.spec.containers[0].name}')" -- sh -c '
      c=$(tr "\000" " " </proc/1/cmdline 2>/dev/null | cut -c1-110)
      n=$(command -v node >/dev/null 2>&1 && node -v 2>&1)
      p=$(command -v python3 >/dev/null 2>&1 && python3 -V 2>&1)
      j=$(command -v java >/dev/null 2>&1 && java -version 2>&1 | grep -m1 " version ")
      if ls /lib/ld-musl* >/dev/null 2>&1; then l=musl; else l=glibc; fi
      echo "  running: pid1=[$c]"
      echo "  runtime: node=${n:--}  python=${p:--}  java=${j:--}  libc=$l"
      ps -eo args 2>/dev/null | grep -E "node |python|java " | grep -v grep | head -3 | cut -c1-110 | sed "s/^/  process: /"
    ' 2>&1 | sed 's/^/  /;s/^    /  /' | head -12 || echo "  (no shell in this image)"
  done
  ;;

precheck)
  echo "== Collector"
  $K get svc otel-collector
  $K get pods | grep -E "otel-collector|tempo" || true
  $K get cm otel-app-config >/dev/null && echo "ConfigMap otel-app-config: present"
  echo; echo "== NetworkPolicies (anything that could block traffic to the collector, port 4318)"
  $K get networkpolicy 2>&1 | head -20
  echo; echo "== Agent image: can the cluster pull it, and is the agent inside?  ($AGENT_IMAGE)"
  $K delete pod otel-agent-check --ignore-not-found >/dev/null 2>&1 || true
  if $K run otel-agent-check --image="$AGENT_IMAGE" --restart=Never --rm -i --command -- ls /autoinstrumentation 2>&1 | head -12; then :; fi
  echo; echo "== Per service: Node version (needs >= 18.19), existing NODE_OPTIONS, container name"
  for s in $SERVICES; do
    nv=$($K exec "deploy/$s" -- node -v 2>/dev/null || echo "node ?")
    no=$($K exec "deploy/$s" -- printenv NODE_OPTIONS 2>/dev/null || echo "-")
    nr=$($K exec "deploy/$s" -- sh -c 'if [ -n "$NEWRELIC_KEY" ]; then echo SET; else echo empty; fi' 2>/dev/null || echo "?")
    printf '  %-34s %-10s NODE_OPTIONS=%-30s NEWRELIC_KEY=%-6s container=%s\n' "$s" "$nv" "$no" "$nr" "$($K get deploy "$s" -o jsonpath='{.spec.template.spec.containers[*].name}')"
  done
  echo; echo "Two things to check above: the 'ls' shows 'autoinstrumentation.js' and 'node_modules'; NEWRELIC_KEY should be 'empty'."
  ;;

backup)
  dir="$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$dir"
  for s in $SERVICES; do $K get deploy "$s" -o yaml > "$dir/$s.yaml"; echo "saved $dir/$s.yaml"; done
  helm -n "$NS" get values fyno > "$dir/helm-values-fyno.yaml" 2>/dev/null && echo "saved helm values of release fyno" || true
  ln -sfn "$dir" "$BACKUP_DIR/latest"
  echo; echo "Backup: $dir   (restore one service:  kubectl -n $NS replace --force -f $dir/<name>.yaml)"
  ;;

preview)
  for s in $SERVICES; do
    echo "================ $s  (OTEL_SERVICE_NAME=$(svc_name "$s"))"
    if already_on "$s"; then echo "already instrumented - nothing to do"; continue; fi
    diff <($K get deploy "$s" -o yaml) <($K patch deploy "$s" --type=json -p "$(build_patch "$s")" --dry-run=server -o yaml) || true
  done
  echo; echo "Nothing was changed (server-side dry run)."
  ;;

apply)
  [ -e "$BACKUP_DIR/latest" ] || { echo "No backup found. Run:  bash $0 backup $SERVICES"; exit 1; }
  for s in $SERVICES; do
    if [ ! -f "$BACKUP_DIR/latest/$s.yaml" ]; then echo "No backup for $s in $BACKUP_DIR/latest - run backup for it first"; exit 1; fi
    if already_on "$s"; then echo "skip $s (already instrumented)"; continue; fi
    echo ">>> patching $s"
    $K patch deploy "$s" --type=json -p "$(build_patch "$s")"
    if ! $K rollout status "deploy/$s" --timeout=240s; then
      echo "!!! $s did not become ready. Undo with:  bash $0 rollback $s"; exit 1
    fi
  done
  echo; echo "Done. Send some traffic, wait 1-2 minutes, then:  bash $0 verify $SERVICES"
  ;;

verify)
  for s in $SERVICES; do
    ready=$($K get deploy "$s" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')
    on=$(already_on "$s" && echo APM-on || echo APM-off)
    printf '  %-34s ready %-5s %s\n' "$s" "$ready" "$on"
    $K logs "deploy/$s" --tail=40 2>/dev/null | grep -iE "opentelemetry|otel|cannot find module" | tail -3 | sed 's/^/      log: /' || true
  done
  echo; echo "== Collector log (last lines)"; $K logs deploy/otel-collector --tail=8
  echo; echo "== Services seen by Prometheus"
  $K exec prometheus-0 -- wget -qO- 'http://localhost:9090/api/v1/label/service_name/values?match[]=traces_span_metrics_calls_total' 2>/dev/null || echo "(open Grafana: APM > Overview)"
  echo
  ;;

rollback)
  for s in $SERVICES; do
    echo ">>> rolling back $s"; $K rollout undo "deploy/$s"; $K rollout status "deploy/$s" --timeout=240s
  done
  ;;

*)
  sed -n 2,20p "$0"
  ;;
esac
