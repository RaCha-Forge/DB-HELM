#!/usr/bin/env python3
"""
Simple Redis HA controller for Kubernetes StatefulSets.
Monitors the current master pod (If state is ready) and promotes a replica when the master is unavailable.
After promotion, the previous master is demoted to a replica of the new master.
This controller assumes a stable service selector for the master via the `role=master` label.
"""

import os
import time
from datetime import datetime

import redis
from kubernetes import client, config
from kubernetes.client.rest import ApiException


def log(message, level="INFO"):
    prefix = {
        "INFO": "ℹ",
        "SUCCESS": "✓",
        "WARNING": "⚠",
        "ERROR": "✗",
        "CRITICAL": "🚨",
    }.get(level, "•")
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] {prefix} {message}")

def timed_call(name, func, *args, **kwargs):
    start = time.time()
    try:
        result = func(*args, **kwargs)
        log(
            f"[TIMING] {name} completed in "
            f"{time.time() - start:.4f}s",
            "DEBUG"
        )
        return result
    except Exception as exc:
        log(
            f"[TIMING] {name} failed after "
            f"{time.time() - start:.4f}s : {exc}",
            "ERROR"
        )
        raise

def pod_ready(index):
    pod_name = get_pod_name(index)
    try:
        pod = k8s_core.read_namespaced_pod(
            name=pod_name,
            namespace=NAMESPACE
        )
        for condition in pod.status.conditions or []:
            if (
                condition.type == "Ready"
                and condition.status == "True"
            ):
                return True
        return False
    except ApiException as exc:
        if exc.status == 404:
            return False
        log(
            f"Failed checking pod {pod_name}: {exc}",
            "ERROR"
        )
        return True
    except Exception as exc:
        log(
            f"Unexpected error checking pod {pod_name}: {exc}",
            "ERROR"
        )
        return True
    
def parse_int(value, default):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def parse_promotable_replicas(value, replica_count):
    if not value:
        return list(range(0, replica_count + 1))

    replicas = []
    for raw in value.split(","):
        raw = raw.strip()
        if not raw:
            continue
        try:
            idx = int(raw)
            if 0 <= idx <= replica_count:
                replicas.append(idx)
            else:
                log(f"Ignored invalid promotable replica index: {raw}", "WARNING")
        except ValueError:
            log(f"Ignored non-integer promotable replica entry: {raw}", "WARNING")

    return sorted(set(replicas)) if replicas else list(range(0, replica_count + 1))


NAMESPACE = os.getenv("NAMESPACE", "default")
SERVICE_NAME = os.getenv("SERVICE_NAME", "redis-ts")
PRIMARY_HOST = os.getenv("PRIMARY_HOST", f"{SERVICE_NAME}-0-0.{SERVICE_NAME}-0")
SERVICE_HOST = os.getenv("SERVICE_HOST", f"{SERVICE_NAME}.{NAMESPACE}.svc.cluster.local")
SERVICE_PORT = parse_int(os.getenv("SERVICE_PORT", "6001"), 6001)
REDIS_PORT = parse_int(os.getenv("REDIS_PORT", "6379"), 6379)
REDIS_PASSWORD = os.getenv("REDIS_PASSWORD", "")
REPLICA_COUNT = parse_int(os.getenv("REPLICA_COUNT", "1"), 1)
PROMOTABLE_REPLICAS = parse_promotable_replicas(os.getenv("PROMOTABLE_REPLICAS", ""), REPLICA_COUNT)
CHECK_INTERVAL = parse_int(os.getenv("CHECK_INTERVAL_SECONDS", "1"), 1)
FAILOVER_THRESHOLD = parse_int(os.getenv("FAILOVER_THRESHOLD", "1"), 1)
FAILOVER_COOLDOWN = parse_int(os.getenv("FAILOVER_COOLDOWN_SECONDS", "0"), 0)
POD_NAME = os.getenv("POD_NAME", "unknown")

last_failover_time = 0
consecutive_failures = 0
current_master_index = 0
last_replication_check = 0


try:
    config.load_incluster_config()
except Exception:
    config.load_kube_config()

k8s_core = client.CoreV1Api()


def get_redis_client(host, port=REDIS_PORT):
    start = time.time()
    if '.' not in host:
        host = f"{host}.{NAMESPACE}.svc.cluster.local"
    try:
        client_obj = redis.Redis(
            host=host,
            port=port,
            password=REDIS_PASSWORD,
            socket_connect_timeout=0.1,
            socket_timeout=0.3,
            decode_responses=True,
        )
        client_obj.ping()
        log(
            f"[TIMING] Redis connect "
            f"{host}:{port} "
            f"{time.time() - start:.4f}s",
            "DEBUG"
        )
        return client_obj
    except Exception as exc:
        log(
            f"[TIMING] Redis connect FAILED "
            f"{host}:{port} "
            f"{time.time() - start:.4f}s "
            f"{exc}",
            "ERROR"
        )

        return None


def get_redis_role(client_obj):
    start = time.time()
    try:
        info = client_obj.info("replication")
        log(
            f"[TIMING] INFO replication "
            f"{time.time() - start:.4f}s",
            "DEBUG"
        )
        return info.get("role")
    except Exception as exc:
        log(
            f"[TIMING] INFO replication FAILED "
            f"{time.time() - start:.4f}s "
            f"{exc}",
            "ERROR"
        )
        return None


def get_replication_lag(client_obj):
    try:
        info = client_obj.info("replication") 
        if info.get("role") == "slave":
            lag = int(
                info.get(
                    "master_last_io_seconds_ago",
                    999999
                )
            )
            if lag < 0:
                return 999999
            return lag
        return 0
    except Exception:
        return 999999


def get_instance_host(index):
    if index == 0:
        return PRIMARY_HOST
    return f"{SERVICE_NAME}-{index}-0.{SERVICE_NAME}-{index}.{NAMESPACE}.svc.cluster.local"


def get_pod_name(index):
    return f"{SERVICE_NAME}-{index}-0"


def normalize_host(host):
    if not host:
        return ""
    return host.split(".")[0]


def same_host(left, right):
    return normalize_host(left) == normalize_host(right)


def patch_pod_label(pod_name, role):
    try:
        body = {"metadata": {"labels": {"role": role}}}
        k8s_core.patch_namespaced_pod(pod_name, NAMESPACE, body)
        log(f"Updated pod {pod_name} label role={role}", "INFO")
        return True
    except ApiException as e:
        log(f"Failed to patch pod {pod_name} label: {e}", "ERROR")
    except Exception as e:
        log(f"Unexpected error updating pod label for {pod_name}: {e}", "ERROR")
    return False


def find_existing_master():
    for index in range(0, REPLICA_COUNT + 1):
        host = get_instance_host(index)
        client_obj = get_redis_client(host)
        if client_obj and get_redis_role(client_obj) == "master":
            return index
    return None


def find_best_replica(exclude_index=None):
    best_replica = None
    best_lag = float("inf")

    for replica_index in PROMOTABLE_REPLICAS:
        if replica_index == exclude_index:
            continue

        host = get_instance_host(replica_index)
        client_obj = get_redis_client(host)
        if not client_obj:
            continue

        role = get_redis_role(client_obj)
        if role == "master":
            continue

        lag = get_replication_lag(client_obj)

        if lag >= 999999:
            log(
                f"Replica {replica_index} replication link is down, "
                f"but considering for failover",
                "WARNING"
            )
            if best_replica is None:
                best_replica = replica_index
            continue

        log(f"Replica {replica_index} lag={lag}s", "DEBUG")

        if lag < best_lag:
            best_lag = lag
            best_replica = replica_index

    if best_replica is not None:
        log(
            f"Selected replica {best_replica} for promotion",
            "INFO"
        )
    return best_replica


def demote_instance_to_replica(index, master_host):
    pod_name = get_pod_name(index)
    host = get_instance_host(index)
    client_obj = get_redis_client(host)
    if not client_obj:
        log(f"Cannot reach instance {pod_name} to demote", "WARNING")
        return False

    try:
        client_obj.replicaof(master_host, REDIS_PORT)
        patch_pod_label(pod_name, "replica")
        log(f"Demoted {pod_name} to replica of {master_host}:{REDIS_PORT}", "SUCCESS")
        return True
    except Exception as e:
        log(f"Failed to demote {pod_name}: {e}", "ERROR")
        return False


def fix_replication(active_master_index):
    log("Fixing replication for remaining replicas", "INFO")
    active_master_host = get_instance_host(active_master_index)

    for index in range(0, REPLICA_COUNT + 1):
        if index == active_master_index:
            continue

        pod_name = get_pod_name(index)
        host = get_instance_host(index)
        client_obj = get_redis_client(host)
        if not client_obj:
            log(f"Replica {pod_name} unreachable", "WARNING")
            continue

        try:
            role = get_redis_role(client_obj)
            info = client_obj.info("replication") if role == "slave" else {}
            master_host = info.get("master_host", "")

            if role == "master":
                log(f"{pod_name} is unexpectedly master, demoting", "WARNING")
                client_obj.replicaof(active_master_host, REDIS_PORT)
                patch_pod_label(pod_name, "replica")
            elif role == "slave" and not same_host(master_host, active_master_host):
                log(f"{pod_name} following wrong master {master_host}, reconfiguring", "WARNING")
                client_obj.replicaof(active_master_host, REDIS_PORT)
            else:
                log(f"{pod_name} replication is healthy", "SUCCESS")
        except Exception as e:
            log(f"Failed to fix replication for {pod_name}: {e}", "ERROR")


def promote_replica(replica_index):
    global current_master_index, last_failover_time

    replica_host = get_instance_host(replica_index)
    pod_name = get_pod_name(replica_index)
    replica_client = get_redis_client(replica_host)
    if not replica_client:
        log(f"Replica {pod_name} is unreachable", "ERROR")
        return False
    try:
        replica_client.replicaof("NO", "ONE")

        # Wait for Redis to actually complete the promotion before
        # patching the label. Patching too early causes the service
        # to route traffic here before Redis is serving as master.
        attempt = 0
        while True:
            time.sleep(0.2)
            attempt += 1
            try:
                role = get_redis_role(replica_client)
                if role == "master":
                    break
                log(
                    f"Waiting for {pod_name} to become master "
                    f"(attempt {attempt}, current role: {role})",
                    "INFO"
                )
            except Exception:
                log(
                    f"Waiting for {pod_name} to become master "
                    f"(attempt {attempt}, Redis unreachable)",
                    "WARNING"
                )

        patch_pod_label(pod_name, "master")
        log(f"Promoted {pod_name} to master", "SUCCESS")

        current_master_index = replica_index
        last_failover_time = time.time()

        return True
    except Exception as e:
        log(f"Failed to promote replica {pod_name}: {e}", "ERROR")
        return False


def main():
    global consecutive_failures
    global current_master_index
    global last_failover_time
    global last_replication_check

    log("Starting Redis HA controller", "INFO")
    log(f"Namespace: {NAMESPACE}", "INFO")
    log(f"Service: {SERVICE_NAME}", "INFO")
    log(f"Primary host: {PRIMARY_HOST}", "INFO")
    log(f"Service host: {SERVICE_HOST}:{SERVICE_PORT}", "INFO")
    log(f"Redis internal port: {REDIS_PORT}", "INFO")
    log(f"Replica count: {REPLICA_COUNT}", "INFO")
    log(f"Promotable replicas: {PROMOTABLE_REPLICAS}", "INFO")
    log(f"Check interval: {CHECK_INTERVAL}s", "INFO")
    log(f"Failover threshold: {FAILOVER_THRESHOLD}", "INFO")

    existing_master = find_existing_master()
    if existing_master is not None:
        current_master_index = existing_master
        log(
            f"Discovered current master: "
            f"{SERVICE_NAME}-{existing_master}-0",
            "INFO"
        )

    while True:
        loop_start = time.time()
        try:
            pod_name = get_pod_name(current_master_index)
            #
            # First check if pod exists.
            # If pod is deleted, skip DNS and Redis checks.
            #
            step_start = time.time()
            master_pod_ready = pod_ready(current_master_index)
            log(
                f"[TIMING] pod_ready "
                f"{time.time() - step_start:.4f}s",
                "DEBUG"
            )   
            if not master_pod_ready:
                log(
                    f"Master pod {pod_name} is not Ready",
                    "CRITICAL"
                )
                primary_is_master = False
            else:
                step_start = time.time()
                primary_host = get_instance_host(
                    current_master_index
                )
                log(
                    f"[TIMING] get_instance_host "
                    f"{time.time() - step_start:.4f}s",
                    "DEBUG"
                )
                step_start = time.time()
                primary_client = get_redis_client(
                    primary_host
                )
                log(
                    f"[TIMING] get_redis_client "
                    f"{time.time() - step_start:.4f}s",
                    "DEBUG"
                )
                step_start = time.time()
                primary_is_master = (
                    primary_client is not None
                    and get_redis_role(primary_client)
                    == "master"
                )
                log(
                    f"[TIMING] get_redis_role "
                    f"{time.time() - step_start:.4f}s",
                    "DEBUG"
                )
            if primary_is_master:
                log(
                    f"Current master "
                    f"{SERVICE_NAME}-{current_master_index}-0 "
                    f"is healthy",
                    "INFO"
                )
                if time.time() - last_replication_check > 30:
                    step_start = time.time()
                    fix_replication(current_master_index)
                    log(
                        f"[TIMING] fix_replication "
                        f"{time.time() - step_start:.4f}s",
                        "DEBUG"
                    )
                    last_replication_check = time.time()
                consecutive_failures = 0

            else:
                consecutive_failures += 1

                log(
                    f"Master check failed "
                    f"({consecutive_failures}/"
                    f"{FAILOVER_THRESHOLD})",
                    "WARNING"
                )
                if (
                    consecutive_failures >= FAILOVER_THRESHOLD
                    and time.time() - last_failover_time
                    >= FAILOVER_COOLDOWN
                ):
                    step_start = time.time()

                    best_replica = find_best_replica(
                        exclude_index=current_master_index
                    )
                    log(
                        f"[TIMING] find_best_replica "
                        f"{time.time() - step_start:.4f}s",
                        "DEBUG"
                    )
                    if best_replica is not None:

                        step_start = time.time()

                        promoted = promote_replica(
                            best_replica
                        )
                        log(
                            f"[TIMING] promote_replica "
                            f"{time.time() - step_start:.4f}s",
                            "DEBUG"
                        )
                        if promoted:
                            log(
                                f"Failover complete: "
                                f"replica {best_replica} "
                                f"is now master",
                                "SUCCESS"
                            )
                            consecutive_failures = 0
                        else:
                            log(
                                "Promotion attempt failed",
                                "ERROR"
                            )
                    else:
                        log(
                            "No healthy replica available "
                            "for promotion",
                            "ERROR"
                        )
        except Exception as exc:
            log(
                f"Unexpected error in controller loop: "
                f"{exc}",
                "ERROR"
            )
        finally:
            log(
                f"[TIMING] FULL LOOP "
                f"{time.time() - loop_start:.4f}s",
                "DEBUG"
            )
        time.sleep(CHECK_INTERVAL)

if __name__ == "__main__":
    main()
