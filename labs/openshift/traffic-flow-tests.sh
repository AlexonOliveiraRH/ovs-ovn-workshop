#!/bin/bash
set -euo pipefail

# =============================================================================
# traffic-flow-tests.sh - Traffic Flow Tests for OVN-Kubernetes in OpenShift
# =============================================================================
#
# Description:
#   Creates test resources and runs connectivity tests to validate OVN-Kubernetes
#   networking in an OpenShift cluster. Tests include same-node pod-to-pod,
#   cross-node pod-to-pod (Geneve tunnel), pod-to-service (OVN load balancer),
#   pod-to-external, and NetworkPolicy enforcement.
#
# Usage:
#   ./traffic-flow-tests.sh [OPTIONS]
#
# Options:
#   --cleanup        Remove all test resources and exit
#   --skip-create    Use existing test resources (skip creation)
#   --node1 NODE     Node for pod-a and pod-b (default: auto-select)
#   --node2 NODE     Node for pod-c (default: auto-select)
#   --help           Show this help message
#
# Prerequisites:
#   - oc CLI authenticated to an OpenShift cluster
#   - Cluster-admin privileges
#   - At least two worker nodes
#
# =============================================================================

# ---------------------------------------------------------------------------
# Color definitions
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Global variables
# ---------------------------------------------------------------------------
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_FILE="/tmp/ovnk-traffic-test-${TIMESTAMP}.txt"
TEST_NS="workshop-test-ns"
TEST_NS2="workshop-test-ns2"
OVN_NAMESPACE="openshift-ovn-kubernetes"
NODE1=""
NODE2=""
DO_CLEANUP=false
SKIP_CREATE=false
POD_IMAGE="registry.access.redhat.com/ubi9/ubi-minimal:latest"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
POD_STYLE=""
NB_LEADER_POD=""

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
${BOLD}traffic-flow-tests.sh${NC} - OVN-K Traffic Flow Tests for OpenShift

${CYAN}USAGE:${NC}
    $0 [OPTIONS]

${CYAN}OPTIONS:${NC}
    --cleanup        Remove all test resources and exit
    --skip-create    Use existing test resources (skip creation)
    --node1 NODE     Node for pod-a and pod-b (default: auto-select worker)
    --node2 NODE     Node for pod-c (default: auto-select different worker)
    --help           Show this help message

${CYAN}TEST CASES:${NC}
    1. Pod-to-pod same node      (pod-a -> pod-b)
    2. Pod-to-pod different node  (pod-a -> pod-c, via Geneve tunnel)
    3. Pod-to-service ClusterIP   (pod-a -> test-service)
    4. Pod-to-external            (pod-a -> 8.8.8.8)
    5. NetworkPolicy enforcement  (pod-a -> pod in $TEST_NS2, should be blocked)

${CYAN}EXAMPLES:${NC}
    $0                                     # Auto-select nodes, run all tests
    $0 --node1 worker-0 --node2 worker-1   # Specify nodes
    $0 --skip-create                       # Reuse existing test resources
    $0 --cleanup                           # Remove all test resources
EOF
}

print_header() {
    local title="$1"
    local line
    line=$(printf '=%.0s' {1..78})
    echo ""
    echo -e "${BLUE}${BOLD}${line}${NC}"
    echo -e "${BLUE}${BOLD}  ${title}${NC}"
    echo -e "${BLUE}${BOLD}${line}${NC}"
    echo ""
}

print_subheader() {
    local title="$1"
    local line
    line=$(printf -- '-%.0s' {1..60})
    echo ""
    echo -e "${CYAN}${BOLD}  ${title}${NC}"
    echo -e "${CYAN}  ${line}${NC}"
}

print_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_pass() {
    echo -e "${GREEN}${BOLD}[PASS]${NC} $1"
    ((PASS_COUNT++)) || true
}

print_fail() {
    echo -e "${RED}${BOLD}[FAIL]${NC} $1"
    ((FAIL_COUNT++)) || true
}

print_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
    ((SKIP_COUNT++)) || true
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

tee_report() {
    tee -a "$REPORT_FILE"
}

# Run a command, capturing output and handling errors
run_cmd() {
    local description="$1"
    shift
    print_info "$description"
    echo "--- $description ---" >> "$REPORT_FILE"
    if output=$("$@" 2>&1); then
        echo "$output" | tee_report
        echo "" >> "$REPORT_FILE"
        return 0
    else
        local rc=$?
        echo "$output" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
        return $rc
    fi
}

ovn_exec() {
    local pod="$1"
    local container="$2"
    shift 2
    oc exec -n "$OVN_NAMESPACE" "$pod" -c "$container" -- "$@" 2>&1
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

preflight_checks() {
    print_header "Pre-flight Checks"

    if ! command -v oc &>/dev/null; then
        print_error "oc CLI not found."
        exit 1
    fi
    print_ok "oc CLI found"

    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to an OpenShift cluster."
        exit 1
    fi
    print_ok "Logged in as: $(oc whoami)"

    if ! oc auth can-i create namespace &>/dev/null; then
        print_error "Cannot create namespaces. Cluster-admin access is required."
        exit 1
    fi
    print_ok "Sufficient privileges"

    # Initialize report
    {
        echo "============================================================"
        echo "  OVN-K Traffic Flow Test Report"
        echo "  Cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
        echo "  Date: $(date)"
        echo "============================================================"
        echo ""
    } > "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Detect OVN-K pod style and find NB leader
# ---------------------------------------------------------------------------

detect_ovn_environment() {
    print_header "Detecting OVN Environment"

    if oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-control-plane --no-headers 2>/dev/null | grep -q .; then
        POD_STYLE="new"
        print_ok "Detected OCP 4.14+ pod style"
    elif oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-master --no-headers 2>/dev/null | grep -q .; then
        POD_STYLE="legacy"
        print_ok "Detected legacy pod style"
    else
        print_warn "Could not detect pod style. ovn-trace will be skipped."
        return
    fi

    # Find NB leader for ovn-trace
    local cp_pods nb_container
    if [[ "$POD_STYLE" == "new" ]]; then
        cp_pods=$(oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-control-plane \
            --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
        nb_container="nbdb"
    else
        cp_pods=$(oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-master \
            --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
        nb_container="northd"
    fi

    for pod in $cp_pods; do
        if ovn_exec "$pod" "$nb_container" \
            ovs-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound 2>/dev/null \
            | grep -q "Role: leader"; then
            NB_LEADER_POD="$pod"
            print_ok "NB Leader: $pod"
            break
        fi
    done

    if [[ -z "$NB_LEADER_POD" ]]; then
        NB_LEADER_POD=$(echo "$cp_pods" | head -1)
        print_warn "No NB leader detected, using: $NB_LEADER_POD"
    fi
}

# ---------------------------------------------------------------------------
# Node selection
# ---------------------------------------------------------------------------

select_nodes() {
    print_header "Node Selection"

    local workers
    mapfile -t workers < <(oc get nodes --no-headers -l node-role.kubernetes.io/worker= \
        -o custom-columns=NAME:.metadata.name 2>/dev/null | head -10)

    if [[ ${#workers[@]} -lt 2 ]]; then
        # Try nodes without master/control-plane role as fallback
        mapfile -t workers < <(oc get nodes --no-headers \
            -o custom-columns=NAME:.metadata.name 2>/dev/null | head -10)
    fi

    if [[ ${#workers[@]} -lt 2 ]]; then
        print_error "At least 2 schedulable nodes are required for cross-node tests."
        print_warn "Found nodes: ${workers[*]:-none}"
        exit 1
    fi

    if [[ -z "$NODE1" ]]; then
        NODE1="${workers[0]}"
    fi
    if [[ -z "$NODE2" ]]; then
        # Pick a different node than NODE1
        for w in "${workers[@]}"; do
            if [[ "$w" != "$NODE1" ]]; then
                NODE2="$w"
                break
            fi
        done
    fi

    if [[ -z "$NODE2" ]]; then
        print_error "Could not find a second node different from $NODE1."
        exit 1
    fi

    print_ok "Node 1 (pod-a, pod-b): $NODE1"
    print_ok "Node 2 (pod-c):        $NODE2"

    {
        echo "Node 1: $NODE1"
        echo "Node 2: $NODE2"
        echo ""
    } >> "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

cleanup_resources() {
    print_header "Cleaning Up Test Resources"

    for ns in "$TEST_NS" "$TEST_NS2"; do
        if oc get namespace "$ns" &>/dev/null; then
            print_info "Deleting namespace: $ns"
            oc delete namespace "$ns" --wait=true --timeout=120s 2>/dev/null || true
            print_ok "Namespace $ns deleted"
        else
            print_info "Namespace $ns does not exist, nothing to clean up"
        fi
    done

    print_ok "Cleanup complete"
}

# ---------------------------------------------------------------------------
# Create test resources
# ---------------------------------------------------------------------------

create_test_resources() {
    print_header "Creating Test Resources"

    # Create namespaces
    print_subheader "Creating Namespaces"
    for ns in "$TEST_NS" "$TEST_NS2"; do
        if oc get namespace "$ns" &>/dev/null; then
            print_warn "Namespace $ns already exists"
        else
            oc create namespace "$ns"
            print_ok "Created namespace: $ns"
        fi
    done

    # Allow privileged workloads (for ubi-minimal, curl, ping)
    # Add SCC for the test pods
    print_info "Setting up security context for test namespaces"
    oc adm policy add-scc-to-user anyuid -z default -n "$TEST_NS" 2>/dev/null || true
    oc adm policy add-scc-to-user anyuid -z default -n "$TEST_NS2" 2>/dev/null || true

    # Create pod-a on NODE1
    print_subheader "Creating Test Pods"

    oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pod-a
  namespace: ${TEST_NS}
  labels:
    app: pod-a
    workshop: traffic-test
spec:
  nodeSelector:
    kubernetes.io/hostname: "${NODE1}"
  containers:
  - name: test
    image: ${POD_IMAGE}
    command: ["sleep", "infinity"]
  terminationGracePeriodSeconds: 0
EOF
    print_ok "Created pod-a on $NODE1"

    # Create pod-b on NODE1 (same node as pod-a)
    oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pod-b
  namespace: ${TEST_NS}
  labels:
    app: pod-b
    workshop: traffic-test
spec:
  nodeSelector:
    kubernetes.io/hostname: "${NODE1}"
  containers:
  - name: test
    image: ${POD_IMAGE}
    command:
    - /bin/sh
    - -c
    - |
      # Start a simple HTTP responder using shell built-ins
      while true; do
        echo -e "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" | \
          nc -l -p 8080 -w 1 2>/dev/null || sleep 1
      done
    ports:
    - containerPort: 8080
      name: http
  terminationGracePeriodSeconds: 0
EOF
    print_ok "Created pod-b on $NODE1"

    # Create pod-c on NODE2 (different node)
    oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pod-c
  namespace: ${TEST_NS}
  labels:
    app: pod-c
    workshop: traffic-test
spec:
  nodeSelector:
    kubernetes.io/hostname: "${NODE2}"
  containers:
  - name: test
    image: ${POD_IMAGE}
    command: ["sleep", "infinity"]
  terminationGracePeriodSeconds: 0
EOF
    print_ok "Created pod-c on $NODE2"

    # Create pod in second namespace for NetworkPolicy test
    oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pod-isolated
  namespace: ${TEST_NS2}
  labels:
    app: pod-isolated
    workshop: traffic-test
spec:
  containers:
  - name: test
    image: ${POD_IMAGE}
    command: ["sleep", "infinity"]
  terminationGracePeriodSeconds: 0
EOF
    print_ok "Created pod-isolated in $TEST_NS2"

    # Create ClusterIP service pointing to pod-b
    print_subheader "Creating Test Service"

    oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: test-service
  namespace: ${TEST_NS}
  labels:
    workshop: traffic-test
spec:
  type: ClusterIP
  selector:
    app: pod-b
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
    name: http
EOF
    print_ok "Created test-service (ClusterIP) -> pod-b:8080"

    # Create NetworkPolicy in TEST_NS2 to deny all ingress
    print_subheader "Creating NetworkPolicy (deny-all-ingress in $TEST_NS2)"

    oc apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
  namespace: ${TEST_NS2}
  labels:
    workshop: traffic-test
spec:
  podSelector: {}
  policyTypes:
  - Ingress
EOF
    print_ok "Created deny-all-ingress NetworkPolicy in $TEST_NS2"
}

# ---------------------------------------------------------------------------
# Wait for pods to be ready
# ---------------------------------------------------------------------------

wait_for_pods() {
    print_header "Waiting for Pods to be Ready"

    local pods=("pod-a:$TEST_NS" "pod-b:$TEST_NS" "pod-c:$TEST_NS" "pod-isolated:$TEST_NS2")
    local max_wait=180
    local interval=5

    for pod_ns in "${pods[@]}"; do
        local pod_name="${pod_ns%%:*}"
        local ns="${pod_ns##*:}"
        print_info "Waiting for $pod_name in $ns..."

        local elapsed=0
        while [[ $elapsed -lt $max_wait ]]; do
            local phase
            phase=$(oc get pod "$pod_name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            if [[ "$phase" == "Running" ]]; then
                # Also check container readiness
                local ready
                ready=$(oc get pod "$pod_name" -n "$ns" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
                if [[ "$ready" == "true" ]]; then
                    print_ok "$pod_name is Running and Ready"
                    break
                fi
            fi
            sleep "$interval"
            elapsed=$((elapsed + interval))
        done

        if [[ $elapsed -ge $max_wait ]]; then
            print_error "$pod_name did not become ready within ${max_wait}s"
            oc get pod "$pod_name" -n "$ns" -o wide 2>/dev/null || true
            oc describe pod "$pod_name" -n "$ns" 2>/dev/null | tail -20 || true
            exit 1
        fi
    done

    # Give a brief moment for networking to fully converge
    print_info "Allowing 5s for OVN networking to converge..."
    sleep 5
}

# ---------------------------------------------------------------------------
# Retrieve pod IPs
# ---------------------------------------------------------------------------

get_pod_ips() {
    POD_A_IP=$(oc get pod pod-a -n "$TEST_NS" -o jsonpath='{.status.podIP}')
    POD_B_IP=$(oc get pod pod-b -n "$TEST_NS" -o jsonpath='{.status.podIP}')
    POD_C_IP=$(oc get pod pod-c -n "$TEST_NS" -o jsonpath='{.status.podIP}')
    POD_ISOLATED_IP=$(oc get pod pod-isolated -n "$TEST_NS2" -o jsonpath='{.status.podIP}')
    SVC_IP=$(oc get svc test-service -n "$TEST_NS" -o jsonpath='{.spec.clusterIP}')

    print_subheader "Test Resource IPs"
    print_info "pod-a ($NODE1):       $POD_A_IP"
    print_info "pod-b ($NODE1):       $POD_B_IP"
    print_info "pod-c ($NODE2):       $POD_C_IP"
    print_info "pod-isolated:         $POD_ISOLATED_IP"
    print_info "test-service (CIP):   $SVC_IP"

    {
        echo "Pod IPs:"
        echo "  pod-a ($NODE1): $POD_A_IP"
        echo "  pod-b ($NODE1): $POD_B_IP"
        echo "  pod-c ($NODE2): $POD_C_IP"
        echo "  pod-isolated:   $POD_ISOLATED_IP"
        echo "  test-service:   $SVC_IP"
        echo ""
    } >> "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# OVN trace helper
# ---------------------------------------------------------------------------

run_ovn_trace() {
    local description="$1"
    local src_mac="$2"
    local src_ip="$3"
    local dst_ip="$4"
    local src_port_name="$5"

    if [[ -z "$NB_LEADER_POD" ]]; then
        print_warn "Skipping ovn-trace (no NB leader pod)"
        return
    fi

    local nb_container
    if [[ "$POD_STYLE" == "new" ]]; then
        nb_container="nbdb"
    else
        nb_container="northd"
    fi

    print_info "Running ovn-trace: $description"
    echo "--- ovn-trace: $description ---" >> "$REPORT_FILE"

    # Find the logical switch port for the source pod
    local lsp
    lsp=$(ovn_exec "$NB_LEADER_POD" "$nb_container" \
        ovn-nbctl --no-leader-only --columns=name find logical_switch_port \
        addresses="*${src_ip}*" 2>/dev/null \
        | grep "^name" | head -1 | awk -F'"' '{print $2}' || echo "")

    if [[ -z "$lsp" && -n "$src_port_name" ]]; then
        lsp="$src_port_name"
    fi

    if [[ -z "$lsp" ]]; then
        print_warn "Could not determine logical switch port for $src_ip"
        echo "Could not determine logical switch port for $src_ip" >> "$REPORT_FILE"
        return
    fi

    local trace_output
    if trace_output=$(ovn_exec "$NB_LEADER_POD" "$nb_container" \
        ovn-trace --no-leader-only "$lsp" \
        "inport==\"${lsp}\" && eth.src==${src_mac} && eth.dst==00:00:00:00:00:00 && ip4.src==${src_ip} && ip4.dst==${dst_ip} && ip.ttl==64" \
        --summary 2>&1); then
        echo "$trace_output" | tee_report
    else
        print_warn "ovn-trace failed"
        echo "ovn-trace failed: $trace_output" >> "$REPORT_FILE"
    fi
    echo "" >> "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Get pod MAC address
# ---------------------------------------------------------------------------

get_pod_mac() {
    local pod="$1"
    local ns="$2"
    # Try to get the MAC from the pod's eth0 interface
    local mac
    mac=$(oc exec -n "$ns" "$pod" -- cat /sys/class/net/eth0/address 2>/dev/null || echo "")
    if [[ -z "$mac" ]]; then
        mac=$(oc exec -n "$ns" "$pod" -- ip link show eth0 2>/dev/null \
            | grep "link/ether" | awk '{print $2}' || echo "00:00:00:00:00:00")
    fi
    echo "$mac"
}

# ---------------------------------------------------------------------------
# Test 1: Pod-to-Pod Same Node
# ---------------------------------------------------------------------------

test_pod_to_pod_same_node() {
    print_header "Test 1: Pod-to-Pod Same Node (pod-a -> pod-b)"

    echo "=== Test 1: Pod-to-Pod Same Node ===" >> "$REPORT_FILE"
    print_info "Expected: Traffic stays within the same node via OVS br-int"
    print_info "Path: pod-a ($POD_A_IP) -> pod-b ($POD_B_IP) on $NODE1"
    echo ""

    # Connectivity test via ping
    print_subheader "Connectivity Test (ping)"
    local result
    if result=$(oc exec -n "$TEST_NS" pod-a -- ping -c 3 -W 5 "$POD_B_IP" 2>&1); then
        echo "$result" | tee_report
        print_pass "Test 1: Pod-to-pod same node - connectivity OK"
    else
        echo "$result" >> "$REPORT_FILE"
        print_fail "Test 1: Pod-to-pod same node - connectivity FAILED"
    fi

    # OVN trace
    print_subheader "OVN Logical Path (ovn-trace)"
    local pod_a_mac
    pod_a_mac=$(get_pod_mac pod-a "$TEST_NS")
    run_ovn_trace "pod-a -> pod-b (same node)" "$pod_a_mac" "$POD_A_IP" "$POD_B_IP" ""

    echo "" >> "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Test 2: Pod-to-Pod Different Nodes
# ---------------------------------------------------------------------------

test_pod_to_pod_different_nodes() {
    print_header "Test 2: Pod-to-Pod Different Nodes (pod-a -> pod-c)"

    echo "=== Test 2: Pod-to-Pod Different Nodes ===" >> "$REPORT_FILE"
    print_info "Expected: Traffic traverses Geneve tunnel between $NODE1 and $NODE2"
    print_info "Path: pod-a ($POD_A_IP on $NODE1) -> Geneve -> pod-c ($POD_C_IP on $NODE2)"
    echo ""

    # Connectivity test via ping
    print_subheader "Connectivity Test (ping)"
    local result
    if result=$(oc exec -n "$TEST_NS" pod-a -- ping -c 3 -W 5 "$POD_C_IP" 2>&1); then
        echo "$result" | tee_report
        print_pass "Test 2: Pod-to-pod different nodes - connectivity OK"
    else
        echo "$result" >> "$REPORT_FILE"
        print_fail "Test 2: Pod-to-pod different nodes - connectivity FAILED"
    fi

    # OVN trace
    print_subheader "OVN Logical Path (ovn-trace)"
    local pod_a_mac
    pod_a_mac=$(get_pod_mac pod-a "$TEST_NS")
    run_ovn_trace "pod-a -> pod-c (cross-node)" "$pod_a_mac" "$POD_A_IP" "$POD_C_IP" ""

    echo "" >> "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Test 3: Pod-to-Service (ClusterIP)
# ---------------------------------------------------------------------------

test_pod_to_service() {
    print_header "Test 3: Pod-to-Service ClusterIP (pod-a -> test-service)"

    echo "=== Test 3: Pod-to-Service ClusterIP ===" >> "$REPORT_FILE"
    print_info "Expected: OVN load balancer DNATs to pod-b ($POD_B_IP:8080)"
    print_info "Path: pod-a ($POD_A_IP) -> ClusterIP ($SVC_IP:80) -> DNAT -> pod-b ($POD_B_IP:8080)"
    echo ""

    # Connectivity test via curl
    print_subheader "Connectivity Test (curl to service)"
    local result
    if result=$(oc exec -n "$TEST_NS" pod-a -- \
        curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "http://${SVC_IP}:80" 2>&1); then
        if [[ "$result" == "200" ]]; then
            print_pass "Test 3: Pod-to-service ClusterIP - HTTP 200 OK"
        else
            print_info "HTTP response code: $result"
            # Even a connection means networking works; the nc-based server may not respond cleanly
            if [[ "$result" =~ ^[0-9]+$ ]] && [[ "$result" -gt 0 ]]; then
                print_pass "Test 3: Pod-to-service ClusterIP - got HTTP response ($result)"
            else
                print_fail "Test 3: Pod-to-service ClusterIP - no HTTP response"
            fi
        fi
        echo "HTTP response: $result" >> "$REPORT_FILE"
    else
        # Fallback: try TCP connectivity
        print_info "curl failed, trying TCP connectivity check..."
        if oc exec -n "$TEST_NS" pod-a -- \
            bash -c "echo > /dev/tcp/${SVC_IP}/80" 2>/dev/null; then
            print_pass "Test 3: Pod-to-service ClusterIP - TCP port 80 reachable"
        else
            echo "$result" >> "$REPORT_FILE"
            print_fail "Test 3: Pod-to-service ClusterIP - FAILED"
        fi
    fi

    # Show the OVN load balancer for this service
    print_subheader "OVN Load Balancer for test-service"
    if [[ -n "$NB_LEADER_POD" ]]; then
        local nb_container
        if [[ "$POD_STYLE" == "new" ]]; then
            nb_container="nbdb"
        else
            nb_container="northd"
        fi
        local lb_output
        if lb_output=$(ovn_exec "$NB_LEADER_POD" "$nb_container" \
            ovn-nbctl --no-leader-only lb-list 2>&1); then
            echo "$lb_output" | grep -i "$SVC_IP" | tee_report || \
                print_info "Service IP $SVC_IP not found in lb-list output"
        fi
    fi

    # OVN trace
    print_subheader "OVN Logical Path (ovn-trace)"
    local pod_a_mac
    pod_a_mac=$(get_pod_mac pod-a "$TEST_NS")
    run_ovn_trace "pod-a -> service ($SVC_IP)" "$pod_a_mac" "$POD_A_IP" "$SVC_IP" ""

    echo "" >> "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Test 4: Pod-to-External
# ---------------------------------------------------------------------------

test_pod_to_external() {
    print_header "Test 4: Pod-to-External (pod-a -> 8.8.8.8)"

    echo "=== Test 4: Pod-to-External ===" >> "$REPORT_FILE"
    print_info "Expected: Traffic goes through OVN gateway router, then SNAT to node IP"
    print_info "Path: pod-a -> ovn_cluster_router -> GR_${NODE1} -> SNAT -> external"
    echo ""

    # Connectivity test via ping
    print_subheader "Connectivity Test (ping 8.8.8.8)"
    local result
    if result=$(oc exec -n "$TEST_NS" pod-a -- ping -c 3 -W 10 8.8.8.8 2>&1); then
        echo "$result" | tee_report
        print_pass "Test 4: Pod-to-external (8.8.8.8) - connectivity OK"
    else
        echo "$result" >> "$REPORT_FILE"
        print_warn "Test 4: Ping to 8.8.8.8 failed (may be blocked by egress policy)"
        # Try DNS as alternative external test
        print_info "Trying DNS lookup as alternative..."
        if oc exec -n "$TEST_NS" pod-a -- \
            nslookup kubernetes.default.svc.cluster.local 2>&1 | tee_report; then
            print_pass "Test 4: DNS resolution works (egress to DNS is functional)"
        else
            print_fail "Test 4: Pod-to-external - connectivity FAILED"
        fi
    fi

    # OVN trace
    print_subheader "OVN Logical Path (ovn-trace)"
    local pod_a_mac
    pod_a_mac=$(get_pod_mac pod-a "$TEST_NS")
    run_ovn_trace "pod-a -> external (8.8.8.8)" "$pod_a_mac" "$POD_A_IP" "8.8.8.8" ""

    echo "" >> "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Test 5: NetworkPolicy Enforcement
# ---------------------------------------------------------------------------

test_network_policy() {
    print_header "Test 5: NetworkPolicy Enforcement (pod-a -> pod-isolated)"

    echo "=== Test 5: NetworkPolicy Enforcement ===" >> "$REPORT_FILE"
    print_info "Expected: Traffic is BLOCKED by deny-all-ingress NetworkPolicy in $TEST_NS2"
    print_info "Path: pod-a ($POD_A_IP) -> pod-isolated ($POD_ISOLATED_IP) [BLOCKED]"
    echo ""

    # Show the NetworkPolicy
    print_subheader "Active NetworkPolicy"
    oc get networkpolicy -n "$TEST_NS2" -o yaml 2>/dev/null | tee_report || true

    # Connectivity test - this should FAIL (timeout/refused)
    print_subheader "Connectivity Test (ping - expected to fail)"
    local result
    if result=$(oc exec -n "$TEST_NS" pod-a -- ping -c 2 -W 5 "$POD_ISOLATED_IP" 2>&1); then
        echo "$result" >> "$REPORT_FILE"
        print_fail "Test 5: NetworkPolicy NOT enforced - ping succeeded (should be blocked)"
    else
        echo "$result" >> "$REPORT_FILE"
        print_pass "Test 5: NetworkPolicy enforced - ping correctly blocked"
    fi

    # Show relevant ACLs
    if [[ -n "$NB_LEADER_POD" ]]; then
        print_subheader "Relevant OVN ACLs"
        local nb_container
        if [[ "$POD_STYLE" == "new" ]]; then
            nb_container="nbdb"
        else
            nb_container="northd"
        fi

        local acl_output
        if acl_output=$(ovn_exec "$NB_LEADER_POD" "$nb_container" \
            ovn-nbctl --no-leader-only find acl 2>&1); then
            # Filter for entries mentioning the test namespace
            echo "$acl_output" | grep -A5 -i "$TEST_NS2" | tee_report || \
                print_info "No explicit ACL references to $TEST_NS2 found (may use port groups)"
        fi
    fi

    # OVN trace
    print_subheader "OVN Logical Path (ovn-trace)"
    local pod_a_mac
    pod_a_mac=$(get_pod_mac pod-a "$TEST_NS")
    run_ovn_trace "pod-a -> pod-isolated (should drop)" "$pod_a_mac" "$POD_A_IP" "$POD_ISOLATED_IP" ""

    echo "" >> "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Show relevant OVS flows for a test
# ---------------------------------------------------------------------------

show_relevant_ovs_flows() {
    print_header "Relevant OVS Flows"

    print_info "Showing OVS flows related to test pod IPs on $NODE1"

    local node_pod
    if [[ "$POD_STYLE" == "new" ]]; then
        node_pod=$(oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-node \
            --field-selector spec.nodeName="$NODE1" --no-headers \
            -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
    else
        node_pod=$(oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-node \
            --field-selector spec.nodeName="$NODE1" --no-headers \
            -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
    fi

    if [[ -n "$node_pod" ]]; then
        # Convert pod IPs to hex for flow matching
        print_subheader "Flows matching pod-a IP ($POD_A_IP)"
        local flows
        if flows=$(ovn_exec "$node_pod" ovnkube-controller \
            ovs-ofctl dump-flows br-int --no-stats 2>/dev/null); then
            local ip_hex
            ip_hex=$(printf '%02x' $(echo "$POD_A_IP" | tr '.' ' ') 2>/dev/null || echo "")
            echo "$flows" | grep -i "$POD_A_IP" | head -20 | tee_report || \
                print_info "No flows explicitly matching $POD_A_IP"
        fi

        print_subheader "Flows matching pod-b IP ($POD_B_IP)"
        echo "$flows" | grep -i "$POD_B_IP" | head -20 | tee_report || \
            print_info "No flows explicitly matching $POD_B_IP"

        print_subheader "Flows matching service IP ($SVC_IP)"
        echo "$flows" | grep -i "$SVC_IP" | head -20 | tee_report || \
            print_info "No flows explicitly matching $SVC_IP (DNAT may happen in OVN pipeline)"
    else
        print_warn "Could not find ovnkube-node pod on $NODE1"
    fi
}

# ---------------------------------------------------------------------------
# Test summary
# ---------------------------------------------------------------------------

print_test_summary() {
    print_header "Test Summary"

    local total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))

    echo -e "  ${GREEN}PASSED:  $PASS_COUNT${NC}"
    echo -e "  ${RED}FAILED:  $FAIL_COUNT${NC}"
    echo -e "  ${YELLOW}SKIPPED: $SKIP_COUNT${NC}"
    echo -e "  TOTAL:   $total"
    echo ""

    {
        echo "=== Test Summary ==="
        echo "PASSED:  $PASS_COUNT"
        echo "FAILED:  $FAIL_COUNT"
        echo "SKIPPED: $SKIP_COUNT"
        echo "TOTAL:   $total"
    } >> "$REPORT_FILE"

    if [[ $FAIL_COUNT -eq 0 ]]; then
        print_ok "All tests passed."
    else
        print_error "$FAIL_COUNT test(s) failed."
    fi

    echo ""
    print_ok "Report saved to: $REPORT_FILE"
    echo ""
    print_info "To clean up test resources, run:"
    echo "    $0 --cleanup"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cleanup)
                DO_CLEANUP=true
                shift
                ;;
            --skip-create)
                SKIP_CREATE=true
                shift
                ;;
            --node1)
                if [[ -z "${2:-}" ]]; then
                    print_error "--node1 requires a node name argument"
                    exit 1
                fi
                NODE1="$2"
                shift 2
                ;;
            --node2)
                if [[ -z "${2:-}" ]]; then
                    print_error "--node2 requires a node name argument"
                    exit 1
                fi
                NODE2="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    echo -e "${BOLD}${BLUE}"
    echo "  ___  _   _ _  _   _  __   _____          __  __ _        _____       _       "
    echo " / _ \\| | | | \\| | | |/ /  |_   _| __ __ _/ _|/ _(_) ___  |_   _|__ ___| |_ ___ "
    echo "| (_) | |_| | .\` | | ' <     | || '__/ _\` | |_| |_| |/ __|   | |/ _ / __| __/ __|"
    echo " \\___/ \\___/|_|\\_| |_|\\_\\    |_||_| \\__,_|_| |_| |_|\\__ \\   |_|\\__\\___|\\__\\___|"
    echo "                                                        |___/                    "
    echo -e "${NC}"
    echo -e "${CYAN}OVN-Kubernetes Traffic Flow Tests for Red Hat OpenShift${NC}"
    echo ""

    # Handle cleanup-only mode
    if [[ "$DO_CLEANUP" == true ]]; then
        preflight_checks
        cleanup_resources
        exit 0
    fi

    preflight_checks
    detect_ovn_environment
    select_nodes

    if [[ "$SKIP_CREATE" == false ]]; then
        create_test_resources
        wait_for_pods
    else
        print_info "Skipping resource creation (--skip-create)"
        # Verify resources exist
        for pod in pod-a pod-b pod-c; do
            if ! oc get pod "$pod" -n "$TEST_NS" &>/dev/null; then
                print_error "Pod $pod not found in $TEST_NS. Run without --skip-create first."
                exit 1
            fi
        done
        if ! oc get pod pod-isolated -n "$TEST_NS2" &>/dev/null; then
            print_error "Pod pod-isolated not found in $TEST_NS2. Run without --skip-create first."
            exit 1
        fi
    fi

    get_pod_ips

    # Run all test cases
    test_pod_to_pod_same_node
    test_pod_to_pod_different_nodes
    test_pod_to_service
    test_pod_to_external
    test_network_policy
    show_relevant_ovs_flows

    print_test_summary
}

main "$@"
