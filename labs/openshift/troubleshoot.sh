#!/bin/bash
set -euo pipefail

# =============================================================================
# troubleshoot.sh - OVN-Kubernetes Troubleshooting Helper for OpenShift
# =============================================================================
#
# Description:
#   Diagnoses OVN-Kubernetes networking issues in an OpenShift cluster. Checks
#   pod health, OVN database cluster status, ovn-controller connections, node
#   network state, common failure patterns, and more. Generates a categorized
#   troubleshooting report with CRITICAL/WARNING/OK findings.
#
# Usage:
#   ./troubleshoot.sh [OPTIONS]
#
# Options:
#   --node NODE    Focus troubleshooting on a specific node
#   --quick        Fast health check (skip detailed analysis)
#   --help         Show this help message
#
# Output:
#   Results are saved to /tmp/ovnk-troubleshoot-YYYYMMDD-HHMMSS.txt
#
# Prerequisites:
#   - oc CLI authenticated to an OpenShift cluster
#   - Cluster-admin privileges
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
REPORT_FILE="/tmp/ovnk-troubleshoot-${TIMESTAMP}.txt"
TARGET_NODE=""
QUICK_MODE=false
OVN_NAMESPACE="openshift-ovn-kubernetes"
POD_STYLE=""
CONTROL_PLANE_PODS=""
NODE_PODS=""

# Findings counters
CRITICAL_COUNT=0
WARNING_COUNT=0
OK_COUNT=0

# Findings storage (arrays)
declare -a CRITICAL_FINDINGS=()
declare -a WARNING_FINDINGS=()
declare -a OK_FINDINGS=()

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
${BOLD}troubleshoot.sh${NC} - OVN-Kubernetes Troubleshooting for OpenShift

${CYAN}USAGE:${NC}
    $0 [OPTIONS]

${CYAN}OPTIONS:${NC}
    --node NODE    Focus troubleshooting on a specific node
    --quick        Fast health check (skip detailed analysis)
    --help         Show this help message

${CYAN}OUTPUT:${NC}
    Results are saved to /tmp/ovnk-troubleshoot-YYYYMMDD-HHMMSS.txt

${CYAN}CHECKS PERFORMED:${NC}
    - OVN-K pod health
    - OVN NB/SB database cluster health (raft)
    - ovn-controller connections
    - Networking events
    - Node network conditions
    - Geneve tunnel status
    - OVS flow integrity
    - NetworkPolicy / ACL analysis
    - OVN NB/SB sync
    - DNS resolution
    - MTU configuration
    - Pod networking failures

${CYAN}EXAMPLES:${NC}
    $0                          # Full troubleshooting
    $0 --quick                  # Fast health check
    $0 --node worker-0          # Focus on a specific node
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

print_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

record_critical() {
    local msg="$1"
    echo -e "${RED}${BOLD}[CRITICAL]${NC} $msg"
    CRITICAL_FINDINGS+=("$msg")
    ((CRITICAL_COUNT++)) || true
    echo "[CRITICAL] $msg" >> "$REPORT_FILE"
}

record_warning() {
    local msg="$1"
    echo -e "${YELLOW}${BOLD}[WARNING]${NC} $msg"
    WARNING_FINDINGS+=("$msg")
    ((WARNING_COUNT++)) || true
    echo "[WARNING] $msg" >> "$REPORT_FILE"
}

record_ok() {
    local msg="$1"
    echo -e "${GREEN}[OK]${NC} $msg"
    OK_FINDINGS+=("$msg")
    ((OK_COUNT++)) || true
    echo "[OK] $msg" >> "$REPORT_FILE"
}

tee_report() {
    tee -a "$REPORT_FILE"
}

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
        echo -e "${RED}[ERROR]${NC} oc CLI not found."
        exit 1
    fi

    if ! oc whoami &>/dev/null; then
        echo -e "${RED}[ERROR]${NC} Not logged in to an OpenShift cluster."
        exit 1
    fi
    local user
    user=$(oc whoami)
    echo -e "${GREEN}[OK]${NC} Logged in as: $user"

    if ! oc get namespace "$OVN_NAMESPACE" &>/dev/null; then
        echo -e "${RED}[ERROR]${NC} Namespace $OVN_NAMESPACE not found."
        exit 1
    fi

    # Initialize report
    {
        echo "============================================================"
        echo "  OVN-Kubernetes Troubleshooting Report"
        echo "  Cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
        echo "  User: $user"
        echo "  Date: $(date)"
        echo "  Mode: $(if $QUICK_MODE; then echo 'Quick'; else echo 'Full'; fi)"
        echo "  Node filter: ${TARGET_NODE:-none (all nodes)}"
        echo "============================================================"
        echo ""
    } > "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Detect pod style
# ---------------------------------------------------------------------------

detect_pod_style() {
    if oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-control-plane --no-headers 2>/dev/null | grep -q .; then
        POD_STYLE="new"
    elif oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-master --no-headers 2>/dev/null | grep -q .; then
        POD_STYLE="legacy"
    else
        if oc get pods -n "$OVN_NAMESPACE" --no-headers 2>/dev/null | grep -q 'ovnkube-control-plane'; then
            POD_STYLE="new"
        elif oc get pods -n "$OVN_NAMESPACE" --no-headers 2>/dev/null | grep -q 'ovnkube-master'; then
            POD_STYLE="legacy"
        else
            record_critical "Unable to detect OVN-K pod naming convention"
            POD_STYLE="unknown"
            return
        fi
    fi

    record_ok "Pod style detected: $POD_STYLE"

    if [[ "$POD_STYLE" == "new" ]]; then
        CONTROL_PLANE_PODS=$(oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-control-plane \
            --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
    else
        CONTROL_PLANE_PODS=$(oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-master \
            --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
    fi

    if [[ "$POD_STYLE" == "new" ]]; then
        NODE_PODS=$(oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-node \
            --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
    else
        NODE_PODS=$(oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-node \
            --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
    fi
}

get_nbdb_container() {
    if [[ "$POD_STYLE" == "new" ]]; then echo "nbdb"; else echo "northd"; fi
}

get_sbdb_container() {
    if [[ "$POD_STYLE" == "new" ]]; then echo "sbdb"; else echo "northd"; fi
}

# ---------------------------------------------------------------------------
# Check 1: OVN-K Pod Health
# ---------------------------------------------------------------------------

check_pod_health() {
    print_header "Check: OVN-K Pod Health"

    echo "--- OVN-K Pod Status ---" >> "$REPORT_FILE"
    local pod_output
    pod_output=$(oc get pods -n "$OVN_NAMESPACE" -o wide 2>&1)
    echo "$pod_output" | tee_report

    # Count non-Running pods
    local non_running
    non_running=$(echo "$pod_output" | tail -n +2 | grep -v "Running" | grep -v "Completed" || true)
    local non_running_count
    non_running_count=$(echo "$non_running" | grep -c . 2>/dev/null || echo 0)

    if [[ "$non_running_count" -gt 0 ]]; then
        record_critical "$non_running_count OVN-K pod(s) not in Running state"
        echo "$non_running" | while read -r line; do
            if [[ -n "$line" ]]; then
                local pod_name
                pod_name=$(echo "$line" | awk '{print $1}')
                local pod_status
                pod_status=$(echo "$line" | awk '{print $3}')
                echo -e "  ${RED}$pod_name: $pod_status${NC}"
            fi
        done
    else
        record_ok "All OVN-K pods are Running"
    fi

    # Check for pod restarts
    local high_restarts
    high_restarts=$(echo "$pod_output" | tail -n +2 | awk '{if ($4+0 > 5) print $1, $4}' || true)
    if [[ -n "$high_restarts" ]]; then
        record_warning "Some OVN-K pods have high restart counts:"
        echo "$high_restarts" | while read -r name restarts; do
            echo "  $name: $restarts restarts"
            echo "  $name: $restarts restarts" >> "$REPORT_FILE"
        done
    else
        record_ok "No excessive pod restarts detected"
    fi

    # Check for recent CrashLoopBackOff
    local crashloop
    crashloop=$(echo "$pod_output" | grep "CrashLoopBackOff" || true)
    if [[ -n "$crashloop" ]]; then
        record_critical "CrashLoopBackOff detected in OVN-K pods"
        echo "$crashloop" | while read -r line; do
            local pod_name
            pod_name=$(echo "$line" | awk '{print $1}')
            print_info "Recent logs for $pod_name:"
            oc logs -n "$OVN_NAMESPACE" "$pod_name" --tail=20 2>/dev/null | tee_report || true
        done
    fi
}

# ---------------------------------------------------------------------------
# Check 2: OVN Database Cluster Health (Raft)
# ---------------------------------------------------------------------------

check_db_cluster_health() {
    print_header "Check: OVN Database Cluster Health (Raft)"

    if [[ "$POD_STYLE" == "unknown" ]]; then
        record_warning "Skipping raft check - pod style unknown"
        return
    fi

    local nb_container sb_container
    nb_container=$(get_nbdb_container)
    sb_container=$(get_sbdb_container)

    # --- Northbound DB ---
    print_subheader "Northbound DB Cluster"
    local nb_leader_found=false
    local nb_member_count=0
    local nb_uncommitted=false

    for pod in $CONTROL_PLANE_PODS; do
        local nb_status
        if nb_status=$(ovn_exec "$pod" "$nb_container" \
            ovs-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound 2>&1); then
            ((nb_member_count++)) || true
            echo "$nb_status" >> "$REPORT_FILE"

            if echo "$nb_status" | grep -q "Role: leader"; then
                nb_leader_found=true
                print_info "NB Leader: $pod"
            fi

            # Check for uncommitted entries
            local uncommitted
            uncommitted=$(echo "$nb_status" | grep "Entries not yet committed:" | awk '{print $NF}' || echo "0")
            if [[ "$uncommitted" -gt 0 ]] 2>/dev/null; then
                nb_uncommitted=true
                record_warning "NB raft on $pod has $uncommitted uncommitted entries"
            fi

            # Check connection status
            local conn_status
            conn_status=$(echo "$nb_status" | grep "Status:" || true)
            if echo "$conn_status" | grep -qi "disconnected"; then
                record_warning "NB raft member $pod shows disconnected peers"
            fi
        else
            record_warning "Could not query NB raft status on $pod"
            echo "NB raft query failed on $pod: $nb_status" >> "$REPORT_FILE"
        fi
    done

    if [[ "$nb_leader_found" == true ]]; then
        record_ok "NB database has a leader"
    else
        record_critical "NB database has NO leader - cluster may be unavailable"
    fi

    if [[ "$nb_member_count" -gt 0 ]]; then
        record_ok "NB raft cluster has $nb_member_count reachable members"
    else
        record_critical "No NB raft members could be contacted"
    fi

    if [[ "$nb_uncommitted" == false ]]; then
        record_ok "NB raft has no uncommitted log entries"
    fi

    # --- Southbound DB ---
    print_subheader "Southbound DB Cluster"
    local sb_leader_found=false
    local sb_member_count=0
    local sb_uncommitted=false

    for pod in $CONTROL_PLANE_PODS; do
        local sb_status
        if sb_status=$(ovn_exec "$pod" "$sb_container" \
            ovs-appctl -t /var/run/ovn/ovnsb_db.ctl cluster/status OVN_Southbound 2>&1); then
            ((sb_member_count++)) || true
            echo "$sb_status" >> "$REPORT_FILE"

            if echo "$sb_status" | grep -q "Role: leader"; then
                sb_leader_found=true
                print_info "SB Leader: $pod"
            fi

            local uncommitted
            uncommitted=$(echo "$sb_status" | grep "Entries not yet committed:" | awk '{print $NF}' || echo "0")
            if [[ "$uncommitted" -gt 0 ]] 2>/dev/null; then
                sb_uncommitted=true
                record_warning "SB raft on $pod has $uncommitted uncommitted entries"
            fi
        else
            record_warning "Could not query SB raft status on $pod"
            echo "SB raft query failed on $pod: $sb_status" >> "$REPORT_FILE"
        fi
    done

    if [[ "$sb_leader_found" == true ]]; then
        record_ok "SB database has a leader"
    else
        record_critical "SB database has NO leader - cluster may be unavailable"
    fi

    if [[ "$sb_member_count" -gt 0 ]]; then
        record_ok "SB raft cluster has $sb_member_count reachable members"
    else
        record_critical "No SB raft members could be contacted"
    fi

    if [[ "$sb_uncommitted" == false ]]; then
        record_ok "SB raft has no uncommitted log entries"
    fi
}

# ---------------------------------------------------------------------------
# Check 3: ovn-controller Connection Status
# ---------------------------------------------------------------------------

check_ovn_controller() {
    print_header "Check: ovn-controller Connection Status"

    if [[ "$POD_STYLE" == "unknown" ]]; then
        record_warning "Skipping ovn-controller check - pod style unknown"
        return
    fi

    local pods_to_check="$NODE_PODS"
    if [[ -n "$TARGET_NODE" ]]; then
        local label
        if [[ "$POD_STYLE" == "new" ]]; then
            label="app=ovnkube-node"
        else
            label="app=ovnkube-node"
        fi
        pods_to_check=$(oc get pods -n "$OVN_NAMESPACE" -l "$label" \
            --field-selector spec.nodeName="$TARGET_NODE" --no-headers \
            -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
    fi

    if [[ -z "$pods_to_check" ]]; then
        record_warning "No ovnkube-node pods found to check"
        return
    fi

    local checked=0
    local connected=0
    local disconnected=0

    for pod in $pods_to_check; do
        ((checked++)) || true
        local node_name
        node_name=$(oc get pod -n "$OVN_NAMESPACE" "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "unknown")

        # Check ovn-controller connection to SB
        local conn_status
        if conn_status=$(ovn_exec "$pod" ovnkube-controller \
            ovs-appctl -t /var/run/ovn/ovn-controller connection-status 2>&1); then
            if echo "$conn_status" | grep -qi "connected"; then
                ((connected++)) || true
                if [[ -n "$TARGET_NODE" ]] || [[ "$QUICK_MODE" == false ]]; then
                    record_ok "ovn-controller on $node_name ($pod): connected"
                fi
            else
                ((disconnected++)) || true
                record_critical "ovn-controller on $node_name ($pod): $conn_status"
            fi
        else
            # Fallback: check pod logs for connection issues
            local recent_logs
            recent_logs=$(oc logs -n "$OVN_NAMESPACE" "$pod" -c ovnkube-controller --tail=50 2>/dev/null || true)
            if echo "$recent_logs" | grep -qi "connection refused\|not connected\|failed to connect"; then
                ((disconnected++)) || true
                record_critical "ovn-controller on $node_name ($pod): connection issues in logs"
            else
                record_warning "Could not determine ovn-controller status on $node_name ($pod)"
            fi
        fi

        # In quick mode, only check a few
        if [[ "$QUICK_MODE" == true ]] && [[ $checked -ge 3 ]]; then
            print_info "Quick mode: checked $checked nodes, skipping remaining..."
            break
        fi
    done

    if [[ $disconnected -eq 0 ]] && [[ $connected -gt 0 ]]; then
        record_ok "All checked ovn-controllers ($connected/$checked) connected to SB database"
    elif [[ $disconnected -gt 0 ]]; then
        record_critical "$disconnected/$checked ovn-controllers are disconnected"
    fi

    echo "" >> "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Check 4: Networking Events
# ---------------------------------------------------------------------------

check_networking_events() {
    print_header "Check: Networking Events"

    print_subheader "Events in $OVN_NAMESPACE"
    local events
    events=$(oc get events -n "$OVN_NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null | tail -30 || true)
    echo "$events" | tee_report

    # Check for warning/error events
    local warning_events
    warning_events=$(echo "$events" | grep -i "Warning\|Error\|Failed" || true)
    if [[ -n "$warning_events" ]]; then
        local wcount
        wcount=$(echo "$warning_events" | grep -c . || echo 0)
        record_warning "$wcount warning/error events found in $OVN_NAMESPACE"
    else
        record_ok "No warning/error events in $OVN_NAMESPACE"
    fi

    if [[ "$QUICK_MODE" == false ]]; then
        print_subheader "NetworkPolicy-related Events (all namespaces)"
        local np_events
        np_events=$(oc get events -A --field-selector reason=NetworkPolicyCreated,reason=NetworkPolicyDeleted \
            2>/dev/null | tail -20 || true)
        if [[ -n "$np_events" && "$np_events" != *"No resources found"* ]]; then
            echo "$np_events" | tee_report
        else
            print_info "No specific NetworkPolicy events found (this is normal)"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Check 5: Node Network State
# ---------------------------------------------------------------------------

check_node_network_state() {
    print_header "Check: Node Network State"

    local nodes
    if [[ -n "$TARGET_NODE" ]]; then
        nodes="$TARGET_NODE"
    else
        nodes=$(oc get nodes --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
    fi

    print_subheader "Node Conditions"
    echo "--- Node Network Conditions ---" >> "$REPORT_FILE"

    for node in $nodes; do
        # Check NetworkUnavailable condition
        local net_unavail
        net_unavail=$(oc get node "$node" -o jsonpath='{range .status.conditions[?(@.type=="NetworkUnavailable")]}{.status}{end}' 2>/dev/null || echo "Unknown")

        local ready
        ready=$(oc get node "$node" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || echo "Unknown")

        if [[ "$net_unavail" == "True" ]]; then
            record_critical "Node $node: NetworkUnavailable=True"
        elif [[ "$net_unavail" == "False" ]]; then
            if [[ "$QUICK_MODE" == false ]] || [[ -n "$TARGET_NODE" ]]; then
                record_ok "Node $node: NetworkUnavailable=False (healthy)"
            fi
        else
            record_warning "Node $node: NetworkUnavailable condition not found"
        fi

        if [[ "$ready" != "True" ]]; then
            record_critical "Node $node: NotReady"
        fi
    done

    # Overall summary for quick mode
    if [[ "$QUICK_MODE" == true ]] && [[ -z "$TARGET_NODE" ]]; then
        local total_nodes
        total_nodes=$(echo "$nodes" | wc -w)
        local unhealthy
        unhealthy=$(for n in $nodes; do
            oc get node "$n" -o jsonpath='{range .status.conditions[?(@.type=="NetworkUnavailable")]}{.status}{end}' 2>/dev/null
        done | grep -c "True" || echo 0)
        if [[ "$unhealthy" -eq 0 ]]; then
            record_ok "All $total_nodes nodes have NetworkUnavailable=False"
        fi
    fi

    # Node annotations related to OVN
    if [[ "$QUICK_MODE" == false ]]; then
        print_subheader "OVN Node Annotations"
        local sample_node
        sample_node=$(echo "$nodes" | head -1)
        if [[ -n "$sample_node" ]]; then
            print_info "OVN annotations on $sample_node:"
            oc get node "$sample_node" -o json 2>/dev/null \
                | python3 -c "
import json, sys
data = json.load(sys.stdin)
annotations = data.get('metadata', {}).get('annotations', {})
for key, val in sorted(annotations.items()):
    if 'ovn' in key.lower() or 'network' in key.lower():
        print(f'  {key}: {val}')
" 2>/dev/null | tee_report || print_info "Could not parse OVN annotations"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Check 6: Geneve Tunnel Status
# ---------------------------------------------------------------------------

check_geneve_tunnels() {
    print_header "Check: Geneve Tunnel Status"

    if [[ "$POD_STYLE" == "unknown" ]]; then
        record_warning "Skipping tunnel check - pod style unknown"
        return
    fi

    local pods_to_check
    if [[ -n "$TARGET_NODE" ]]; then
        local label="app=ovnkube-node"
        pods_to_check=$(oc get pods -n "$OVN_NAMESPACE" -l "$label" \
            --field-selector spec.nodeName="$TARGET_NODE" --no-headers \
            -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
    else
        pods_to_check=$(echo "$NODE_PODS" | head -3) # Check a sample
    fi

    if [[ -z "$pods_to_check" ]]; then
        record_warning "No ovnkube-node pods available to check tunnels"
        return
    fi

    for pod in $pods_to_check; do
        local node_name
        node_name=$(oc get pod -n "$OVN_NAMESPACE" "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "unknown")

        print_subheader "Tunnel ports on $node_name ($pod)"

        local ovs_show
        if ovs_show=$(ovn_exec "$pod" ovnkube-controller ovs-vsctl show 2>&1); then
            echo "$ovs_show" >> "$REPORT_FILE"

            # Count Geneve tunnel interfaces
            local tunnel_count
            tunnel_count=$(echo "$ovs_show" | grep -c "type: geneve" || echo 0)

            if [[ "$tunnel_count" -gt 0 ]]; then
                record_ok "Node $node_name: $tunnel_count Geneve tunnel interface(s) configured"
            else
                record_critical "Node $node_name: No Geneve tunnel interfaces found"
            fi

            # Check for tunnel errors
            if echo "$ovs_show" | grep -qi "error"; then
                record_warning "Node $node_name: Errors detected in OVS configuration"
            fi
        else
            record_warning "Could not query OVS on $node_name ($pod)"
        fi

        if [[ "$QUICK_MODE" == true ]]; then
            break
        fi
    done
}

# ---------------------------------------------------------------------------
# Check 7: OVS Flow Integrity
# ---------------------------------------------------------------------------

check_ovs_flows() {
    print_header "Check: OVS Flow Integrity on br-int"

    if [[ "$QUICK_MODE" == true ]] && [[ -z "$TARGET_NODE" ]]; then
        print_info "Quick mode: checking flows on one sample node only"
    fi

    if [[ "$POD_STYLE" == "unknown" ]]; then
        record_warning "Skipping OVS flow check - pod style unknown"
        return
    fi

    local pods_to_check
    if [[ -n "$TARGET_NODE" ]]; then
        pods_to_check=$(oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-node \
            --field-selector spec.nodeName="$TARGET_NODE" --no-headers \
            -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
    else
        pods_to_check=$(echo "$NODE_PODS" | head -3)
    fi

    if [[ -z "$pods_to_check" ]]; then
        record_warning "No ovnkube-node pods to check flows"
        return
    fi

    for pod in $pods_to_check; do
        local node_name
        node_name=$(oc get pod -n "$OVN_NAMESPACE" "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "unknown")

        local flow_count
        if flow_count=$(ovn_exec "$pod" ovnkube-controller \
            ovs-ofctl dump-flows br-int --no-stats 2>/dev/null | wc -l); then
            if [[ "$flow_count" -gt 10 ]]; then
                record_ok "Node $node_name: br-int has $flow_count flows (healthy)"
            elif [[ "$flow_count" -gt 0 ]]; then
                record_warning "Node $node_name: br-int has only $flow_count flows (low, possible issue)"
            else
                record_critical "Node $node_name: br-int has 0 flows (flows missing)"
            fi
            echo "Node $node_name: $flow_count flows on br-int" >> "$REPORT_FILE"
        else
            record_warning "Could not dump flows on $node_name"
        fi

        # Check for the existence of key tables (table 0 = classifier, table 44 = ACLs, etc.)
        if [[ "$QUICK_MODE" == false ]]; then
            local flows
            flows=$(ovn_exec "$pod" ovnkube-controller \
                ovs-ofctl dump-flows br-int --no-stats 2>/dev/null || true)
            if [[ -n "$flows" ]]; then
                local tables_present
                tables_present=$(echo "$flows" | grep -oP 'table=\d+' | sort -t= -k2 -n -u | wc -l || echo 0)
                print_info "Node $node_name: $tables_present distinct OpenFlow tables in use"
                echo "Node $node_name: $tables_present tables in use" >> "$REPORT_FILE"
            fi
        fi

        if [[ "$QUICK_MODE" == true ]]; then
            break
        fi
    done
}

# ---------------------------------------------------------------------------
# Check 8: NetworkPolicy / ACL Issues
# ---------------------------------------------------------------------------

check_acl_config() {
    print_header "Check: NetworkPolicy / ACL Configuration"

    if [[ "$QUICK_MODE" == true ]]; then
        # Just count NetworkPolicies
        local np_count
        np_count=$(oc get networkpolicy -A --no-headers 2>/dev/null | wc -l || echo 0)
        record_ok "Cluster has $np_count NetworkPolicies defined"
        return
    fi

    if [[ "$POD_STYLE" == "unknown" ]]; then
        record_warning "Skipping ACL check - pod style unknown"
        return
    fi

    local nb_container
    nb_container=$(get_nbdb_container)
    local leader_pod
    leader_pod=$(echo "$CONTROL_PLANE_PODS" | head -1)

    # Count ACLs
    local acl_output
    if acl_output=$(ovn_exec "$leader_pod" "$nb_container" \
        ovn-nbctl --no-leader-only --columns=_uuid,action,direction,priority,match list acl 2>&1); then
        local acl_count
        acl_count=$(echo "$acl_output" | grep -c "^_uuid" || echo 0)
        record_ok "OVN has $acl_count ACLs configured"

        # Check for deny ACLs
        local deny_count
        deny_count=$(echo "$acl_output" | grep -c "action.*: drop\|action.*: reject" || echo 0)
        if [[ "$deny_count" -gt 0 ]]; then
            print_info "$deny_count deny/reject ACLs found (NetworkPolicies active)"
        fi

        # Check for extremely high ACL counts (performance concern)
        if [[ "$acl_count" -gt 5000 ]]; then
            record_warning "High ACL count ($acl_count) - may impact OVN performance"
        fi
    else
        record_warning "Could not query ACLs from NB database"
    fi

    # Count NetworkPolicies
    local np_count
    np_count=$(oc get networkpolicy -A --no-headers 2>/dev/null | wc -l || echo 0)
    print_info "Cluster has $np_count Kubernetes NetworkPolicies"
    echo "Kubernetes NetworkPolicies: $np_count" >> "$REPORT_FILE"

    # Check for common ACL misconfigurations
    # Stale address sets (address sets with no addresses)
    local empty_as
    if empty_as=$(ovn_exec "$leader_pod" "$nb_container" \
        ovn-nbctl --no-leader-only --columns=name,addresses list address_set 2>&1); then
        local empty_count
        empty_count=$(echo "$empty_as" | grep -B1 'addresses.*\[\]' | grep -c "^name" || echo 0)
        if [[ "$empty_count" -gt 50 ]]; then
            record_warning "$empty_count empty address sets found (possible stale NetworkPolicy references)"
        else
            print_info "$empty_count empty address sets (normal)"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Check 9: OVN NB/SB Sync
# ---------------------------------------------------------------------------

check_nb_sb_sync() {
    print_header "Check: OVN NB/SB Synchronization"

    if [[ "$POD_STYLE" == "unknown" ]]; then
        record_warning "Skipping NB/SB sync check - pod style unknown"
        return
    fi

    local nb_container sb_container
    nb_container=$(get_nbdb_container)
    sb_container=$(get_sbdb_container)
    local leader_pod
    leader_pod=$(echo "$CONTROL_PLANE_PODS" | head -1)

    # Compare logical switch count in NB vs SB
    local nb_ls_count sb_ls_count
    nb_ls_count=$(ovn_exec "$leader_pod" "$nb_container" \
        ovn-nbctl --no-leader-only ls-list 2>/dev/null | wc -l || echo 0)
    sb_ls_count=$(ovn_exec "$leader_pod" "$sb_container" \
        ovn-sbctl --no-leader-only --columns=name list datapath_binding 2>/dev/null | grep -c "^name" || echo 0)

    print_info "NB logical switches: $nb_ls_count"
    print_info "SB datapath bindings: $sb_ls_count"
    echo "NB logical switches: $nb_ls_count, SB datapath bindings: $sb_ls_count" >> "$REPORT_FILE"

    # They won't match exactly (SB includes routers too), but zero is a problem
    if [[ "$nb_ls_count" -eq 0 ]]; then
        record_critical "No logical switches in NB database"
    elif [[ "$sb_ls_count" -eq 0 ]]; then
        record_critical "No datapath bindings in SB database - northd may not be running"
    else
        record_ok "NB and SB databases both contain data (NB: $nb_ls_count LS, SB: $sb_ls_count DP)"
    fi

    # Check northd status
    print_subheader "northd Status"
    for pod in $CONTROL_PLANE_PODS; do
        local northd_container
        if [[ "$POD_STYLE" == "new" ]]; then
            northd_container="northd"
        else
            northd_container="northd"
        fi

        local northd_status
        if northd_status=$(ovn_exec "$pod" "$northd_container" \
            ovs-appctl -t /var/run/ovn/ovn-northd status 2>&1); then
            echo "northd on $pod: $northd_status" | tee_report
            if echo "$northd_status" | grep -qi "active\|running"; then
                record_ok "northd active on $pod"
            fi
        else
            print_info "Could not query northd status on $pod (may be in standby)"
        fi

        if [[ "$QUICK_MODE" == true ]]; then
            break
        fi
    done
}

# ---------------------------------------------------------------------------
# Check 10: Pod Networking Failures
# ---------------------------------------------------------------------------

check_pod_networking_failures() {
    print_header "Check: Pod Networking Failures"

    # Look for pods with network-related issues
    print_subheader "Pods in Pending state with network issues"
    local pending_pods
    pending_pods=$(oc get pods -A --field-selector status.phase=Pending --no-headers 2>/dev/null \
        | head -20 || true)
    if [[ -n "$pending_pods" ]]; then
        local pcount
        pcount=$(echo "$pending_pods" | wc -l || echo 0)
        record_warning "$pcount pods in Pending state (may include network issues)"
        echo "$pending_pods" >> "$REPORT_FILE"
    else
        record_ok "No pods stuck in Pending state"
    fi

    # Check for recent events mentioning network errors
    print_subheader "Recent Network Error Events (cluster-wide)"
    local net_events
    net_events=$(oc get events -A --sort-by='.lastTimestamp' --no-headers 2>/dev/null \
        | grep -i "network\|subnet\|cni\|ovn\|multus\|ip address" | tail -15 || true)
    if [[ -n "$net_events" ]]; then
        record_warning "Network-related events found in cluster"
        echo "$net_events" | tee_report
    else
        record_ok "No recent network-related error events"
    fi

    # Check for FailedCreatePodSandBox
    local sandbox_errors
    sandbox_errors=$(oc get events -A --field-selector reason=FailedCreatePodSandBox \
        --no-headers 2>/dev/null | tail -10 || true)
    if [[ -n "$sandbox_errors" && "$sandbox_errors" != *"No resources found"* ]]; then
        record_warning "FailedCreatePodSandBox events found (CNI issues)"
        echo "$sandbox_errors" | tee_report
    else
        record_ok "No FailedCreatePodSandBox events"
    fi
}

# ---------------------------------------------------------------------------
# Check 11: DNS Resolution
# ---------------------------------------------------------------------------

check_dns() {
    print_header "Check: DNS Resolution (CoreDNS)"

    # Check CoreDNS pods
    print_subheader "CoreDNS Pod Status"
    local dns_pods
    dns_pods=$(oc get pods -n openshift-dns -l dns.operator.openshift.io/daemonset-dns=default \
        --no-headers 2>/dev/null || true)

    if [[ -z "$dns_pods" ]]; then
        # Try alternative label
        dns_pods=$(oc get pods -n openshift-dns --no-headers 2>/dev/null || true)
    fi

    if [[ -n "$dns_pods" ]]; then
        echo "$dns_pods" | tee_report

        local dns_non_running
        dns_non_running=$(echo "$dns_pods" | grep -v "Running" | grep -v "Completed" || true)
        if [[ -n "$dns_non_running" ]]; then
            local dns_bad_count
            dns_bad_count=$(echo "$dns_non_running" | grep -c . || echo 0)
            record_critical "$dns_bad_count CoreDNS pod(s) not Running"
        else
            record_ok "All CoreDNS pods are Running"
        fi
    else
        record_warning "Could not find CoreDNS pods in openshift-dns"
    fi

    # Check DNS operator
    print_subheader "DNS Operator Status"
    local dns_op_status
    if dns_op_status=$(oc get dns.operator/default -o jsonpath='{range .status.conditions[*]}{.type}={.status}{" "}{end}' 2>/dev/null); then
        echo "DNS operator conditions: $dns_op_status" | tee_report
        if echo "$dns_op_status" | grep -q "Available=True"; then
            record_ok "DNS operator reports Available=True"
        else
            record_warning "DNS operator may not be fully available"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Check 12: MTU Configuration
# ---------------------------------------------------------------------------

check_mtu() {
    print_header "Check: MTU Configuration"

    # Get cluster network MTU from network config
    local cluster_mtu
    cluster_mtu=$(oc get network.config cluster -o jsonpath='{.status.clusterNetworkMTU}' 2>/dev/null || echo "")

    if [[ -n "$cluster_mtu" ]]; then
        print_info "Cluster network MTU: $cluster_mtu"
        echo "Cluster network MTU: $cluster_mtu" >> "$REPORT_FILE"

        # Geneve overhead is 100 bytes; typical physical MTU is 1500
        # So cluster MTU should be physical MTU - 100
        if [[ "$cluster_mtu" -le 0 ]] 2>/dev/null; then
            record_critical "Invalid cluster MTU: $cluster_mtu"
        elif [[ "$cluster_mtu" -lt 1300 ]] 2>/dev/null; then
            record_warning "Cluster MTU ($cluster_mtu) is low - may cause fragmentation issues"
        else
            record_ok "Cluster MTU ($cluster_mtu) looks reasonable"
        fi
    else
        record_warning "Could not determine cluster network MTU"
    fi

    # Check a sample node's br-int MTU if not in quick mode
    if [[ "$QUICK_MODE" == false ]]; then
        local sample_pod
        sample_pod=$(echo "$NODE_PODS" | head -1)
        if [[ -n "$sample_pod" ]]; then
            print_subheader "Interface MTU on sample node"
            local iface_info
            if iface_info=$(ovn_exec "$sample_pod" ovnkube-controller \
                ip link show 2>&1); then
                echo "$iface_info" | grep "mtu" | head -10 | tee_report

                # Check for MTU mismatches between interfaces
                local mtus
                mtus=$(echo "$iface_info" | grep -oP 'mtu \K\d+' | sort -u || true)
                local mtu_count
                mtu_count=$(echo "$mtus" | wc -l || echo 0)
                if [[ "$mtu_count" -gt 3 ]]; then
                    record_warning "Multiple different MTU values detected on interfaces: $(echo $mtus | tr '\n' ' ')"
                fi
            fi
        fi
    fi
}

# ---------------------------------------------------------------------------
# Check 13: Common Issue Patterns in Logs
# ---------------------------------------------------------------------------

check_log_patterns() {
    print_header "Check: Common Error Patterns in OVN-K Logs"

    if [[ "$QUICK_MODE" == true ]]; then
        print_info "Quick mode: skipping detailed log analysis"
        return
    fi

    local patterns=(
        "connection refused"
        "failed to connect"
        "leader changed"
        "not connected"
        "timeout"
        "OOM"
        "out of memory"
        "Failed to"
        "Error:"
    )

    # Check a few control plane pods
    local pods_checked=0
    for pod in $CONTROL_PLANE_PODS; do
        ((pods_checked++)) || true
        if [[ $pods_checked -gt 2 ]]; then break; fi

        print_subheader "Log analysis: $pod"

        local containers
        containers=$(oc get pod -n "$OVN_NAMESPACE" "$pod" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || true)

        for container in $containers; do
            local logs
            logs=$(oc logs -n "$OVN_NAMESPACE" "$pod" -c "$container" --tail=200 --since=1h 2>/dev/null || true)
            if [[ -z "$logs" ]]; then continue; fi

            for pattern in "${patterns[@]}"; do
                local matches
                matches=$(echo "$logs" | grep -ci "$pattern" 2>/dev/null || echo 0)
                if [[ "$matches" -gt 0 ]]; then
                    if [[ "$matches" -gt 10 ]]; then
                        record_warning "$pod/$container: '$pattern' appears $matches times in recent logs"
                    else
                        print_info "$pod/$container: '$pattern' appears $matches time(s)"
                    fi
                    echo "$pod/$container: pattern '$pattern' count=$matches" >> "$REPORT_FILE"
                fi
            done
        done
    done

    if [[ $pods_checked -eq 0 ]]; then
        record_warning "No control plane pods available for log analysis"
    fi
}

# ---------------------------------------------------------------------------
# Must-gather hint
# ---------------------------------------------------------------------------

show_must_gather_hint() {
    print_header "Must-Gather Collection"

    echo -e "${CYAN}If further investigation is needed, collect a networking must-gather:${NC}"
    echo ""
    echo -e "${BOLD}  oc adm must-gather --dest-dir=/tmp/must-gather-networking \\${NC}"
    echo -e "${BOLD}    -- /usr/bin/gather_network_logs${NC}"
    echo ""
    echo -e "${CYAN}For a targeted OVN-specific collection:${NC}"
    echo ""
    echo -e "${BOLD}  oc adm must-gather --dest-dir=/tmp/must-gather-ovn \\${NC}"
    echo -e "${BOLD}    --image=quay.io/openshift/origin-must-gather \\${NC}"
    echo -e "${BOLD}    -- /usr/bin/gather_network_logs${NC}"
    echo ""
    echo -e "${CYAN}To open a support case, attach the must-gather archive.${NC}"

    {
        echo "--- Must-Gather Commands ---"
        echo "oc adm must-gather --dest-dir=/tmp/must-gather-networking -- /usr/bin/gather_network_logs"
        echo ""
    } >> "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Final Report Summary
# ---------------------------------------------------------------------------

print_final_report() {
    print_header "Troubleshooting Report Summary"

    local total=$((CRITICAL_COUNT + WARNING_COUNT + OK_COUNT))

    # Print counts
    echo -e "  ${RED}${BOLD}CRITICAL: $CRITICAL_COUNT${NC}"
    echo -e "  ${YELLOW}${BOLD}WARNING:  $WARNING_COUNT${NC}"
    echo -e "  ${GREEN}OK:       $OK_COUNT${NC}"
    echo -e "  TOTAL:    $total checks"
    echo ""

    {
        echo "============================================================"
        echo "  REPORT SUMMARY"
        echo "============================================================"
        echo "CRITICAL: $CRITICAL_COUNT"
        echo "WARNING:  $WARNING_COUNT"
        echo "OK:       $OK_COUNT"
        echo "TOTAL:    $total checks"
        echo ""
    } >> "$REPORT_FILE"

    # List critical findings
    if [[ ${#CRITICAL_FINDINGS[@]} -gt 0 ]]; then
        echo -e "${RED}${BOLD}--- Critical Issues ---${NC}"
        {
            echo "--- Critical Issues ---"
        } >> "$REPORT_FILE"
        for finding in "${CRITICAL_FINDINGS[@]}"; do
            echo -e "  ${RED}* $finding${NC}"
            echo "  * $finding" >> "$REPORT_FILE"
        done
        echo ""
        echo "" >> "$REPORT_FILE"
    fi

    # List warnings
    if [[ ${#WARNING_FINDINGS[@]} -gt 0 ]]; then
        echo -e "${YELLOW}${BOLD}--- Warnings ---${NC}"
        {
            echo "--- Warnings ---"
        } >> "$REPORT_FILE"
        for finding in "${WARNING_FINDINGS[@]}"; do
            echo -e "  ${YELLOW}* $finding${NC}"
            echo "  * $finding" >> "$REPORT_FILE"
        done
        echo ""
        echo "" >> "$REPORT_FILE"
    fi

    # List OK items (only if few, to keep it readable)
    if [[ ${#OK_FINDINGS[@]} -gt 0 ]] && [[ ${#OK_FINDINGS[@]} -le 20 ]]; then
        echo -e "${GREEN}--- Healthy Checks ---${NC}"
        {
            echo "--- Healthy Checks ---"
        } >> "$REPORT_FILE"
        for finding in "${OK_FINDINGS[@]}"; do
            echo -e "  ${GREEN}* $finding${NC}"
            echo "  * $finding" >> "$REPORT_FILE"
        done
        echo ""
        echo "" >> "$REPORT_FILE"
    elif [[ ${#OK_FINDINGS[@]} -gt 20 ]]; then
        echo -e "${GREEN}--- Healthy Checks ---${NC}"
        echo -e "  ${GREEN}$OK_COUNT checks passed (see report for details)${NC}"
        {
            echo "--- Healthy Checks ---"
            for finding in "${OK_FINDINGS[@]}"; do
                echo "  * $finding"
            done
            echo ""
        } >> "$REPORT_FILE"
    fi

    # Overall verdict
    echo ""
    if [[ $CRITICAL_COUNT -gt 0 ]]; then
        echo -e "${RED}${BOLD}VERDICT: $CRITICAL_COUNT critical issue(s) require immediate attention.${NC}"
        echo "VERDICT: $CRITICAL_COUNT critical issue(s) require immediate attention." >> "$REPORT_FILE"
    elif [[ $WARNING_COUNT -gt 0 ]]; then
        echo -e "${YELLOW}${BOLD}VERDICT: No critical issues, but $WARNING_COUNT warning(s) should be reviewed.${NC}"
        echo "VERDICT: No critical issues, but $WARNING_COUNT warning(s) should be reviewed." >> "$REPORT_FILE"
    else
        echo -e "${GREEN}${BOLD}VERDICT: OVN-Kubernetes appears healthy. No issues detected.${NC}"
        echo "VERDICT: OVN-Kubernetes appears healthy. No issues detected." >> "$REPORT_FILE"
    fi

    echo ""
    echo -e "${GREEN}[OK]${NC} Full report saved to: $REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --node)
                if [[ -z "${2:-}" ]]; then
                    echo -e "${RED}[ERROR]${NC} --node requires a node name argument"
                    exit 1
                fi
                TARGET_NODE="$2"
                shift 2
                ;;
            --quick)
                QUICK_MODE=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo -e "${RED}[ERROR]${NC} Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    echo -e "${BOLD}${BLUE}"
    echo "  ___  _   _ _  _   _  __   _____                _     _           _           _   "
    echo " / _ \\| | | | \\| | | |/ /  |_   _| __ ___  _  _| |__ | | ___  ___| |__   ___ | |_ "
    echo "| (_) | |_| | .\` | | ' <     | || '__/ _ \\| | | | '_ \\| |/ _ \\/ __| '_ \\ / _ \\| __|"
    echo " \\___/ \\___/|_|\\_| |_|\\_\\    |_||_|  \\___/|_,_|_.__/|_|\\___/\\___|_| |_|\\___/ \\__|"
    echo -e "${NC}"
    echo -e "${CYAN}OVN-Kubernetes Troubleshooting Helper for Red Hat OpenShift${NC}"
    if [[ "$QUICK_MODE" == true ]]; then
        echo -e "${YELLOW}Running in quick mode${NC}"
    fi
    echo ""

    preflight_checks
    detect_pod_style

    check_pod_health
    check_db_cluster_health
    check_ovn_controller

    if [[ "$QUICK_MODE" == false ]]; then
        check_networking_events
    fi

    check_node_network_state
    check_geneve_tunnels
    check_ovs_flows

    if [[ "$QUICK_MODE" == false ]]; then
        check_acl_config
        check_nb_sb_sync
    fi

    check_pod_networking_failures
    check_dns
    check_mtu

    if [[ "$QUICK_MODE" == false ]]; then
        check_log_patterns
    fi

    show_must_gather_hint
    print_final_report
}

main "$@"
