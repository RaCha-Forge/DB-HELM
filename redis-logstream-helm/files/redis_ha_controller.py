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

# ===========================
# LOGGING HELPER
# ===========================
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

# ===========================
# CONFIGURATION
# ===========================
NAMESPACE = os.getenv("NAMESPACE", "redis")
PRIMARY_HOST = os.getenv("PRIMARY_HOST", "redis-queue-0-0.redis-queue-0")
REPLICA_COUNT = int(os.getenv("REPLICA_COUNT", "1"))
PORT = int(os.getenv("REDIS_PORT", "6000"))
REDIS_PASSWORD = os.getenv("REDIS_PASSWORD", "")
SERVICE_NAME = os.getenv("SERVICE_NAME", "redis-queue")

# Parse promotable replicas list (e.g., "0,1,2" or "" for all)
# Uses 0-based array indexing: 0=first replica, 1=second replica, etc.
PROMOTABLE_REPLICAS_STR = os.getenv("PROMOTABLE_REPLICAS", "")
if PROMOTABLE_REPLICAS_STR:
    PROMOTABLE_REPLICAS = [int(x.strip()) for x in PROMOTABLE_REPLICAS_STR.split(",") if x.strip()]
else:
    PROMOTABLE_REPLICAS = list(range(REPLICA_COUNT))  # All replicas promotable by default

LEADER_ELECTION_ENABLED = os.getenv("LEADER_ELECTION_ENABLED", "true").lower() == "true"
LEASE_NAME = os.getenv("LEASE_NAME", "redis-ha-controller-lease")
POD_NAME = os.getenv("POD_NAME", "unknown")

CHECK_INTERVAL = 2  # Check every 2 seconds for fast detection
LEASE_DURATION = 15
LEASE_RENEW_DEADLINE = 10
REPLICA_SYNC_CHECK_INTERVAL = 10  # Check replica sync every 10 seconds
FAILOVER_COOLDOWN = 5  # Wait 5 seconds after failover before next check

# ===========================
# STATE TRACKING
# ===========================
last_known_primary = None
last_failover_time = 0
consecutive_failures = {}
replica_sync_last_check = 0
failover_occurred = False  # Track if a failover has happened (to prevent re-promoting original primary)

# ===========================
# KUBERNETES CLIENT
# ===========================
try:
    config.load_incluster_config()
except:
    config.load_kube_config()

k8s_core = client.CoreV1Api()
k8s_coord = client.CoordinationV1Api()

# ===========================
# LEADER ELECTION
# ===========================
def acquire_or_renew_lease():
    """Acquire or renew leadership lease"""
    if not LEADER_ELECTION_ENABLED:
        return True

    try:
        lease = k8s_coord.read_namespaced_lease(LEASE_NAME, NAMESPACE)
        
        if lease.spec.holder_identity == POD_NAME:
            # Renew our lease
            lease.spec.renew_time = datetime.now(timezone.utc)
            k8s_coord.replace_namespaced_lease(LEASE_NAME, NAMESPACE, lease)
            return True
        
        # Check if current lease expired
        if lease.spec.renew_time:
            renew_time = lease.spec.renew_time
            if hasattr(renew_time, 'timestamp'):
                renew_timestamp = renew_time.timestamp()
            else:
                renew_timestamp = time.mktime(renew_time.timetuple())
            
            if time.time() - renew_timestamp > LEASE_DURATION:
                # Lease expired, take over
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
            # Create new lease
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

# ===========================
# REDIS HELPERS
# ===========================
def get_redis_client(host):
    """Create Redis client with connection"""
    try:
        # Add namespace suffix if not present
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

def get_redis_role(r):
    """Get Redis role (master/slave)"""
    try:
        info = r.info("replication")
        return info.get("role")
    except:
        return None

def get_redis_info(r):
    """Get detailed Redis replication info"""
    try:
        return r.info("replication")
    except:
        return {}

def is_replication_healthy(r):
    """Check if replica replication is healthy"""
    try:
        info = r.info("replication")
        role = info.get("role")
        
        if role == "slave":
            # Check if connected and syncing
            master_link = info.get("master_link_status")
            master_sync_in_progress = info.get("master_sync_in_progress", 0)
            
            # Healthy if link is up and not in initial sync, or if actively syncing
            return master_link == "up" or master_sync_in_progress == 1
        
        return True  # Master is always "healthy" from replication perspective
    except:
        return False

def get_replication_lag(r):
    """Get replication lag in seconds"""
    try:
        info = r.info("replication")
        if info.get("role") == "slave":
            return info.get("master_last_io_seconds_ago", float('inf'))
        return 0
    except:
        return float('inf')

# ===========================
# KUBERNETES HELPERS
# ===========================
def update_service_selector(role_label, redis_index=None):
    """Update service selector to point to specific role or index"""
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

def update_pod_label(pod_name, labels):
    """Update pod labels"""
    try:
        body = {"metadata": {"labels": labels}}
        k8s_core.patch_namespaced_pod(pod_name, NAMESPACE, body)
        return True
    except Exception as e:
        log(f"Failed to update pod labels for {pod_name}: {e}", "ERROR")
        return False

def get_replica_host(index):
    """Get replica hostname by index"""
    return f"{SERVICE_NAME}-{index}-0.{SERVICE_NAME}-{index}.{NAMESPACE}.svc.cluster.local"

def get_all_redis_instances():
    """Get all Redis instances (primary + replicas)"""
    instances = [(f"{SERVICE_NAME}-0-0", 0, PRIMARY_HOST)]
    
    for idx in range(REPLICA_COUNT):
        replica_index = idx + 1  # Pod index (1, 2, 3...)
        host = get_replica_host(replica_index)
        instances.append((f"{SERVICE_NAME}-{replica_index}-0", replica_index, host))
    
    return instances

# ===========================
# FAILOVER LOGIC
# ===========================
def promote_replica(replica_index):
    """Promote replica to master"""
    global last_known_primary, last_failover_time, failover_occurred
    
    replica_host = get_replica_host(replica_index)
    log(f"Promoting replica {replica_index} ({replica_host}) to MASTER", "CRITICAL")
    
    replica = get_redis_client(replica_host)
    if not replica:
        log(f"Replica {replica_index} is unreachable, cannot promote", "ERROR")
        return False

    try:
        # Make replica a master
        replica.replicaof("NO", "ONE")
        log(f"Replica {replica_index} promoted to MASTER", "SUCCESS")
        
        # Update service to point to this replica
        update_service_selector("replica", replica_index)
        
        # Update pod label - keep role as "replica" to match service selector
        update_pod_label(f"{SERVICE_NAME}-{replica_index}-0", {
            "app": SERVICE_NAME,
            "role": "replica",
            "redis-index": str(replica_index)
        })
        
        last_known_primary = replica_index
        last_failover_time = time.time()
        failover_occurred = True  # Mark that a failover has occurred
        
        # Reconfigure other replicas to follow new primary
        time.sleep(1)  # Brief pause for promotion to settle
        fix_replication(exclude_index=replica_index)
        
        return True
    except Exception as e:
        log(f"Failed to promote replica {replica_index}: {e}", "ERROR")
        return False

def demote_to_replica(instance_index):
    """Demote an instance to replica"""
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
        # Make it follow service endpoint (current primary)
        service_host = f"{SERVICE_NAME}.{NAMESPACE}.svc.cluster.local"
        instance.replicaof(service_host, PORT)
        log(f"Instance {instance_index} demoted to REPLICA, following {service_host}", "SUCCESS")
        
        # Update pod label
        update_pod_label(pod_name, {
            "app": SERVICE_NAME,
            "role": "replica",
            "redis-index": str(instance_index)
        })
        
        return True
    except Exception as e:
        log(f"Failed to demote instance {instance_index}: {e}", "ERROR")
        return False

def fix_replication(exclude_index=None):
    """Restore replication for all replicas to current primary"""
    log("Fixing replication for all replicas", "INFO")
    
    # Always use service endpoint so replicas follow current primary
    service_host = f"{SERVICE_NAME}.{NAMESPACE}.svc.cluster.local"
    
    # Fix all instances (including original primary if it's not the current primary)
    all_instances = get_all_redis_instances()
    
    for pod_name, index, host in all_instances:
        # Skip if this is the excluded index (current primary)
        if exclude_index is not None and index == exclude_index:
            continue
        
        host_full = host if '.' in host else f"{host}.{NAMESPACE}.svc.cluster.local"
        instance = get_redis_client(host_full)
        
        if not instance:
            log(f"  Instance {index} ({pod_name}) unreachable, skipping", "WARNING")
            continue

        try:
            current_role = get_redis_role(instance)
            
            # If it's a master but shouldn't be, demote it
            if current_role == "master" and index != exclude_index:
                log(f"  Instance {index} is master but shouldn't be, demoting...", "WARNING")
                instance.replicaof(service_host, PORT)
                update_pod_label(pod_name, {
                    "app": SERVICE_NAME,
                    "role": "replica",
                    "redis-index": str(index)
                })
            
            # If it's a replica, ensure it's following service
            elif current_role == "slave":
                info = get_redis_info(instance)
                master_host = info.get("master_host", "")
                
                # Check if it's following the service endpoint
                if service_host not in master_host and SERVICE_NAME not in master_host:
                    log(f"  Instance {index} following wrong master ({master_host}), fixing...", "WARNING")
                    instance.replicaof(service_host, PORT)
            
            # Verify replication health
            if not is_replication_healthy(instance):
                print(f"  ⚠ Instance {index} replication unhealthy, reconnecting...")
                instance.replicaof(service_host, PORT)
            else:
                log(f"  Instance {index} replication healthy", "SUCCESS")
                
        except Exception as e:
            log(f"  Failed to fix instance {index}: {e}", "ERROR")

def check_replica_sync():
    """Periodically check all replicas are syncing properly"""
    global replica_sync_last_check
    
    current_time = time.time()
    if current_time - replica_sync_last_check < REPLICA_SYNC_CHECK_INTERVAL:
        return
    
    replica_sync_last_check = current_time
    
    log("Checking replica synchronization status...", "DEBUG")
    
    for idx in range(REPLICA_COUNT):
        replica_index = idx + 1  # Pod index (1, 2, 3...)
        replica_host = get_replica_host(replica_index)
        replica = get_redis_client(replica_host)
        
        if not replica:
            continue
        
        lag = get_replication_lag(replica)
        if lag > 10:  # More than 10 seconds lag
            log(f"  Replica {replica_index} has high lag: {lag}s", "WARNING")
        elif lag == float('inf'):
            log(f"  Replica {replica_index} not connected to master", "WARNING")
            fix_replication()
        else:
            log(f"  Replica {replica_index} lag: {lag}s", "SUCCESS")

def find_best_replica():
    """Find the best replica to promote (lowest lag, most up-to-date, and promotable)"""
    best_replica_index = None
    best_lag = float('inf')
    
    for idx in range(REPLICA_COUNT):
        # Skip non-promotable replicas (idx is 0-based array index)
        if idx not in PROMOTABLE_REPLICAS:
            log(f"  Replica array index {idx} (pod {SERVICE_NAME}-{idx+1}-0) is not promotable", "INFO")
            continue
        
        replica_index = idx + 1  # Pod index (1, 2, 3...)
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

def sync_pod_labels_with_redis_roles():
    """Dynamically sync service selector to match current master pod's ALL labels"""
    try:
        # Find current master pod
        master_pod_name = None
        
        for pod_name, index, host in get_all_redis_instances():
            client = get_redis_client(host)
            if client and get_redis_role(client) == "master":
                master_pod_name = pod_name
                break
        
        if not master_pod_name:
            log("No master found for service sync", "WARNING")
            return
        
        # Read ALL labels from master pod (fully dynamic - no hardcoding)
        master_pod = k8s_core.read_namespaced_pod(master_pod_name, NAMESPACE)
        master_labels = dict(master_pod.metadata.labels) if master_pod.metadata.labels else {}
        
        if not master_labels:
            log(f"Master pod {master_pod_name} has no labels", "WARNING")
            return
        
        # Update service selector to match ALL master pod labels
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

def validate_and_fix_service():
    """Validate service selector matches current master's ALL labels and fix if needed"""
    # This function is now redundant since sync_pod_labels_with_redis_roles() handles everything
    # Keeping it for backwards compatibility but it just calls the sync function
    sync_pod_labels_with_redis_roles()

# ===========================
# MAIN MONITORING LOOP
# ===========================
def main():
    global last_known_primary, consecutive_failures, failover_occurred
    
    # Build full primary hostname
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
    
    last_known_primary = 0  # Start with {SERVICE_NAME}-0 as primary

    while True:
        try:
            # Check leadership
            if not acquire_or_renew_lease():
                time.sleep(CHECK_INTERVAL)
                continue

            # Check if in failover cooldown
            if time.time() - last_failover_time < FAILOVER_COOLDOWN:
                time.sleep(CHECK_INTERVAL)
                continue

            # Get all instances status
            # Check the actual current primary based on last known state
            if last_known_primary == 0:
                current_primary_host = primary_full
            else:
                current_primary_host = get_replica_host(last_known_primary)
            
            primary = get_redis_client(current_primary_host)
            primary_up = primary is not None
            primary_is_master = get_redis_role(primary) == "master" if primary else False

            # Track consecutive failures
            if not primary_up:
                consecutive_failures[0] = consecutive_failures.get(0, 0) + 1
            else:
                consecutive_failures[0] = 0

            # CASE 1: Primary is healthy and is master
            if primary_up and primary_is_master:
                # Always check if any OTHER instance is also master (split-brain detection)
                log(f"Current primary ({SERVICE_NAME}-{last_known_primary}) is master, checking for split-brain...", "DEBUG")
                
                # Reset failover flag when promoted replica is stable as master
                if failover_occurred and last_known_primary != 0:
                    failover_occurred = False
                    log(f"Promoted replica {last_known_primary} is stable as master - failover recovery complete", "SUCCESS")
                
                # Sync pod labels and validate service
                sync_pod_labels_with_redis_roles()
                validate_and_fix_service()
                
                rogue_masters = []  # Track all OTHER instances that think they're master
                
                # Check {SERVICE_NAME}-0 if it's not the current primary
                if last_known_primary != 0:
                    primary_0_client = get_redis_client(primary_full)
                    if primary_0_client and get_redis_role(primary_0_client) == "master":
                        log(f"  {SERVICE_NAME}-0 role: master (ROGUE!)", "DEBUG")
                        rogue_masters.append(0)
                    elif primary_0_client:
                        log(f"  {SERVICE_NAME}-0 role: slave (correct)", "DEBUG")
                
                # Check all replicas (excluding current primary if it's a replica)
                for idx in range(REPLICA_COUNT):
                    replica_index = idx + 1
                    
                    # Skip if this replica is the current primary
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
                
                # If any rogue masters found, demote them
                if rogue_masters:
                    log(f"SPLIT-BRAIN DETECTED: Rogue masters found: {rogue_masters}", "CRITICAL")
                    for rogue_idx in rogue_masters:
                        log(f"Demoting rogue master {SERVICE_NAME}-{rogue_idx}", "WARNING")
                        demote_to_replica(rogue_idx)
                    # Don't change last_known_primary - current master is correct
                    continue
                
                # Update service to point to current primary (may be redis-queue-0 or a replica)
                if last_known_primary == 0:
                    update_service_selector("primary")
                    update_pod_label(f"{SERVICE_NAME}-0-0", {
                        "app": SERVICE_NAME,
                        "role": "primary",
                        "redis-index": "0"
                    })
                else:
                    update_service_selector("replica", redis_index=str(last_known_primary))
                    # Pod already has correct role=replica label from StatefulSet
                
                # Check replica synchronization periodically
                check_replica_sync()

            # CASE 2: Primary is down - promote best replica
            elif not primary_up:
                if consecutive_failures[0] >= 2:  # Require 2 consecutive failures
                    log(f"PRIMARY DOWN (consecutive failures: {consecutive_failures[0]})", "CRITICAL")
                    
                    # Find best replica to promote
                    best_replica = find_best_replica()
                    
                    if best_replica:
                        if promote_replica(best_replica):
                            log(f"Failover complete - Replica {best_replica} is now primary", "SUCCESS")
                            consecutive_failures[0] = 0
                    else:
                        log("No healthy replicas available for promotion", "ERROR")

            # CASE 3: Primary is up but not master (split brain recovery)
            elif primary_up and not primary_is_master:
                log("SPLIT-BRAIN DETECTED: Primary reachable but not master", "WARNING")
                
                # Check if any replicas are acting as master
                current_master_index = None
                rogue_masters = []  # Track all master replicas
                
                for idx in range(REPLICA_COUNT):
                    replica_index = idx + 1  # Pod index (1, 2, 3...)
                    replica_full = get_replica_host(replica_index)
                    replica = get_redis_client(replica_full)
                    if replica and get_redis_role(replica) == "master":
                        rogue_masters.append(replica_index)
                        if current_master_index is None:
                            current_master_index = replica_index
                
                if current_master_index:
                    # One or more replicas are masters
                    log(f"Replica {current_master_index} is currently master (failover was successful)", "INFO")
                    
                    # If multiple rogue masters, demote extras (keep only first one)
                    if len(rogue_masters) > 1:
                        log(f"Multiple rogue masters detected: {rogue_masters}", "CRITICAL")
                        for rogue_idx in rogue_masters[1:]:  # Keep first, demote rest
                            log(f"Demoting rogue master replica {rogue_idx}", "WARNING")
                            demote_to_replica(rogue_idx)
                    
                    log(f"Demoting redis-queue-0 to replica to preserve data consistency", "INFO")
                    
                    # Demote the old primary to replica
                    demote_to_replica(0)
                    
                    # Keep the current master (replica) as primary
                    last_known_primary = current_master_index
                    
                    # Ensure service points to current master
                    update_service_selector("replica", redis_index=str(current_master_index))
                else:
                    # No active master found - IMPORTANT: Don't auto-restore if failover occurred
                    if failover_occurred:
                        # A failover already happened, the promoted replica is temporarily unavailable
                        # Promote it again instead of restoring the original primary
                        log(f"Failover already occurred - promoted replica is temporarily unavailable, attempting recovery", "WARNING")
                        best_replica = find_best_replica()
                        
                        if best_replica and best_replica == last_known_primary:
                            # The same replica that was promoted is still the intended primary
                            log(f"Promoting replica {best_replica} again to restore primary status", "INFO")
                            promote_replica(best_replica)
                        elif best_replica:
                            # Different replica is healthier, promote it instead
                            log(f"Original promoted replica unavailable, promoting alternative replica {best_replica}", "WARNING")
                            promote_replica(best_replica)
                        else:
                            # No healthy replicas at all
                            log("No healthy replicas available for recovery - waiting for promoted replica to recover", "ERROR")
                            # Don't restore original primary, wait for the promoted replica
                    else:
                        # No failover has occurred yet - safe to restore original primary
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
