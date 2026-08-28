#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"


# ============================================================
# Skip Helm release if already installed
#
# Default:
#   Redis/Mongo = true
#   Application  = false
# ============================================================

APPLICATION_SKIP_IF_EXISTS="${APPLICATION_SKIP_IF_EXISTS:-false}"

REDIS_CACHE_SKIP_IF_EXISTS="${REDIS_CACHE_SKIP_IF_EXISTS:-true}"
REDIS_QUEUE_SKIP_IF_EXISTS="${REDIS_QUEUE_SKIP_IF_EXISTS:-true}"
REDIS_DB_SKIP_IF_EXISTS="${REDIS_DB_SKIP_IF_EXISTS:-true}"
REDIS_TIMESERIES_SKIP_IF_EXISTS="${REDIS_TIMESERIES_SKIP_IF_EXISTS:-true}"
REDIS_LOGSTREAM_SKIP_IF_EXISTS="${REDIS_LOGSTREAM_SKIP_IF_EXISTS:-true}"
MONGODB_SKIP_IF_EXISTS="${MONGODB_SKIP_IF_EXISTS:-true}"

# ============================================================
# Helm helper
# ============================================================

helm_deploy() {
    local release="$1"
    local chart="$2"
    local enable="$3"
    local skip_if_exists="$4"

    # --------------------------------------------------------
    # Check ENABLE
    # --------------------------------------------------------
    if [[ "$enable" != "true" ]]; then
        echo "Skipping $release because ENABLE=$enable"
        return 0
    fi

    # --------------------------------------------------------
    # Check whether Helm release already exists
    # --------------------------------------------------------
    if [[ "$skip_if_exists" == "true" ]]; then

        if helm status "$release" \
            --namespace "$NAMESPACE" \
            >/dev/null 2>&1; then

            echo "Skipping $release because Helm release already exists"
            return 0
        fi
    fi

    # --------------------------------------------------------
    # Install / Upgrade
    # --------------------------------------------------------
    echo "Installing/upgrading $release..."

    helm upgrade --install "$release" "$chart" \
        --namespace "$NAMESPACE" \
        --create-namespace \
        --wait \
        --timeout 10m
}


# Set any *_ENABLE variable to false to skip that chart's values updates.
# Defaults remain true for backwards compatibility.
APPLICATION_ENABLE="${APPLICATION_ENABLE:-true}"
REDIS_CACHE_ENABLE="${REDIS_CACHE_ENABLE:-true}"
REDIS_QUEUE_ENABLE="${REDIS_QUEUE_ENABLE:-true}"
REDIS_DB_ENABLE="${REDIS_DB_ENABLE:-true}"
REDIS_TIMESERIES_ENABLE="${REDIS_TIMESERIES_ENABLE:-${REDIS_TS_ENABLE:-true}}"
REDIS_LOGSTREAM_ENABLE="${REDIS_LOGSTREAM_ENABLE:-true}"
MONGODB_ENABLE="${MONGODB_ENABLE:-${MONGO_ENABLE:-true}}"
NAMESPACE="${NAMESPACE:-fyno}"

is_enabled() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        true|1|yes|y) return 0 ;;
        false|0|no|n) return 1 ;;
        *) echo "Invalid enable flag: $1 (use true or false)" >&2; exit 1 ;;
    esac
}

require_file() {
    [[ -f "$1" ]] || { echo "Required values file not found: $1" >&2; exit 1; }
}

# ===========================
# All values file paths
# ===========================

APPLICATION_YAML_FILE="application-helm/values.yaml"
REDIS_CACHE_YAML_FILE="redis-cache-helm/values.yaml"
REDIS_QUEUE_YAML_FILE="redis-queue-helm/values.yaml"
REDIS_DB_YAML_FILE="redis-db-helm/values.yaml"
REDIS_TS_YAML_FILE="redis-timeseries-helm/values.yaml"
REDIS_LOGSTREAM_YAML_FILE="redis-logstream-helm/values.yaml"
MONGO_YAML_FILE="mongodb-helm/values.yaml"

# ===========================
# All Images
# ===========================
APPLICATION_AI_IMAGE="599626541385.dkr.ecr.ap-south-1.amazonaws.com/fyno/il-ecr-sancharv2-smartservice-du:26-2-5-17"
APPLICATION_ANALYTICS_IMAGE="599626541385.dkr.ecr.ap-south-1.amazonaws.com/fyno/il-ecr-sancharv2-analytics-du:prod-8263f398"
APPLICATION_BACKEND_IMAGE="599626541385.dkr.ecr.ap-south-1.amazonaws.com/fyno/il-ecr-sancharv2-backend-du:26-2-5-10"
APPLICATION_FRONTEND_IMAGE="599626541385.dkr.ecr.ap-south-1.amazonaws.com/fyno/il-ecr-sancharv2-frontend-du:26-2-5-11"
APPLICATION_PDF_IMAGE="599626541385.dkr.ecr.ap-south-1.amazonaws.com/fyno/gotenberg:v8.29.1"
APPLICATION_INAPP_IMAGE="599626541385.dkr.ecr.ap-south-1.amazonaws.com/fyno/il-ecr-sancharv2-smartapiservice-du:prod-f27cca5b"
APPLICATION_MONITOR_IMAGE="599626541385.dkr.ecr.ap-south-1.amazonaws.com/fyno/il-ecr-sancharv2-backend-du:26-2-5-10"
APPLICATION_LICENSE_IMAGE="599626541385.dkr.ecr.ap-south-1.amazonaws.com/fyno/il-ecr-sancharv2-licenseservice-du:prod-1a14c139"
APPLICATION_TRINO_IMAGE="599626541385.dkr.ecr.ap-south-1.amazonaws.com/fyno/trino:latest"

REDIS_IMAGE="599626541385.dkr.ecr.ap-south-1.amazonaws.com/fyno/redis:8.6.3"
ENVOY_IMAGE="envoyproxy/envoy:v1.30.0"
REDIS_HA_CONTROLLER_IMAGE="599626541385.dkr.ecr.ap-south-1.amazonaws.com/fyno/mongo:ha-python"

# MONGO_REGISTRY="599626541385.dkr.ecr.ap-south-1.amazonaws.com"
# MONGO_REPOSITORY="fyno/mongo"
# MONGO_TAG="8.0.5"
MONGO_REGISTRY="docker.io"
MONGO_REPOSITORY="library/mongo"
MONGO_TAG="8.0.5"


# ===========================
# Application environment
# ===========================
# These values are written to application-helm/values.yaml when enabled.
APPLICATION_NAMESPACE="${APPLICATION_NAMESPACE:-$NAMESPACE}"

# ===========================
# Redis Cache environment
# ===========================
REDIS_CACHE_PASS="${REDIS_CACHE_PASS:-qwertyuiop}"
REDIS_CACHE_PORT="${REDIS_CACHE_PORT:-6001}"
REDIS_CACHE_STORAGE_CLASS="${REDIS_CACHE_STORAGE_CLASS:-standard}"
REDIS_CACHE_MIN_CPU="${REDIS_CACHE_MIN_CPU:-1}"
REDIS_CACHE_MAX_CPU="${REDIS_CACHE_MAX_CPU:-1}"
REDIS_CACHE_MIN_MEM="${REDIS_CACHE_MIN_MEM:-1Gi}"
REDIS_CACHE_MAX_MEM="${REDIS_CACHE_MAX_MEM:-2Gi}"
REDIS_CACHE_PVC="${REDIS_CACHE_PVC:-10Gi}"
REDIS_CACHE_MAX_MEMORY="${REDIS_CACHE_MAX_MEMORY:-7gb}"

# ===========================
# Redis Queue environment
# ===========================
REDIS_QUEUE_PASS="${REDIS_QUEUE_PASS:-Redis@fyno}"
REDIS_QUEUE_PORT="${REDIS_QUEUE_PORT:-6000}"
REDIS_QUEUE_STORAGE_CLASS="${REDIS_QUEUE_STORAGE_CLASS:-standard}"
REDIS_QUEUE_MIN_CPU="${REDIS_QUEUE_MIN_CPU:-1}"
REDIS_QUEUE_MAX_CPU="${REDIS_QUEUE_MAX_CPU:-1}"
REDIS_QUEUE_MIN_MEM="${REDIS_QUEUE_MIN_MEM:-1Gi}"
REDIS_QUEUE_MAX_MEM="${REDIS_QUEUE_MAX_MEM:-2Gi}"
REDIS_QUEUE_PVC="${REDIS_QUEUE_PVC:-10Gi}"
REDIS_QUEUE_MAX_MEMORY="${REDIS_QUEUE_MAX_MEMORY:-4gb}"

# ===========================
# Redis DB environment
# ===========================
REDIS_DB_PASS="${REDIS_DB_PASS:-qazwsxedcrfv}"
REDIS_DB_STORAGE_CLASS="${REDIS_DB_STORAGE_CLASS:-standard}"
REDIS_DB_MIN_CPU="${REDIS_DB_MIN_CPU:-1}"
REDIS_DB_MAX_CPU="${REDIS_DB_MAX_CPU:-1}"
REDIS_DB_MIN_MEM="${REDIS_DB_MIN_MEM:-1Gi}"
REDIS_DB_MAX_MEM="${REDIS_DB_MAX_MEM:-2Gi}"
REDIS_DB_PVC="${REDIS_DB_PVC:-10Gi}"
REDIS_DB_MAX_MEMORY="${REDIS_DB_MAX_MEMORY:-2gb}"
REDIS_DB_PORT="${REDIS_DB_PORT:-6001}"

# ===========================
# Redis TimeSeries environment
# ===========================
REDIS_TS_PASS="${REDIS_TS_PASS:-tsqwertyuiopts}"
REDIS_TS_PORT="${REDIS_TS_PORT:-6005}"
REDIS_TS_STORAGE_CLASS="${REDIS_TS_STORAGE_CLASS:-standard}"
REDIS_TS_MIN_CPU="${REDIS_TS_MIN_CPU:-1}"
REDIS_TS_MAX_CPU="${REDIS_TS_MAX_CPU:-1}"
REDIS_TS_MIN_MEM="${REDIS_TS_MIN_MEM:-1Gi}"
REDIS_TS_MAX_MEM="${REDIS_TS_MAX_MEM:-2Gi}"
REDIS_TS_PVC="${REDIS_TS_PVC:-10Gi}"
REDIS_TS_MAX_MEMORY="${REDIS_TS_MAX_MEMORY:-4gb}"

# ===========================
# Redis LogStream environment
# ===========================
REDIS_LOGSTREAM_PASS="${REDIS_LOGSTREAM_PASS:-Redis#sjahdbckjas}"
REDIS_LOGSTREAM_PORT="${REDIS_LOGSTREAM_PORT:-6003}"
REDIS_LOGSTREAM_STORAGE_CLASS="${REDIS_LOGSTREAM_STORAGE_CLASS:-standard}"
REDIS_LOGSTREAM_MIN_CPU="${REDIS_LOGSTREAM_MIN_CPU:-1}"
REDIS_LOGSTREAM_MAX_CPU="${REDIS_LOGSTREAM_MAX_CPU:-1}"
REDIS_LOGSTREAM_MIN_MEM="${REDIS_LOGSTREAM_MIN_MEM:-1Gi}"
REDIS_LOGSTREAM_MAX_MEM="${REDIS_LOGSTREAM_MAX_MEM:-2Gi}"
REDIS_LOGSTREAM_PVC="${REDIS_LOGSTREAM_PVC:-10Gi}"
REDIS_LOGSTREAM_MAX_MEMORY="${REDIS_LOGSTREAM_MAX_MEMORY:-6gb}"

# ===========================
# MongoDB environment
# ===========================
MONGO_DB_USER="${MONGO_DB_USER:-fynodev_mongouser}"
MONGO_DB_PASSWORD="${MONGO_DB_PASSWORD:-Bw2PIzA4MI3m9zbV}"
MONGO_SERVICE_PORT="${MONGO_SERVICE_PORT:-28128}"

# ===========================
# Generic YAML value updater
#
# Usage:
#   update_yaml_value "path.to.key" "value" "file"
#
# Examples:
#   update_yaml_value "image.tag" "8.0.6" "$FILE"
#   update_yaml_value "haController.image" "python:3.12" "$FILE"
#   update_yaml_value "initJob.user.password" '"mypassword"' "$FILE"
# ===========================

update_yaml_value() {
    [[ $# -eq 3 ]] || { echo "Usage: update_yaml_value <path> <value> <file>" >&2; exit 1; }

    local path="$1"
    local value="$2"
    local file="$3"

    require_file "$file"

    awk -v target="$path" -v new_value="$value" '
    BEGIN {
        split(target, target_parts, ".")

        target_depth = 0
        for (i in target_parts) {
            target_depth++
        }
    }

    # Preserve comments
    /^[[:space:]]*#/ {
        print
        next
    }

    # Preserve blank lines
    /^[[:space:]]*$/ {
        print
        next
    }

    {
        # ---------------------------------
        # Determine indentation
        # ---------------------------------

        match($0, /^[[:space:]]*/)
        indent = RLENGTH

        line = substr($0, indent + 1)

        # ---------------------------------
        # Extract YAML key
        # ---------------------------------

        if (line !~ /^[A-Za-z0-9_-]+:/) {
            print
            next
        }

        colon = index(line, ":")

        key = substr(line, 1, colon - 1)

        # ---------------------------------
        # Remove parents whose indentation
        # is greater than or equal to current
        # ---------------------------------

        while (stack_depth > 0 &&
               stack_indent[stack_depth] >= indent) {

            delete stack_key[stack_depth]
            delete stack_indent[stack_depth]

            stack_depth--
        }

        # ---------------------------------
        # Add current key to path stack
        # ---------------------------------

        stack_depth++

        stack_key[stack_depth] = key
        stack_indent[stack_depth] = indent

        # ---------------------------------
        # Check whether current YAML path
        # matches target path
        # ---------------------------------

        if (stack_depth == target_depth) {

            match_path = 1

            for (i = 1; i <= target_depth; i++) {
                if (stack_key[i] != target_parts[i]) {
                    match_path = 0
                    break
                }
            }

            # ---------------------------------
            # Replace only the value
            # ---------------------------------

            if (match_path) {

                prefix = substr($0, 1, indent + colon)

                rest = substr(line, colon + 1)

                # Preserve whitespace immediately
                # after the colon
                match(rest, /^[[:space:]]*/)
                spaces = substr(rest, 1, RLENGTH)

                comment = ""
                if (match(rest, /[[:space:]]+#/)) {
                    comment = substr(rest, RSTART)
                }

                print prefix spaces new_value comment
                next
            }
        }

        print
    }
    ' "$file" > "${file}.tmp"

    mv "${file}.tmp" "$file"
}


# ===========================
# Application Images
# ===========================
if is_enabled "$APPLICATION_ENABLE"; then
if is_enabled "$REDIS_QUEUE_ENABLE"; then
update_yaml_value "db.REDIS_QUEUE_HOST" "redis-queue.${APPLICATION_NAMESPACE}.svc.cluster.local" "$APPLICATION_YAML_FILE"
update_yaml_value "db.REDIS_QUEUE_PORT" "$REDIS_QUEUE_PORT" "$APPLICATION_YAML_FILE"
update_yaml_value "db.REDIS_QUEUE_PASSWORD" "\"$REDIS_QUEUE_PASS\"" "$APPLICATION_YAML_FILE"
fi
if is_enabled "$REDIS_CACHE_ENABLE"; then
update_yaml_value "db.REDIS_CACHE_HOST" "redis-cache.${APPLICATION_NAMESPACE}.svc.cluster.local" "$APPLICATION_YAML_FILE"
update_yaml_value "db.REDIS_CACHE_PORT" "$REDIS_CACHE_PORT" "$APPLICATION_YAML_FILE"
update_yaml_value "db.REDIS_CACHE_PASSWORD" "\"$REDIS_CACHE_PASS\"" "$APPLICATION_YAML_FILE"
fi
if is_enabled "$REDIS_DB_ENABLE"; then
update_yaml_value "db.REDIS_DB_HOST" "redis-db.${APPLICATION_NAMESPACE}.svc.cluster.local" "$APPLICATION_YAML_FILE"
update_yaml_value "db.REDIS_DB_PORT" "$REDIS_DB_PORT" "$APPLICATION_YAML_FILE"
update_yaml_value "db.REDIS_DB_PASSWORD" "\"$REDIS_DB_PASS\"" "$APPLICATION_YAML_FILE"
fi
if is_enabled "$MONGODB_ENABLE"; then
update_yaml_value "db.MONGO_DB_HOST" "mongo.${APPLICATION_NAMESPACE}.svc.cluster.local" "$APPLICATION_YAML_FILE"
update_yaml_value "db.MONGO_DB_PORT" "$MONGO_SERVICE_PORT" "$APPLICATION_YAML_FILE"
update_yaml_value "db.MONGO_DB_USER" "\"$MONGO_DB_USER\"" "$APPLICATION_YAML_FILE"
update_yaml_value "db.MONGO_DB_PASSWORD" "\"$MONGO_DB_PASSWORD\"" "$APPLICATION_YAML_FILE"
fi
update_yaml_value "services.aiservice.image" "$APPLICATION_AI_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.analytics.image" "$APPLICATION_ANALYTICS_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.api_service.image" "$APPLICATION_BACKEND_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.apiservice.image" "$APPLICATION_BACKEND_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.automationservice.image" "$APPLICATION_BACKEND_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.backend.image" "$APPLICATION_BACKEND_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.c_api.image" "$APPLICATION_BACKEND_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.c_event.image" "$APPLICATION_BACKEND_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.c_transporter.image" "$APPLICATION_BACKEND_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.callback.image" "$APPLICATION_BACKEND_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.dlr.image" "$APPLICATION_BACKEND_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.eventservice.image" "$APPLICATION_BACKEND_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.frontend.image" "$APPLICATION_FRONTEND_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.pdfservice.image" "$APPLICATION_PDF_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.inapp.image" "$APPLICATION_INAPP_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.log.image" "$APPLICATION_BACKEND_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.smart.image" "$APPLICATION_AI_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.transporter.image" "$APPLICATION_BACKEND_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.monitor.image" "$APPLICATION_MONITOR_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.logstream.image" "$APPLICATION_BACKEND_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.license.image" "$APPLICATION_LICENSE_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.trino.image" "$APPLICATION_TRINO_IMAGE" "$APPLICATION_YAML_FILE"
update_yaml_value "services.trino_worker.image" "$APPLICATION_TRINO_IMAGE" "$APPLICATION_YAML_FILE"
fi


# ===========================
# Redis Cache
# ===========================
if is_enabled "$REDIS_CACHE_ENABLE"; then
update_yaml_value "secrets.redisPassword" "\"$REDIS_CACHE_PASS\"" "$REDIS_CACHE_YAML_FILE"
update_yaml_value "services.ReplicationInitJob.image" "$REDIS_IMAGE" "$REDIS_CACHE_YAML_FILE"
update_yaml_value "services.RedisCache.image" "$REDIS_IMAGE" "$REDIS_CACHE_YAML_FILE"
update_yaml_value "services.RedisCache.port" "$REDIS_CACHE_PORT" "$REDIS_CACHE_YAML_FILE"
update_yaml_value "services.Envoy.servicePort" "$REDIS_CACHE_PORT" "$REDIS_CACHE_YAML_FILE"
update_yaml_value "storageClass.name" "\"$REDIS_CACHE_STORAGE_CLASS\"" "$REDIS_CACHE_YAML_FILE"
update_yaml_value "services.RedisCache.resources.requests.cpu" "\"$REDIS_CACHE_MIN_CPU\"" "$REDIS_CACHE_YAML_FILE"
update_yaml_value "services.RedisCache.resources.requests.memory" "\"$REDIS_CACHE_MIN_MEM\"" "$REDIS_CACHE_YAML_FILE"
update_yaml_value "services.RedisCache.resources.requests.storage" "\"$REDIS_CACHE_PVC\"" "$REDIS_CACHE_YAML_FILE"
update_yaml_value "services.RedisCache.resources.limits.cpu" "\"$REDIS_CACHE_MAX_CPU\"" "$REDIS_CACHE_YAML_FILE"
update_yaml_value "services.RedisCache.resources.limits.memory" "\"$REDIS_CACHE_MAX_MEM\"" "$REDIS_CACHE_YAML_FILE"
update_yaml_value "services.RedisCache.resources.config.maxmemory" "\"$REDIS_CACHE_MAX_MEMORY\"" "$REDIS_CACHE_YAML_FILE"
update_yaml_value "services.Envoy.image" "$ENVOY_IMAGE" "$REDIS_CACHE_YAML_FILE"
update_yaml_value "services.RedisController.image" "$REDIS_HA_CONTROLLER_IMAGE" "$REDIS_CACHE_YAML_FILE"
fi


# ===========================
# Redis Queue
# ===========================
if is_enabled "$REDIS_QUEUE_ENABLE"; then
update_yaml_value "secrets.redisPassword" "\"$REDIS_QUEUE_PASS\"" "$REDIS_QUEUE_YAML_FILE"
update_yaml_value "storageClass.name" "\"$REDIS_QUEUE_STORAGE_CLASS\"" "$REDIS_QUEUE_YAML_FILE"
update_yaml_value "services.ReplicationInitJob.image" "$REDIS_IMAGE" "$REDIS_QUEUE_YAML_FILE"
update_yaml_value "services.RedisQueue.image" "$REDIS_IMAGE" "$REDIS_QUEUE_YAML_FILE"
update_yaml_value "services.RedisQueue.port" "$REDIS_QUEUE_PORT" "$REDIS_QUEUE_YAML_FILE"
update_yaml_value "services.Envoy.servicePort" "$REDIS_QUEUE_PORT" "$REDIS_QUEUE_YAML_FILE"
update_yaml_value "services.RedisQueue.resources.requests.cpu" "\"$REDIS_QUEUE_MIN_CPU\"" "$REDIS_QUEUE_YAML_FILE"
update_yaml_value "services.RedisQueue.resources.requests.memory" "\"$REDIS_QUEUE_MIN_MEM\"" "$REDIS_QUEUE_YAML_FILE"
update_yaml_value "services.RedisQueue.resources.requests.storage" "\"$REDIS_QUEUE_PVC\"" "$REDIS_QUEUE_YAML_FILE"
update_yaml_value "services.RedisQueue.resources.limits.cpu" "\"$REDIS_QUEUE_MAX_CPU\"" "$REDIS_QUEUE_YAML_FILE"
update_yaml_value "services.RedisQueue.resources.limits.memory" "\"$REDIS_QUEUE_MAX_MEM\"" "$REDIS_QUEUE_YAML_FILE"
update_yaml_value "services.RedisQueue.resources.config.maxmemory" "\"$REDIS_QUEUE_MAX_MEMORY\"" "$REDIS_QUEUE_YAML_FILE"
update_yaml_value "services.Envoy.image" "$ENVOY_IMAGE" "$REDIS_QUEUE_YAML_FILE"
update_yaml_value "services.RedisController.image" "$REDIS_HA_CONTROLLER_IMAGE" "$REDIS_QUEUE_YAML_FILE"
fi


# ===========================
# Redis DB
# ===========================
if is_enabled "$REDIS_DB_ENABLE"; then
update_yaml_value "secrets.redisPassword" "\"$REDIS_DB_PASS\"" "$REDIS_DB_YAML_FILE"
update_yaml_value "storageClass.name" "\"$REDIS_DB_STORAGE_CLASS\"" "$REDIS_DB_YAML_FILE"
update_yaml_value "services.ReplicationInitJob.image" "$REDIS_IMAGE" "$REDIS_DB_YAML_FILE"
update_yaml_value "services.RedisDB.image" "$REDIS_IMAGE" "$REDIS_DB_YAML_FILE"
update_yaml_value "services.RedisDB.port" "$REDIS_DB_PORT" "$REDIS_DB_YAML_FILE"
update_yaml_value "services.Envoy.servicePort" "$REDIS_DB_PORT" "$REDIS_DB_YAML_FILE"
update_yaml_value "services.RedisDB.resources.requests.cpu" "\"$REDIS_DB_MIN_CPU\"" "$REDIS_DB_YAML_FILE"
update_yaml_value "services.RedisDB.resources.requests.memory" "\"$REDIS_DB_MIN_MEM\"" "$REDIS_DB_YAML_FILE"
update_yaml_value "services.RedisDB.resources.requests.storage" "\"$REDIS_DB_PVC\"" "$REDIS_DB_YAML_FILE"
update_yaml_value "services.RedisDB.resources.limits.cpu" "\"$REDIS_DB_MAX_CPU\"" "$REDIS_DB_YAML_FILE"
update_yaml_value "services.RedisDB.resources.limits.memory" "\"$REDIS_DB_MAX_MEM\"" "$REDIS_DB_YAML_FILE"
update_yaml_value "services.RedisDB.resources.config.maxmemory" "\"$REDIS_DB_MAX_MEMORY\"" "$REDIS_DB_YAML_FILE"
update_yaml_value "services.Envoy.image" "$ENVOY_IMAGE" "$REDIS_DB_YAML_FILE"
update_yaml_value "services.RedisController.image" "$REDIS_HA_CONTROLLER_IMAGE" "$REDIS_DB_YAML_FILE"
fi


# ===========================
# Redis TimeSeries
# ===========================
if is_enabled "$REDIS_TIMESERIES_ENABLE"; then
update_yaml_value "secrets.redisPassword" "\"$REDIS_TS_PASS\"" "$REDIS_TS_YAML_FILE"
update_yaml_value "storageClass.name" "\"$REDIS_TS_STORAGE_CLASS\"" "$REDIS_TS_YAML_FILE"
update_yaml_value "services.ReplicationInitJob.image" "$REDIS_IMAGE" "$REDIS_TS_YAML_FILE"
update_yaml_value "services.RedisTS.image" "$REDIS_IMAGE" "$REDIS_TS_YAML_FILE"
update_yaml_value "services.RedisTS.port" "$REDIS_TS_PORT" "$REDIS_TS_YAML_FILE"
update_yaml_value "services.Envoy.servicePort" "$REDIS_TS_PORT" "$REDIS_TS_YAML_FILE"
update_yaml_value "services.RedisTS.resources.requests.cpu" "\"$REDIS_TS_MIN_CPU\"" "$REDIS_TS_YAML_FILE"
update_yaml_value "services.RedisTS.resources.requests.memory" "\"$REDIS_TS_MIN_MEM\"" "$REDIS_TS_YAML_FILE"
update_yaml_value "services.RedisTS.resources.requests.storage" "\"$REDIS_TS_PVC\"" "$REDIS_TS_YAML_FILE"
update_yaml_value "services.RedisTS.resources.limits.cpu" "\"$REDIS_TS_MAX_CPU\"" "$REDIS_TS_YAML_FILE"
update_yaml_value "services.RedisTS.resources.limits.memory" "\"$REDIS_TS_MAX_MEM\"" "$REDIS_TS_YAML_FILE"
update_yaml_value "services.RedisTS.resources.config.maxmemory" "\"$REDIS_TS_MAX_MEMORY\"" "$REDIS_TS_YAML_FILE"
update_yaml_value "services.Envoy.image" "$ENVOY_IMAGE" "$REDIS_TS_YAML_FILE"
update_yaml_value "services.RedisController.image" "$REDIS_HA_CONTROLLER_IMAGE" "$REDIS_TS_YAML_FILE"
fi


# ===========================
# Redis LogStream
# ===========================
if is_enabled "$REDIS_LOGSTREAM_ENABLE"; then
update_yaml_value "secrets.redisPassword" "\"$REDIS_LOGSTREAM_PASS\"" "$REDIS_LOGSTREAM_YAML_FILE"
update_yaml_value "storageClass.name" "\"$REDIS_LOGSTREAM_STORAGE_CLASS\"" "$REDIS_LOGSTREAM_YAML_FILE"
update_yaml_value "services.ReplicationInitJob.image" "$REDIS_IMAGE" "$REDIS_LOGSTREAM_YAML_FILE"
update_yaml_value "services.RedisLogStream.image" "$REDIS_IMAGE" "$REDIS_LOGSTREAM_YAML_FILE"
update_yaml_value "services.RedisLogStream.port" "$REDIS_LOGSTREAM_PORT" "$REDIS_LOGSTREAM_YAML_FILE"
update_yaml_value "services.Envoy.servicePort" "$REDIS_LOGSTREAM_PORT" "$REDIS_LOGSTREAM_YAML_FILE"
update_yaml_value "services.RedisLogStream.resources.requests.cpu" "\"$REDIS_LOGSTREAM_MIN_CPU\"" "$REDIS_LOGSTREAM_YAML_FILE"
update_yaml_value "services.RedisLogStream.resources.requests.memory" "\"$REDIS_LOGSTREAM_MIN_MEM\"" "$REDIS_LOGSTREAM_YAML_FILE"
update_yaml_value "services.RedisLogStream.resources.requests.storage" "\"$REDIS_LOGSTREAM_PVC\"" "$REDIS_LOGSTREAM_YAML_FILE"
update_yaml_value "services.RedisLogStream.resources.limits.cpu" "\"$REDIS_LOGSTREAM_MAX_CPU\"" "$REDIS_LOGSTREAM_YAML_FILE"
update_yaml_value "services.RedisLogStream.resources.limits.memory" "\"$REDIS_LOGSTREAM_MAX_MEM\"" "$REDIS_LOGSTREAM_YAML_FILE"
update_yaml_value "services.RedisLogStream.resources.config.maxmemory" "\"$REDIS_LOGSTREAM_MAX_MEMORY\"" "$REDIS_LOGSTREAM_YAML_FILE"
update_yaml_value "services.Envoy.image" "$ENVOY_IMAGE" "$REDIS_LOGSTREAM_YAML_FILE"
update_yaml_value "services.RedisController.image" "$REDIS_HA_CONTROLLER_IMAGE" "$REDIS_LOGSTREAM_YAML_FILE"
fi


# ===========================
# Redis Marketing
# ===========================


# ===========================
# MongoDB
# ===========================
if is_enabled "$MONGODB_ENABLE"; then
update_yaml_value "image.registry" "$MONGO_REGISTRY" "$MONGO_YAML_FILE"
update_yaml_value "image.repository" "$MONGO_REPOSITORY" "$MONGO_YAML_FILE"
update_yaml_value "image.tag" "$MONGO_TAG" "$MONGO_YAML_FILE"
update_yaml_value "service.port" "$MONGO_SERVICE_PORT" "$MONGO_YAML_FILE"
update_yaml_value "initJob.user.name" "$MONGO_DB_USER" "$MONGO_YAML_FILE"
update_yaml_value "initJob.user.password" "\"$MONGO_DB_PASSWORD\"" "$MONGO_YAML_FILE"
fi


# ===========================
# MariaDB
# ===========================


# ===========================
# Minio
# ===========================


echo "YAML values updated successfully."


# ============================================================
# Redis Cache
# ============================================================

helm_deploy \
    "redis-cache" \
    "./redis-cache-helm" \
    "$REDIS_CACHE_ENABLE" \
    "$REDIS_CACHE_SKIP_IF_EXISTS"


# ============================================================
# Redis Queue
# ============================================================

helm_deploy \
    "redis-queue" \
    "./redis-queue-helm" \
    "$REDIS_QUEUE_ENABLE" \
    "$REDIS_QUEUE_SKIP_IF_EXISTS"


# ============================================================
# Redis DB
# ============================================================

helm_deploy \
    "redis-db" \
    "./redis-db-helm" \
    "$REDIS_DB_ENABLE" \
    "$REDIS_DB_SKIP_IF_EXISTS"


# ============================================================
# Redis TimeSeries
# ============================================================

helm_deploy \
    "redis-ts" \
    "./redis-timeseries-helm" \
    "$REDIS_TIMESERIES_ENABLE" \
    "$REDIS_TIMESERIES_SKIP_IF_EXISTS"


# ============================================================
# Redis LogStream
# ============================================================

helm_deploy \
    "redis-logstream" \
    "./redis-logstream-helm" \
    "$REDIS_LOGSTREAM_ENABLE" \
    "$REDIS_LOGSTREAM_SKIP_IF_EXISTS"


# ============================================================
# MongoDB
# ============================================================

helm_deploy \
    "mongo" \
    "./mongodb-helm" \
    "$MONGODB_ENABLE" \
    "$MONGODB_SKIP_IF_EXISTS"


# ============================================================
# Application
# ============================================================

helm_deploy \
    "fyno" \
    "./application-helm" \
    "$APPLICATION_ENABLE" \
    "$APPLICATION_SKIP_IF_EXISTS"