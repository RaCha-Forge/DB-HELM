# Redis HA Controller Documentation

This document explains the full `redis_ha_controller.py` script in plain language, piece by piece. Each section shows the code snippet and then explains what it does. The goal is to make the script understandable even to non-technical readers.

---

## 1. Script Purpose

The `redis_ha_controller.py` script is an automated controller for Redis high availability (HA). It runs inside Kubernetes and does these things:

- watches the current Redis primary server
- detects when the primary fails
- promotes a replica to primary when needed
- updates Kubernetes service routing so clients connect to the correct Redis instance
- handles leader election if multiple controller copies are running

It is written in Python and uses the Redis and Kubernetes Python libraries.

---

## 2. Header and Imports

```python
#!/usr/bin/env python3
"""
Redis HA Controller with Leader Election
Monitors Redis primary/replica health and performs automatic failover with zero downtime
Supports multiple controller replicas with leader election
"""
import time
import os
import sys
import redis
from kubernetes import client, config
from kubernetes.client.rest import ApiException
from datetime import datetime, timezone
```

### Explanation

- `#!/usr/bin/env python3` tells the operating system to run this script with Python 3.
- The block comment describes the purpose of the script.
- The imports bring in required libraries:
  - `time`, `os`, and `sys` are standard Python modules.
  - `redis` is the Redis client library.
  - `kubernetes.client` and `kubernetes.config` are used to talk to the Kubernetes API.
  - `ApiException` is used to catch Kubernetes API errors.
  - `datetime` is used for timestamps.

---

## 3. Logging Helper

```python
def log(message, level="INFO"):
    """Log with timestamp"""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    prefix = {
        "INFO": "ℹ",
        "SUCCESS": "✓",
        "WARNING": "⚠",
        "ERROR": "✗",
        "CRITICAL": "🚨",
        "DEBUG": "🔍"
    }.get(level, "•")
    print(f"[{timestamp}] {prefix} {message}")
```

### Explanation

- This function prints messages with a timestamp and a symbol for the log level.
- It makes all script output easier to read and understand.
- Example output: `[2026-06-03 12:00:00] ✓ Replica promoted successfully`

---

## 4. Configuration Section

```python
NAMESPACE = os.getenv("NAMESPACE", "redis")
PRIMARY_HOST = os.getenv("PRIMARY_HOST", "redis-cache-0-0.redis-cache-0")
REPLICA_COUNT = int(os.getenv("REPLICA_COUNT", "1"))
PORT = int(os.getenv("REDIS_PORT", "6001"))
REDIS_PASSWORD = os.getenv("REDIS_PASSWORD", "")
SERVICE_NAME = os.getenv("SERVICE_NAME", "redis-cache")

PROMOTABLE_REPLICAS_STR = os.getenv("PROMOTABLE_REPLICAS", "")
if PROMOTABLE_REPLICAS_STR:
    PROMOTABLE_REPLICAS = [int(x.strip()) for x in PROMOTABLE_REPLICAS_STR.split(",") if x.strip()]
else:
    PROMOTABLE_REPLICAS = list(range(REPLICA_COUNT))

LEADER_ELECTION_ENABLED = os.getenv("LEADER_ELECTION_ENABLED", "true").lower() == "true"
LEASE_NAME = os.getenv("LEASE_NAME", "redis-ha-controller-lease")
POD_NAME = os.getenv("POD_NAME", "unknown")

CHECK_INTERVAL = 2
LEASE_DURATION = 15
LEASE_RENEW_DEADLINE = 10
REPLICA_SYNC_CHECK_INTERVAL = 10
FAILOVER_COOLDOWN = 5
```

### Explanation

This section reads configuration from environment variables. These values can be set in Kubernetes deployment YAML.

- `NAMESPACE`: Kubernetes namespace where Redis runs.
- `PRIMARY_HOST`: Hostname for the original primary Redis.
- `REPLICA_COUNT`: How many replica Redis instances exist.
- `PORT`: Redis port.
- `REDIS_PASSWORD`: Redis password.
- `SERVICE_NAME`: Kubernetes service name.

Promotable replicas:
- `PROMOTABLE_REPLICAS` can be empty to mean "all replicas can be promoted".
- Otherwise, it must be a comma-separated list like `0,1,2`.

Leader election and timing:
- `LEADER_ELECTION_ENABLED` controls whether multiple controllers compete.
- `LEASE_NAME` is the lease resource name used in Kubernetes.
- `POD_NAME` is the name of the current controller pod.
- `CHECK_INTERVAL` is how often the script checks Redis health.
- `LEASE_DURATION` is how long the controller lease is valid.
- `REPLICA_SYNC_CHECK_INTERVAL` is how often replica sync health is checked.
- `FAILOVER_COOLDOWN` delays follow-up failover checks.

---

## 5. State Tracking

```python
last_known_primary = None
last_failover_time = 0
consecutive_failures = {}
replica_sync_last_check = 0
failover_occurred = False
```

### Explanation

These variables store the controller’s runtime state:

- `last_known_primary`: which instance the script believes is primary.
- `last_failover_time`: when the last promotion happened.
- `consecutive_failures`: counts failures to avoid false triggers.
- `replica_sync_last_check`: tracks last time replication health was checked.
- `failover_occurred`: marks whether a failover has already happened.

---

## 6. Kubernetes Client Setup

```python
try:
    config.load_incluster_config()
except:
    config.load_kube_config()

k8s_core = client.CoreV1Api()
k8s_coord = client.CoordinationV1Api()
```

### Explanation

This initializes communication with Kubernetes.

- `load_incluster_config()` is used when the controller runs inside Kubernetes.
- If that fails, it falls back to the local kubeconfig file.
- `k8s_core` is used for normal Kubernetes resources like Services and Pods.
- `k8s_coord` is used for lease resources for leader election.

---

## 7. Leader Election

```python
def acquire_or_renew_lease():
    """Acquire or renew leadership lease"""
    if not LEADER_ELECTION_ENABLED:
        return True

    try:
        lease = k8s_coord.read_namespaced_lease(LEASE_NAME, NAMESPACE)
        
        if lease.spec.holder_identity == POD_NAME:
            lease.spec.renew_time = datetime.now(timezone.utc)
            k8s_coord.replace_namespaced_lease(LEASE_NAME, NAMESPACE, lease)
            return True
        
        if lease.spec.renew_time:
            renew_time = lease.spec.renew_time
            if hasattr(renew_time, 'timestamp'):
                renew_timestamp = renew_time.timestamp()
            else:
                renew_timestamp = time.mktime(renew_time.timetuple())
            
            if time.time() - renew_timestamp > LEASE_DURATION:
                lease.spec.holder_identity = POD_NAME
                lease.spec.acquire_time = datetime.now(timezone.utc)
                lease.spec.renew_time = datetime.now(timezone.utc)
                lease.spec.lease_duration_seconds = LEASE_DURATION
                k8s_coord.replace_namespaced_lease(LEASE_NAME, NAMESPACE, lease)
                log(f"Acquired leadership from expired lease (previous holder: {lease.spec.holder_identity})", "SUCCESS")
                return True
        
        return False

    except ApiException as e:
        if e.status == 404:
            lease = client.V1Lease(
                metadata=client.V1ObjectMeta(name=LEASE_NAME, namespace=NAMESPACE),
                spec=client.V1LeaseSpec(
                    holder_identity=POD_NAME,
                    lease_duration_seconds=LEASE_DURATION,
                    acquire_time=datetime.now(timezone.utc),
                    renew_time=datetime.now(timezone.utc),
                )
            )
            k8s_coord.create_namespaced_lease(NAMESPACE, lease)
            log("Created new lease and acquired leadership", "SUCCESS")
            return True
        log(f"Error in leader election: {e}", "ERROR")
        return False
```

### Explanation

This function ensures only one controller instance acts as the active leader.

- If leader election is disabled, it returns `True` and continues.
- If the current pod already holds the lease, it renews it.
- If another pod holds the lease but the lease has expired, this pod takes it over.
- If the lease does not exist, it creates one.
- If another active leader still holds the lease, it returns `False` and this pod waits.

This prevents two controllers from fighting over failover actions.

---

## 8. Redis Helpers

### Create Redis Connection

```python
def get_redis_client(host):
    try:
        if '.' not in host:
            host = f"{host}.{NAMESPACE}.svc.cluster.local"
        r = redis.Redis(
            host=host,
            port=PORT,
            password=REDIS_PASSWORD,
            socket_connect_timeout=1,
            socket_timeout=2,
            decode_responses=True,
        )
        r.ping()
        return r
    except Exception:
        return None
```

### Explanation

- Connects to a Redis server on the given hostname.
- Adds Kubernetes DNS suffix if needed.
- Verifies connectivity with `PING`.
- Returns a Redis client object if successful, otherwise `None`.

---

### Get Redis Role

```python
def get_redis_role(r):
    try:
        info = r.info("replication")
        return info.get("role")
    except:
        return None
```

### Explanation

- Reads Redis replication info.
- Returns whether the instance is `master` or `slave`.

---

### Get Redis Replication Info

```python
def get_redis_info(r):
    try:
        return r.info("replication")
    except:
        return {}
```

### Explanation

- Fetches full replication metadata from Redis.
- Used for deeper checks later.

---

### Check Replica Health

```python
def is_replication_healthy(r):
    try:
        info = r.info("replication")
        role = info.get("role")
        
        if role == "slave":
            master_link = info.get("master_link_status")
            master_sync_in_progress = info.get("master_sync_in_progress", 0)
            return master_link == "up" or master_sync_in_progress == 1
        return True
    except:
        return False
```

### Explanation

- If the instance is a replica, it checks whether it is connected to the master.
- A healthy replica is either fully synced or currently syncing.
- Masters are assumed healthy for replication checks.

---

### Replication Lag

```python
def get_replication_lag(r):
    try:
        info = r.info("replication")
        if info.get("role") == "slave":
            return info.get("master_last_io_seconds_ago", float('inf'))
        return 0
    except:
        return float('inf')
```

### Explanation

- Measures how far behind a replica is from its master.
- If the replica is not connected or the check fails, it returns a very large value.

---

## 9. Kubernetes Helpers

### Update Service Selector

```python
def update_service_selector(role_label, redis_index=None):
    try:
        service = k8s_core.read_namespaced_service(SERVICE_NAME, NAMESPACE)
        current_role = service.spec.selector.get("role", "")
        current_index = service.spec.selector.get("redis-index", "")
        
        new_selector = {"app": SERVICE_NAME, "role": role_label}
        if redis_index is not None:
            new_selector["redis-index"] = str(redis_index)
        
        changed = current_role != role_label or (redis_index is not None and current_index != str(redis_index))
        
        if changed:
            service.spec.selector = new_selector
            k8s_core.patch_namespaced_service(SERVICE_NAME, NAMESPACE, service)
            if redis_index is not None:
                log(f"Service '{SERVICE_NAME}' now routes to role={role_label}, redis-index={redis_index}", "SUCCESS")
            else:
                log(f"Service '{SERVICE_NAME}' now routes to role={role_label}", "SUCCESS")
            return True
        return False
    except Exception as e:
        log(f"Failed to update service: {e}", "ERROR")
        return False
```

### Explanation

- Reads the Kubernetes Service object.
- Changes the selector labels so that traffic routes to the correct Redis pod.
- The selector can target either the primary or a specific replica.
- This is how the controller moves client traffic automatically.

---

### Update Pod Label

```python
def update_pod_label(pod_name, labels):
    try:
        body = {"metadata": {"labels": labels}}
        k8s_core.patch_namespaced_pod(pod_name, NAMESPACE, body)
        return True
    except Exception as e:
        log(f"Failed to update pod labels for {pod_name}: {e}", "ERROR")
        return False
```

### Explanation

- Labels the pod in Kubernetes so other code and service selectors can identify it.
- It is used to mark current primary and replicas clearly.

---

### Replica Host Naming

```python
def get_replica_host(index):
    return f"{SERVICE_NAME}-{index}-0.{SERVICE_NAME}-{index}.{NAMESPACE}.svc.cluster.local"
```

### Explanation

- Constructs the full DNS name for a replica pod.
- Example: `redis-cache-1-0.redis-cache-1.redis.svc.cluster.local`.

---

### List All Redis Instances

```python
def get_all_redis_instances():
    instances = [(f"{SERVICE_NAME}-0-0", 0, PRIMARY_HOST)]
    for idx in range(REPLICA_COUNT):
        replica_index = idx + 1
        host = get_replica_host(replica_index)
        instances.append((f"{SERVICE_NAME}-{replica_index}-0", replica_index, host))
    return instances
```

### Explanation

- Builds a list of the primary plus all replica pods.
- The primary is always stored as index `0`.
- Replica pods use index `1, 2, ...`.

---

## 10. Failover Logic

### Promote Replica

```python
def promote_replica(replica_index):
    global last_known_primary, last_failover_time, failover_occurred
    replica_host = get_replica_host(replica_index)
    log(f"Promoting replica {replica_index} ({replica_host}) to MASTER", "CRITICAL")
    replica = get_redis_client(replica_host)
    if not replica:
        log(f"Replica {replica_index} is unreachable, cannot promote", "ERROR")
        return False

    try:
        replica.replicaof("NO", "ONE")
        log(f"Replica {replica_index} promoted to MASTER", "SUCCESS")
        update_service_selector("replica", replica_index)
        update_pod_label(f"{SERVICE_NAME}-{replica_index}-0", {
            "app": SERVICE_NAME,
            "role": "replica",
            "redis-index": str(replica_index)
        })
        last_known_primary = replica_index
        last_failover_time = time.time()
        failover_occurred = True
        time.sleep(1)
        fix_replication(exclude_index=replica_index)
        return True
    except Exception as e:
        log(f"Failed to promote replica {replica_index}: {e}", "ERROR")
        return False
```

### Explanation

- Connects to the chosen replica.
- Runs `replicaof NO ONE` on that replica, turning it into master.
- Updates the Kubernetes Service so traffic goes to the promoted replica.
- Updates pod labels to mark it as the active replica primary.
- Stores the new primary index and records the failover time.
- Calls `fix_replication()` to rewire the remaining replicas to the new primary.

---

### Demote Instance to Replica

```python
def demote_to_replica(instance_index):
    if instance_index == 0:
        host = PRIMARY_HOST
        pod_name = f"{SERVICE_NAME}-0-0"
    else:
        host = get_replica_host(instance_index)
        pod_name = f"{SERVICE_NAME}-{instance_index}-0"
    host_full = host if '.' in host else f"{host}.{NAMESPACE}.svc.cluster.local"
    log(f"Demoting instance {instance_index} ({pod_name}) to REPLICA", "INFO")
    instance = get_redis_client(host_full)
    if not instance:
        log(f"Instance {instance_index} is unreachable", "ERROR")
        return False
    try:
        service_host = f"{SERVICE_NAME}.{NAMESPACE}.svc.cluster.local"
        instance.replicaof(service_host, PORT)
        log(f"Instance {instance_index} demoted to REPLICA, following {service_host}", "SUCCESS")
        update_pod_label(pod_name, {
            "app": SERVICE_NAME,
            "role": "replica",
            "redis-index": str(instance_index)
        })
        return True
    except Exception as e:
        log(f"Failed to demote instance {instance_index}: {e}", "ERROR")
        return False
```

### Explanation

- Makes the specified Redis instance follow the current service endpoint.
- That means it stops being master and becomes a replica again.
- It is used when the old primary needs to be demoted after failover.

---

### Fix Replication State

```python
def fix_replication(exclude_index=None):
    log("Fixing replication for all replicas", "INFO")
    service_host = f"{SERVICE_NAME}.{NAMESPACE}.svc.cluster.local"
    all_instances = get_all_redis_instances()
    for pod_name, index, host in all_instances:
        if exclude_index is not None and index == exclude_index:
            continue
        host_full = host if '.' in host else f"{host}.{NAMESPACE}.svc.cluster.local"
        instance = get_redis_client(host_full)
        if not instance:
            log(f"  Instance {index} ({pod_name}) unreachable, skipping", "WARNING")
            continue
        try:
            current_role = get_redis_role(instance)
            if current_role == "master" and index != exclude_index:
                log(f"  Instance {index} is master but shouldn't be, demoting...", "WARNING")
                instance.replicaof(service_host, PORT)
                update_pod_label(pod_name, {
                    "app": SERVICE_NAME,
                    "role": "replica",
                    "redis-index": str(index)
                })
            elif current_role == "slave":
                info = get_redis_info(instance)
                master_host = info.get("master_host", "")
                if service_host not in master_host and SERVICE_NAME not in master_host:
                    log(f"  Instance {index} following wrong master ({master_host}), fixing...", "WARNING")
                    instance.replicaof(service_host, PORT)
            if not is_replication_healthy(instance):
                print(f"  ⚠ Instance {index} replication unhealthy, reconnecting...")
                instance.replicaof(service_host, PORT)
            else:
                log(f"  Instance {index} replication healthy", "SUCCESS")
        except Exception as e:
            log(f"  Failed to fix instance {index}: {e}", "ERROR")
```

### Explanation

- Ensures all replicas follow the current primary.
- Skips the current primary replica when `exclude_index` is set.
- If a replica is incorrectly master, it forces it back to replica mode.
- If a replica is following the wrong master, it rewires it.
- If replication is unhealthy, it tries to reconnect.

---

## 11. Replica Sync Check

```python
def check_replica_sync():
    global replica_sync_last_check
    current_time = time.time()
    if current_time - replica_sync_last_check < REPLICA_SYNC_CHECK_INTERVAL:
        return
    replica_sync_last_check = current_time
    log("Checking replica synchronization status...", "DEBUG")
    for idx in range(REPLICA_COUNT):
        replica_index = idx + 1
        replica_host = get_replica_host(replica_index)
        replica = get_redis_client(replica_host)
        if not replica:
            continue
        lag = get_replication_lag(replica)
        if lag > 10:
            log(f"  Replica {replica_index} has high lag: {lag}s", "WARNING")
        elif lag == float('inf'):
            log(f"  Replica {replica_index} not connected to master", "WARNING")
            fix_replication()
        else:
            log(f"  Replica {replica_index} lag: {lag}s", "SUCCESS")
```

### Explanation

- Runs only once every `REPLICA_SYNC_CHECK_INTERVAL` seconds.
- Checks whether replicas are lagging or disconnected.
- If a replica is disconnected, it calls `fix_replication()`.

---

## 12. Choosing the Best Replica

```python
def find_best_replica():
    best_replica_index = None
    best_lag = float('inf')
    for idx in range(REPLICA_COUNT):
        if idx not in PROMOTABLE_REPLICAS:
            log(f"  Replica array index {idx} (pod {SERVICE_NAME}-{idx+1}-0) is not promotable", "INFO")
            continue
        replica_index = idx + 1
        replica_host = get_replica_host(replica_index)
        replica = get_redis_client(replica_host)
        if not replica:
            continue
        lag = get_replication_lag(replica)
        log(f"  Replica array index {idx} (pod {SERVICE_NAME}-{replica_index}-0) is promotable, lag: {lag}s", "SUCCESS")
        if lag < best_lag:
            best_lag = lag
            best_replica_index = replica_index
    if best_replica_index:
        log(f"  → Selected replica pod {SERVICE_NAME}-{best_replica_index}-0 for promotion (lowest lag: {best_lag}s)", "INFO")
    return best_replica_index
```

### Explanation

- Decides which replica is best to promote.
- It checks only replicas allowed by `PROMOTABLE_REPLICAS`.
- The lowest replication lag replica wins.
- Returns the replica pod index to use for promotion.

---

## 13. Service Sync Helper

```python
def sync_pod_labels_with_redis_roles():
    try:
        master_pod_name = None
        for pod_name, index, host in get_all_redis_instances():
            client = get_redis_client(host)
            if client and get_redis_role(client) == "master":
                master_pod_name = pod_name
                break
        if not master_pod_name:
            log("No master found for service sync", "WARNING")
            return
        master_pod = k8s_core.read_namespaced_pod(master_pod_name, NAMESPACE)
        master_labels = dict(master_pod.metadata.labels) if master_pod.metadata.labels else {}
        if not master_labels:
            log(f"Master pod {master_pod_name} has no labels", "WARNING")
            return
        service = k8s_core.read_namespaced_service(SERVICE_NAME, NAMESPACE)
        current_selector = dict(service.spec.selector) if service.spec.selector else {}
        if current_selector != master_labels:
            log(f"Syncing service '{SERVICE_NAME}' to master {master_pod_name}", "INFO")
            log(f"  Current selector: {current_selector}", "DEBUG")
            log(f"  New selector (ALL pod labels): {master_labels}", "DEBUG")
            service.spec.selector = master_labels
            try:
                k8s_core.patch_namespaced_service(SERVICE_NAME, NAMESPACE, service)
                log(f"✓ Service synced to master with ALL labels: {master_labels}", "SUCCESS")
            except ApiException as e:
                if "field is immutable" in str(e):
                    log(f"Service selector immutable - requires manual recreation", "ERROR")
                else:
                    raise
    except Exception as e:
        log(f"Error syncing service to master labels: {e}", "ERROR")
```

### Explanation

- Finds the Redis pod currently acting as master.
- Reads its labels from Kubernetes.
- Updates the Service selector to match the master pod.
- This keeps the service pointed at the actual Redis master.
- It also handles the case where the service selector cannot be changed.

---

## 14. Main Monitoring Loop

This is the central part of the script. It runs forever and repeatedly checks Redis status.

```python
def main():
    global last_known_primary, consecutive_failures, failover_occurred
    primary_full = PRIMARY_HOST if '.' in PRIMARY_HOST else f"{PRIMARY_HOST}.{NAMESPACE}.svc.cluster.local"
    log("=" * 60)
    log("🚀 Redis HA Controller Started")
    log(f"   Namespace: {NAMESPACE}")
    log(f"   Primary: {primary_full}:{PORT}")
    log(f"   Replicas: {REPLICA_COUNT}")
    log(f"   Promotable Replicas: {PROMOTABLE_REPLICAS}")
    log(f"   Service: {SERVICE_NAME}")
    log(f"   Check Interval: {CHECK_INTERVAL}s")
    log(f"   Leader Election: {LEADER_ELECTION_ENABLED}")
    log(f"   Pod Name: {POD_NAME}")
    log(f"   Lease: {LEASE_NAME}")
    log("=" * 60)
    last_known_primary = 0
    while True:
        try:
            if not acquire_or_renew_lease():
                time.sleep(CHECK_INTERVAL)
                continue
            if time.time() - last_failover_time < FAILOVER_COOLDOWN:
                time.sleep(CHECK_INTERVAL)
                continue
            if last_known_primary == 0:
                current_primary_host = primary_full
            else:
                current_primary_host = get_replica_host(last_known_primary)
            primary = get_redis_client(current_primary_host)
            primary_up = primary is not None
            primary_is_master = get_redis_role(primary) == "master" if primary else False
            if not primary_up:
                consecutive_failures[0] = consecutive_failures.get(0, 0) + 1
            else:
                consecutive_failures[0] = 0
            if primary_up and primary_is_master:
                log(f"Current primary ({SERVICE_NAME}-{last_known_primary}) is master, checking for split-brain...", "DEBUG")
                if failover_occurred and last_known_primary != 0:
                    failover_occurred = False
                    log(f"Promoted replica {last_known_primary} is stable as master - failover recovery complete", "SUCCESS")
                sync_pod_labels_with_redis_roles()
                validate_and_fix_service()
                rogue_masters = []
                if last_known_primary != 0:
                    primary_0_client = get_redis_client(primary_full)
                    if primary_0_client and get_redis_role(primary_0_client) == "master":
                        log(f"  {SERVICE_NAME}-0 role: master (ROGUE!)", "DEBUG")
                        rogue_masters.append(0)
                    elif primary_0_client:
                        log(f"  {SERVICE_NAME}-0 role: slave (correct)", "DEBUG")
                for idx in range(REPLICA_COUNT):
                    replica_index = idx + 1
                    if replica_index == last_known_primary:
                        continue
                    replica_full = get_replica_host(replica_index)
                    log(f"  Checking replica {replica_index} at {replica_full}...", "DEBUG")
                    replica_client = get_redis_client(replica_full)
                    if replica_client:
                        role = get_redis_role(replica_client)
                        log(f"  Replica {replica_index} role: {role}", "DEBUG")
                        if role == "master":
                            rogue_masters.append(replica_index)
                    else:
                        log(f"  Replica {replica_index} unreachable", "DEBUG")
                if rogue_masters:
                    log(f"SPLIT-BRAIN DETECTED: Rogue masters found: {rogue_masters}", "CRITICAL")
                    for rogue_idx in rogue_masters:
                        log(f"Demoting rogue master {SERVICE_NAME}-{rogue_idx}", "WARNING")
                        demote_to_replica(rogue_idx)
                    continue
                if last_known_primary == 0:
                    update_service_selector("primary")
                    update_pod_label(f"{SERVICE_NAME}-0-0", {
                        "app": SERVICE_NAME,
                        "role": "primary",
                        "redis-index": "0"
                    })
                else:
                    update_service_selector("replica", redis_index=str(last_known_primary))
                check_replica_sync()
            elif not primary_up:
                if consecutive_failures[0] >= 2:
                    log(f"PRIMARY DOWN (consecutive failures: {consecutive_failures[0]})", "CRITICAL")
                    best_replica = find_best_replica()
                    if best_replica:
                        if promote_replica(best_replica):
                            log(f"Failover complete - Replica {best_replica} is now primary", "SUCCESS")
                            consecutive_failures[0] = 0
                    else:
                        log("No healthy replicas available for promotion", "ERROR")
            elif primary_up and not primary_is_master:
                log("SPLIT-BRAIN DETECTED: Primary reachable but not master", "WARNING")
                current_master_index = None
                rogue_masters = []
                for idx in range(REPLICA_COUNT):
                    replica_index = idx + 1
                    replica_full = get_replica_host(replica_index)
                    replica = get_redis_client(replica_full)
                    if replica and get_redis_role(replica) == "master":
                        rogue_masters.append(replica_index)
                        if current_master_index is None:
                            current_master_index = replica_index
                if current_master_index:
                    log(f"Replica {current_master_index} is currently master (failover was successful)", "INFO")
                    if len(rogue_masters) > 1:
                        log(f"Multiple rogue masters detected: {rogue_masters}", "CRITICAL")
                        for rogue_idx in rogue_masters[1:]:
                            log(f"Demoting rogue master replica {rogue_idx}", "WARNING")
                            demote_to_replica(rogue_idx)
                    log(f"Demoting {SERVICE_NAME}-0 to replica to preserve data consistency", "INFO")
                    demote_to_replica(0)
                    last_known_primary = current_master_index
                    update_service_selector("replica", redis_index=str(current_master_index))
                else:
                    if failover_occurred:
                        log(f"Failover already occurred - promoted replica is temporarily unavailable, attempting recovery", "WARNING")
                        best_replica = find_best_replica()
                        if best_replica and best_replica == last_known_primary:
                            log(f"Promoting replica {best_replica} again to restore primary status", "INFO")
                            promote_replica(best_replica)
                        elif best_replica:
                            log(f"Original promoted replica unavailable, promoting alternative replica {best_replica}", "WARNING")
                            promote_replica(best_replica)
                        else:
                            log("No healthy replicas available for recovery - waiting for promoted replica to recover", "ERROR")
                    else:
                        log("No active master found anywhere, restoring {SERVICE_NAME}-0 as primary", "WARNING")
                        primary.replicaof("NO", "ONE")
                        update_service_selector("primary")
                        update_pod_label(f"{SERVICE_NAME}-0-0", {
                            "app": SERVICE_NAME,
                            "role": "primary",
                            "redis-index": "0"
                        })
                        fix_replication(exclude_index=0)
                        last_known_primary = 0
        except Exception as e:
            log(f"Error in main loop: {e}", "ERROR")
            import traceback
            traceback.print_exc()
        time.sleep(CHECK_INTERVAL)

if __name__ == "__main__":
    main()
```

### Explanation

This is the controller’s continuous loop:

1. **Acquire leadership** if leader election is enabled.
2. **Wait if a recent failover just happened.**
3. **Determine the current primary** based on `last_known_primary`.
4. **Check if the primary is reachable and is master.**
5. If the primary is healthy:
   - ensure the Service points to the master
   - detect and correct split-brain
   - check replica synchronization
6. If the primary is down:
   - wait for 2 failed checks
   - choose the best replica and promote it
7. If the primary is reachable but not master:
   - decide whether a replica is the active master
   - preserve the promoted replica if failover already occurred
   - only restore the original primary if no failover has happened
8. On any error, log it and continue looping.

The loop sleeps for `CHECK_INTERVAL` seconds between iterations.

---

## 15. Overall Behavior Summary

The script is built to:

- avoid accidental double promotions with leader election
- promote a healthy replica when the primary is confirmed down
- keep the service selector in sync with the actual master
- correct unhealthy replicas and wrong master assignments
- be careful not to restore the old primary immediately after failover

It is designed for Kubernetes deployments where Redis is run as a StatefulSet and the controller needs to manage failover automatically.

---

## 16. Important Config Notes for Non-IT Readers

- `REPLICA_COUNT` is the number of replicas, not the number of total Redis pods.
- `PROMOTABLE_REPLICAS` is a list of replica indices, and it is zero-based.
- If `PROMOTABLE_REPLICAS` is empty, the controller may promote any replica.
- The script only promotes replicas; it does not create Redis instances.
- It relies on Kubernetes DNS names and pod labels to route traffic.

---

## 17. Example Environment Settings

```yaml
env:
  - name: NAMESPACE
    value: redis
  - name: PRIMARY_HOST
    value: redis-cache-0-0.redis-cache-0
  - name: SERVICE_NAME
    value: redis-cache
  - name: REDIS_PORT
    value: "6001"
  - name: REPLICA_COUNT
    value: "1"
  - name: PROMOTABLE_REPLICAS
    value: ""
  - name: LEADER_ELECTION_ENABLED
    value: "true"
  - name: LEASE_NAME
    value: redis-cache-ha-controller-lease
```

### Explanation

- `PROMOTABLE_REPLICAS: ""` means allow all replicas.
- `REPLICA_COUNT: "1"` means there is one replica.
- The controller will watch the primary and fail over if it fails.

---

## 18. Final Note

This script is the brain of Redis high availability in your Helm charts. It combines Redis commands and Kubernetes operations to keep Redis working even when a server fails.

If you want, I can also create a shorter checklist-style version for operators and non-technical users.
