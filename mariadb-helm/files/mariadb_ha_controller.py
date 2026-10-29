#!/usr/bin/env python3
import time
import pymysql
import json
import os
import logging
import socket
from datetime import datetime, timedelta
from kubernetes import client, config
from kubernetes.client.rest import ApiException

# ===========================
# CONFIG
# ===========================

# Read hosts and ports from environment variables (comma-separated)
PRIMARY_HOST = os.environ.get("PRIMARY_HOST")
REPLICA_HOSTS = os.environ.get("REPLICA_HOSTS", "").split(",")
REPLICA_PORTS = [int(p) for p in os.environ.get("REPLICA_PORTS", "").split(",") if p]
ROOT_PASS = os.environ.get("MARIADB_ROOT_PASSWORD") or os.environ.get("ROOT_PASS")
APP_USER = os.environ.get("APP_USER")
APP_PASS = os.environ.get("APP_PASS")
STATE_FILE = "/var/lib/ha-controller/ha_state.json"
NAMESPACE = os.environ.get("NAMESPACE", "mariadb")
SERVICE_NAME = os.environ.get("SERVICE_NAME", "mariadb")
# List of promotable replica indices (e.g., "0,2" for replica1 and replica3)
PROMOTABLE_REPLICAS = [int(i) for i in os.environ.get("PROMOTABLE_REPLICAS", "0").split(",") if i]
FORCED_FAILOVER_TIMEOUT = int(os.environ.get("FORCED_FAILOVER_TIMEOUT", "10"))  # Seconds until forced promotion
REPLICATION_SYNC_TIMEOUT = int(os.environ.get("REPLICATION_SYNC_TIMEOUT", "60"))
HEALTH_CHECK_INTERVAL = int(os.environ.get("HEALTH_CHECK_INTERVAL", "5"))
PRIMARY_DOWN_SINCE = None  # Track when primary went down

# Leader election config
LEADER_ELECTION_ENABLED = os.environ.get("LEADER_ELECTION_ENABLED", "true").lower() == "true"
LEASE_NAME = os.environ.get("LEASE_NAME", "mariadb-ha-controller-lease")
STATE_ANNOTATION = "mariadb-ha/current-primary"
POD_NAME = os.environ.get("POD_NAME", socket.gethostname())
LEASE_DURATION = 15  # seconds
RENEW_DEADLINE = 10  # seconds
RETRY_PERIOD = 2  # seconds

# ===========================
# LOGGING
# ===========================
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')

# ===========================
# INIT KUBERNETES
# ===========================
config.load_incluster_config()
k8s = client.CoreV1Api()
coordination_api = client.CoordinationV1Api()

# ===========================
# STATE MANAGEMENT
# ===========================
def load_state():
    try:
        lease = coordination_api.read_namespaced_lease(LEASE_NAME, NAMESPACE)
        annotation = (lease.metadata.annotations or {}).get(STATE_ANNOTATION)
        if annotation:
            return json.loads(annotation)
    except Exception as e:
        logging.debug(f"Failed to load primary state from Lease: {e}")
    try:
        with open(STATE_FILE, "r") as f:
            return json.load(f)
    except Exception as e:
        logging.error(f"Failed to load state: {e}")
        return {"primary": PRIMARY_HOST, "primary_port": REPLICA_PORTS[0] if REPLICA_PORTS else 3306}

def save_state(state):
    serialized_state = json.dumps(state)
    try:
        with open(STATE_FILE, "w") as f:
            f.write(serialized_state)
    except Exception as e:
        logging.error(f"Failed to save state: {e}")
    try:
        coordination_api.patch_namespaced_lease(
            name=LEASE_NAME,
            namespace=NAMESPACE,
            body={"metadata": {"annotations": {STATE_ANNOTATION: serialized_state}}}
        )
    except Exception as e:
        logging.error(f"Failed to persist primary state in Lease: {e}")

# ===========================
# LEADER ELECTION
# ===========================
def is_leader():
    """Check if this pod is the leader using Kubernetes Lease."""
    if not LEADER_ELECTION_ENABLED:
        return True  # No leader election, always act as leader
    
    try:
        lease = coordination_api.read_namespaced_lease(LEASE_NAME, NAMESPACE)
        if lease.spec.holder_identity == POD_NAME:
            # We are the leader, check if lease is still valid
            if lease.spec.renew_time:
                renew_time = lease.spec.renew_time
                now = datetime.now(renew_time.tzinfo)
                if now < renew_time + timedelta(seconds=LEASE_DURATION):
                    return True
        return False
    except ApiException as e:
        if e.status == 404:
            # Lease doesn't exist yet
            return False
        logging.error(f"Error checking leader status: {e}")
        return False

def acquire_or_renew_lease():
    """Try to acquire or renew the leadership lease."""
    if not LEADER_ELECTION_ENABLED:
        return True
    
    # Use RFC3339 format with microseconds and timezone
    now = datetime.utcnow().isoformat() + 'Z'
    
    try:
        # Try to get existing lease
        lease = coordination_api.read_namespaced_lease(LEASE_NAME, NAMESPACE)
        
        # Check if we can take over or renew
        if lease.spec.holder_identity == POD_NAME:
            # We hold the lease, renew it
            lease.spec.renew_time = now
            lease.spec.lease_duration_seconds = LEASE_DURATION
            coordination_api.replace_namespaced_lease(LEASE_NAME, NAMESPACE, lease)
            logging.debug(f"Renewed leadership lease")
            return True
        else:
            # Someone else holds it, check if expired
            if lease.spec.renew_time:
                renew_time = lease.spec.renew_time
                if datetime.now(renew_time.tzinfo) > renew_time + timedelta(seconds=LEASE_DURATION):
                    # Lease expired, take over
                    lease.spec.holder_identity = POD_NAME
                    lease.spec.acquire_time = now
                    lease.spec.renew_time = now
                    lease.spec.lease_duration_seconds = LEASE_DURATION
                    coordination_api.replace_namespaced_lease(LEASE_NAME, NAMESPACE, lease)
                    logging.info(f"Acquired leadership lease (took over from {lease.spec.holder_identity})")
                    return True
            return False
            
    except ApiException as e:
        if e.status == 404:
            # Lease doesn't exist, create it
            try:
                lease = client.V1Lease(
                    metadata=client.V1ObjectMeta(name=LEASE_NAME, namespace=NAMESPACE),
                    spec=client.V1LeaseSpec(
                        holder_identity=POD_NAME,
                        lease_duration_seconds=LEASE_DURATION,
                        acquire_time=now,
                        renew_time=now
                    )
                )
                coordination_api.create_namespaced_lease(NAMESPACE, lease)
                logging.info(f"Acquired leadership lease (created new)")
                return True
            except ApiException as create_error:
                if create_error.status == 409:
                    # Someone else created it first
                    logging.debug(f"Lost race to create lease")
                    return False
                logging.error(f"Error creating lease: {create_error}")
                return False
        else:
            logging.error(f"Error accessing lease: {e}")
            return False

# ===========================
# MYSQL HELPERS
# ===========================
def resolve_hostname(hostname, max_retries=3):
    """Resolve hostname to IP with retry logic for DNS flakiness"""
    for attempt in range(max_retries):
        try:
            return socket.gethostbyname(hostname)
        except socket.gaierror as e:
            if attempt < max_retries - 1:
                time.sleep(0.5)
                continue
            logging.error(f"DNS resolution failed for {hostname} after {max_retries} attempts: {e}")
            return hostname  # Fallback to hostname if resolution fails

def mysql_exec(host, port, query):
    try:
        # Pre-resolve hostname to avoid pymysql DNS timeout issues
        resolved_host = resolve_hostname(host)
        conn = pymysql.connect(
            host=resolved_host,
            port=port,
            user=APP_USER or "root",
            password=APP_PASS or ROOT_PASS,
            autocommit=True,
            connect_timeout=1,
            read_timeout=2,
            write_timeout=2
        )
        cur = conn.cursor()
        cur.execute(query)
        res = cur.fetchall()
        cur.close()
        conn.close()
        return res
    except Exception as e:
        logging.debug(f"MySQL exec error on {host}:{port}: {e}")
        return None

def sql_literal(value):
    """Escape a value for use as a single-quoted SQL string literal."""
    return pymysql.converters.escape_string(str(value))

def ensure_replication_user(master_host, master_port):
    """Ensure every promoted primary accepts replication connections."""
    password = sql_literal(ROOT_PASS or "")
    queries = [
        f"CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY '{password}';",
        f"ALTER USER 'repl'@'%' IDENTIFIED BY '{password}';",
        "GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';",
        "FLUSH PRIVILEGES;"
    ]
    for query in queries:
        if mysql_exec(master_host, master_port, query) is None:
            logging.error(f"Unable to prepare replication user on {master_host}:{master_port}")
            return False
    return True

def is_alive(host, port):
    return mysql_exec(host, port, "SELECT 1;") is not None

def get_master_status(host, port):
    """Returns (binlog_file, position)"""
    try:
        resolved_host = resolve_hostname(host)
        conn = pymysql.connect(
            host=resolved_host,
            port=port,
            user=APP_USER or "root",
            password=APP_PASS or ROOT_PASS,
            autocommit=True,
            connect_timeout=1,
            read_timeout=2,
            write_timeout=2,
            cursorclass=pymysql.cursors.DictCursor
        )
        cur = conn.cursor()
        cur.execute("SHOW MASTER STATUS;")
        row = cur.fetchone()
        cur.close()
        conn.close()
        if not row:
            return None, None
        return row.get("File"), int(row.get("Position"))
    except Exception as e:
        logging.error(f"get_master_status error: {e}")
        return None, None

def get_replica_status(host, port):
    """Safe parsing for all MariaDB versions"""
    try:
        resolved_host = resolve_hostname(host)
        conn = pymysql.connect(
            host=resolved_host,
            port=port,
            user=APP_USER or "root",
            password=APP_PASS or ROOT_PASS,
            autocommit=True,
            connect_timeout=1,
            read_timeout=2,
            write_timeout=2,
            cursorclass=pymysql.cursors.DictCursor
        )
        cur = conn.cursor()
        cur.execute("SHOW SLAVE STATUS;")
        row = cur.fetchone()
        cur.close()
        conn.close()
        if not row:
            return None
        return {
            "slave_io": row.get("Slave_IO_Running"),
            "slave_sql": row.get("Slave_SQL_Running"),
            "relay_pos": int(row.get("Relay_Log_Pos", 0)),
            "exec_pos": int(row.get("Exec_Master_Log_Pos", 0)),
            "read_master_pos": int(row.get("Read_Master_Log_Pos", 0)),
            "behind": row.get("Seconds_Behind_Master"),
            "master_file": row.get("Master_Log_File"),
            "master_pos": int(row.get("Read_Master_Log_Pos", 0)),
            "exec_master_pos": int(row.get("Exec_Master_Log_Pos", 0)),
            "using_gtid": row.get("Using_Gtid"),
            "gtid_io_pos": row.get("Gtid_IO_Pos"),
            "last_sql_errno": int(row.get("Last_SQL_Errno", 0) or 0),
            "last_sql_error": row.get("Last_SQL_Error")
        }
    except Exception as e:
        logging.error(f"get_replica_status error: {e}")
        return None

def replication_ok(host, port):
    rs = get_replica_status(host, port)
    if not rs:
        return False
    return (rs["slave_io"] == "Yes" and rs["slave_sql"] == "Yes" and
            rs["using_gtid"] == "Slave_Pos" and bool(rs["gtid_io_pos"]) and
            rs["last_sql_errno"] == 0)

def replication_requires_reseed(host, port):
    """Return True when local GTID history cannot safely be joined to its master."""
    status = get_replica_status(host, port)
    if not status:
        return False
    if status["last_sql_errno"] == 1950:
        logging.critical(
            f"{host}:{port} has divergent GTID history; re-seed from the active primary before retrying"
        )
        return True
    return False

def replica_in_sync(replica_host, replica_port, master_host=None, master_port=None):
    """Zero data loss: checks replica caught up fully."""
    master_host = master_host or PRIMARY_HOST
    master_port = master_port or (REPLICA_PORTS[0] if REPLICA_PORTS else 3306)
    ms_file, ms_pos = get_master_status(master_host, master_port)
    rs = get_replica_status(replica_host, replica_port)
    if not ms_file or not rs:
        return False
    if rs["slave_io"] != "Yes" or rs["slave_sql"] != "Yes":
        return False
    return (rs["master_file"] == ms_file) and (rs["exec_master_pos"] >= ms_pos)

def wait_for_replica_sync(master_host, master_port, replica_host, replica_port, timeout=None):
    """Wait until a GTID replica has applied all currently available master events."""
    deadline = time.time() + (timeout or REPLICATION_SYNC_TIMEOUT)
    while time.time() < deadline:
        status = get_replica_status(replica_host, replica_port)
        if status and status["using_gtid"] == "Slave_Pos" and status["last_sql_errno"] == 0:
            try:
                behind = int(status["behind"]) if status["behind"] is not None else -1
            except (TypeError, ValueError):
                behind = -1
            if (status["slave_io"] == "Yes" and status["slave_sql"] == "Yes" and
                    status["gtid_io_pos"] and behind == 0 and
                    replica_in_sync(replica_host, replica_port, master_host, master_port)):
                return True
        time.sleep(2)
    logging.error(f"Replica {replica_host}:{replica_port} did not catch up from {master_host}:{master_port}")
    return False

def check_data_loss_risk(replica_host, replica_port, force_promote=False, primary_alive=True):
    """
    Check if promotion would cause data loss.
    
    Args:
        force_promote: If True (primary down >30s), allow promotion even with stopped replication
        primary_alive: If False, don't check replication threads (primary is dead, threads will be stopped)
    
    Returns True if safe to promote (zero data loss), False otherwise.
    """
    rs = get_replica_status(replica_host, replica_port)
    if not rs:
        logging.error(f"Cannot check data loss: no replica status from {replica_host}:{replica_port}")
        return False
    
    # Only check replication threads if primary is alive
    # (If primary is dead, replication threads will naturally stop, but replica still has the data!)
    if primary_alive:
        if rs["slave_io"] != "Yes" or rs["slave_sql"] != "Yes":
            logging.warning(f"Replication threads not running on {replica_host}:{replica_port} while primary is alive. Promote risky.")
            return False
    else:
        if rs["last_sql_errno"]:
            logging.warning(
                f"Replica {replica_host}:{replica_port} has SQL error {rs['last_sql_errno']}; refusing promotion"
            )
            return False

        # A stopped replica cannot prove that it received the primary's last
        # transactions. Only the explicit forced path may accept that risk.
        if force_promote:
            logging.critical(
                f"FORCED PROMOTION: Primary down >{FORCED_FAILOVER_TIMEOUT}s; "
                f"promoting {replica_host}:{replica_port} with unverified final transactions"
            )
            return True
        if rs["slave_io"] != "Yes" or rs["slave_sql"] != "Yes":
            logging.warning(
                f"Replica {replica_host}:{replica_port} is not fully running; waiting before promotion"
            )
            return False
    
    # Check seconds behind master - if too far behind, risky
    # (Only meaningful if primary is alive and we can get fresh data)
    if primary_alive:
        try:
            behind = int(rs.get("behind", -1)) if rs.get("behind") else -1
            if behind > 5:  # If more than 5 seconds behind, promote is risky
                logging.warning(f"Replica {replica_host}:{replica_port} is {behind}s behind master. Risky to promote.")
                return False
        except:
            pass
        
        # Check if replica is fully in sync with master
        if not replica_in_sync(replica_host, replica_port):
            logging.warning(f"Replica {replica_host}:{replica_port} NOT in sync with master. Risky to promote.")
            return False
    
    logging.info(f"Data loss check PASSED for {replica_host}:{replica_port} - Safe to promote")
    return True

def get_best_promotable_replica(force_promote=False, primary_alive=True):
    """
    Find the best promotable replica to promote (lowest data loss risk).
    
    Args:
        force_promote: If True, allow promotion even with stopped replication (primary timeout)
        primary_alive: If False, don't check replication threads (primary is dead)
    
    Returns (host, port) or (None, None) if none safe.
    """
    best_replica = None
    best_lag = float('inf')
    
    for idx in PROMOTABLE_REPLICAS:
        if idx >= len(REPLICA_HOSTS) or idx >= len(REPLICA_PORTS):
            continue
        
        replica_host = REPLICA_HOSTS[idx].strip()
        replica_port = REPLICA_PORTS[idx]
        
        if not is_alive(replica_host, replica_port):
            continue
        
        # Check data loss risk before considering
        if not check_data_loss_risk(replica_host, replica_port, force_promote=force_promote, primary_alive=primary_alive):
            logging.warning(f"Skipping {replica_host}:{replica_port} due to data loss risk")
            continue
        
        rs = get_replica_status(replica_host, replica_port)
        if rs:
            try:
                lag = int(rs.get("behind", float('inf'))) if rs.get("behind") else 0
                if lag < best_lag:
                    best_lag = lag
                    best_replica = (replica_host, replica_port)
            except:
                pass
    
    return best_replica if best_replica else (None, None)

# ===========================
# SERVICE UPDATER (HA switch)
# ===========================
def get_pod_for_service(service_prefix):
    """
    Find the running pod backing a service.
    For service names like "mariadb-primary", finds "mariadb-primary-0", "mariadb-primary-1", etc.
    Returns the pod name or None if not found.
    """
    try:
        pods = k8s.list_namespaced_pod(NAMESPACE)
        # Find the first running pod matching the service prefix
        for pod in pods.items:
            pod_name = pod.metadata.name
            # Match by service name prefix (e.g., "mariadb-primary" -> "mariadb-primary-0")
            if pod_name.startswith(service_prefix):
                if pod.status.phase == "Running":
                    return pod_name
        return None
    except Exception as e:
        logging.error(f"Failed to find pod for service {service_prefix}: {e}")
        return None

def get_pod_labels_by_hostname(hostname):
    """
    Find the pod matching the given hostname and return its labels.
    Handles both service names and pod FQDNs.
    
    If hostname is a service name (e.g., mariadb-primary.mariadb.svc.cluster.local),
    find the backing pod by matching the service name prefix to pod StatefulSet names.
    If hostname is a pod FQDN, extract pod name and find the pod directly.
    """
    try:
        pods = k8s.list_namespaced_pod(NAMESPACE)
        
        # Extract pod name from FQDN or hostname
        pod_name_from_fqdn = hostname.split('.')[0] if '.' in hostname else hostname
        
        for pod in pods.items:
            pod_name = pod.metadata.name
            pod_hostname = pod.status.pod_ip if pod.status else None
            
            # Match by pod name if it's a StatefulSet pod (format: name-0, name-1, etc.)
            if pod_name.startswith("mariadb-"):
                # Exact match on pod name
                if pod_name == pod_name_from_fqdn:
                    logging.info(f"Found pod {pod_name} with labels: {pod.metadata.labels}")
                    return pod.metadata.labels or {}
                
                # If hostname is a service name, match by service name prefix
                # e.g., "mariadb-primary" service -> "mariadb-primary-0" pod
                if '-' in pod_name and pod_name_from_fqdn in pod_name and pod.status.phase == "Running":
                    logging.info(f"Found pod {pod_name} (service match) with labels: {pod.metadata.labels}")
                    return pod.metadata.labels or {}
                
                # Match by IP if available
                if pod_hostname and hostname in pod_hostname:
                    logging.info(f"Found pod {pod_name} (IP match) with labels: {pod.metadata.labels}")
                    return pod.metadata.labels or {}
        
        logging.warning(f"Pod with hostname {hostname} (extracted: {pod_name_from_fqdn}) not found for label extraction")
        return {}
    except Exception as e:
        logging.error(f"Failed to get pod labels for {hostname}: {e}")
        return {}

def update_service_endpoint(primary_host, primary_port):
    """
    Update service endpoint to point to current primary.
    Uses the actual pod's labels to ensure service selects the right pod,
    whether it's the original primary (role: primary) or a promoted replica (role: replica, replica-index: N).
    """
    logging.info(f"Updating service endpoint → {primary_host}:{primary_port}")
    
    try:
        # Get the current primary pod's actual labels
        pod_labels = get_pod_labels_by_hostname(primary_host)
        
        if not pod_labels:
            logging.warning(f"Could not get labels for {primary_host}, using default selector")
            # Fallback: try to determine if this is replica or primary based on hostname
            if "replica" in primary_host.lower():
                selector = {"app": "mariadb", "role": "replica"}
            else:
                selector = {"app": "mariadb", "role": "primary"}
        else:
            # Use the pod's actual labels for selector
            # Include app, role, and replica-index if present for unique identification
            selector = {
                "app": pod_labels.get("app", "mariadb"),
                "role": pod_labels.get("role", "primary")
            }
            
            # If this is a replica (has replica-index), MUST include it in selector for unique routing
            if "replica-index" in pod_labels:
                selector["replica-index"] = pod_labels.get("replica-index")
                logging.info(f"Service selector with replica-index: {selector}")
            else:
                logging.info(f"Service selector for primary (no replica-index): {selector}")
        
        body = {"spec": {"selector": selector}}
        
        k8s.patch_namespaced_service(
            name=SERVICE_NAME,
            namespace=NAMESPACE,
            body=body
        )
        logging.info(f"Service now points to {primary_host}:{primary_port} with selector {selector}")
        return True
    except Exception as e:
        logging.error(f"Failed to update service endpoint: {e}")
        return False

# ===========================
# FAILOVER & FAILBACK LOGIC
# ===========================
def promote_replica(replica_host, replica_port, force_promote=False, primary_alive=True):
    """
    Promote a replica to primary status - with data loss safety check.
    
    Args:
        force_promote: If True, skip data loss checks (primary timeout scenario)
        primary_alive: If False, don't check replication threads (primary is dead)
    
    Only promotes if it's safe (no data loss risk), or forced.
    """
    logging.warning(f"FAILOVER: Checking data loss risk for {replica_host}:{replica_port}")
    
    # Critical: Check for data loss before promotion (unless forced)
    if not check_data_loss_risk(replica_host, replica_port, force_promote=force_promote, primary_alive=primary_alive):
        logging.critical(f"DATA LOSS RISK DETECTED! Aborting promotion of {replica_host}:{replica_port}")
        return False
    
    logging.warning(f"FAILOVER: Data loss check PASSED. Promoting {replica_host}:{replica_port} to PRIMARY")
    mysql_exec(replica_host, replica_port, "STOP SLAVE;")
    mysql_exec(replica_host, replica_port, "RESET SLAVE ALL;")
    if not ensure_replication_user(replica_host, replica_port):
        logging.error(f"Cannot promote {replica_host}:{replica_port}: replication user setup failed")
        return False
    file, pos = get_master_status(replica_host, replica_port)
    if file:
        logging.info(f"Replica {replica_host}:{replica_port} promoted as MASTER → {file}:{pos}")
        if update_service_endpoint(replica_host, replica_port):
            save_state({"primary": replica_host, "primary_port": replica_port})
            return True
    logging.error(f"Failed to promote replica {replica_host}:{replica_port}")
    return False

def failback_to_primary(primary_host, primary_port, current_primary_host, current_primary_port):
    """Rejoin the old primary and fail back only after it is fully synchronized."""
    logging.warning(f"FAILBACK: Bringing original primary {primary_host}:{primary_port} back")
    if not fix_replication(current_primary_host, current_primary_port, primary_host, primary_port):
        return False
    if not wait_for_replica_sync(current_primary_host, current_primary_port,
                                 primary_host, primary_port):
        logging.error("Refusing failback: original primary is not fully caught up")
        return False

    mysql_exec(primary_host, primary_port, "STOP SLAVE;")
    mysql_exec(primary_host, primary_port, "RESET SLAVE ALL;")
    file, pos = get_master_status(primary_host, primary_port)
    if file:
        logging.info(f"Original primary {primary_host}:{primary_port} re-promoted as MASTER → {file}:{pos}")
        # Promote current primary to replica
        fix_replication(primary_host, primary_port, current_primary_host, current_primary_port)
        if update_service_endpoint(primary_host, primary_port):
            save_state({"primary": primary_host, "primary_port": primary_port})
            return True
    logging.error(f"Failed to failback to primary {primary_host}:{primary_port}")
    return False

def fix_replication(master_host, master_port, replica_host, replica_port, use_current_pos=False):
    """Fix broken replication using MariaDB GTID slave position."""
    logging.info(f"Fixing replication: {replica_host}:{replica_port} <- {master_host}:{master_port}")
    if replication_requires_reseed(replica_host, replica_port):
        return False
    if not ensure_replication_user(master_host, master_port):
        return False
    mysql_exec(replica_host, replica_port, "STOP SLAVE;")
    mysql_exec(replica_host, replica_port, "RESET SLAVE ALL;")
    change_master_query = f"""
    CHANGE MASTER TO
        MASTER_HOST='{master_host}',
        MASTER_PORT={master_port},
        MASTER_USER='repl',
        MASTER_PASSWORD='{ROOT_PASS}',
        MASTER_USE_GTID={'current_pos' if use_current_pos else 'slave_pos'};
    """
    mysql_exec(replica_host, replica_port, change_master_query)
    mysql_exec(replica_host, replica_port, "START SLAVE;")
    status = get_replica_status(replica_host, replica_port)
    if not status or status["using_gtid"] != "Slave_Pos":
        logging.error(f"Replication was not configured with GTID on {replica_host}:{replica_port}")
        return False
    gtid_mode = "current_pos" if use_current_pos else "slave_pos"
    logging.info(f"Replication configured: {replica_host}:{replica_port} now replicates from {master_host}:{master_port} using GTID ({gtid_mode})")
    return True

# ===========================
# MAIN LOOP - Production-Ready HA Controller with Leader Election
# ===========================
logging.info(f"MariaDB HA Manager (Zero-Data-Loss Mode) Started... POD_NAME={POD_NAME}")
if LEADER_ELECTION_ENABLED:
    logging.info(f"Leader election ENABLED: LEASE_NAME={LEASE_NAME}, LEASE_DURATION={LEASE_DURATION}s")
else:
    logging.info("Leader election DISABLED: Running as single controller")

failover_cooldown = 0  # Prevent rapid failover attempts
last_health_check = 0
PRIMARY_DOWN_SINCE = None  # Track when primary went down

while True:
    time.sleep(2)
    
    # Leader election check
    if LEADER_ELECTION_ENABLED:
        if not acquire_or_renew_lease():
            # Not leader, wait and retry
            logging.debug(f"Not leader, waiting {RETRY_PERIOD}s...")
            time.sleep(RETRY_PERIOD)
            continue
        else:
            logging.debug(f"Leading - performing HA checks")
    
    failover_cooldown = max(0, failover_cooldown - 2)
    if time.time() - last_health_check < HEALTH_CHECK_INTERVAL:
        continue
    last_health_check = time.time()
    
    state = load_state()
    current_primary = state["primary"]
    current_primary_port = state.get("primary_port", REPLICA_PORTS[0] if REPLICA_PORTS else 3306)
    
    # Check original primary
    primary_port = REPLICA_PORTS[0] if REPLICA_PORTS else 3306
    primary_ok = is_alive(PRIMARY_HOST, primary_port)
    
    # Track primary down time for forced failover
    if not primary_ok:
        if PRIMARY_DOWN_SINCE is None:
            PRIMARY_DOWN_SINCE = time.time()
    else:
        PRIMARY_DOWN_SINCE = None
    
    # Calculate if we should force promotion (primary down for too long)
    force_promote = PRIMARY_DOWN_SINCE is not None and (time.time() - PRIMARY_DOWN_SINCE) > FORCED_FAILOVER_TIMEOUT
    if force_promote:
        logging.critical(f"PRIMARY down for {FORCED_FAILOVER_TIMEOUT}s - FORCING FAILOVER")
    
    # Check all replicas
    replica_statuses = []
    for idx, (host, port) in enumerate(zip(REPLICA_HOSTS, REPLICA_PORTS)):
        if host.strip():
            ok = is_alive(host, port)
            repl_ok = ok and replication_ok(host, port)
            in_sync = ok and replica_in_sync(host, port, current_primary, current_primary_port)
            replica_statuses.append({
                "host": host,
                "port": port,
                "alive": ok,
                "replication_ok": repl_ok,
                "in_sync": in_sync,
                "promotable": idx in PROMOTABLE_REPLICAS,
                "index": idx
            })
    
    # =============================================
    # SCENARIO 1: Original primary is the current primary
    # =============================================
    if current_primary == PRIMARY_HOST:
        if not primary_ok:
            # Original primary is DOWN - FAILOVER required
            if failover_cooldown == 0:
                logging.critical("SCENARIO 1A: Original PRIMARY DOWN - Initiating FAILOVER")
                # Use optimized best replica selection with data loss checks
                # primary_alive=False because primary is dead (allows immediate promotion without waiting 30s)
                best_replica_host, best_replica_port = get_best_promotable_replica(force_promote=force_promote, primary_alive=False)
                
                if best_replica_host and best_replica_port is not None:
                    if promote_replica(best_replica_host, best_replica_port, force_promote=force_promote, primary_alive=False):
                        PRIMARY_DOWN_SINCE = None  # Reset timer
                        failover_cooldown = 30  # Cooldown period
                        logging.info(f"Failover successful: {best_replica_host}:{best_replica_port} is now PRIMARY")
                else:
                    if not force_promote:
                        logging.error(f"No safe replicas for failover. Waiting {FORCED_FAILOVER_TIMEOUT}s for forced promotion...")
                    else:
                        logging.error("No alive replicas available for forced failover!")
        else:
            # Original primary is UP - Keep it as primary and sync replicas
            logging.debug("SCENARIO 1B: Original PRIMARY UP - Monitoring replicas")
            # Update service to point to primary
            update_service_endpoint(PRIMARY_HOST, primary_port)
            # Monitor and fix replication on all replicas
            for r in replica_statuses:
                if r["alive"]:
                    if not r["replication_ok"]:
                        logging.warning(f"Replica {r['host']}:{r['port']} replication broken - fixing")
                        fix_replication(PRIMARY_HOST, primary_port, r["host"], r["port"])
                    elif not r["in_sync"]:
                        logging.info(f"Replica {r['host']}:{r['port']} catching up...")
                    else:
                        logging.debug(f"Replica {r['host']}:{r['port']} fully synchronized")
    
    # =============================================
    # SCENARIO 2: A promoted replica is the current primary
    # =============================================
    else:
        promoted_ok = is_alive(current_primary, current_primary_port)
        
        if not promoted_ok:
            # Never promote a potentially stale original primary while the active
            # primary is unavailable; its missing transactions cannot be verified.
            if primary_ok and failover_cooldown == 0:
                logging.critical("SCENARIO 2A: Promoted PRIMARY DOWN - refusing unsafe failback to original PRIMARY")
                logging.critical("Original PRIMARY remains available but may be stale; manual recovery is required")
                failover_cooldown = 30
            elif not primary_ok:
                logging.warning("SCENARIO 2B: Both original and promoted primary DOWN - Waiting for recovery")
        else:
            # Current promoted primary is UP - Keep monitoring
            logging.debug(f"SCENARIO 2C: Promoted PRIMARY {current_primary}:{current_primary_port} UP - Monitoring")
            # Update service endpoint
            update_service_endpoint(current_primary, current_primary_port)
            
            # Ensure original primary replicates if up
            if primary_ok and not replication_ok(PRIMARY_HOST, primary_port):
                logging.warning(f"Original primary replication broken - fixing")
                fix_replication(current_primary, current_primary_port, PRIMARY_HOST, primary_port)
            
            # Monitor other replicas
            for r in replica_statuses:
                if r["host"] != current_primary and r["alive"]:
                    if not r["replication_ok"]:
                        logging.warning(f"Replica {r['host']}:{r['port']} replication broken - fixing")
                        fix_replication(current_primary, current_primary_port, r["host"], r["port"])
                    elif not r["in_sync"]:
                        logging.info(f"Replica {r['host']}:{r['port']} catching up...")
                    else:
                        logging.debug(f"Replica {r['host']}:{r['port']} fully synchronized")
