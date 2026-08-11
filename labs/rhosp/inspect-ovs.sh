#!/bin/bash
set -euo pipefail

###############################################################################
# inspect-ovs.sh - Inspect OVS configuration in a RHOSP environment
#
# Designed for Red Hat OpenStack Platform environments using the ML2/OVS
# networking backend. Inspects Open vSwitch bridges, flows, ports, bonds,
# tunnels, and interface statistics on controller, compute, and networker
# nodes.
#
# All operations are read-only. No configuration changes are made.
#
# Usage:
#   ./inspect-ovs.sh [OPTIONS]
#
# Options:
#   --help          Show this help message
#   --no-report     Do not save output to a report file
#   --report-dir    Directory for the report file (default: /tmp)
#   --bridges       Only inspect specific bridges (comma-separated)
#   --section SEC   Run only a specific section:
#                     version, role, bridges, flows, ports, fdb,
#                     bonds, tunnels, interfaces
#
# Output:
#   Timestamped report saved to /tmp/ovs-inspect-YYYYMMDD-HHMMSS.txt
#
# Requirements:
#   - Open vSwitch utilities (ovs-vsctl, ovs-ofctl, ovs-appctl)
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
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
REPORT_ENABLED=true
REPORT_DIR="/tmp"
REPORT_FILE=""
SPECIFIC_BRIDGES=""
SPECIFIC_SECTION=""
TIMESTAMP=""

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

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Inspect OVS configuration on a RHOSP node (controller, compute, or networker).
All operations are read-only.

Options:
  --help              Show this help message and exit
  --no-report         Do not save output to a report file
  --report-dir DIR    Directory for the report file (default: /tmp)
  --bridges LIST      Only inspect specific bridges (comma-separated)
  --section SECTION   Run only a specific section:
                        version   - RHOSP version and backend detection
                        role      - Node role detection
                        bridges   - OVS bridge topology
                        flows     - OpenFlow flow dumps
                        ports     - Port statistics
                        fdb       - MAC learning tables
                        bonds     - Bond status
                        tunnels   - Tunnel endpoints
                        interfaces - Interface statistics and errors

Examples:
  $(basename "$0")                          # Full inspection
  $(basename "$0") --section flows          # Only dump flows
  $(basename "$0") --bridges br-int,br-ex   # Only inspect specific bridges
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
            --bridges)
                SPECIFIC_BRIDGES="$2"
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
# Pre-flight checks
# ---------------------------------------------------------------------------
preflight_checks() {
    local missing=()

    for cmd in ovs-vsctl ovs-ofctl ovs-appctl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Required commands not found: ${missing[*]}"
        print_info "Install Open vSwitch utilities or ensure they are in PATH."
        exit 1
    fi

    # Verify OVS daemon is running
    if ! run_privileged ovs-vsctl show &>/dev/null; then
        print_error "Cannot connect to Open vSwitch. Is ovsdb-server running?"
        exit 1
    fi

    print_success "Pre-flight checks passed."
}

# ---------------------------------------------------------------------------
# Section: RHOSP version and backend detection
# ---------------------------------------------------------------------------
detect_rhosp_version() {
    print_header "RHOSP VERSION AND BACKEND DETECTION"

    # RHOSP release file
    if [[ -f /etc/rhosp-release ]]; then
        print_info "RHOSP release:"
        cat /etc/rhosp-release
        echo ""
    elif [[ -f /etc/nova/release ]]; then
        print_info "Nova release file:"
        cat /etc/nova/release
        echo ""
    else
        print_warning "No /etc/rhosp-release found. Attempting alternative detection."
    fi

    # Check Red Hat release
    if [[ -f /etc/redhat-release ]]; then
        print_info "OS release: $(cat /etc/redhat-release)"
    fi

    # Check tripleo / heat configs for RHOSP version hints
    if [[ -d /etc/puppet/hieradata ]]; then
        local version_hint
        version_hint=$(grep -r 'rhosp_release\|openstack_version' /etc/puppet/hieradata/ 2>/dev/null | head -5 || true)
        if [[ -n "$version_hint" ]]; then
            print_info "TripleO version hints:"
            echo "$version_hint"
        fi
    fi

    # Detect ML2 backend
    print_subheader "ML2 Backend Detection"

    local backend="unknown"

    # Check ml2_conf.ini
    local ml2_conf=""
    for path in /etc/neutron/plugins/ml2/ml2_conf.ini \
                /var/lib/config-data/puppet-generated/neutron/etc/neutron/plugins/ml2/ml2_conf.ini \
                /etc/neutron/plugin.ini; do
        if [[ -f "$path" ]]; then
            ml2_conf="$path"
            break
        fi
    done

    if [[ -n "$ml2_conf" ]]; then
        print_info "ML2 config found: $ml2_conf"
        local mechanism
        mechanism=$(grep -i 'mechanism_drivers' "$ml2_conf" 2>/dev/null || true)
        if [[ -n "$mechanism" ]]; then
            echo "  $mechanism"
            if echo "$mechanism" | grep -qi 'ovn'; then
                backend="ml2/ovn"
            elif echo "$mechanism" | grep -qi 'openvswitch'; then
                backend="ml2/ovs"
            fi
        fi
    fi

    # Fallback: check running processes
    if [[ "$backend" == "unknown" ]]; then
        if pgrep -f ovn-controller &>/dev/null; then
            backend="ml2/ovn"
        elif pgrep -f neutron-openvswitch-agent &>/dev/null; then
            backend="ml2/ovs"
        fi
    fi

    # Fallback: check for OVN containers
    if [[ "$backend" == "unknown" ]]; then
        if podman ps 2>/dev/null | grep -qi ovn || docker ps 2>/dev/null | grep -qi ovn; then
            backend="ml2/ovn"
        fi
    fi

    case "$backend" in
        ml2/ovs)
            print_success "Detected backend: ML2/OVS"
            ;;
        ml2/ovn)
            print_warning "Detected backend: ML2/OVN - consider using inspect-ovn.sh instead"
            ;;
        *)
            print_warning "Could not auto-detect backend. Proceeding with OVS inspection."
            ;;
    esac

    # OVS version
    print_subheader "OVS Version"
    run_privileged ovs-vsctl --version 2>/dev/null || print_warning "Could not determine OVS version."
}

# ---------------------------------------------------------------------------
# Section: Node role detection
# ---------------------------------------------------------------------------
detect_node_role() {
    print_header "NODE ROLE DETECTION"

    local roles=()

    # Controller indicators
    local controller_services=(
        "neutron-server"
        "nova-api"
        "nova-scheduler"
        "nova-conductor"
        "keystone"
        "glance-api"
        "heat-engine"
        "cinder-api"
    )

    # Compute indicators
    local compute_services=(
        "nova-compute"
        "qemu-kvm"
        "libvirtd"
    )

    # Networker indicators
    local networker_services=(
        "neutron-l3-agent"
        "neutron-dhcp-agent"
        "neutron-metadata-agent"
        "neutron-openvswitch-agent"
    )

    print_info "Checking running services to determine node role..."
    echo ""

    # Check controller services
    local ctrl_count=0
    for svc in "${controller_services[@]}"; do
        if pgrep -f "$svc" &>/dev/null; then
            ((ctrl_count++)) || true
        fi
    done
    if [[ $ctrl_count -ge 2 ]]; then
        roles+=("controller")
        print_success "Controller role detected ($ctrl_count services matched)"
    fi

    # Check compute services
    local comp_count=0
    for svc in "${compute_services[@]}"; do
        if pgrep -f "$svc" &>/dev/null; then
            ((comp_count++)) || true
        fi
    done
    if [[ $comp_count -ge 1 ]]; then
        roles+=("compute")
        print_success "Compute role detected ($comp_count services matched)"
    fi

    # Check networker services
    local net_count=0
    for svc in "${networker_services[@]}"; do
        if pgrep -f "$svc" &>/dev/null; then
            ((net_count++)) || true
        fi
    done
    if [[ $net_count -ge 2 ]]; then
        roles+=("networker")
        print_success "Networker role detected ($net_count services matched)"
    fi

    # Also check containerized services (RHOSP 13+)
    if command -v podman &>/dev/null; then
        local container_list
        container_list=$(podman ps --format '{{.Names}}' 2>/dev/null || true)
        if echo "$container_list" | grep -qi 'nova_api\|neutron_api\|keystone'; then
            if [[ ! " ${roles[*]:-} " =~ " controller " ]]; then
                roles+=("controller")
                print_success "Controller role detected (containerized services)"
            fi
        fi
        if echo "$container_list" | grep -qi 'nova_compute'; then
            if [[ ! " ${roles[*]:-} " =~ " compute " ]]; then
                roles+=("compute")
                print_success "Compute role detected (containerized services)"
            fi
        fi
        if echo "$container_list" | grep -qi 'neutron_l3_agent\|neutron_dhcp'; then
            if [[ ! " ${roles[*]:-} " =~ " networker " ]]; then
                roles+=("networker")
                print_success "Networker role detected (containerized services)"
            fi
        fi
    fi

    if [[ ${#roles[@]} -eq 0 ]]; then
        print_warning "Could not determine node role. Proceeding with generic inspection."
    else
        print_info "Detected roles: ${roles[*]}"
    fi

    echo ""
    print_info "Hostname: $(hostname -f 2>/dev/null || hostname)"
    print_info "Date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
}

# ---------------------------------------------------------------------------
# Section: OVS bridges
# ---------------------------------------------------------------------------
inspect_bridges() {
    print_header "OVS BRIDGE TOPOLOGY"

    run_cmd "OVS Full Topology (ovs-vsctl show)" run_privileged ovs-vsctl show

    run_cmd "Bridge List" run_privileged ovs-vsctl list-br

    # List ports per bridge
    local bridges
    if [[ -n "$SPECIFIC_BRIDGES" ]]; then
        IFS=',' read -ra bridges <<< "$SPECIFIC_BRIDGES"
    else
        mapfile -t bridges < <(run_privileged ovs-vsctl list-br 2>/dev/null)
    fi

    for br in "${bridges[@]}"; do
        run_cmd "Ports on bridge: $br" run_privileged ovs-vsctl list-ports "$br"
    done
}

# ---------------------------------------------------------------------------
# Section: OpenFlow flows
# ---------------------------------------------------------------------------
inspect_flows() {
    print_header "OPENFLOW FLOW DUMPS"

    local bridges
    if [[ -n "$SPECIFIC_BRIDGES" ]]; then
        IFS=',' read -ra bridges <<< "$SPECIFIC_BRIDGES"
    else
        mapfile -t bridges < <(run_privileged ovs-vsctl list-br 2>/dev/null)
    fi

    for br in "${bridges[@]}"; do
        # Flow count summary
        local flow_count
        flow_count=$(run_privileged ovs-ofctl dump-flows "$br" 2>/dev/null | grep -c 'cookie=' || echo "0")
        print_info "Bridge $br: $flow_count flows"

        run_cmd "Flows on $br (human-readable, sorted by table)" \
            run_privileged ovs-ofctl dump-flows "$br" --rsort=priority

        # Flow table summary (count per table)
        print_subheader "Flow Count Per Table - $br"
        if output=$(run_privileged ovs-ofctl dump-flows "$br" 2>/dev/null); then
            echo "$output" | grep -oP 'table=\d+' | sort | uniq -c | sort -rn
        else
            print_warning "Could not dump flows for $br"
        fi
        echo ""

        # Table descriptions for well-known bridges
        if [[ "$br" == "br-int" ]]; then
            print_subheader "br-int Table Reference (ML2/OVS)"
            echo "  Table  0 - Local switching / ingress classification"
            echo "  Table  1 - VLAN tagging (ingress)"
            echo "  Table  2 - Distributed Virtual Router (DVR)"
            echo "  Table 20 - Ingress security group"
            echo "  Table 21 - Ingress security group conntrack"
            echo "  Table 22 - Ingress security group rules"
            echo "  Table 23 - Ingress security group accept"
            echo "  Table 24 - Ingress security group final"
            echo "  Table 60 - Local forwarding"
            echo "  Table 61 - Egress security group"
            echo "  Table 62 - Egress security group conntrack"
            echo ""
        fi
    done
}

# ---------------------------------------------------------------------------
# Section: Port statistics
# ---------------------------------------------------------------------------
inspect_ports() {
    print_header "PORT STATISTICS"

    local bridges
    if [[ -n "$SPECIFIC_BRIDGES" ]]; then
        IFS=',' read -ra bridges <<< "$SPECIFIC_BRIDGES"
    else
        mapfile -t bridges < <(run_privileged ovs-vsctl list-br 2>/dev/null)
    fi

    for br in "${bridges[@]}"; do
        run_cmd "Port Statistics - $br" run_privileged ovs-ofctl dump-ports "$br"
        run_cmd "Port Descriptions - $br" run_privileged ovs-ofctl dump-ports-desc "$br"
    done
}

# ---------------------------------------------------------------------------
# Section: MAC learning table
# ---------------------------------------------------------------------------
inspect_fdb() {
    print_header "MAC LEARNING TABLES (FDB)"

    local bridges
    if [[ -n "$SPECIFIC_BRIDGES" ]]; then
        IFS=',' read -ra bridges <<< "$SPECIFIC_BRIDGES"
    else
        mapfile -t bridges < <(run_privileged ovs-vsctl list-br 2>/dev/null)
    fi

    for br in "${bridges[@]}"; do
        run_cmd "FDB Table - $br" run_privileged ovs-appctl fdb/show "$br"
    done
}

# ---------------------------------------------------------------------------
# Section: Bond status
# ---------------------------------------------------------------------------
inspect_bonds() {
    print_header "BOND STATUS"

    # Discover bonds
    local bonds
    bonds=$(run_privileged ovs-appctl bond/list 2>/dev/null || true)

    if [[ -z "$bonds" || "$bonds" == *"no bonds"* ]]; then
        print_info "No bonds configured on this node."
        return
    fi

    echo "$bonds"
    echo ""

    # Show details for each bond
    local bond_names
    bond_names=$(echo "$bonds" | tail -n +2 | awk '{print $1}')

    for bond in $bond_names; do
        run_cmd "Bond Details - $bond" run_privileged ovs-appctl bond/show "$bond"
    done

    # LACP status
    run_cmd "LACP Status (all bonds)" run_privileged ovs-appctl lacp/show 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Section: Tunnel endpoints
# ---------------------------------------------------------------------------
inspect_tunnels() {
    print_header "TUNNEL ENDPOINTS"

    run_cmd "VXLAN Tunnels" run_privileged ovs-vsctl find interface type=vxlan
    run_cmd "Geneve Tunnels" run_privileged ovs-vsctl find interface type=geneve
    run_cmd "GRE Tunnels" run_privileged ovs-vsctl find interface type=gre

    # Summary of tunnel remote IPs
    print_subheader "Tunnel Remote IP Summary"
    local tunnel_ips
    tunnel_ips=$(run_privileged ovs-vsctl find interface type=vxlan 2>/dev/null | grep -oP 'remote_ip="?\K[0-9.]+' || true)
    tunnel_ips+=$'\n'
    tunnel_ips+=$(run_privileged ovs-vsctl find interface type=geneve 2>/dev/null | grep -oP 'remote_ip="?\K[0-9.]+' || true)
    tunnel_ips+=$'\n'
    tunnel_ips+=$(run_privileged ovs-vsctl find interface type=gre 2>/dev/null | grep -oP 'remote_ip="?\K[0-9.]+' || true)

    tunnel_ips=$(echo "$tunnel_ips" | sort -u | grep -v '^$' || true)

    if [[ -n "$tunnel_ips" ]]; then
        echo "Remote tunnel endpoints found:"
        echo "$tunnel_ips" | while read -r ip; do
            echo "  - $ip"
        done
    else
        print_info "No tunnel endpoints found."
    fi
    echo ""

    # Local tunnel IP
    print_subheader "Local Tunnel Endpoint IP"
    local local_ip
    local_ip=$(run_privileged ovs-vsctl get open_vswitch . other_config:local_ip 2>/dev/null || true)
    if [[ -n "$local_ip" ]]; then
        print_info "Local tunnel IP: $local_ip"
    else
        print_warning "local_ip not set in other_config. Checking external_ids..."
        local_ip=$(run_privileged ovs-vsctl get open_vswitch . external_ids 2>/dev/null || true)
        echo "$local_ip"
    fi
}

# ---------------------------------------------------------------------------
# Section: Interface statistics and errors
# ---------------------------------------------------------------------------
inspect_interfaces() {
    print_header "INTERFACE STATISTICS AND ERROR COUNTERS"

    # List all interfaces with stats
    run_cmd "All Interfaces (name, type, admin_state, link_state)" \
        run_privileged ovs-vsctl --columns=name,type,admin_state,link_state list interface

    # Show interfaces with errors
    print_subheader "Interfaces With Errors"
    local ifaces
    ifaces=$(run_privileged ovs-vsctl --columns=name,statistics list interface 2>/dev/null || true)

    if [[ -n "$ifaces" ]]; then
        # Parse and show only interfaces with non-zero errors
        local current_name=""
        local has_errors=false
        local error_output=""

        while IFS= read -r line; do
            if [[ "$line" =~ ^name ]]; then
                # Print previous interface if it had errors
                if [[ "$has_errors" == true && -n "$current_name" ]]; then
                    echo -e "${RED}${current_name}${NC}"
                    echo "$error_output"
                    echo ""
                fi
                current_name=$(echo "$line" | sed 's/.*: *//')
                has_errors=false
                error_output=""
            elif [[ "$line" =~ ^statistics ]]; then
                local stats
                stats=$(echo "$line" | sed 's/.*: *//')
                # Check for non-zero error counters
                local error_fields
                error_fields=$(echo "$stats" | grep -oP '(rx_errors|tx_errors|rx_dropped|tx_dropped|collisions|rx_crc_err|rx_frame_err|rx_over_err)=\d+' || true)
                if [[ -n "$error_fields" ]]; then
                    while IFS= read -r field; do
                        local val
                        val=$(echo "$field" | grep -oP '\d+$')
                        if [[ "$val" -gt 0 ]]; then
                            has_errors=true
                        fi
                    done <<< "$error_fields"
                    error_output="  $error_fields"
                fi
            fi
        done <<< "$ifaces"

        # Handle last interface
        if [[ "$has_errors" == true && -n "$current_name" ]]; then
            echo -e "${RED}${current_name}${NC}"
            echo "$error_output"
            echo ""
        fi

        if [[ "$has_errors" == false ]]; then
            print_success "No interfaces with error counters detected."
        fi
    fi

    # Datapath stats
    run_cmd "Datapath Statistics" run_privileged ovs-appctl dpctl/show --statistics 2>/dev/null || true

    # Coverage counters summary
    run_cmd "OVS Coverage Counters (top 20 by count)" bash -c \
        "$(cat <<'INNER'
ovs-appctl coverage/show 2>/dev/null | sort -t: -k2 -rn | head -20
INNER
)"
}

# ---------------------------------------------------------------------------
# Report file setup
# ---------------------------------------------------------------------------
setup_report() {
    if [[ "$REPORT_ENABLED" != true ]]; then
        return
    fi

    TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
    REPORT_FILE="${REPORT_DIR}/ovs-inspect-${TIMESTAMP}.txt"

    if [[ ! -d "$REPORT_DIR" ]]; then
        mkdir -p "$REPORT_DIR"
    fi

    # Tee all output to the report file (strip ANSI color codes for the file)
    exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' > "$REPORT_FILE"))
    exec 2>&1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    echo -e "${BLUE}${BOLD}"
    echo "  _____ _____   _____                           _"
    echo " / ____|  __ \ / ____|                         | |"
    echo "| |  __| |__) | (___    ___ __   ___  ___  ___| |_"
    echo "| | |_ |  _  / \___ \  / _ \ \\ / / |/ _ \\/ __| __|"
    echo "| |__| | | \\ \\ ____) ||  __/\\ V /| |  __/ (__| |_"
    echo " \\_____|_|  \\_\\_____/  \\___| \\_/ |_|\\___|\\___|\\___|"
    echo ""
    echo "  OVS Inspector for Red Hat OpenStack Platform"
    echo -e "${NC}"

    setup_report
    preflight_checks

    if [[ -n "$SPECIFIC_SECTION" ]]; then
        case "$SPECIFIC_SECTION" in
            version)    detect_rhosp_version ;;
            role)       detect_node_role ;;
            bridges)    inspect_bridges ;;
            flows)      inspect_flows ;;
            ports)      inspect_ports ;;
            fdb)        inspect_fdb ;;
            bonds)      inspect_bonds ;;
            tunnels)    inspect_tunnels ;;
            interfaces) inspect_interfaces ;;
            *)
                print_error "Unknown section: $SPECIFIC_SECTION"
                echo "Valid sections: version, role, bridges, flows, ports, fdb, bonds, tunnels, interfaces"
                exit 1
                ;;
        esac
    else
        detect_rhosp_version
        detect_node_role
        inspect_bridges
        inspect_flows
        inspect_ports
        inspect_fdb
        inspect_bonds
        inspect_tunnels
        inspect_interfaces
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
