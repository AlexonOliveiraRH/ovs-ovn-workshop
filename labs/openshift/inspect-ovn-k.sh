#!/bin/bash
set -euo pipefail

# =============================================================================
# inspect-ovn-k.sh - Inspect OVN-Kubernetes in Red Hat OpenShift Container Platform
# =============================================================================
#
# Description:
#   Comprehensive inspection of OVN-Kubernetes components running in an
#   OpenShift cluster. Examines OVN databases, logical switches, routers,
#   load balancers, ACLs, address sets, OVS flows, Geneve tunnels, chassis,
#   and port bindings.
#
# Usage:
#   ./inspect-ovn-k.sh [OPTIONS]
#
# Options:
#   --node NODE    Focus inspection on a specific node
#   --all          Inspect OVS flows and tunnels on all nodes
#   --help         Show this help message
#
# Output:
#   Results are saved to /tmp/ovnk-inspect-YYYYMMDD-HHMMSS.txt
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
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Global variables
# ---------------------------------------------------------------------------
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_FILE="/tmp/ovnk-inspect-${TIMESTAMP}.txt"
TARGET_NODE=""
INSPECT_ALL=false
OVN_NAMESPACE="openshift-ovn-kubernetes"
NB_LEADER_POD=""
SB_LEADER_POD=""
CONTROL_PLANE_PODS=""
NODE_PODS=""
POD_STYLE=""  # "new" for ovnkube-control-plane/ovnkube-node, "legacy" for ovnkube-master

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
${BOLD}inspect-ovn-k.sh${NC} - Inspect OVN-Kubernetes in OpenShift

${CYAN}USAGE:${NC}
    $0 [OPTIONS]

${CYAN}OPTIONS:${NC}
    --node NODE    Focus inspection on a specific node
    --all          Inspect OVS flows and tunnels on all nodes
    --help         Show this help message

${CYAN}OUTPUT:${NC}
    Results are saved to /tmp/ovnk-inspect-YYYYMMDD-HHMMSS.txt

${CYAN}EXAMPLES:${NC}
    $0                          # General OVN-K inspection
    $0 --node worker-0          # Focus on a specific node
    $0 --all                    # Inspect all nodes (OVS flows, tunnels)

${CYAN}PREREQUISITES:${NC}
    - oc CLI authenticated to an OpenShift cluster
    - Cluster-admin privileges
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

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

# Write to both stdout and report file
tee_report() {
    tee -a "$REPORT_FILE"
}

# Run a command and capture output, handling errors gracefully
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
        print_warn "Command failed: $*"
        echo "Command failed: $*" >> "$REPORT_FILE"
        echo "$output" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
        return 1
    fi
}

# Run oc exec inside an OVN pod
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

    # Check oc CLI
    if ! command -v oc &>/dev/null; then
        print_error "oc CLI not found. Please install it and authenticate to your cluster."
        exit 1
    fi
    print_ok "oc CLI found"

    # Check cluster connectivity
    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to an OpenShift cluster. Run 'oc login' first."
        exit 1
    fi
    local user
    user=$(oc whoami)
    print_ok "Logged in as: $user"

    # Check cluster-admin privileges
    if ! oc auth can-i get pods -n "$OVN_NAMESPACE" &>/dev/null; then
        print_error "Insufficient privileges. Cluster-admin access is required."
        exit 1
    fi
    print_ok "Sufficient privileges confirmed"

    # Check OVN namespace exists
    if ! oc get namespace "$OVN_NAMESPACE" &>/dev/null; then
        print_error "Namespace $OVN_NAMESPACE not found. Is OVN-Kubernetes the active CNI?"
        exit 1
    fi
    print_ok "Namespace $OVN_NAMESPACE exists"

    # Initialize report file
    {
        echo "============================================================"
        echo "  OVN-Kubernetes Inspection Report"
        echo "  Cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
        echo "  User: $user"
        echo "  Date: $(date)"
        echo "  Node filter: ${TARGET_NODE:-none (all nodes)}"
        echo "============================================================"
        echo ""
    } > "$REPORT_FILE"

    print_ok "Report file initialized: $REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Detect pod naming convention
# ---------------------------------------------------------------------------

detect_pod_style() {
    print_header "Detecting OVN-K Pod Style"

    # OCP 4.14+ uses ovnkube-control-plane and ovnkube-node
    # Older versions use ovnkube-master and ovnkube-node
    if oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-control-plane --no-headers 2>/dev/null | grep -q .; then
        POD_STYLE="new"
        print_ok "Detected OCP 4.14+ pod style (ovnkube-control-plane / ovnkube-node)"
    elif oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-master --no-headers 2>/dev/null | grep -q .; then
        POD_STYLE="legacy"
        print_ok "Detected legacy pod style (ovnkube-master / ovnkube-node)"
    else
        print_warn "Could not detect pod style by label. Attempting name-based detection."
        if oc get pods -n "$OVN_NAMESPACE" --no-headers 2>/dev/null | grep -q 'ovnkube-control-plane'; then
            POD_STYLE="new"
            print_ok "Detected OCP 4.14+ pod style via pod names"
        elif oc get pods -n "$OVN_NAMESPACE" --no-headers 2>/dev/null | grep -q 'ovnkube-master'; then
            POD_STYLE="legacy"
            print_ok "Detected legacy pod style via pod names"
        else
            print_error "Unable to detect OVN-K pod naming convention."
            exit 1
        fi
    fi

    echo "Pod style: $POD_STYLE" >> "$REPORT_FILE"

    # Populate pod lists
    if [[ "$POD_STYLE" == "new" ]]; then
        CONTROL_PLANE_PODS=$(oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-control-plane \
            --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
        NODE_PODS=$(oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-node \
            --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
    else
        CONTROL_PLANE_PODS=$(oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-master \
            --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
        NODE_PODS=$(oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-node \
            --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
    fi

    if [[ -z "$CONTROL_PLANE_PODS" ]]; then
        print_error "No control plane pods found."
        exit 1
    fi

    print_info "Control plane pods:"
    echo "$CONTROL_PLANE_PODS" | while read -r pod; do
        echo "    $pod"
    done
}

# ---------------------------------------------------------------------------
# Get the nbctl/sbctl container name depending on pod style
# ---------------------------------------------------------------------------

get_nbdb_container() {
    if [[ "$POD_STYLE" == "new" ]]; then
        echo "nbdb"
    else
        echo "northd"
    fi
}

get_sbdb_container() {
    if [[ "$POD_STYLE" == "new" ]]; then
        echo "sbdb"
    else
        echo "northd"
    fi
}

get_ovnkube_container() {
    if [[ "$POD_STYLE" == "new" ]]; then
        echo "ovnkube-cluster-manager"
    else
        echo "ovnkube-master"
    fi
}

get_node_ovnkube_container() {
    echo "ovnkube-controller"
}

# ---------------------------------------------------------------------------
# Section: OVN-K Pod Status
# ---------------------------------------------------------------------------

inspect_pod_status() {
    print_header "OVN-Kubernetes Pod Status"
    run_cmd "All pods in $OVN_NAMESPACE" \
        oc get pods -n "$OVN_NAMESPACE" -o wide
}

# ---------------------------------------------------------------------------
# Section: Cluster Network Configuration
# ---------------------------------------------------------------------------

inspect_network_config() {
    print_header "Cluster Network Configuration"
    run_cmd "network.config/cluster" \
        oc get network.config cluster -o yaml

    print_subheader "Cluster Network Operator Status"
    run_cmd "Cluster Network Operator" \
        oc get network.operator cluster -o yaml
}

# ---------------------------------------------------------------------------
# Section: OVN NB/SB Raft Leader
# ---------------------------------------------------------------------------

find_raft_leaders() {
    print_header "OVN Raft Cluster Status"

    local nb_container
    local sb_container
    nb_container=$(get_nbdb_container)
    sb_container=$(get_sbdb_container)

    print_subheader "Northbound DB Raft Status"
    echo "--- NB Raft Status ---" >> "$REPORT_FILE"

    for pod in $CONTROL_PLANE_PODS; do
        print_info "Checking NB raft on pod: $pod"
        local nb_status
        if nb_status=$(ovn_exec "$pod" "$nb_container" \
            ovs-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound 2>&1); then
            echo "$nb_status" >> "$REPORT_FILE"
            if echo "$nb_status" | grep -q "Role: leader"; then
                NB_LEADER_POD="$pod"
                print_ok "NB Leader: $pod"
            else
                local role
                role=$(echo "$nb_status" | grep "^Role:" | awk '{print $2}' || echo "unknown")
                print_info "NB $role: $pod"
            fi
        else
            print_warn "Could not get NB raft status from $pod"
            echo "Failed to get NB raft from $pod: $nb_status" >> "$REPORT_FILE"
        fi
    done
    echo "" >> "$REPORT_FILE"

    if [[ -z "$NB_LEADER_POD" ]]; then
        print_warn "No NB leader found. Using first control plane pod for NB queries."
        NB_LEADER_POD=$(echo "$CONTROL_PLANE_PODS" | head -1)
    fi

    print_subheader "Southbound DB Raft Status"
    echo "--- SB Raft Status ---" >> "$REPORT_FILE"

    for pod in $CONTROL_PLANE_PODS; do
        print_info "Checking SB raft on pod: $pod"
        local sb_status
        if sb_status=$(ovn_exec "$pod" "$sb_container" \
            ovs-appctl -t /var/run/ovn/ovnsb_db.ctl cluster/status OVN_Southbound 2>&1); then
            echo "$sb_status" >> "$REPORT_FILE"
            if echo "$sb_status" | grep -q "Role: leader"; then
                SB_LEADER_POD="$pod"
                print_ok "SB Leader: $pod"
            else
                local role
                role=$(echo "$sb_status" | grep "^Role:" | awk '{print $2}' || echo "unknown")
                print_info "SB $role: $pod"
            fi
        else
            print_warn "Could not get SB raft status from $pod"
            echo "Failed to get SB raft from $pod: $sb_status" >> "$REPORT_FILE"
        fi
    done
    echo "" >> "$REPORT_FILE"

    if [[ -z "$SB_LEADER_POD" ]]; then
        print_warn "No SB leader found. Using first control plane pod for SB queries."
        SB_LEADER_POD=$(echo "$CONTROL_PLANE_PODS" | head -1)
    fi
}

# ---------------------------------------------------------------------------
# Section: Logical Switches
# ---------------------------------------------------------------------------

inspect_logical_switches() {
    print_header "OVN Logical Switches"

    local nb_container
    nb_container=$(get_nbdb_container)

    print_subheader "Logical Switch List"
    run_cmd "Logical switches" \
        ovn_exec "$NB_LEADER_POD" "$nb_container" ovn-nbctl --no-leader-only ls-list

    print_subheader "Logical Switch Ports (summary)"
    echo "--- Logical Switch Ports ---" >> "$REPORT_FILE"

    local switches
    switches=$(ovn_exec "$NB_LEADER_POD" "$nb_container" \
        ovn-nbctl --no-leader-only ls-list 2>/dev/null | awk '{print $2}' | tr -d '()' || true)

    for sw in $switches; do
        print_info "Ports on switch: $sw"
        local ports
        if ports=$(ovn_exec "$NB_LEADER_POD" "$nb_container" \
            ovn-nbctl --no-leader-only lsp-list "$sw" 2>&1); then
            local count
            count=$(echo "$ports" | grep -c . || echo 0)
            echo "  Switch $sw: $count ports" | tee_report
        else
            print_warn "Could not list ports for switch $sw"
        fi
    done
}

# ---------------------------------------------------------------------------
# Section: Logical Routers
# ---------------------------------------------------------------------------

inspect_logical_routers() {
    print_header "OVN Logical Routers"

    local nb_container
    nb_container=$(get_nbdb_container)

    print_subheader "Logical Router List"
    run_cmd "Logical routers" \
        ovn_exec "$NB_LEADER_POD" "$nb_container" ovn-nbctl --no-leader-only lr-list

    print_subheader "Logical Router Ports"
    local routers
    routers=$(ovn_exec "$NB_LEADER_POD" "$nb_container" \
        ovn-nbctl --no-leader-only lr-list 2>/dev/null | awk '{print $2}' | tr -d '()' || true)

    for rt in $routers; do
        echo "--- Router: $rt ---" >> "$REPORT_FILE"
        print_info "Ports on router: $rt"
        ovn_exec "$NB_LEADER_POD" "$nb_container" \
            ovn-nbctl --no-leader-only lrp-list "$rt" 2>&1 | tee_report || true
    done

    print_subheader "Static Routes (ovn_cluster_router)"
    if ovn_exec "$NB_LEADER_POD" "$nb_container" \
        ovn-nbctl --no-leader-only lr-route-list ovn_cluster_router &>/dev/null; then
        run_cmd "Static routes on ovn_cluster_router" \
            ovn_exec "$NB_LEADER_POD" "$nb_container" \
            ovn-nbctl --no-leader-only lr-route-list ovn_cluster_router
    else
        print_warn "Could not list routes for ovn_cluster_router"
    fi

    print_subheader "NAT Rules (ovn_cluster_router)"
    if ovn_exec "$NB_LEADER_POD" "$nb_container" \
        ovn-nbctl --no-leader-only lr-nat-list ovn_cluster_router &>/dev/null; then
        run_cmd "NAT rules on ovn_cluster_router" \
            ovn_exec "$NB_LEADER_POD" "$nb_container" \
            ovn-nbctl --no-leader-only lr-nat-list ovn_cluster_router
    else
        print_warn "Could not list NAT rules for ovn_cluster_router"
    fi
}

# ---------------------------------------------------------------------------
# Section: Load Balancers
# ---------------------------------------------------------------------------

inspect_load_balancers() {
    print_header "OVN Load Balancers (Kubernetes Services)"

    local nb_container
    nb_container=$(get_nbdb_container)

    print_subheader "Load Balancer List"
    run_cmd "Load balancers" \
        ovn_exec "$NB_LEADER_POD" "$nb_container" ovn-nbctl --no-leader-only lb-list

    print_subheader "Load Balancer Groups"
    run_cmd "Load balancer groups" \
        ovn_exec "$NB_LEADER_POD" "$nb_container" ovn-nbctl --no-leader-only list load_balancer_group
}

# ---------------------------------------------------------------------------
# Section: ACLs (NetworkPolicies)
# ---------------------------------------------------------------------------

inspect_acls() {
    print_header "OVN ACLs (NetworkPolicies)"

    local nb_container
    nb_container=$(get_nbdb_container)

    local switches
    switches=$(ovn_exec "$NB_LEADER_POD" "$nb_container" \
        ovn-nbctl --no-leader-only ls-list 2>/dev/null | awk '{print $2}' | tr -d '()' || true)

    for sw in $switches; do
        local acls
        if acls=$(ovn_exec "$NB_LEADER_POD" "$nb_container" \
            ovn-nbctl --no-leader-only acl-list "$sw" 2>&1); then
            if [[ -n "$acls" ]]; then
                print_subheader "ACLs on switch: $sw"
                echo "$acls" | tee_report
            fi
        fi
    done

    print_subheader "Port Group ACLs (OCP 4.12+)"
    echo "--- Port Group ACLs ---" >> "$REPORT_FILE"
    print_info "In OCP 4.12+, ACLs are typically attached to port groups rather than switches."
    local pg_acls
    if pg_acls=$(ovn_exec "$NB_LEADER_POD" "$nb_container" \
        ovn-nbctl --no-leader-only --columns=name,acls list port_group 2>&1); then
        echo "$pg_acls" | tee_report
    else
        print_warn "Could not list port group ACLs"
    fi
}

# ---------------------------------------------------------------------------
# Section: Address Sets
# ---------------------------------------------------------------------------

inspect_address_sets() {
    print_header "OVN Address Sets (NetworkPolicy references)"

    local nb_container
    nb_container=$(get_nbdb_container)

    run_cmd "Address sets" \
        ovn_exec "$NB_LEADER_POD" "$nb_container" ovn-nbctl --no-leader-only list address_set
}

# ---------------------------------------------------------------------------
# Section: Chassis
# ---------------------------------------------------------------------------

inspect_chassis() {
    print_header "OVN Chassis (Southbound DB)"

    local sb_container
    sb_container=$(get_sbdb_container)

    print_subheader "Chassis List"
    run_cmd "Chassis list" \
        ovn_exec "$SB_LEADER_POD" "$sb_container" ovn-sbctl --no-leader-only list chassis

    print_subheader "Chassis Summary"
    run_cmd "Chassis summary" \
        ovn_exec "$SB_LEADER_POD" "$sb_container" ovn-sbctl --no-leader-only show
}

# ---------------------------------------------------------------------------
# Section: Port Bindings
# ---------------------------------------------------------------------------

inspect_port_bindings() {
    print_header "OVN Port Bindings"

    local sb_container
    sb_container=$(get_sbdb_container)

    if [[ -n "$TARGET_NODE" ]]; then
        print_subheader "Port Bindings for chassis (node): $TARGET_NODE"
        local chassis_name
        chassis_name=$(ovn_exec "$SB_LEADER_POD" "$sb_container" \
            ovn-sbctl --no-leader-only --columns=name find chassis hostname="$TARGET_NODE" 2>/dev/null \
            | grep "^name" | awk -F'"' '{print $2}' || echo "$TARGET_NODE")
        run_cmd "Port bindings for $TARGET_NODE" \
            ovn_exec "$SB_LEADER_POD" "$sb_container" \
            ovn-sbctl --no-leader-only find port_binding chassis="$chassis_name"
    else
        print_subheader "All Port Bindings (summary)"
        run_cmd "Port bindings" \
            ovn_exec "$SB_LEADER_POD" "$sb_container" \
            ovn-sbctl --no-leader-only --columns=logical_port,type,tunnel_key,chassis list port_binding
    fi
}

# ---------------------------------------------------------------------------
# Section: Geneve Tunnels
# ---------------------------------------------------------------------------

inspect_geneve_tunnels() {
    print_header "Geneve Tunnels"

    local nodes_to_inspect=()

    if [[ -n "$TARGET_NODE" ]]; then
        nodes_to_inspect=("$TARGET_NODE")
    elif [[ "$INSPECT_ALL" == true ]]; then
        mapfile -t nodes_to_inspect < <(oc get nodes --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
    else
        # Pick a node pod to show tunnel configuration
        local sample_pod
        sample_pod=$(echo "$NODE_PODS" | head -1)
        if [[ -n "$sample_pod" ]]; then
            print_subheader "Geneve tunnel interfaces (sample from $sample_pod)"
            run_cmd "OVS tunnel ports" \
                ovn_exec "$sample_pod" ovnkube-controller \
                ovs-vsctl show
        fi
        return
    fi

    for node in "${nodes_to_inspect[@]}"; do
        print_subheader "Geneve tunnels on node: $node"

        # Find the ovnkube-node pod running on this node
        local node_pod
        if [[ "$POD_STYLE" == "new" ]]; then
            node_pod=$(oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-node \
                --field-selector spec.nodeName="$node" --no-headers \
                -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
        else
            node_pod=$(oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-node \
                --field-selector spec.nodeName="$node" --no-headers \
                -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
        fi

        if [[ -n "$node_pod" ]]; then
            run_cmd "OVS interfaces on $node" \
                ovn_exec "$node_pod" ovnkube-controller \
                ovs-vsctl show
        else
            print_warn "No ovnkube-node pod found on node $node"
            # Try debug node as fallback
            print_info "Attempting via oc debug node..."
            run_cmd "OVS show on $node via debug" \
                oc debug "node/$node" --quiet -- chroot /host ovs-vsctl show || true
        fi
    done
}

# ---------------------------------------------------------------------------
# Section: OVS Flows
# ---------------------------------------------------------------------------

inspect_ovs_flows() {
    print_header "OVS Flows on br-int"

    local nodes_to_inspect=()

    if [[ -n "$TARGET_NODE" ]]; then
        nodes_to_inspect=("$TARGET_NODE")
    elif [[ "$INSPECT_ALL" == true ]]; then
        mapfile -t nodes_to_inspect < <(oc get nodes --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
    else
        print_info "Use --node NODE or --all to inspect OVS flows."
        print_info "Skipping OVS flow inspection (no node specified)."
        echo "OVS flow inspection skipped (no --node or --all specified)" >> "$REPORT_FILE"
        return
    fi

    for node in "${nodes_to_inspect[@]}"; do
        print_subheader "OVS flows on node: $node"

        # Find the ovnkube-node pod on this node
        local node_pod
        if [[ "$POD_STYLE" == "new" ]]; then
            node_pod=$(oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-node \
                --field-selector spec.nodeName="$node" --no-headers \
                -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
        else
            node_pod=$(oc get pods -n "$OVN_NAMESPACE" -l app=ovnkube-node \
                --field-selector spec.nodeName="$node" --no-headers \
                -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
        fi

        if [[ -n "$node_pod" ]]; then
            run_cmd "Flow count on $node" \
                ovn_exec "$node_pod" ovnkube-controller \
                ovs-ofctl dump-flows br-int --no-stats 2>/dev/null | wc -l || true

            run_cmd "OVS flows on $node (br-int)" \
                ovn_exec "$node_pod" ovnkube-controller \
                ovs-ofctl dump-flows br-int --no-stats
        else
            print_warn "No ovnkube-node pod on node $node, trying oc debug..."
            run_cmd "OVS flows on $node via debug" \
                oc debug "node/$node" --quiet -- chroot /host ovs-ofctl dump-flows br-int --no-stats || true
        fi
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --node)
                if [[ -z "${2:-}" ]]; then
                    print_error "--node requires a node name argument"
                    exit 1
                fi
                TARGET_NODE="$2"
                shift 2
                ;;
            --all)
                INSPECT_ALL=true
                shift
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
    echo "  ___  _   _ _  _   _  __       _                          _            "
    echo " / _ \\| | | | \\| | | |/ /      (_)_ _  ___ _ __  ___ __  | |_          "
    echo "| (_) | |_| | .\` | | ' <   _   | | ' \\(_-< '_ \\/ -_) _| |  _|         "
    echo " \\___/ \\___/|_|\\_| |_|\\_\\ (_)  |_|_||_/__/ .__/\\___\\__|  \\__|         "
    echo "                                          |_|                            "
    echo -e "${NC}"
    echo -e "${CYAN}OVN-Kubernetes Inspector for Red Hat OpenShift${NC}"
    echo ""

    preflight_checks
    detect_pod_style
    inspect_pod_status
    inspect_network_config
    find_raft_leaders
    inspect_logical_switches
    inspect_logical_routers
    inspect_load_balancers
    inspect_acls
    inspect_address_sets
    inspect_chassis
    inspect_port_bindings
    inspect_geneve_tunnels
    inspect_ovs_flows

    # Final summary
    print_header "Inspection Complete"
    print_ok "Report saved to: $REPORT_FILE"

    local total_lines
    total_lines=$(wc -l < "$REPORT_FILE")
    print_info "Report contains $total_lines lines"

    if [[ -n "$TARGET_NODE" ]]; then
        print_info "Inspection was focused on node: $TARGET_NODE"
    fi
    if [[ "$INSPECT_ALL" == true ]]; then
        print_info "Full cluster inspection was performed (all nodes)"
    fi
}

main "$@"
