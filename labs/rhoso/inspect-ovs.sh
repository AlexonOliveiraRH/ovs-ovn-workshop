#!/bin/bash
set -euo pipefail

###############################################################################
# inspect-ovs.sh - OVS Inspection for RHOSO (Red Hat OpenStack Services on OpenShift)
#
# Inspects Open vSwitch on RHOSO data plane nodes. In RHOSO, OVS runs on
# bare-metal data plane nodes while the control plane runs on OpenShift. This
# script SSHes into data plane nodes to gather OVS state and also checks for
# OVS-related pods on the control plane.
#
# Usage:
#   ./inspect-ovs.sh [OPTIONS]
#
# Options:
#   --dataplane-node <host>   Inspect a specific data plane node (IP or hostname)
#   --all-nodes               Discover and inspect all data plane nodes
#   --ssh-key <path>          Path to SSH private key (default: ~/.ssh/id_rsa)
#   --ssh-user <user>         SSH user for data plane nodes (default: root)
#   --namespace <ns>          OpenShift namespace for OpenStack (default: openstack)
#   --output-dir <dir>        Directory for report files (default: ./reports)
#   --no-report               Print to stdout only, do not save a report file
#   --help                    Show this help message
#
# Examples:
#   ./inspect-ovs.sh --all-nodes
#   ./inspect-ovs.sh --dataplane-node 192.168.122.100 --ssh-user root
#   ./inspect-ovs.sh --dataplane-node compute-0.example.com --ssh-key ~/.ssh/osp_key
#
# Requirements:
#   - oc (OpenShift CLI) logged into the OCP cluster
#   - SSH access to data plane nodes
#   - Permissions to run ovs-vsctl / ovs-ofctl / ovs-appctl on data plane nodes
###############################################################################

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
# Defaults
# ---------------------------------------------------------------------------
DATAPLANE_NODE=""
ALL_NODES=false
SSH_KEY="${HOME}/.ssh/id_rsa"
SSH_USER="root"
NAMESPACE="openstack"
OUTPUT_DIR="./reports"
NO_REPORT=false
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_FILE=""

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
header()  { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}\n"; }
subheader() { echo -e "\n${BLUE}--- $* ---${NC}\n"; }

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
usage() {
    sed -n '/^###/,/^###/{ /^###/d; s/^# \{0,1\}//; p }' "$0"
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dataplane-node)
                DATAPLANE_NODE="$2"; shift 2 ;;
            --all-nodes)
                ALL_NODES=true; shift ;;
            --ssh-key)
                SSH_KEY="$2"; shift 2 ;;
            --ssh-user)
                SSH_USER="$2"; shift 2 ;;
            --namespace)
                NAMESPACE="$2"; shift 2 ;;
            --output-dir)
                OUTPUT_DIR="$2"; shift 2 ;;
            --no-report)
                NO_REPORT=true; shift ;;
            --help|-h)
                usage ;;
            *)
                error "Unknown option: $1"
                echo "Use --help for usage information."
                exit 1 ;;
        esac
    done

    if [[ "$ALL_NODES" == false && -z "$DATAPLANE_NODE" ]]; then
        error "Specify --dataplane-node <host> or --all-nodes."
        echo "Use --help for usage information."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflight() {
    header "Pre-flight Checks"

    # oc CLI
    if ! command -v oc &>/dev/null; then
        error "'oc' CLI not found in PATH."
        exit 1
    fi
    success "oc CLI found: $(command -v oc)"

    # oc login status
    if ! oc whoami &>/dev/null; then
        error "Not logged into an OpenShift cluster. Run 'oc login' first."
        exit 1
    fi
    success "Logged into OpenShift as $(oc whoami) on $(oc whoami --show-server)"

    # SSH key
    if [[ ! -f "$SSH_KEY" ]]; then
        warn "SSH key not found at $SSH_KEY - SSH connections may fail."
    else
        success "SSH key found: $SSH_KEY"
    fi

    # ssh client
    if ! command -v ssh &>/dev/null; then
        error "'ssh' not found in PATH."
        exit 1
    fi
    success "ssh client available"
}

# ---------------------------------------------------------------------------
# Report / tee helpers
# ---------------------------------------------------------------------------
setup_report() {
    if [[ "$NO_REPORT" == true ]]; then
        return
    fi
    mkdir -p "$OUTPUT_DIR"
    REPORT_FILE="${OUTPUT_DIR}/ovs-inspect-${TIMESTAMP}.log"
    info "Report will be saved to: ${BOLD}${REPORT_FILE}${NC}"
    # Start tee - duplicate all further stdout/stderr to the report file.
    exec > >(tee -a "$REPORT_FILE") 2>&1
}

# ---------------------------------------------------------------------------
# SSH wrapper
# ---------------------------------------------------------------------------
ssh_cmd() {
    local host="$1"; shift
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o LogLevel=ERROR \
        -i "$SSH_KEY" \
        "${SSH_USER}@${host}" \
        "$@"
}

# ---------------------------------------------------------------------------
# Discover data plane nodes
# ---------------------------------------------------------------------------
discover_nodes() {
    header "Discovering Data Plane Nodes"

    local nodes=()

    # Method 1: OpenStackDataPlaneNodeSet CRD (preferred in RHOSO 18+)
    info "Trying oc get openstackdataplanenodeset in namespace $NAMESPACE ..."
    if oc get openstackdataplanenodeset -n "$NAMESPACE" &>/dev/null; then
        local nodeset_names
        nodeset_names=$(oc get openstackdataplanenodeset -n "$NAMESPACE" \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        for ns_name in $nodeset_names; do
            local hosts
            hosts=$(oc get openstackdataplanenodeset "$ns_name" -n "$NAMESPACE" \
                -o jsonpath='{range .spec.nodes[*]}{.ansibleHost}{"\n"}{end}' 2>/dev/null || true)
            if [[ -z "$hosts" ]]; then
                # Alternate path: hostName field
                hosts=$(oc get openstackdataplanenodeset "$ns_name" -n "$NAMESPACE" \
                    -o jsonpath='{range .spec.nodes[*]}{.hostName}{"\n"}{end}' 2>/dev/null || true)
            fi
            for h in $hosts; do
                [[ -n "$h" ]] && nodes+=("$h")
            done
        done
    fi

    # Method 2: Fall back to openstackdataplanenode CRD
    if [[ ${#nodes[@]} -eq 0 ]]; then
        info "Trying oc get openstackdataplanenode ..."
        if oc get openstackdataplanenode -n "$NAMESPACE" &>/dev/null; then
            local dp_hosts
            dp_hosts=$(oc get openstackdataplanenode -n "$NAMESPACE" \
                -o jsonpath='{range .items[*]}{.spec.ansibleHost}{"\n"}{end}' 2>/dev/null || true)
            for h in $dp_hosts; do
                [[ -n "$h" ]] && nodes+=("$h")
            done
        fi
    fi

    # Method 3: baremetalhost resources
    if [[ ${#nodes[@]} -eq 0 ]]; then
        info "Trying baremetalhost resources ..."
        local bmh_ips
        bmh_ips=$(oc get baremetalhost -A \
            -o jsonpath='{range .items[*]}{.status.provisioning.IP}{"\n"}{end}' 2>/dev/null || true)
        for h in $bmh_ips; do
            [[ -n "$h" ]] && nodes+=("$h")
        done
    fi

    if [[ ${#nodes[@]} -eq 0 ]]; then
        error "Could not auto-discover data plane nodes."
        error "Use --dataplane-node <host> to specify one manually."
        exit 1
    fi

    # De-duplicate
    local unique_nodes
    unique_nodes=$(printf '%s\n' "${nodes[@]}" | sort -u)
    DISCOVERED_NODES=()
    while IFS= read -r n; do
        [[ -n "$n" ]] && DISCOVERED_NODES+=("$n")
    done <<< "$unique_nodes"

    success "Discovered ${#DISCOVERED_NODES[@]} data plane node(s):"
    for n in "${DISCOVERED_NODES[@]}"; do
        echo "    - $n"
    done
}

# ---------------------------------------------------------------------------
# Check OVS-related pods on the control plane
# ---------------------------------------------------------------------------
check_control_plane_pods() {
    header "OVS-Related Pods on the Control Plane (namespace: $NAMESPACE)"

    local pods
    pods=$(oc get pods -n "$NAMESPACE" 2>/dev/null | grep -iE 'ovs|openvswitch' || true)
    if [[ -z "$pods" ]]; then
        info "No OVS-related pods found in namespace $NAMESPACE."
        info "This is expected in RHOSO - OVS runs directly on data plane nodes."
    else
        echo "$pods"
    fi

    # Also show OVN pods for context
    subheader "OVN Pods (for reference)"
    oc get pods -n "$NAMESPACE" 2>/dev/null | grep -iE 'ovn' || info "No OVN pods found."
}

# ---------------------------------------------------------------------------
# Inspect OVS on a single data plane node
# ---------------------------------------------------------------------------
inspect_node() {
    local node="$1"

    header "Inspecting OVS on Data Plane Node: $node"

    # Verify SSH connectivity
    subheader "SSH Connectivity Check"
    if ! ssh_cmd "$node" "echo 'SSH connection successful'" 2>/dev/null; then
        error "Cannot SSH into $node - skipping this node."
        return 1
    fi
    success "SSH connection to $node established"

    # OVS version
    subheader "OVS Version"
    ssh_cmd "$node" "sudo ovs-vsctl --version 2>/dev/null || echo 'ovs-vsctl not available'" || true

    # ovs-vsctl show (bridges, ports, interfaces)
    subheader "OVS Bridge Configuration (ovs-vsctl show)"
    ssh_cmd "$node" "sudo ovs-vsctl show 2>/dev/null || echo 'Failed to run ovs-vsctl show'" || true

    # List all bridges
    subheader "Bridge List"
    local bridges
    bridges=$(ssh_cmd "$node" "sudo ovs-vsctl list-br 2>/dev/null" || true)
    if [[ -z "$bridges" ]]; then
        warn "No bridges found on $node"
        return 0
    fi
    echo "$bridges"

    # For each bridge: dump flows, port stats
    while IFS= read -r bridge; do
        [[ -z "$bridge" ]] && continue

        subheader "Flows on bridge '$bridge' (ovs-ofctl dump-flows)"
        ssh_cmd "$node" "sudo ovs-ofctl dump-flows $bridge 2>/dev/null | head -200" || true

        subheader "Flow count per table on bridge '$bridge'"
        ssh_cmd "$node" "sudo ovs-ofctl dump-flows $bridge 2>/dev/null \
            | grep -oP 'table=\d+' \
            | sort \
            | uniq -c \
            | sort -rn" || true

        subheader "Port statistics on bridge '$bridge' (ovs-ofctl dump-ports)"
        ssh_cmd "$node" "sudo ovs-ofctl dump-ports $bridge 2>/dev/null" || true

        subheader "Port descriptions on bridge '$bridge'"
        ssh_cmd "$node" "sudo ovs-ofctl dump-ports-desc $bridge 2>/dev/null" || true

    done <<< "$bridges"

    # Tunnel endpoints (Geneve / VXLAN)
    subheader "Tunnel Endpoints"
    ssh_cmd "$node" "sudo ovs-vsctl find interface type=geneve 2>/dev/null" || true
    ssh_cmd "$node" "sudo ovs-vsctl find interface type=vxlan 2>/dev/null" || true

    # Interface statistics and error counters
    subheader "Interface Statistics and Error Counters"
    ssh_cmd "$node" "sudo ovs-vsctl list interface 2>/dev/null \
        | grep -E '^name|^statistics|^error' " || true

    # Detailed interface error report
    subheader "Interfaces with Errors (non-zero error counters)"
    ssh_cmd "$node" "
        sudo ovs-vsctl --columns=name,statistics list interface 2>/dev/null \
        | paste - - \
        | grep -v '{.*rx_errors=0.*tx_errors=0.*collisions=0.*rx_dropped=0.*tx_dropped=0.*}' \
        || echo 'No interfaces with errors detected.'
    " || true

    # Bond status
    subheader "Bond Status"
    local bonds
    bonds=$(ssh_cmd "$node" "sudo ovs-appctl bond/list 2>/dev/null" || true)
    if [[ -z "$bonds" || "$bonds" == *"no such command"* ]]; then
        info "No bonds configured or bond command unavailable."
    else
        echo "$bonds"
        # Show details for each bond
        local bond_names
        bond_names=$(echo "$bonds" | tail -n +2 | awk '{print $1}')
        for bond in $bond_names; do
            [[ -z "$bond" ]] && continue
            subheader "Bond details: $bond"
            ssh_cmd "$node" "sudo ovs-appctl bond/show $bond 2>/dev/null" || true
        done
    fi

    # DPDK status (if applicable)
    subheader "DPDK Status (if enabled)"
    ssh_cmd "$node" "sudo ovs-vsctl get Open_vSwitch . other_config:dpdk-init 2>/dev/null || echo 'DPDK not configured'" || true

    # OVS daemon status
    subheader "OVS Daemon Status"
    ssh_cmd "$node" "sudo systemctl status openvswitch --no-pager -l 2>/dev/null || \
                     sudo systemctl status ovs-vswitchd --no-pager -l 2>/dev/null || \
                     echo 'Could not determine OVS service status'" || true

    # OVS logs (last 20 lines)
    subheader "Recent OVS Log Entries (last 20 lines)"
    ssh_cmd "$node" "sudo journalctl -u ovs-vswitchd --no-pager -n 20 2>/dev/null || \
                     sudo tail -20 /var/log/openvswitch/ovs-vswitchd.log 2>/dev/null || \
                     echo 'Could not read OVS logs'" || true

    # Coverage counters (useful for troubleshooting)
    subheader "OVS Coverage Counters (top 20)"
    ssh_cmd "$node" "sudo ovs-appctl coverage/show 2>/dev/null | head -30" || true

    success "Inspection complete for node: $node"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo -e "${CYAN}${BOLD}"
    echo "================================================================="
    echo "  OVS Inspection for RHOSO"
    echo "  Red Hat OpenStack Services on OpenShift"
    echo "  $(date)"
    echo "================================================================="
    echo -e "${NC}"

    parse_args "$@"
    setup_report
    preflight

    # Determine which nodes to inspect
    local nodes_to_inspect=()
    if [[ "$ALL_NODES" == true ]]; then
        discover_nodes
        nodes_to_inspect=("${DISCOVERED_NODES[@]}")
    else
        nodes_to_inspect=("$DATAPLANE_NODE")
    fi

    # Check control plane pods
    check_control_plane_pods

    # Inspect each node
    local failed_nodes=()
    local success_count=0
    for node in "${nodes_to_inspect[@]}"; do
        if inspect_node "$node"; then
            ((success_count++))
        else
            failed_nodes+=("$node")
        fi
    done

    # Summary
    header "Inspection Summary"
    success "Nodes inspected successfully: $success_count"
    if [[ ${#failed_nodes[@]} -gt 0 ]]; then
        warn "Nodes that failed inspection:"
        for n in "${failed_nodes[@]}"; do
            echo "    - $n"
        done
    fi

    if [[ "$NO_REPORT" == false && -n "$REPORT_FILE" ]]; then
        echo ""
        success "Full report saved to: ${BOLD}${REPORT_FILE}${NC}"
    fi
}

main "$@"
