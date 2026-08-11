#!/bin/bash
set -euo pipefail

###############################################################################
# inspect-ovn.sh - OVN Inspection for RHOSO (Red Hat OpenStack Services on OpenShift)
#
# Inspects OVN state in a RHOSO environment. In RHOSO, OVN NB/SB databases
# run in pods on OpenShift (control plane), while ovn-controller runs on
# bare-metal data plane nodes alongside OVS. This script accesses the OVN
# databases via 'oc exec' into the appropriate pods and reaches data plane
# nodes via SSH.
#
# Usage:
#   ./inspect-ovn.sh [OPTIONS]
#
# Options:
#   --namespace <ns>          OpenShift namespace for OpenStack (default: openstack)
#   --dataplane-node <host>   Also inspect ovn-controller on this data plane node
#   --all-nodes               Discover and inspect ovn-controller on all data plane nodes
#   --ssh-key <path>          Path to SSH private key (default: ~/.ssh/id_rsa)
#   --ssh-user <user>         SSH user for data plane nodes (default: root)
#   --output-dir <dir>        Directory for report files (default: ./reports)
#   --no-report               Print to stdout only, do not save a report file
#   --help                    Show this help message
#
# Examples:
#   ./inspect-ovn.sh
#   ./inspect-ovn.sh --all-nodes --ssh-user root
#   ./inspect-ovn.sh --dataplane-node 192.168.122.100 --namespace openstack
#
# Requirements:
#   - oc (OpenShift CLI) logged into the OCP cluster
#   - SSH access to data plane nodes (for ovn-controller inspection)
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
NC='\033[0m'

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
NAMESPACE="openstack"
DATAPLANE_NODE=""
ALL_NODES=false
SSH_KEY="${HOME}/.ssh/id_rsa"
SSH_USER="root"
OUTPUT_DIR="./reports"
NO_REPORT=false
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_FILE=""

# Pod names discovered at runtime
NB_POD=""
SB_POD=""

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
info()      { echo -e "${BLUE}[INFO]${NC}  $*"; }
success()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()      { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()     { echo -e "${RED}[ERROR]${NC} $*"; }
header()    { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}\n"; }
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
            --namespace)
                NAMESPACE="$2"; shift 2 ;;
            --dataplane-node)
                DATAPLANE_NODE="$2"; shift 2 ;;
            --all-nodes)
                ALL_NODES=true; shift ;;
            --ssh-key)
                SSH_KEY="$2"; shift 2 ;;
            --ssh-user)
                SSH_USER="$2"; shift 2 ;;
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
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflight() {
    header "Pre-flight Checks"

    if ! command -v oc &>/dev/null; then
        error "'oc' CLI not found in PATH."
        exit 1
    fi
    success "oc CLI found"

    if ! oc whoami &>/dev/null; then
        error "Not logged into an OpenShift cluster. Run 'oc login' first."
        exit 1
    fi
    success "Logged into OpenShift as $(oc whoami) on $(oc whoami --show-server)"

    if [[ "$ALL_NODES" == true || -n "$DATAPLANE_NODE" ]]; then
        if [[ ! -f "$SSH_KEY" ]]; then
            warn "SSH key not found at $SSH_KEY - data plane inspection may fail."
        else
            success "SSH key found: $SSH_KEY"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Report helpers
# ---------------------------------------------------------------------------
setup_report() {
    if [[ "$NO_REPORT" == true ]]; then
        return
    fi
    mkdir -p "$OUTPUT_DIR"
    REPORT_FILE="${OUTPUT_DIR}/ovn-inspect-${TIMESTAMP}.log"
    info "Report will be saved to: ${BOLD}${REPORT_FILE}${NC}"
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
# Find OVN pods on the control plane
# ---------------------------------------------------------------------------
find_ovn_pods() {
    header "Discovering OVN Pods (namespace: $NAMESPACE)"

    info "All OVN-related pods:"
    oc get pods -n "$NAMESPACE" 2>/dev/null | grep -iE 'ovn' || {
        error "No OVN pods found in namespace $NAMESPACE."
        error "Verify the namespace or that the OpenStack control plane is deployed."
        exit 1
    }
    echo ""

    # Find the NB DB pod (look for ovsdb-server-nb or ovn-northd containers)
    info "Locating OVN Northbound DB pod ..."
    NB_POD=$(oc get pods -n "$NAMESPACE" -l service=ovsdb-server-nb \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -z "$NB_POD" ]]; then
        # Alternate: look for pod names containing "nb"
        NB_POD=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
            | grep -iE 'ovn.*nb' | head -1 | awk '{print $1}' || true)
    fi
    if [[ -z "$NB_POD" ]]; then
        # Broader search: any ovn-northd pod can access NB
        NB_POD=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
            | grep -iE 'ovn-northd\|ovsdb-server-nb' | head -1 | awk '{print $1}' || true)
    fi
    if [[ -z "$NB_POD" ]]; then
        # Last resort: any ovn pod
        NB_POD=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
            | grep -iE 'ovn' | head -1 | awk '{print $1}' || true)
    fi

    if [[ -z "$NB_POD" ]]; then
        error "Could not find an OVN NB pod. Aborting."
        exit 1
    fi
    success "NB pod: $NB_POD"

    # Find the SB DB pod
    info "Locating OVN Southbound DB pod ..."
    SB_POD=$(oc get pods -n "$NAMESPACE" -l service=ovsdb-server-sb \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -z "$SB_POD" ]]; then
        SB_POD=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
            | grep -iE 'ovn.*sb' | head -1 | awk '{print $1}' || true)
    fi
    if [[ -z "$SB_POD" ]]; then
        SB_POD=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
            | grep -iE 'ovsdb-server-sb' | head -1 | awk '{print $1}' || true)
    fi
    # Fall back to using the same pod as NB (some deployments colocate both)
    if [[ -z "$SB_POD" ]]; then
        SB_POD="$NB_POD"
        warn "Could not find a separate SB pod - using $NB_POD for SB queries too."
    fi
    success "SB pod: $SB_POD"
}

# ---------------------------------------------------------------------------
# Helper: run ovn-nbctl inside the NB pod
# ---------------------------------------------------------------------------
nb_exec() {
    oc exec -n "$NAMESPACE" "$NB_POD" -- ovn-nbctl "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Helper: run ovn-sbctl inside the SB pod
# ---------------------------------------------------------------------------
sb_exec() {
    oc exec -n "$NAMESPACE" "$SB_POD" -- ovn-sbctl "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Determine NB / SB leaders
# ---------------------------------------------------------------------------
check_db_leaders() {
    header "OVN Database Cluster Status"

    subheader "Northbound DB Cluster Status"
    oc exec -n "$NAMESPACE" "$NB_POD" -- \
        ovs-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound 2>/dev/null || \
    oc exec -n "$NAMESPACE" "$NB_POD" -- \
        ovs-appctl -t /var/run/ovn/ovsdb-server-nb.ctl cluster/status OVN_Northbound 2>/dev/null || \
        warn "Could not retrieve NB cluster status."

    subheader "Southbound DB Cluster Status"
    oc exec -n "$NAMESPACE" "$SB_POD" -- \
        ovs-appctl -t /var/run/ovn/ovnsb_db.ctl cluster/status OVN_Southbound 2>/dev/null || \
    oc exec -n "$NAMESPACE" "$SB_POD" -- \
        ovs-appctl -t /var/run/ovn/ovsdb-server-sb.ctl cluster/status OVN_Southbound 2>/dev/null || \
        warn "Could not retrieve SB cluster status."
}

# ---------------------------------------------------------------------------
# Northbound DB inspection
# ---------------------------------------------------------------------------
inspect_nb() {
    header "OVN Northbound Database"

    subheader "NB Summary (ovn-nbctl show)"
    nb_exec show || warn "ovn-nbctl show failed."

    subheader "Logical Switches"
    nb_exec ls-list || warn "Could not list logical switches."

    subheader "Logical Switch Ports (per switch)"
    local switches
    switches=$(nb_exec --format=table --no-headings --columns=name find Logical_Switch 2>/dev/null || true)
    if [[ -n "$switches" ]]; then
        while IFS= read -r sw; do
            sw=$(echo "$sw" | xargs)  # trim whitespace
            [[ -z "$sw" ]] && continue
            echo -e "${YELLOW}Switch: $sw${NC}"
            nb_exec lsp-list "$sw" 2>/dev/null || true
            echo ""
        done <<< "$switches"
    else
        # Fallback: try to parse from ls-list
        local sw_names
        sw_names=$(nb_exec ls-list 2>/dev/null | awk '{print $2}' | tr -d '()' || true)
        for sw in $sw_names; do
            [[ -z "$sw" ]] && continue
            echo -e "${YELLOW}Switch: $sw${NC}"
            nb_exec lsp-list "$sw" 2>/dev/null || true
            echo ""
        done
    fi

    subheader "Logical Routers"
    nb_exec lr-list || warn "Could not list logical routers."

    subheader "Logical Router Routes (per router)"
    local routers
    routers=$(nb_exec lr-list 2>/dev/null | awk '{print $2}' | tr -d '()' || true)
    for lr in $routers; do
        [[ -z "$lr" ]] && continue
        echo -e "${YELLOW}Router: $lr${NC}"
        nb_exec lr-route-list "$lr" 2>/dev/null || true
        echo ""
    done

    subheader "Logical Router Ports (per router)"
    for lr in $routers; do
        [[ -z "$lr" ]] && continue
        echo -e "${YELLOW}Router: $lr${NC}"
        nb_exec lrp-list "$lr" 2>/dev/null || true
        echo ""
    done

    subheader "ACLs"
    nb_exec acl-list 2>/dev/null || \
    nb_exec --format=table find ACL 2>/dev/null || \
        warn "Could not list ACLs."

    subheader "NAT Rules (per router)"
    for lr in $routers; do
        [[ -z "$lr" ]] && continue
        echo -e "${YELLOW}Router: $lr${NC}"
        nb_exec lr-nat-list "$lr" 2>/dev/null || true
        echo ""
    done

    subheader "Load Balancers"
    nb_exec lb-list 2>/dev/null || info "No load balancers or command not available."

    subheader "DHCP Options"
    nb_exec dhcp-options-list 2>/dev/null || info "No DHCP options configured or command not available."
}

# ---------------------------------------------------------------------------
# Southbound DB inspection
# ---------------------------------------------------------------------------
inspect_sb() {
    header "OVN Southbound Database"

    subheader "SB Summary (ovn-sbctl show)"
    sb_exec show || warn "ovn-sbctl show failed."

    subheader "Chassis List"
    sb_exec chassis-list 2>/dev/null || \
    sb_exec --format=table find Chassis 2>/dev/null || \
        warn "Could not list chassis."

    subheader "Port Bindings"
    sb_exec --format=table find Port_Binding 2>/dev/null | head -100 || \
        warn "Could not list port bindings."

    subheader "Port Binding Summary (type counts)"
    sb_exec --format=csv --no-headings --columns=type find Port_Binding 2>/dev/null \
        | sort | uniq -c | sort -rn || true

    subheader "MAC Bindings"
    sb_exec --format=table find MAC_Binding 2>/dev/null | head -50 || \
        info "No MAC bindings or command not available."

    subheader "Datapath Bindings"
    sb_exec --format=table find Datapath_Binding 2>/dev/null | head -50 || \
        warn "Could not list datapath bindings."

    subheader "Logical Flows Summary (count per table per datapath)"
    sb_exec --format=csv --no-headings --columns=logical_datapath,table_id find Logical_Flow 2>/dev/null \
        | sort | uniq -c | sort -rn | head -40 || \
        warn "Could not summarize logical flows."

    subheader "Total Logical Flow Count"
    local flow_count
    flow_count=$(sb_exec --format=csv --no-headings find Logical_Flow 2>/dev/null | wc -l || echo "unknown")
    info "Total logical flows: $flow_count"

    subheader "Connections"
    sb_exec --format=table find Connection 2>/dev/null || info "No connection entries."
}

# ---------------------------------------------------------------------------
# OVN Topology summary
# ---------------------------------------------------------------------------
topology_summary() {
    header "OVN Topology Summary"

    local num_switches num_routers num_ports num_acls num_chassis

    num_switches=$(nb_exec ls-list 2>/dev/null | wc -l || echo "?")
    num_routers=$(nb_exec lr-list 2>/dev/null | wc -l || echo "?")
    num_ports=$(nb_exec --format=csv --no-headings find Logical_Switch_Port 2>/dev/null | wc -l || echo "?")
    num_acls=$(nb_exec --format=csv --no-headings find ACL 2>/dev/null | wc -l || echo "?")
    num_chassis=$(sb_exec --format=csv --no-headings find Chassis 2>/dev/null | wc -l || echo "?")

    echo -e "${BOLD}Topology Overview:${NC}"
    echo "  Logical Switches:       $num_switches"
    echo "  Logical Routers:        $num_routers"
    echo "  Logical Switch Ports:   $num_ports"
    echo "  ACLs:                   $num_acls"
    echo "  Chassis (data plane):   $num_chassis"
    echo ""

    # Show connections between routers and switches
    subheader "Router-to-Switch Connections"
    local routers
    routers=$(nb_exec lr-list 2>/dev/null | awk '{print $2}' | tr -d '()' || true)
    for lr in $routers; do
        [[ -z "$lr" ]] && continue
        echo -e "${YELLOW}Router: $lr${NC}"
        local ports
        ports=$(nb_exec lrp-list "$lr" 2>/dev/null || true)
        echo "$ports"
        # For each router port, find the peer switch port
        while IFS= read -r port_line; do
            local port_name
            port_name=$(echo "$port_line" | awk '{print $2}' | tr -d '()' || true)
            [[ -z "$port_name" ]] && continue
            local peer
            peer=$(nb_exec get Logical_Router_Port "$port_name" peer 2>/dev/null | tr -d '"' || true)
            if [[ -n "$peer" && "$peer" != "[]" ]]; then
                echo "    -> peers with: $peer"
            fi
        done <<< "$ports"
        echo ""
    done
}

# ---------------------------------------------------------------------------
# Discover data plane nodes
# ---------------------------------------------------------------------------
discover_nodes() {
    header "Discovering Data Plane Nodes"

    local nodes=()

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
                hosts=$(oc get openstackdataplanenodeset "$ns_name" -n "$NAMESPACE" \
                    -o jsonpath='{range .spec.nodes[*]}{.hostName}{"\n"}{end}' 2>/dev/null || true)
            fi
            for h in $hosts; do
                [[ -n "$h" ]] && nodes+=("$h")
            done
        done
    fi

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

    if [[ ${#nodes[@]} -eq 0 ]]; then
        # Try to discover from SB chassis list
        info "Trying to discover nodes from OVN SB chassis list ..."
        local chassis_hosts
        chassis_hosts=$(sb_exec --format=csv --no-headings --columns=hostname find Chassis 2>/dev/null || true)
        for h in $chassis_hosts; do
            [[ -n "$h" ]] && nodes+=("$h")
        done
    fi

    if [[ ${#nodes[@]} -eq 0 ]]; then
        error "Could not auto-discover data plane nodes."
        error "Use --dataplane-node <host> to specify one manually."
        exit 1
    fi

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
# Inspect ovn-controller on a data plane node
# ---------------------------------------------------------------------------
inspect_dataplane_node() {
    local node="$1"

    header "OVN Controller on Data Plane Node: $node"

    subheader "SSH Connectivity Check"
    if ! ssh_cmd "$node" "echo 'SSH connection successful'" 2>/dev/null; then
        error "Cannot SSH into $node - skipping this node."
        return 1
    fi
    success "SSH connection to $node established"

    subheader "ovn-controller Status"
    ssh_cmd "$node" "sudo systemctl status ovn-controller --no-pager -l 2>/dev/null || \
                     echo 'ovn-controller service status not available'" || true

    subheader "ovn-controller Version"
    ssh_cmd "$node" "sudo ovn-controller --version 2>/dev/null || echo 'version not available'" || true

    subheader "OVN Remote Configuration"
    ssh_cmd "$node" "sudo ovs-vsctl get open_vswitch . external_ids:ovn-remote 2>/dev/null || \
                     echo 'ovn-remote not configured'" || true

    subheader "OVN Encapsulation Configuration"
    ssh_cmd "$node" "sudo ovs-vsctl get open_vswitch . external_ids:ovn-encap-type 2>/dev/null || true" || true
    ssh_cmd "$node" "sudo ovs-vsctl get open_vswitch . external_ids:ovn-encap-ip 2>/dev/null || true" || true

    subheader "OVN External IDs"
    ssh_cmd "$node" "sudo ovs-vsctl get open_vswitch . external_ids 2>/dev/null || true" || true

    subheader "Geneve Tunnel Status"
    ssh_cmd "$node" "sudo ovs-vsctl find interface type=geneve 2>/dev/null || echo 'No Geneve tunnels found'" || true

    subheader "Geneve Tunnel Ports on br-int"
    ssh_cmd "$node" "sudo ovs-vsctl list-ports br-int 2>/dev/null | while read -r port; do
        type=\$(sudo ovs-vsctl get interface \"\$port\" type 2>/dev/null || true)
        if [[ \"\$type\" == *geneve* || \"\$type\" == *vxlan* ]]; then
            remote=\$(sudo ovs-vsctl get interface \"\$port\" options:remote_ip 2>/dev/null || true)
            echo \"  \$port (type=\$type, remote_ip=\$remote)\"
        fi
    done" || true

    subheader "ovn-controller Connection Status"
    ssh_cmd "$node" "sudo ovs-appctl -t ovn-controller connection-status 2>/dev/null || \
                     echo 'Could not query connection status'" || true

    subheader "Recent ovn-controller Log Entries (last 20 lines)"
    ssh_cmd "$node" "sudo journalctl -u ovn-controller --no-pager -n 20 2>/dev/null || \
                     sudo tail -20 /var/log/ovn/ovn-controller.log 2>/dev/null || \
                     echo 'Could not read ovn-controller logs'" || true

    success "Data plane inspection complete for node: $node"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo -e "${CYAN}${BOLD}"
    echo "================================================================="
    echo "  OVN Inspection for RHOSO"
    echo "  Red Hat OpenStack Services on OpenShift"
    echo "  $(date)"
    echo "================================================================="
    echo -e "${NC}"

    parse_args "$@"
    setup_report
    preflight

    # Discover OVN pods on the control plane
    find_ovn_pods

    # Check cluster / leader status
    check_db_leaders

    # Inspect Northbound DB
    inspect_nb

    # Inspect Southbound DB
    inspect_sb

    # Topology summary
    topology_summary

    # Inspect data plane nodes if requested
    if [[ "$ALL_NODES" == true || -n "$DATAPLANE_NODE" ]]; then
        local nodes_to_inspect=()
        if [[ "$ALL_NODES" == true ]]; then
            discover_nodes
            nodes_to_inspect=("${DISCOVERED_NODES[@]}")
        else
            nodes_to_inspect=("$DATAPLANE_NODE")
        fi

        local failed_nodes=()
        local dp_success_count=0
        for node in "${nodes_to_inspect[@]}"; do
            if inspect_dataplane_node "$node"; then
                ((dp_success_count++))
            else
                failed_nodes+=("$node")
            fi
        done

        header "Data Plane Inspection Summary"
        success "Nodes inspected successfully: $dp_success_count"
        if [[ ${#failed_nodes[@]} -gt 0 ]]; then
            warn "Nodes that failed inspection:"
            for n in "${failed_nodes[@]}"; do
                echo "    - $n"
            done
        fi
    else
        info ""
        info "Tip: Use --all-nodes or --dataplane-node <host> to also inspect"
        info "ovn-controller on data plane nodes."
    fi

    # Final summary
    header "Inspection Complete"
    success "OVN control plane inspection finished."
    if [[ "$NO_REPORT" == false && -n "$REPORT_FILE" ]]; then
        success "Full report saved to: ${BOLD}${REPORT_FILE}${NC}"
    fi
}

main "$@"
