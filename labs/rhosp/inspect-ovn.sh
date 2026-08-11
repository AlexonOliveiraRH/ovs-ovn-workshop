#!/bin/bash
set -euo pipefail

###############################################################################
# inspect-ovn.sh - Inspect OVN configuration in a RHOSP environment
#
# Designed for Red Hat OpenStack Platform environments using the ML2/OVN
# networking backend. Inspects OVN Northbound and Southbound databases,
# logical switches, routers, ACLs, NAT rules, chassis bindings, logical
# flows, and the corresponding OVS datapath on br-int.
#
# Handles both containerized (RHOSP 16+) and non-containerized OVN access.
# All operations are read-only. No configuration changes are made.
#
# Usage:
#   ./inspect-ovn.sh [OPTIONS]
#
# Options:
#   --help            Show this help message
#   --no-report       Do not save output to a report file
#   --report-dir DIR  Directory for the report file (default: /tmp)
#   --section SEC     Run only a specific section:
#                       environment, nb-summary, sb-summary, switches,
#                       routers, acls, nat, chassis, lflows, ovs-flows,
#                       connectivity
#
# Output:
#   Timestamped report saved to /tmp/ovn-inspect-YYYYMMDD-HHMMSS.txt
#
# Requirements:
#   - OVN utilities (ovn-nbctl, ovn-sbctl) or access to OVN containers
#   - Open vSwitch utilities (ovs-vsctl, ovs-ofctl)
#   - Root or sudo privileges
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
# Globals
# ---------------------------------------------------------------------------
REPORT_ENABLED=true
REPORT_DIR="/tmp"
REPORT_FILE=""
SPECIFIC_SECTION=""
TIMESTAMP=""

# Container/execution context
IS_CONTAINERIZED=false
CONTAINER_RUNTIME=""       # podman or docker
OVN_NB_CONTAINER=""        # container name for ovn-nbctl
OVN_SB_CONTAINER=""        # container name for ovn-sbctl
OVN_CONTROLLER_CONTAINER="" # container name for ovn-controller

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

print_header() {
    local title="$1"
    local line
    line=$(printf '=%.0s' {1..76})
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
    echo -e "${CYAN}${BOLD}--- ${title} ${line:${#title}}${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_info() {
    echo -e "${BOLD}[INFO]${NC} $1"
}

# Run a command, display its output, and handle errors gracefully.
run_cmd() {
    local description="$1"
    shift
    print_subheader "$description"
    echo -e "${YELLOW}# $*${NC}"
    echo ""
    if output=$("$@" 2>&1); then
        if [[ -z "$output" ]]; then
            print_warning "Command produced no output."
        else
            echo "$output"
        fi
    else
        local rc=$?
        if [[ -n "${output:-}" ]]; then
            echo "$output"
        fi
        print_error "Command exited with code $rc"
    fi
    echo ""
}

# Run a command via sudo if not already root.
run_privileged() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Run ovn-nbctl, handling containerized vs host access.
ovn_nbctl() {
    if [[ "$IS_CONTAINERIZED" == true && -n "$OVN_NB_CONTAINER" ]]; then
        run_privileged "$CONTAINER_RUNTIME" exec "$OVN_NB_CONTAINER" ovn-nbctl "$@"
    else
        run_privileged ovn-nbctl "$@"
    fi
}

# Run ovn-sbctl, handling containerized vs host access.
ovn_sbctl() {
    if [[ "$IS_CONTAINERIZED" == true && -n "$OVN_SB_CONTAINER" ]]; then
        run_privileged "$CONTAINER_RUNTIME" exec "$OVN_SB_CONTAINER" ovn-sbctl "$@"
    else
        run_privileged ovn-sbctl "$@"
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Inspect OVN configuration on a RHOSP node.
Handles both containerized and non-containerized OVN access.
All operations are read-only.

Options:
  --help              Show this help message and exit
  --no-report         Do not save output to a report file
  --report-dir DIR    Directory for the report file (default: /tmp)
  --section SECTION   Run only a specific section:
                        environment    - Container/host detection and OVN access
                        nb-summary     - OVN Northbound DB summary
                        sb-summary     - OVN Southbound DB summary
                        switches       - Logical switches and ports
                        routers        - Logical routers, routes, and gateways
                        acls           - Access Control Lists
                        nat            - NAT rules
                        chassis        - Chassis list and port bindings
                        lflows         - Logical flows summary
                        ovs-flows      - OVS flows installed by OVN on br-int
                        connectivity   - OVN controller and tunnel connectivity

Examples:
  $(basename "$0")                          # Full inspection
  $(basename "$0") --section switches       # Only show logical switches
  $(basename "$0") --section connectivity   # Only check connectivity
  $(basename "$0") --no-report              # Skip report file generation
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                usage
                ;;
            --no-report)
                REPORT_ENABLED=false
                shift
                ;;
            --report-dir)
                REPORT_DIR="$2"
                shift 2
                ;;
            --section)
                SPECIFIC_SECTION="$2"
                shift 2
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use --help for usage information."
                exit 1
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Section: Environment detection
# ---------------------------------------------------------------------------
detect_environment() {
    print_header "ENVIRONMENT DETECTION"

    # Check if we are inside a container
    print_subheader "Container Environment Check"

    if [[ -f /run/.containerenv ]]; then
        print_info "Running INSIDE a container (/run/.containerenv detected)"
        print_info "Container environment details:"
        cat /run/.containerenv 2>/dev/null || true
    elif grep -q 'container=' /proc/1/environ 2>/dev/null; then
        print_info "Running INSIDE a container (cgroup namespace check)"
    elif [[ -f /.dockerenv ]]; then
        print_info "Running INSIDE a Docker container"
    else
        print_info "Running on the host (not inside a container)"
    fi

    # Detect container runtime and OVN containers on the host
    print_subheader "OVN Container Discovery"

    # Try podman first (default for RHOSP 16+)
    if command -v podman &>/dev/null; then
        local podman_containers
        podman_containers=$(run_privileged podman ps --format '{{.Names}}' 2>/dev/null || true)
        if [[ -n "$podman_containers" ]]; then
            CONTAINER_RUNTIME="podman"
            print_info "Container runtime: podman"

            # Look for OVN-related containers
            echo ""
            echo "OVN-related containers:"
            echo "$podman_containers" | grep -i 'ovn\|ovsdb' | while read -r name; do
                echo -e "  ${GREEN}$name${NC}"
            done || print_info "No OVN containers found via podman."

            # Identify NB/SB/controller containers
            OVN_NB_CONTAINER=$(echo "$podman_containers" | grep -iE 'ovn.*nb|ovn_northd|ovn-dbs' | head -1 || true)
            OVN_SB_CONTAINER=$(echo "$podman_containers" | grep -iE 'ovn.*sb|ovn_northd|ovn-dbs' | head -1 || true)
            OVN_CONTROLLER_CONTAINER=$(echo "$podman_containers" | grep -iE 'ovn.*controller' | head -1 || true)

            # Fallback: try the unified ovn-dbs or ovn_cluster container
            if [[ -z "$OVN_NB_CONTAINER" ]]; then
                OVN_NB_CONTAINER=$(echo "$podman_containers" | grep -iE 'ovn[-_]dbs|ovn[-_]cluster|ovn_northd' | head -1 || true)
            fi
            if [[ -z "$OVN_SB_CONTAINER" ]]; then
                OVN_SB_CONTAINER=$(echo "$podman_containers" | grep -iE 'ovn[-_]dbs|ovn[-_]cluster|ovn_northd' | head -1 || true)
            fi

            if [[ -n "$OVN_NB_CONTAINER" || -n "$OVN_SB_CONTAINER" ]]; then
                IS_CONTAINERIZED=true
            fi
        fi
    fi

    # Try docker if podman did not find anything
    if [[ "$IS_CONTAINERIZED" == false ]] && command -v docker &>/dev/null; then
        local docker_containers
        docker_containers=$(run_privileged docker ps --format '{{.Names}}' 2>/dev/null || true)
        if [[ -n "$docker_containers" ]]; then
            CONTAINER_RUNTIME="docker"
            print_info "Container runtime: docker"

            echo ""
            echo "OVN-related containers:"
            echo "$docker_containers" | grep -i 'ovn\|ovsdb' | while read -r name; do
                echo -e "  ${GREEN}$name${NC}"
            done || print_info "No OVN containers found via docker."

            OVN_NB_CONTAINER=$(echo "$docker_containers" | grep -iE 'ovn.*nb|ovn_northd|ovn-dbs' | head -1 || true)
            OVN_SB_CONTAINER=$(echo "$docker_containers" | grep -iE 'ovn.*sb|ovn_northd|ovn-dbs' | head -1 || true)
            OVN_CONTROLLER_CONTAINER=$(echo "$docker_containers" | grep -iE 'ovn.*controller' | head -1 || true)

            if [[ -z "$OVN_NB_CONTAINER" ]]; then
                OVN_NB_CONTAINER=$(echo "$docker_containers" | grep -iE 'ovn[-_]dbs|ovn[-_]cluster|ovn_northd' | head -1 || true)
            fi
            if [[ -z "$OVN_SB_CONTAINER" ]]; then
                OVN_SB_CONTAINER=$(echo "$docker_containers" | grep -iE 'ovn[-_]dbs|ovn[-_]cluster|ovn_northd' | head -1 || true)
            fi

            if [[ -n "$OVN_NB_CONTAINER" || -n "$OVN_SB_CONTAINER" ]]; then
                IS_CONTAINERIZED=true
            fi
        fi
    fi

    # Check for host-level OVN commands
    if [[ "$IS_CONTAINERIZED" == false ]]; then
        if command -v ovn-nbctl &>/dev/null; then
            print_success "ovn-nbctl available on host"
        else
            print_warning "ovn-nbctl not found on host and no OVN containers detected"
            print_info "NB/SB database queries may fail"
        fi
        if command -v ovn-sbctl &>/dev/null; then
            print_success "ovn-sbctl available on host"
        fi
    fi

    # Display detected containers
    print_subheader "Access Method Summary"
    if [[ "$IS_CONTAINERIZED" == true ]]; then
        print_info "Access method: containerized ($CONTAINER_RUNTIME)"
        [[ -n "$OVN_NB_CONTAINER" ]] && print_info "  NB container: $OVN_NB_CONTAINER"
        [[ -n "$OVN_SB_CONTAINER" ]] && print_info "  SB container: $OVN_SB_CONTAINER"
        [[ -n "$OVN_CONTROLLER_CONTAINER" ]] && print_info "  Controller container: $OVN_CONTROLLER_CONTAINER"
    else
        print_info "Access method: host-level commands"
    fi

    # OVN version
    print_subheader "OVN Version"
    if [[ "$IS_CONTAINERIZED" == true && -n "$OVN_NB_CONTAINER" ]]; then
        run_privileged "$CONTAINER_RUNTIME" exec "$OVN_NB_CONTAINER" ovn-nbctl --version 2>/dev/null || \
            print_warning "Could not determine OVN version from container"
    else
        ovn-nbctl --version 2>/dev/null || print_warning "Could not determine OVN version"
    fi

    # RHOSP version
    print_subheader "RHOSP Version"
    if [[ -f /etc/rhosp-release ]]; then
        cat /etc/rhosp-release
    else
        print_warning "No /etc/rhosp-release found"
    fi

    if [[ -f /etc/redhat-release ]]; then
        print_info "OS: $(cat /etc/redhat-release)"
    fi

    echo ""
    print_info "Hostname: $(hostname -f 2>/dev/null || hostname)"
    print_info "Date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
}

# ---------------------------------------------------------------------------
# Section: OVN NB DB summary
# ---------------------------------------------------------------------------
inspect_nb_summary() {
    print_header "OVN NORTHBOUND DATABASE SUMMARY"

    run_cmd "OVN NB Show (topology overview)" ovn_nbctl show

    # Count objects
    print_subheader "NB Database Object Counts"
    local switches routers acls nat_rules lbs
    switches=$(ovn_nbctl ls-list 2>/dev/null | wc -l || echo "?")
    routers=$(ovn_nbctl lr-list 2>/dev/null | wc -l || echo "?")
    acls=$(ovn_nbctl acl-list 2>/dev/null | wc -l || echo "?")

    echo "  Logical Switches:   $switches"
    echo "  Logical Routers:    $routers"
    echo "  ACL Rules:          $acls"

    # Count NAT rules across all routers
    local total_nat=0
    while IFS= read -r lr; do
        local lr_name
        lr_name=$(echo "$lr" | grep -oP '\(.*?\)' | tr -d '()' || true)
        if [[ -n "$lr_name" ]]; then
            local count
            count=$(ovn_nbctl lr-nat-list "$lr_name" 2>/dev/null | grep -c 'snat\|dnat\|dnat_and_snat' || echo "0")
            total_nat=$((total_nat + count))
        fi
    done < <(ovn_nbctl lr-list 2>/dev/null || true)
    echo "  NAT Rules (total):  $total_nat"

    # Load balancers
    lbs=$(ovn_nbctl lb-list 2>/dev/null | tail -n +2 | wc -l || echo "?")
    echo "  Load Balancers:     $lbs"
    echo ""

    # NB connection status
    run_cmd "NB Connection Status" ovn_nbctl get-connection 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Section: OVN SB DB summary
# ---------------------------------------------------------------------------
inspect_sb_summary() {
    print_header "OVN SOUTHBOUND DATABASE SUMMARY"

    run_cmd "OVN SB Show (chassis and port bindings)" ovn_sbctl show

    # Count objects
    print_subheader "SB Database Object Counts"
    local chassis port_bindings
    chassis=$(ovn_sbctl list chassis 2>/dev/null | grep -c '^_uuid' || echo "?")
    port_bindings=$(ovn_sbctl list port_binding 2>/dev/null | grep -c '^_uuid' || echo "?")

    echo "  Chassis:        $chassis"
    echo "  Port Bindings:  $port_bindings"
    echo ""

    # SB connection status
    run_cmd "SB Connection Status" ovn_sbctl get-connection 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Section: Logical switches and ports
# ---------------------------------------------------------------------------
inspect_switches() {
    print_header "LOGICAL SWITCHES AND PORTS"

    run_cmd "Logical Switch List" ovn_nbctl ls-list

    # Enumerate ports per switch
    local switches
    switches=$(ovn_nbctl ls-list 2>/dev/null || true)

    if [[ -n "$switches" ]]; then
        while IFS= read -r line; do
            local ls_name
            ls_name=$(echo "$line" | grep -oP '\(.*?\)' | tr -d '()' || true)
            if [[ -n "$ls_name" ]]; then
                run_cmd "Ports on Logical Switch: $ls_name" ovn_nbctl lsp-list "$ls_name"

                # Show port details (type, addresses) for first 50 ports
                print_subheader "Port Details - $ls_name (up to 50 ports)"
                local ports
                ports=$(ovn_nbctl lsp-list "$ls_name" 2>/dev/null || true)
                local count=0
                while IFS= read -r port_line && [[ $count -lt 50 ]]; do
                    local port_name
                    port_name=$(echo "$port_line" | awk '{print $1}' || true)
                    # The UUID is first, name is second
                    port_name=$(echo "$port_line" | grep -oP '\(.*?\)' | tr -d '()' || true)
                    if [[ -n "$port_name" ]]; then
                        local port_type port_addrs
                        port_type=$(ovn_nbctl lsp-get-type "$port_name" 2>/dev/null || echo "unknown")
                        port_addrs=$(ovn_nbctl lsp-get-addresses "$port_name" 2>/dev/null || echo "unknown")
                        echo -e "  ${CYAN}$port_name${NC}"
                        echo "    Type:      ${port_type:-regular}"
                        echo "    Addresses: $port_addrs"
                        ((count++)) || true
                    fi
                done <<< "$ports"
                echo ""
            fi
        done <<< "$switches"
    else
        print_warning "No logical switches found or unable to query NB DB."
    fi
}

# ---------------------------------------------------------------------------
# Section: Logical routers and routes
# ---------------------------------------------------------------------------
inspect_routers() {
    print_header "LOGICAL ROUTERS, ROUTES, AND GATEWAY CONFIG"

    run_cmd "Logical Router List" ovn_nbctl lr-list

    local routers
    routers=$(ovn_nbctl lr-list 2>/dev/null || true)

    if [[ -n "$routers" ]]; then
        while IFS= read -r line; do
            local lr_name
            lr_name=$(echo "$line" | grep -oP '\(.*?\)' | tr -d '()' || true)
            if [[ -n "$lr_name" ]]; then
                run_cmd "Router Details: $lr_name" ovn_nbctl show "$lr_name" 2>/dev/null || true

                run_cmd "Static Routes - $lr_name" ovn_nbctl lr-route-list "$lr_name"

                # Gateway chassis / HA chassis group
                print_subheader "Gateway Config - $lr_name"
                local lr_ports
                lr_ports=$(ovn_nbctl lrp-list "$lr_name" 2>/dev/null || true)
                if [[ -n "$lr_ports" ]]; then
                    while IFS= read -r port_line; do
                        local lrp_name
                        lrp_name=$(echo "$port_line" | grep -oP '\(.*?\)' | tr -d '()' || true)
                        if [[ -n "$lrp_name" ]]; then
                            local gw_chassis
                            gw_chassis=$(ovn_nbctl lrp-get-gateway-chassis "$lrp_name" 2>/dev/null || true)
                            if [[ -n "$gw_chassis" ]]; then
                                echo -e "  ${CYAN}$lrp_name${NC} -> Gateway chassis: $gw_chassis"
                            fi
                        fi
                    done <<< "$lr_ports"
                fi
                echo ""
            fi
        done <<< "$routers"
    else
        print_warning "No logical routers found or unable to query NB DB."
    fi
}

# ---------------------------------------------------------------------------
# Section: ACLs
# ---------------------------------------------------------------------------
inspect_acls() {
    print_header "ACCESS CONTROL LISTS (ACLs)"

    # ACLs per logical switch
    local switches
    switches=$(ovn_nbctl ls-list 2>/dev/null || true)

    if [[ -n "$switches" ]]; then
        local total_acls=0
        while IFS= read -r line; do
            local ls_name
            ls_name=$(echo "$line" | grep -oP '\(.*?\)' | tr -d '()' || true)
            if [[ -n "$ls_name" ]]; then
                local acl_output
                acl_output=$(ovn_nbctl acl-list "$ls_name" 2>/dev/null || true)
                if [[ -n "$acl_output" ]]; then
                    local count
                    count=$(echo "$acl_output" | wc -l)
                    total_acls=$((total_acls + count))
                    run_cmd "ACLs on Switch: $ls_name ($count rules)" ovn_nbctl acl-list "$ls_name"
                fi
            fi
        done <<< "$switches"

        print_info "Total ACL rules across all switches: $total_acls"
    else
        print_warning "No logical switches found."
    fi

    # Port group ACLs (OVN >= 2.10)
    print_subheader "Port Group ACLs"
    local pg_list
    pg_list=$(ovn_nbctl --columns=name list port_group 2>/dev/null || true)
    if [[ -n "$pg_list" ]]; then
        echo "$pg_list"
    else
        print_info "No port groups found (or OVN version does not support port groups)."
    fi
}

# ---------------------------------------------------------------------------
# Section: NAT rules
# ---------------------------------------------------------------------------
inspect_nat() {
    print_header "NAT RULES"

    local routers
    routers=$(ovn_nbctl lr-list 2>/dev/null || true)

    if [[ -n "$routers" ]]; then
        while IFS= read -r line; do
            local lr_name
            lr_name=$(echo "$line" | grep -oP '\(.*?\)' | tr -d '()' || true)
            if [[ -n "$lr_name" ]]; then
                run_cmd "NAT Rules - Router: $lr_name" ovn_nbctl lr-nat-list "$lr_name"
            fi
        done <<< "$routers"
    else
        print_warning "No logical routers found."
    fi
}

# ---------------------------------------------------------------------------
# Section: Chassis and port bindings
# ---------------------------------------------------------------------------
inspect_chassis() {
    print_header "CHASSIS AND PORT BINDINGS"

    run_cmd "Chassis List (SB)" ovn_sbctl list chassis

    # Chassis summary
    print_subheader "Chassis Summary"
    local chassis_data
    chassis_data=$(ovn_sbctl show 2>/dev/null || true)
    if [[ -n "$chassis_data" ]]; then
        # Extract chassis names and their encap IPs
        echo "$chassis_data" | grep -E 'Chassis|hostname|Encap' | head -60
    fi
    echo ""

    # Port bindings
    run_cmd "Port Bindings (SB)" ovn_sbctl list port_binding

    # Port binding summary - count per chassis
    print_subheader "Port Binding Count Per Chassis"
    local binding_data
    binding_data=$(ovn_sbctl --columns=chassis,logical_port,type list port_binding 2>/dev/null || true)
    if [[ -n "$binding_data" ]]; then
        ovn_sbctl --columns=chassis list port_binding 2>/dev/null | \
            grep -v '^$' | sort | uniq -c | sort -rn | head -20 || true
    fi
    echo ""

    # Unbound ports (potential issues)
    print_subheader "Unbound Ports (chassis = [])"
    local unbound
    unbound=$(ovn_sbctl find port_binding chassis=[] 2>/dev/null | grep -E 'logical_port|type' || true)
    if [[ -n "$unbound" ]]; then
        print_warning "Found unbound ports:"
        echo "$unbound"
    else
        print_success "No unbound ports detected."
    fi
}

# ---------------------------------------------------------------------------
# Section: Logical flows
# ---------------------------------------------------------------------------
inspect_lflows() {
    print_header "LOGICAL FLOWS SUMMARY"

    # Count total logical flows
    local total_flows
    total_flows=$(ovn_sbctl lflow-list 2>/dev/null | wc -l || echo "?")
    print_info "Total logical flows in SB DB: $total_flows"

    # Group by table (pipeline + table number)
    print_subheader "Logical Flow Count Per Table"
    local lflow_data
    lflow_data=$(ovn_sbctl lflow-list 2>/dev/null || true)
    if [[ -n "$lflow_data" ]]; then
        echo "$lflow_data" | \
            grep -oP 'Datapath:.*?table=\d+' | \
            awk -F'table=' '{print "table="$2}' | \
            sort | uniq -c | sort -rn | head -30
    fi
    echo ""

    # Group by datapath
    print_subheader "Logical Flow Count Per Datapath"
    if [[ -n "$lflow_data" ]]; then
        echo "$lflow_data" | \
            grep -oP 'Datapath: "[^"]*"' | \
            sort | uniq -c | sort -rn | head -20
    fi
    echo ""

    # Show sample flows for inspection (first 50 lines)
    print_subheader "Sample Logical Flows (first 50)"
    if [[ -n "$lflow_data" ]]; then
        echo "$lflow_data" | head -50
    fi
    echo ""
    print_info "Use 'ovn-sbctl lflow-list <datapath>' to see flows for a specific datapath"
}

# ---------------------------------------------------------------------------
# Section: OVS flows installed by OVN on br-int
# ---------------------------------------------------------------------------
inspect_ovs_flows() {
    print_header "OVS FLOWS ON br-int (INSTALLED BY OVN)"

    # Check if br-int exists
    if ! run_privileged ovs-vsctl br-exists br-int 2>/dev/null; then
        print_warning "br-int bridge does not exist on this node."
        return
    fi

    # Flow count
    local flow_count
    flow_count=$(run_privileged ovs-ofctl dump-flows br-int 2>/dev/null | grep -c 'cookie=' || echo "0")
    print_info "Total OVS flows on br-int: $flow_count"

    # Flow count per table
    print_subheader "Flow Count Per OpenFlow Table - br-int"
    run_privileged ovs-ofctl dump-flows br-int 2>/dev/null | \
        grep -oP 'table=\d+' | sort | uniq -c | sort -rn || true
    echo ""

    # OVN-specific OpenFlow table reference
    print_subheader "OVN OpenFlow Table Reference (br-int)"
    echo "  Table  0 - Classifier / Admission"
    echo "  Table  8 - Pre-ingress (from-lport)"
    echo "  Table  9 - Ingress pipeline stage 0"
    echo "  Table 10-31 - Ingress pipeline stages"
    echo "  Table 32 - Pre-egress"
    echo "  Table 33 - Egress pipeline stage 0"
    echo "  Table 34-63 - Egress pipeline stages"
    echo "  Table 64 - Output / delivery"
    echo "  Table 65 - MAC learning"
    echo ""

    # Dump all flows sorted by table
    run_cmd "All Flows on br-int (sorted by table)" \
        run_privileged ovs-ofctl dump-flows br-int --rsort=priority

    # Show OVS bridge topology for context
    run_cmd "OVS Bridges on this Node" run_privileged ovs-vsctl show
}

# ---------------------------------------------------------------------------
# Section: OVN controller and tunnel connectivity
# ---------------------------------------------------------------------------
inspect_connectivity() {
    print_header "OVN CONTROLLER AND TUNNEL CONNECTIVITY"

    # OVN remote connection (what ovn-controller connects to)
    run_cmd "OVN Remote (SB DB connection)" \
        run_privileged ovs-vsctl get open_vswitch . external_ids:ovn-remote 2>/dev/null || true

    # OVN encap type and IP
    print_subheader "OVN Encapsulation Config"
    local encap_type encap_ip
    encap_type=$(run_privileged ovs-vsctl get open_vswitch . external_ids:ovn-encap-type 2>/dev/null || echo "not set")
    encap_ip=$(run_privileged ovs-vsctl get open_vswitch . external_ids:ovn-encap-ip 2>/dev/null || echo "not set")
    echo "  Encap type: $encap_type"
    echo "  Encap IP:   $encap_ip"
    echo ""

    # OVN bridge mappings
    print_subheader "OVN Bridge Mappings"
    local bridge_mappings
    bridge_mappings=$(run_privileged ovs-vsctl get open_vswitch . external_ids:ovn-bridge-mappings 2>/dev/null || echo "not set")
    echo "  Bridge mappings: $bridge_mappings"
    echo ""

    # All external_ids
    run_cmd "Full external_ids on Open_vSwitch" \
        run_privileged ovs-vsctl get open_vswitch . external_ids

    # OVN controller status
    print_subheader "OVN Controller Process"
    if pgrep -f ovn-controller &>/dev/null; then
        print_success "ovn-controller is running"
        pgrep -af ovn-controller || true
    elif [[ "$IS_CONTAINERIZED" == true && -n "$OVN_CONTROLLER_CONTAINER" ]]; then
        local state
        state=$(run_privileged "$CONTAINER_RUNTIME" inspect --format '{{.State.Status}}' "$OVN_CONTROLLER_CONTAINER" 2>/dev/null || echo "unknown")
        if [[ "$state" == "running" ]]; then
            print_success "ovn-controller container ($OVN_CONTROLLER_CONTAINER) is running"
        else
            print_error "ovn-controller container ($OVN_CONTROLLER_CONTAINER) state: $state"
        fi
    else
        print_warning "ovn-controller does not appear to be running"
    fi
    echo ""

    # Geneve tunnels
    run_cmd "Geneve Tunnel Interfaces" \
        run_privileged ovs-vsctl find interface type=geneve

    # Tunnel summary
    print_subheader "Geneve Tunnel Remote IPs"
    local tunnel_ips
    tunnel_ips=$(run_privileged ovs-vsctl find interface type=geneve 2>/dev/null | \
        grep -oP 'remote_ip="?\K[0-9.]+' | sort -u || true)
    if [[ -n "$tunnel_ips" ]]; then
        echo "Active Geneve tunnel endpoints:"
        echo "$tunnel_ips" | while read -r ip; do
            echo -e "  - ${GREEN}$ip${NC}"
        done
    else
        print_info "No Geneve tunnels found on this node."
    fi
    echo ""

    # Connection status to SB DB
    print_subheader "SB Database Connection Test"
    if ovn_sbctl show &>/dev/null; then
        print_success "Successfully connected to OVN Southbound database"
    else
        print_error "Cannot connect to OVN Southbound database"
    fi

    if ovn_nbctl show &>/dev/null; then
        print_success "Successfully connected to OVN Northbound database"
    else
        print_warning "Cannot connect to OVN Northbound database (may be expected on compute nodes)"
    fi
}

# ---------------------------------------------------------------------------
# Report file setup
# ---------------------------------------------------------------------------
setup_report() {
    if [[ "$REPORT_ENABLED" != true ]]; then
        return
    fi

    TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
    REPORT_FILE="${REPORT_DIR}/ovn-inspect-${TIMESTAMP}.txt"

    if [[ ! -d "$REPORT_DIR" ]]; then
        mkdir -p "$REPORT_DIR"
    fi

    exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' > "$REPORT_FILE"))
    exec 2>&1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    echo -e "${BLUE}${BOLD}"
    echo "   ___  _   _ _   _   ___                           _"
    echo "  / _ \\| | | | \\ | | |_ _|_ __  ___ _ __   ___  ___| |_"
    echo " | | | | | | |  \\| |  | || '_ \\/ __| '_ \\ / _ \\/ __| __|"
    echo " | |_| | |_| | |\\  |  | || | | \\__ \\ |_) |  __/ (__| |_"
    echo "  \\___/ \\___/|_| \\_| |___|_| |_|___/ .__/ \\___|\\___|\\___|"
    echo "                                    |_|"
    echo ""
    echo "  OVN Inspector for Red Hat OpenStack Platform"
    echo -e "${NC}"

    setup_report

    # Always detect environment first (sets container access variables)
    if [[ -z "$SPECIFIC_SECTION" || "$SPECIFIC_SECTION" == "environment" ]]; then
        detect_environment
    else
        # Silent environment detection to set up container access
        detect_environment > /dev/null 2>&1 || true
    fi

    if [[ -n "$SPECIFIC_SECTION" ]]; then
        case "$SPECIFIC_SECTION" in
            environment)  ;; # Already done above
            nb-summary)   inspect_nb_summary ;;
            sb-summary)   inspect_sb_summary ;;
            switches)     inspect_switches ;;
            routers)      inspect_routers ;;
            acls)         inspect_acls ;;
            nat)          inspect_nat ;;
            chassis)      inspect_chassis ;;
            lflows)       inspect_lflows ;;
            ovs-flows)    inspect_ovs_flows ;;
            connectivity) inspect_connectivity ;;
            *)
                print_error "Unknown section: $SPECIFIC_SECTION"
                echo "Valid sections: environment, nb-summary, sb-summary, switches, routers,"
                echo "                acls, nat, chassis, lflows, ovs-flows, connectivity"
                exit 1
                ;;
        esac
    else
        inspect_nb_summary
        inspect_sb_summary
        inspect_switches
        inspect_routers
        inspect_acls
        inspect_nat
        inspect_chassis
        inspect_lflows
        inspect_ovs_flows
        inspect_connectivity
    fi

    # Final summary
    print_header "INSPECTION COMPLETE"
    print_info "Hostname: $(hostname -f 2>/dev/null || hostname)"
    print_info "Date: $(date '+%Y-%m-%d %H:%M:%S %Z')"

    if [[ "$REPORT_ENABLED" == true && -n "$REPORT_FILE" ]]; then
        print_success "Report saved to: ${REPORT_FILE}"
    fi
}

main "$@"
