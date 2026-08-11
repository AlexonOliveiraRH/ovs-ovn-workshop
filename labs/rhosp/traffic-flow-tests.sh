#!/bin/bash
set -euo pipefail

###############################################################################
# traffic-flow-tests.sh - Test and trace traffic flows in RHOSP
#
# Creates test resources (networks, subnets, routers, VMs) and runs
# connectivity tests between them. For each test, shows the ping result,
# matching OVS/OVN flows, and suggests tcpdump capture points.
#
# Supports both ML2/OVS and ML2/OVN backends with backend-specific
# flow tracing (ovn-trace for OVN, ovs-ofctl for OVS).
#
# All test resources are labeled with a "workshop-test-" prefix for
# easy identification and cleanup.
#
# Usage:
#   ./traffic-flow-tests.sh [OPTIONS]
#
# Options:
#   --help              Show this help message
#   --backend ovs|ovn   Force backend (default: auto-detect)
#   --create-resources  Create test networks, subnets, routers, and VMs
#   --use-existing      Use existing workshop-test-* resources
#   --cleanup           Remove all workshop-test-* resources
#   --skip-ping         Skip ping tests (useful when VMs are not yet ready)
#   --credentials FILE  Path to OpenStack credentials file (default: auto-detect)
#   --report-dir DIR    Directory for the report file (default: /tmp)
#   --no-report         Do not save output to a report file
#   --image NAME        Glance image name to use for VMs (default: cirros)
#   --flavor NAME       Flavor to use for VMs (default: m1.tiny)
#
# Output:
#   Timestamped report saved to /tmp/traffic-flow-tests-YYYYMMDD-HHMMSS.txt
#
# Requirements:
#   - OpenStack CLI (python-openstackclient)
#   - Sourced OpenStack credentials (overcloudrc)
#   - For OVN: ovn-nbctl, ovn-sbctl, ovn-trace
#   - For OVS: ovs-ofctl, ovs-appctl
#   - Root or sudo privileges for flow inspection
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
BACKEND=""            # ovs or ovn (auto-detected or forced)
ACTION=""             # create-resources, use-existing, cleanup
REPORT_ENABLED=true
REPORT_DIR="/tmp"
REPORT_FILE=""
CREDENTIALS_FILE=""
SKIP_PING=false
IMAGE_NAME="cirros"
FLAVOR_NAME="m1.tiny"
TIMESTAMP=""

# Resource naming prefix
PREFIX="workshop-test"

# Network/subnet names
NET1_NAME="${PREFIX}-net1"
NET2_NAME="${PREFIX}-net2"
SUBNET1_NAME="${PREFIX}-subnet1"
SUBNET2_NAME="${PREFIX}-subnet2"
ROUTER_NAME="${PREFIX}-router"
EXT_NET_NAME=""      # Detected from existing external network

# VM names
VM1_NAME="${PREFIX}-vm1"   # net1, compute A
VM2_NAME="${PREFIX}-vm2"   # net1, compute B (or same if single compute)
VM3_NAME="${PREFIX}-vm3"   # net2, any compute

# Subnet CIDRs
SUBNET1_CIDR="192.168.100.0/24"
SUBNET2_CIDR="192.168.200.0/24"

# Test results tracking
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Container access (for OVN)
IS_CONTAINERIZED=false
CONTAINER_RUNTIME=""
OVN_NB_CONTAINER=""
OVN_SB_CONTAINER=""

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

print_pass() {
    echo -e "${GREEN}${BOLD}[PASS]${NC} $1"
    ((TESTS_PASSED++)) || true
}

print_fail() {
    echo -e "${RED}${BOLD}[FAIL]${NC} $1"
    ((TESTS_FAILED++)) || true
}

print_skip() {
    echo -e "${YELLOW}${BOLD}[SKIP]${NC} $1"
    ((TESTS_SKIPPED++)) || true
}

run_privileged() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

# OVN command wrappers (handle containerized access)
ovn_nbctl() {
    if [[ "$IS_CONTAINERIZED" == true && -n "$OVN_NB_CONTAINER" ]]; then
        run_privileged "$CONTAINER_RUNTIME" exec "$OVN_NB_CONTAINER" ovn-nbctl "$@"
    else
        run_privileged ovn-nbctl "$@"
    fi
}

ovn_sbctl() {
    if [[ "$IS_CONTAINERIZED" == true && -n "$OVN_SB_CONTAINER" ]]; then
        run_privileged "$CONTAINER_RUNTIME" exec "$OVN_SB_CONTAINER" ovn-sbctl "$@"
    else
        run_privileged ovn-sbctl "$@"
    fi
}

ovn_trace() {
    if [[ "$IS_CONTAINERIZED" == true && -n "$OVN_SB_CONTAINER" ]]; then
        run_privileged "$CONTAINER_RUNTIME" exec "$OVN_SB_CONTAINER" ovn-trace "$@"
    else
        run_privileged ovn-trace "$@"
    fi
}

# Wait for a VM to reach ACTIVE status
wait_for_vm_active() {
    local vm_name="$1"
    local timeout="${2:-300}"
    local elapsed=0
    local interval=10

    print_info "Waiting for $vm_name to become ACTIVE (timeout: ${timeout}s)..."

    while [[ $elapsed -lt $timeout ]]; do
        local status
        status=$(openstack server show "$vm_name" -f value -c status 2>/dev/null || echo "UNKNOWN")
        case "$status" in
            ACTIVE)
                print_success "$vm_name is ACTIVE"
                return 0
                ;;
            ERROR)
                print_error "$vm_name is in ERROR state"
                openstack server show "$vm_name" -c fault -f value 2>/dev/null || true
                return 1
                ;;
            BUILD)
                ;;
            *)
                print_warning "$vm_name status: $status"
                ;;
        esac
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    print_error "$vm_name did not become ACTIVE within ${timeout}s"
    return 1
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Test and trace traffic flows in a RHOSP environment.
Supports both ML2/OVS and ML2/OVN backends.

Options:
  --help                Show this help message and exit
  --backend ovs|ovn     Force backend type (default: auto-detect)
  --create-resources    Create test networks, subnets, routers, and VMs
  --use-existing        Use existing workshop-test-* resources
  --cleanup             Remove all workshop-test-* resources
  --skip-ping           Skip ping tests (useful when VMs are not ready)
  --credentials FILE    Path to OpenStack credentials file
  --report-dir DIR      Directory for the report file (default: /tmp)
  --no-report           Do not save output to a report file
  --image NAME          Glance image for test VMs (default: cirros)
  --flavor NAME         Flavor for test VMs (default: m1.tiny)

Workflow:
  1. Create resources:    $(basename "$0") --create-resources
  2. Run tests:           $(basename "$0") --use-existing
  3. Clean up:            $(basename "$0") --cleanup

Examples:
  $(basename "$0") --create-resources --backend ovn
  $(basename "$0") --use-existing --skip-ping
  $(basename "$0") --cleanup
  $(basename "$0") --create-resources --image cirros-0.5.2 --flavor m1.small
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
            --backend)
                BACKEND="$2"
                if [[ "$BACKEND" != "ovs" && "$BACKEND" != "ovn" ]]; then
                    print_error "Invalid backend: $BACKEND (must be 'ovs' or 'ovn')"
                    exit 1
                fi
                shift 2
                ;;
            --create-resources)
                ACTION="create"
                shift
                ;;
            --use-existing)
                ACTION="existing"
                shift
                ;;
            --cleanup)
                ACTION="cleanup"
                shift
                ;;
            --skip-ping)
                SKIP_PING=true
                shift
                ;;
            --credentials)
                CREDENTIALS_FILE="$2"
                shift 2
                ;;
            --report-dir)
                REPORT_DIR="$2"
                shift 2
                ;;
            --no-report)
                REPORT_ENABLED=false
                shift
                ;;
            --image)
                IMAGE_NAME="$2"
                shift 2
                ;;
            --flavor)
                FLAVOR_NAME="$2"
                shift 2
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use --help for usage information."
                exit 1
                ;;
        esac
    done

    if [[ -z "$ACTION" ]]; then
        print_error "You must specify one of: --create-resources, --use-existing, or --cleanup"
        echo "Use --help for usage information."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Source OpenStack credentials
# ---------------------------------------------------------------------------
source_credentials() {
    print_header "OPENSTACK CREDENTIALS"

    # If already sourced (OS_AUTH_URL is set), skip
    if [[ -n "${OS_AUTH_URL:-}" ]]; then
        print_success "OpenStack credentials already sourced"
        print_info "Auth URL: ${OS_AUTH_URL}"
        print_info "Project: ${OS_PROJECT_NAME:-unknown}"
        return 0
    fi

    # Try to find credentials file
    local cred_paths=(
        "$CREDENTIALS_FILE"
        ~/overcloudrc
        ~/overcloudrc.v3
        /home/stack/overcloudrc
        /home/stack/overcloudrc.v3
        ~/stackrc
    )

    for path in "${cred_paths[@]}"; do
        if [[ -n "$path" && -f "$path" ]]; then
            print_info "Sourcing credentials from: $path"
            # shellcheck disable=SC1090
            source "$path"
            print_success "Credentials loaded"
            print_info "Auth URL: ${OS_AUTH_URL:-not set}"
            print_info "Project: ${OS_PROJECT_NAME:-unknown}"
            return 0
        fi
    done

    print_error "No OpenStack credentials found."
    print_info "Please source your overcloudrc file or use --credentials FILE"
    exit 1
}

# ---------------------------------------------------------------------------
# Detect backend
# ---------------------------------------------------------------------------
detect_backend() {
    if [[ -n "$BACKEND" ]]; then
        print_info "Backend forced to: $BACKEND"
        return
    fi

    print_subheader "Auto-detecting Networking Backend"

    # Check ML2 config
    for path in /etc/neutron/plugins/ml2/ml2_conf.ini \
                /var/lib/config-data/puppet-generated/neutron/etc/neutron/plugins/ml2/ml2_conf.ini; do
        if [[ -f "$path" ]]; then
            local mechanism
            mechanism=$(grep -i 'mechanism_drivers' "$path" 2>/dev/null || true)
            if echo "$mechanism" | grep -qi 'ovn'; then
                BACKEND="ovn"
                print_success "Detected backend: ML2/OVN (from $path)"
                return
            elif echo "$mechanism" | grep -qi 'openvswitch'; then
                BACKEND="ovs"
                print_success "Detected backend: ML2/OVS (from $path)"
                return
            fi
        fi
    done

    # Check running processes
    if pgrep -f ovn-controller &>/dev/null; then
        BACKEND="ovn"
        print_success "Detected backend: ML2/OVN (ovn-controller running)"
    elif pgrep -f neutron-openvswitch-agent &>/dev/null; then
        BACKEND="ovs"
        print_success "Detected backend: ML2/OVS (neutron-openvswitch-agent running)"
    fi

    # Check containers
    if [[ -z "$BACKEND" ]]; then
        if podman ps 2>/dev/null | grep -qi 'ovn'; then
            BACKEND="ovn"
            print_success "Detected backend: ML2/OVN (OVN containers running)"
        fi
    fi

    # Try via Neutron API
    if [[ -z "$BACKEND" && -n "${OS_AUTH_URL:-}" ]]; then
        local agents
        agents=$(openstack network agent list -f value -c "Agent Type" 2>/dev/null || true)
        if echo "$agents" | grep -qi 'ovn'; then
            BACKEND="ovn"
            print_success "Detected backend: ML2/OVN (from Neutron API)"
        elif echo "$agents" | grep -qi 'Open vSwitch'; then
            BACKEND="ovs"
            print_success "Detected backend: ML2/OVS (from Neutron API)"
        fi
    fi

    if [[ -z "$BACKEND" ]]; then
        print_error "Could not auto-detect backend. Use --backend ovs|ovn"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Detect OVN container access
# ---------------------------------------------------------------------------
detect_ovn_containers() {
    if [[ "$BACKEND" != "ovn" ]]; then
        return
    fi

    for runtime in podman docker; do
        if ! command -v "$runtime" &>/dev/null; then
            continue
        fi
        local containers
        containers=$(run_privileged "$runtime" ps --format '{{.Names}}' 2>/dev/null || true)
        if [[ -z "$containers" ]]; then
            continue
        fi

        CONTAINER_RUNTIME="$runtime"
        OVN_NB_CONTAINER=$(echo "$containers" | grep -iE 'ovn.*nb|ovn_northd|ovn[-_]dbs|ovn[-_]cluster' | head -1 || true)
        OVN_SB_CONTAINER=$(echo "$containers" | grep -iE 'ovn.*sb|ovn_northd|ovn[-_]dbs|ovn[-_]cluster' | head -1 || true)

        if [[ -n "$OVN_NB_CONTAINER" || -n "$OVN_SB_CONTAINER" ]]; then
            IS_CONTAINERIZED=true
            print_info "OVN access: containerized ($runtime)"
            [[ -n "$OVN_NB_CONTAINER" ]] && print_info "  NB container: $OVN_NB_CONTAINER"
            [[ -n "$OVN_SB_CONTAINER" ]] && print_info "  SB container: $OVN_SB_CONTAINER"
            return
        fi
    done
}

# ---------------------------------------------------------------------------
# Create test resources
# ---------------------------------------------------------------------------
create_resources() {
    print_header "CREATING TEST RESOURCES"

    # Check for existing resources
    local existing
    existing=$(openstack server list --name "^${PREFIX}" -f value -c Name 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
        print_warning "Existing workshop-test resources found:"
        echo "$existing"
        echo ""
        print_info "Use --cleanup first, or --use-existing to test with current resources."
        return 1
    fi

    # Detect external network
    print_subheader "Detecting External Network"
    EXT_NET_NAME=$(openstack network list --external -f value -c Name 2>/dev/null | head -1 || true)
    if [[ -n "$EXT_NET_NAME" ]]; then
        print_success "External network: $EXT_NET_NAME"
    else
        print_warning "No external network found. Floating IP tests will be skipped."
    fi

    # Detect available image
    print_subheader "Checking Image and Flavor"
    local image_id
    image_id=$(openstack image show "$IMAGE_NAME" -f value -c id 2>/dev/null || true)
    if [[ -z "$image_id" ]]; then
        # Try to find any cirros image
        image_id=$(openstack image list --name '*cirros*' -f value -c ID 2>/dev/null | head -1 || true)
        if [[ -z "$image_id" ]]; then
            print_error "Image '$IMAGE_NAME' not found. Specify --image NAME."
            print_info "Available images:"
            openstack image list -f table -c Name -c Status 2>/dev/null || true
            return 1
        fi
        IMAGE_NAME=$(openstack image show "$image_id" -f value -c name 2>/dev/null)
        print_info "Using image: $IMAGE_NAME"
    else
        print_success "Image found: $IMAGE_NAME ($image_id)"
    fi

    local flavor_id
    flavor_id=$(openstack flavor show "$FLAVOR_NAME" -f value -c id 2>/dev/null || true)
    if [[ -z "$flavor_id" ]]; then
        print_error "Flavor '$FLAVOR_NAME' not found. Specify --flavor NAME."
        print_info "Available flavors:"
        openstack flavor list -f table -c Name -c RAM -c VCPUs 2>/dev/null || true
        return 1
    fi
    print_success "Flavor found: $FLAVOR_NAME"

    # Create Network 1
    print_subheader "Creating Network 1 ($NET1_NAME)"
    openstack network create "$NET1_NAME" -f table
    openstack subnet create "$SUBNET1_NAME" \
        --network "$NET1_NAME" \
        --subnet-range "$SUBNET1_CIDR" \
        --dns-nameserver 8.8.8.8 \
        -f table
    print_success "Network 1 created: $NET1_NAME ($SUBNET1_CIDR)"

    # Create Network 2
    print_subheader "Creating Network 2 ($NET2_NAME)"
    openstack network create "$NET2_NAME" -f table
    openstack subnet create "$SUBNET2_NAME" \
        --network "$NET2_NAME" \
        --subnet-range "$SUBNET2_CIDR" \
        --dns-nameserver 8.8.8.8 \
        -f table
    print_success "Network 2 created: $NET2_NAME ($SUBNET2_CIDR)"

    # Create Router
    print_subheader "Creating Router ($ROUTER_NAME)"
    if [[ -n "$EXT_NET_NAME" ]]; then
        openstack router create "$ROUTER_NAME" \
            --external-gateway "$EXT_NET_NAME" \
            -f table
    else
        openstack router create "$ROUTER_NAME" -f table
    fi
    openstack router add subnet "$ROUTER_NAME" "$SUBNET1_NAME"
    openstack router add subnet "$ROUTER_NAME" "$SUBNET2_NAME"
    print_success "Router created and connected to both subnets"

    # Detect available compute hosts for scheduling
    print_subheader "Detecting Compute Hosts"
    local compute_hosts
    compute_hosts=$(openstack compute service list --service nova-compute -f value -c Host -c State 2>/dev/null | \
        grep 'up' | awk '{print $1}' || true)
    local host_count
    host_count=$(echo "$compute_hosts" | grep -c . || echo "0")
    print_info "Available compute hosts: $host_count"
    if [[ -n "$compute_hosts" ]]; then
        echo "$compute_hosts" | while read -r h; do
            echo "  - $h"
        done
    fi
    echo ""

    local host1 host2
    host1=$(echo "$compute_hosts" | head -1 || true)
    host2=$(echo "$compute_hosts" | tail -1 || true)

    # Create VMs
    print_subheader "Creating Test VMs"

    # VM1: net1 (try to place on host1)
    local vm1_cmd="openstack server create $VM1_NAME --image $IMAGE_NAME --flavor $FLAVOR_NAME --network $NET1_NAME"
    if [[ -n "$host1" ]]; then
        vm1_cmd+=" --availability-zone nova:$host1"
    fi
    print_info "Creating $VM1_NAME on net1..."
    eval "$vm1_cmd" -f table

    # VM2: net1 (try to place on host2 for cross-compute test)
    local vm2_cmd="openstack server create $VM2_NAME --image $IMAGE_NAME --flavor $FLAVOR_NAME --network $NET2_NAME"
    if [[ -n "$host2" && "$host2" != "$host1" ]]; then
        vm2_cmd+=" --availability-zone nova:$host2"
        print_info "Creating $VM2_NAME on net2 (different compute: $host2)..."
    else
        print_info "Creating $VM2_NAME on net2 (same compute - only one host available)..."
    fi
    eval "$vm2_cmd" -f table

    # VM3: net2 (for cross-network routing test)
    print_info "Creating $VM3_NAME on net1..."
    openstack server create "$VM3_NAME" \
        --image "$IMAGE_NAME" \
        --flavor "$FLAVOR_NAME" \
        --network "$NET1_NAME" \
        -f table

    # Wait for VMs to become ACTIVE
    print_subheader "Waiting for VMs to Boot"
    local all_active=true
    for vm in "$VM1_NAME" "$VM2_NAME" "$VM3_NAME"; do
        if ! wait_for_vm_active "$vm" 300; then
            all_active=false
        fi
    done

    if [[ "$all_active" == false ]]; then
        print_warning "Not all VMs reached ACTIVE state. Check 'openstack server list'."
    fi

    # Create floating IP for external access test
    if [[ -n "$EXT_NET_NAME" ]]; then
        print_subheader "Creating Floating IP"
        local fip
        fip=$(openstack floating ip create "$EXT_NET_NAME" -f value -c floating_ip_address 2>/dev/null || true)
        if [[ -n "$fip" ]]; then
            # Get VM1's port
            local vm1_port
            vm1_port=$(openstack port list --server "$VM1_NAME" -f value -c ID 2>/dev/null | head -1 || true)
            if [[ -n "$vm1_port" ]]; then
                openstack floating ip set --port "$vm1_port" "$fip" 2>/dev/null || true
                print_success "Floating IP $fip assigned to $VM1_NAME"
            fi
        else
            print_warning "Could not create floating IP"
        fi
    fi

    # Summary
    print_subheader "Resource Creation Summary"
    echo ""
    echo "Networks:"
    openstack network list --name "^${PREFIX}" -f table 2>/dev/null || true
    echo ""
    echo "Subnets:"
    openstack subnet list --name "^${PREFIX}" -f table 2>/dev/null || true
    echo ""
    echo "Router:"
    openstack router show "$ROUTER_NAME" -f table -c name -c status -c external_gateway_info 2>/dev/null || true
    echo ""
    echo "Servers:"
    openstack server list --name "^${PREFIX}" -f table 2>/dev/null || true
    echo ""

    print_success "Test resources created. Run with --use-existing to execute tests."
}

# ---------------------------------------------------------------------------
# Cleanup test resources
# ---------------------------------------------------------------------------
cleanup_resources() {
    print_header "CLEANING UP TEST RESOURCES"
    print_warning "This will remove all resources with the '${PREFIX}-' prefix."
    echo ""

    # Delete floating IPs
    print_subheader "Removing Floating IPs"
    local fips
    fips=$(openstack floating ip list -f value -c ID -c "Floating IP Address" 2>/dev/null || true)
    # Find FIPs attached to our VMs
    for vm in "$VM1_NAME" "$VM2_NAME" "$VM3_NAME"; do
        local vm_fips
        vm_fips=$(openstack server show "$vm" -f json -c addresses 2>/dev/null | \
            grep -oP '\d+\.\d+\.\d+\.\d+' || true)
        if [[ -n "$vm_fips" ]]; then
            while IFS= read -r fip_addr; do
                local fip_id
                fip_id=$(openstack floating ip list --floating-ip-address "$fip_addr" -f value -c ID 2>/dev/null || true)
                if [[ -n "$fip_id" ]]; then
                    openstack floating ip delete "$fip_id" 2>/dev/null && \
                        print_success "Deleted floating IP: $fip_addr" || \
                        print_warning "Could not delete floating IP: $fip_addr"
                fi
            done <<< "$vm_fips"
        fi
    done

    # Delete VMs
    print_subheader "Removing VMs"
    local servers
    servers=$(openstack server list --name "^${PREFIX}" -f value -c ID 2>/dev/null || true)
    if [[ -n "$servers" ]]; then
        while IFS= read -r server_id; do
            local server_name
            server_name=$(openstack server show "$server_id" -f value -c name 2>/dev/null || echo "$server_id")
            openstack server delete "$server_id" --wait 2>/dev/null && \
                print_success "Deleted server: $server_name" || \
                print_warning "Could not delete server: $server_name"
        done <<< "$servers"
    else
        print_info "No workshop-test VMs found."
    fi

    # Remove router interfaces and delete router
    print_subheader "Removing Router"
    if openstack router show "$ROUTER_NAME" &>/dev/null 2>&1; then
        openstack router remove subnet "$ROUTER_NAME" "$SUBNET1_NAME" 2>/dev/null || true
        openstack router remove subnet "$ROUTER_NAME" "$SUBNET2_NAME" 2>/dev/null || true
        openstack router unset --external-gateway "$ROUTER_NAME" 2>/dev/null || true
        openstack router delete "$ROUTER_NAME" 2>/dev/null && \
            print_success "Deleted router: $ROUTER_NAME" || \
            print_warning "Could not delete router: $ROUTER_NAME"
    else
        print_info "Router $ROUTER_NAME not found."
    fi

    # Delete subnets
    print_subheader "Removing Subnets"
    for subnet in "$SUBNET1_NAME" "$SUBNET2_NAME"; do
        if openstack subnet show "$subnet" &>/dev/null 2>&1; then
            openstack subnet delete "$subnet" 2>/dev/null && \
                print_success "Deleted subnet: $subnet" || \
                print_warning "Could not delete subnet: $subnet"
        fi
    done

    # Delete networks
    print_subheader "Removing Networks"
    for net in "$NET1_NAME" "$NET2_NAME"; do
        if openstack network show "$net" &>/dev/null 2>&1; then
            # Delete any remaining ports
            local ports
            ports=$(openstack port list --network "$net" -f value -c ID 2>/dev/null || true)
            if [[ -n "$ports" ]]; then
                while IFS= read -r port_id; do
                    openstack port delete "$port_id" 2>/dev/null || true
                done <<< "$ports"
            fi
            openstack network delete "$net" 2>/dev/null && \
                print_success "Deleted network: $net" || \
                print_warning "Could not delete network: $net"
        fi
    done

    # Verify cleanup
    print_subheader "Cleanup Verification"
    local remaining
    remaining=$(openstack server list --name "^${PREFIX}" -f value -c Name 2>/dev/null || true)
    if [[ -n "$remaining" ]]; then
        print_warning "Some resources may still exist:"
        echo "$remaining"
    else
        print_success "All workshop-test resources removed."
    fi
}

# ---------------------------------------------------------------------------
# Discover existing test resources
# ---------------------------------------------------------------------------
discover_resources() {
    print_header "DISCOVERING EXISTING TEST RESOURCES"

    # List VMs
    print_subheader "Test VMs"
    local vms
    vms=$(openstack server list --name "^${PREFIX}" -f table 2>/dev/null || true)
    if [[ -z "$vms" || $(echo "$vms" | wc -l) -le 3 ]]; then
        print_error "No workshop-test VMs found. Run with --create-resources first."
        exit 1
    fi
    echo "$vms"

    # Check VM status
    for vm in "$VM1_NAME" "$VM2_NAME" "$VM3_NAME"; do
        local status
        status=$(openstack server show "$vm" -f value -c status 2>/dev/null || echo "NOT_FOUND")
        if [[ "$status" == "ACTIVE" ]]; then
            print_success "$vm: ACTIVE"
        elif [[ "$status" == "NOT_FOUND" ]]; then
            print_warning "$vm: not found"
        else
            print_warning "$vm: $status"
        fi
    done

    # List networks
    print_subheader "Test Networks"
    openstack network list --name "^${PREFIX}" -f table 2>/dev/null || true

    # Show router
    print_subheader "Test Router"
    openstack router show "$ROUTER_NAME" -f table -c name -c status -c external_gateway_info 2>/dev/null || \
        print_warning "Router $ROUTER_NAME not found"

    # External network
    EXT_NET_NAME=$(openstack network list --external -f value -c Name 2>/dev/null | head -1 || true)
    if [[ -n "$EXT_NET_NAME" ]]; then
        print_info "External network: $EXT_NET_NAME"
    fi
}

# ---------------------------------------------------------------------------
# Get VM IP addresses
# ---------------------------------------------------------------------------
get_vm_ip() {
    local vm_name="$1"
    local network="${2:-}"

    if [[ -n "$network" ]]; then
        openstack server show "$vm_name" -f json -c addresses 2>/dev/null | \
            python3 -c "
import sys, json
data = json.load(sys.stdin)
addrs = data.get('addresses', '')
if isinstance(addrs, str):
    # Parse 'net1=192.168.100.5; net2=192.168.200.3' format
    for part in addrs.split(';'):
        part = part.strip()
        if part.startswith('$network='):
            ips = part.split('=')[1].strip().split(',')
            print(ips[0].strip())
            break
elif isinstance(addrs, dict):
    for ip_info in addrs.get('$network', []):
        if isinstance(ip_info, dict):
            print(ip_info['addr'])
            break
        else:
            print(ip_info)
            break
" 2>/dev/null || true
    else
        # Return first fixed IP
        openstack server show "$vm_name" -f value -c addresses 2>/dev/null | \
            grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || true
    fi
}

get_vm_host() {
    local vm_name="$1"
    openstack server show "$vm_name" -f value -c "OS-EXT-SRV-ATTR:host" 2>/dev/null || echo "unknown"
}

get_vm_port_mac() {
    local vm_name="$1"
    openstack port list --server "$vm_name" -f value -c "MAC Address" 2>/dev/null | head -1 || true
}

# ---------------------------------------------------------------------------
# Test: Ping between VMs
# ---------------------------------------------------------------------------
run_ping_test() {
    local test_name="$1"
    local src_vm="$2"
    local dst_ip="$3"

    print_subheader "PING TEST: $test_name"

    if [[ "$SKIP_PING" == true ]]; then
        print_skip "Ping test skipped (--skip-ping)"
        return
    fi

    print_info "Source: $src_vm -> Destination: $dst_ip"

    # Try via network namespace (if we are on the compute hosting the VM)
    local src_port_id
    src_port_id=$(openstack port list --server "$src_vm" -f value -c ID 2>/dev/null | head -1 || true)

    if [[ -z "$src_port_id" ]]; then
        print_skip "Cannot determine port for $src_vm"
        return
    fi

    # Try namespace-based ping (tap interface namespace)
    local ns_name="qdhcp-"
    local src_net_id
    src_net_id=$(openstack port show "$src_port_id" -f value -c network_id 2>/dev/null || true)

    if [[ -n "$src_net_id" ]]; then
        ns_name="qdhcp-${src_net_id}"
    fi

    local ping_success=false

    # Method 1: Try via DHCP namespace
    if run_privileged ip netns list 2>/dev/null | grep -q "$ns_name"; then
        print_info "Pinging via namespace: $ns_name"
        if run_privileged ip netns exec "$ns_name" ping -c 3 -W 5 "$dst_ip" 2>&1; then
            ping_success=true
        fi
    fi

    # Method 2: Try via openstack console (for cirros VMs)
    if [[ "$ping_success" == false ]]; then
        print_info "Attempting ping via 'openstack server ssh' or console..."
        # This requires the VM to be accessible
        if openstack server ssh "$src_vm" -- ping -c 3 -W 5 "$dst_ip" 2>&1; then
            ping_success=true
        else
            print_warning "Direct SSH/console ping not available."
            print_info "Manual test: ssh into $src_vm and run: ping -c 3 $dst_ip"
        fi
    fi

    if [[ "$ping_success" == true ]]; then
        print_pass "$test_name - Ping successful"
    else
        print_fail "$test_name - Ping failed or could not be executed"
        print_info "Manual verification required if ping could not be executed from this host."
    fi
}

# ---------------------------------------------------------------------------
# Show matching OVS flows for traffic
# ---------------------------------------------------------------------------
show_ovs_flow_match() {
    local src_mac="$1"
    local dst_ip="$2"
    local description="$3"

    print_subheader "OVS Flow Match: $description"

    if ! run_privileged ovs-vsctl br-exists br-int 2>/dev/null; then
        print_warning "br-int not found on this node."
        return
    fi

    # Match flows by source MAC
    if [[ -n "$src_mac" ]]; then
        print_info "Matching flows for src MAC: $src_mac"
        local matched
        matched=$(run_privileged ovs-ofctl dump-flows br-int 2>/dev/null | grep -i "$src_mac" || true)
        if [[ -n "$matched" ]]; then
            echo "$matched"
        else
            print_info "No flows matching source MAC on this node's br-int."
        fi
    fi

    # Match flows by destination IP (nw_dst)
    if [[ -n "$dst_ip" ]]; then
        echo ""
        print_info "Matching flows for dst IP: $dst_ip"
        local matched_ip
        matched_ip=$(run_privileged ovs-ofctl dump-flows br-int 2>/dev/null | grep "nw_dst=$dst_ip" || true)
        if [[ -n "$matched_ip" ]]; then
            echo "$matched_ip"
        else
            print_info "No flows matching destination IP on this node's br-int."
        fi
    fi
}

# ---------------------------------------------------------------------------
# Show tcpdump capture suggestions
# ---------------------------------------------------------------------------
suggest_tcpdump() {
    local test_name="$1"
    local src_vm="$2"
    local dst_ip="$3"
    local src_host="${4:-}"
    local dst_host="${5:-}"

    print_subheader "tcpdump Capture Points: $test_name"

    local src_port_id src_mac
    src_port_id=$(openstack port list --server "$src_vm" -f value -c ID 2>/dev/null | head -1 || true)
    src_mac=$(openstack port list --server "$src_vm" -f value -c "MAC Address" 2>/dev/null | head -1 || true)

    echo "Suggested capture commands:"
    echo ""

    if [[ -n "$src_port_id" ]]; then
        local tap_iface="tap${src_port_id:0:11}"
        echo -e "  ${CYAN}# On source compute ($src_host) - VM tap interface:${NC}"
        echo "  sudo tcpdump -i $tap_iface -nn icmp"
        echo ""
    fi

    echo -e "  ${CYAN}# On source compute ($src_host) - br-int:${NC}"
    echo "  sudo tcpdump -i br-int -nn icmp and host $dst_ip"
    echo ""

    if [[ "$BACKEND" == "ovs" ]]; then
        echo -e "  ${CYAN}# On source compute ($src_host) - tunnel bridge (br-tun):${NC}"
        echo "  sudo tcpdump -i br-tun -nn icmp"
        echo ""
    fi

    if [[ "$BACKEND" == "ovn" ]]; then
        echo -e "  ${CYAN}# On any node - Geneve tunnel interface:${NC}"
        local geneve_iface
        geneve_iface=$(run_privileged ovs-vsctl list-ports br-int 2>/dev/null | grep 'ovn-' | head -1 || echo "ovn-<chassis>-0")
        echo "  sudo tcpdump -i $geneve_iface -nn"
        echo ""
    fi

    if [[ -n "$src_host" && -n "$dst_host" && "$src_host" != "$dst_host" ]]; then
        echo -e "  ${CYAN}# On destination compute ($dst_host) - br-int:${NC}"
        echo "  sudo tcpdump -i br-int -nn icmp and host $dst_ip"
        echo ""
    fi

    echo -e "  ${CYAN}# On router namespace (controller/networker):${NC}"
    local router_id
    router_id=$(openstack router show "$ROUTER_NAME" -f value -c id 2>/dev/null || true)
    if [[ -n "$router_id" ]]; then
        echo "  sudo ip netns exec qrouter-$router_id tcpdump -nn icmp and host $dst_ip"
    else
        echo "  sudo ip netns exec qrouter-<ROUTER_ID> tcpdump -nn icmp and host $dst_ip"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# OVN trace for a traffic flow
# ---------------------------------------------------------------------------
run_ovn_trace() {
    local test_name="$1"
    local src_vm="$2"
    local src_ip="$3"
    local dst_ip="$4"

    if [[ "$BACKEND" != "ovn" ]]; then
        return
    fi

    print_subheader "OVN Trace: $test_name"

    local src_mac src_port_id
    src_mac=$(get_vm_port_mac "$src_vm")
    src_port_id=$(openstack port list --server "$src_vm" -f value -c ID 2>/dev/null | head -1 || true)

    if [[ -z "$src_mac" || -z "$src_port_id" ]]; then
        print_warning "Cannot determine source MAC/port for OVN trace."
        print_info "Manual command: ovn-trace <datapath> 'inport==\"<port>\" && eth.src==<mac> && ip4.src==$src_ip && ip4.dst==$dst_ip && ip.ttl==64'"
        return
    fi

    # Find the logical port name for this Neutron port
    local lsp_name="$src_port_id"

    # Find the datapath (logical switch) for this port
    local datapath
    datapath=$(openstack port show "$src_port_id" -f value -c network_id 2>/dev/null || true)

    # Find the logical switch name from OVN
    local ls_name
    ls_name=$(ovn_nbctl --columns=name find logical_switch 2>/dev/null | \
        grep "$datapath" | head -1 | awk '{print $NF}' || true)

    if [[ -z "$ls_name" ]]; then
        # Try listing all switches
        ls_name=$(ovn_nbctl ls-list 2>/dev/null | grep "$datapath" | \
            grep -oP '\(.*?\)' | tr -d '()' | head -1 || true)
    fi

    # Build the ovn-trace command
    local trace_cmd="ovn-trace"
    if [[ -n "$ls_name" ]]; then
        trace_cmd+=" \"$ls_name\""
    else
        trace_cmd+=" <logical-switch>"
        print_warning "Could not determine logical switch name."
    fi
    trace_cmd+=" 'inport==\"$lsp_name\" && eth.src==$src_mac && eth.dst==ff:ff:ff:ff:ff:ff && ip4.src==$src_ip && ip4.dst==$dst_ip && ip.ttl==64'"

    echo -e "${YELLOW}# $trace_cmd${NC}"
    echo ""

    # Execute the trace
    if [[ -n "$ls_name" ]]; then
        local trace_output
        trace_output=$(ovn_trace "$ls_name" \
            "inport==\"$lsp_name\" && eth.src==$src_mac && eth.dst==ff:ff:ff:ff:ff:ff && ip4.src==$src_ip && ip4.dst==$dst_ip && ip.ttl==64" \
            2>&1 || true)
        if [[ -n "$trace_output" ]]; then
            echo "$trace_output"
        else
            print_warning "ovn-trace produced no output. The port/datapath may not be available on this node."
        fi
    else
        print_info "Run the trace command manually on a controller node."
    fi
}

# ---------------------------------------------------------------------------
# OVS flow trace (ML2/OVS)
# ---------------------------------------------------------------------------
run_ovs_trace() {
    local test_name="$1"
    local src_mac="$2"
    local src_ip="$3"
    local dst_ip="$4"

    if [[ "$BACKEND" != "ovs" ]]; then
        return
    fi

    print_subheader "OVS Flow Trace: $test_name"

    if ! run_privileged ovs-vsctl br-exists br-int 2>/dev/null; then
        print_warning "br-int not found on this node."
        return
    fi

    # Find the in_port for the source VM
    local in_port=""
    local port_list
    port_list=$(run_privileged ovs-ofctl dump-ports-desc br-int 2>/dev/null || true)
    if [[ -n "$src_mac" && -n "$port_list" ]]; then
        # Look up the port number for this MAC
        in_port=$(echo "$port_list" | grep -B1 "$src_mac" | head -1 | grep -oP '^\s*\K\d+' || true)
    fi

    local trace_flow="in_port=${in_port:-1},dl_src=${src_mac:-00:00:00:00:00:01},dl_dst=ff:ff:ff:ff:ff:ff,dl_type=0x0800,nw_src=$src_ip,nw_dst=$dst_ip,nw_proto=1"

    echo -e "${YELLOW}# ovs-appctl ofproto/trace br-int \"$trace_flow\"${NC}"
    echo ""

    local trace_output
    trace_output=$(run_privileged ovs-appctl ofproto/trace br-int "$trace_flow" 2>&1 || true)
    if [[ -n "$trace_output" ]]; then
        echo "$trace_output"
    else
        print_warning "ofproto/trace produced no output."
    fi
}

# ---------------------------------------------------------------------------
# Run all traffic flow tests
# ---------------------------------------------------------------------------
run_tests() {
    print_header "TRAFFIC FLOW TESTS (Backend: ${BACKEND^^})"

    # Gather VM information
    local vm1_ip vm2_ip vm3_ip
    local vm1_host vm2_host vm3_host
    local vm1_mac vm2_mac vm3_mac

    vm1_ip=$(get_vm_ip "$VM1_NAME")
    vm2_ip=$(get_vm_ip "$VM2_NAME")
    vm3_ip=$(get_vm_ip "$VM3_NAME")

    vm1_host=$(get_vm_host "$VM1_NAME")
    vm2_host=$(get_vm_host "$VM2_NAME")
    vm3_host=$(get_vm_host "$VM3_NAME")

    vm1_mac=$(get_vm_port_mac "$VM1_NAME")
    vm2_mac=$(get_vm_port_mac "$VM2_NAME")
    vm3_mac=$(get_vm_port_mac "$VM3_NAME")

    print_subheader "Test VM Details"
    echo "  $VM1_NAME: IP=$vm1_ip  MAC=$vm1_mac  Host=$vm1_host  Net=$NET1_NAME"
    echo "  $VM2_NAME: IP=$vm2_ip  MAC=$vm2_mac  Host=$vm2_host  Net=$NET2_NAME"
    echo "  $VM3_NAME: IP=$vm3_ip  MAC=$vm3_mac  Host=$vm3_host  Net=$NET1_NAME"
    echo ""

    # =====================================================================
    # TEST 1: VM to VM on same network (VM1 -> VM3, both on net1)
    # =====================================================================
    print_header "TEST 1: Same Network Communication ($VM1_NAME -> $VM3_NAME)"
    print_info "Both VMs on $NET1_NAME"
    if [[ "$vm1_host" == "$vm3_host" ]]; then
        print_info "Same compute host ($vm1_host) - traffic stays local"
    else
        print_info "Different compute hosts ($vm1_host -> $vm3_host) - traffic crosses tunnel"
    fi

    if [[ -n "$vm3_ip" ]]; then
        run_ping_test "Same-network: $VM1_NAME -> $VM3_NAME" "$VM1_NAME" "$vm3_ip"
        show_ovs_flow_match "$vm1_mac" "$vm3_ip" "Same-network $VM1_NAME -> $VM3_NAME"
        run_ovn_trace "Same-network $VM1_NAME -> $VM3_NAME" "$VM1_NAME" "$vm1_ip" "$vm3_ip"
        run_ovs_trace "Same-network $VM1_NAME -> $VM3_NAME" "$vm1_mac" "$vm1_ip" "$vm3_ip"
        suggest_tcpdump "Same-network" "$VM1_NAME" "$vm3_ip" "$vm1_host" "$vm3_host"
    else
        print_skip "Cannot determine IP for $VM3_NAME"
    fi

    # =====================================================================
    # TEST 2: VM to VM on different networks (VM1 net1 -> VM2 net2)
    # =====================================================================
    print_header "TEST 2: Cross-Network Communication ($VM1_NAME -> $VM2_NAME)"
    print_info "$VM1_NAME on $NET1_NAME -> $VM2_NAME on $NET2_NAME (via $ROUTER_NAME)"

    if [[ -n "$vm2_ip" ]]; then
        run_ping_test "Cross-network: $VM1_NAME -> $VM2_NAME" "$VM1_NAME" "$vm2_ip"
        show_ovs_flow_match "$vm1_mac" "$vm2_ip" "Cross-network $VM1_NAME -> $VM2_NAME"
        run_ovn_trace "Cross-network $VM1_NAME -> $VM2_NAME" "$VM1_NAME" "$vm1_ip" "$vm2_ip"
        run_ovs_trace "Cross-network $VM1_NAME -> $VM2_NAME" "$vm1_mac" "$vm1_ip" "$vm2_ip"
        suggest_tcpdump "Cross-network" "$VM1_NAME" "$vm2_ip" "$vm1_host" "$vm2_host"

        # Additional info about the routing path
        print_subheader "Routing Path Details"
        if [[ "$BACKEND" == "ovn" ]]; then
            print_info "In OVN, routing happens in the logical pipeline (distributed)."
            print_info "Traffic is routed through the logical router's pipeline stages"
            print_info "directly on the source compute (no dedicated network node needed)."
        else
            print_info "In ML2/OVS, traffic goes through the L3 agent namespace."
            local router_id
            router_id=$(openstack router show "$ROUTER_NAME" -f value -c id 2>/dev/null || true)
            if [[ -n "$router_id" ]]; then
                print_info "Router namespace: qrouter-$router_id"
                print_info "Check interfaces: sudo ip netns exec qrouter-$router_id ip a"
            fi
        fi
    else
        print_skip "Cannot determine IP for $VM2_NAME"
    fi

    # =====================================================================
    # TEST 3: VM to External (Floating IP)
    # =====================================================================
    print_header "TEST 3: External Access (Floating IP)"

    local vm1_fip
    vm1_fip=$(openstack server show "$VM1_NAME" -f json -c addresses 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
addrs = str(data.get('addresses', ''))
# Find floating IP (second IP on a network)
parts = addrs.replace(\"'\", '\"')
ips = []
import re
for m in re.finditer(r'(\d+\.\d+\.\d+\.\d+)', addrs):
    ips.append(m.group(1))
if len(ips) > 1:
    print(ips[1])
" 2>/dev/null || true)

    if [[ -n "$vm1_fip" ]]; then
        print_info "Floating IP for $VM1_NAME: $vm1_fip"

        run_ping_test "External: FIP $vm1_fip -> $VM1_NAME" "$VM1_NAME" "$vm1_fip"

        print_subheader "Floating IP Flow Path"
        if [[ "$BACKEND" == "ovn" ]]; then
            print_info "In OVN, DNAT/SNAT for floating IPs is handled in the logical router pipeline."
            print_info "Check NAT rules:"
            echo ""
            ovn_nbctl lr-nat-list "$ROUTER_NAME" 2>/dev/null || \
                print_info "Run: ovn-nbctl lr-nat-list <router-name>"
            echo ""
            print_info "The gateway chassis processes external traffic."
            print_info "Check gateway chassis for the router ports:"
            local lr_ports
            lr_ports=$(ovn_nbctl lrp-list "$ROUTER_NAME" 2>/dev/null || true)
            if [[ -n "$lr_ports" ]]; then
                echo "$lr_ports"
            fi
        else
            print_info "In ML2/OVS, floating IP NAT is handled in the router namespace (iptables)."
            local router_id
            router_id=$(openstack router show "$ROUTER_NAME" -f value -c id 2>/dev/null || true)
            if [[ -n "$router_id" ]]; then
                print_info "Check NAT rules:"
                echo "  sudo ip netns exec qrouter-$router_id iptables -t nat -L -n -v"
                echo ""
                print_info "Check external interface:"
                echo "  sudo ip netns exec qrouter-$router_id ip a show qg-*"
            fi
        fi

        suggest_tcpdump "Floating IP" "$VM1_NAME" "$vm1_fip" "$vm1_host" ""

        # Additional: capture on external bridge
        echo -e "  ${CYAN}# On gateway/networker node - external bridge:${NC}"
        echo "  sudo tcpdump -i br-ex -nn host $vm1_fip"
        echo ""
    else
        print_skip "No floating IP assigned to $VM1_NAME"
        print_info "Assign one with: openstack floating ip create <ext-net> && openstack server add floating ip $VM1_NAME <fip>"
    fi

    # =====================================================================
    # TEST 4: Reverse path - VM2 -> VM1 (cross-network, opposite direction)
    # =====================================================================
    print_header "TEST 4: Reverse Cross-Network ($VM2_NAME -> $VM1_NAME)"
    print_info "$VM2_NAME on $NET2_NAME -> $VM1_NAME on $NET1_NAME (via $ROUTER_NAME)"

    if [[ -n "$vm1_ip" ]]; then
        run_ping_test "Reverse cross-network: $VM2_NAME -> $VM1_NAME" "$VM2_NAME" "$vm1_ip"
        show_ovs_flow_match "$vm2_mac" "$vm1_ip" "Reverse cross-network $VM2_NAME -> $VM1_NAME"
        run_ovn_trace "Reverse cross-network $VM2_NAME -> $VM1_NAME" "$VM2_NAME" "$vm2_ip" "$vm1_ip"
        run_ovs_trace "Reverse cross-network $VM2_NAME -> $VM1_NAME" "$vm2_mac" "$vm2_ip" "$vm1_ip"
    else
        print_skip "Cannot determine IP for $VM1_NAME"
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
    REPORT_FILE="${REPORT_DIR}/traffic-flow-tests-${TIMESTAMP}.txt"

    if [[ ! -d "$REPORT_DIR" ]]; then
        mkdir -p "$REPORT_DIR"
    fi

    exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' > "$REPORT_FILE"))
    exec 2>&1
}

# ---------------------------------------------------------------------------
# Print test summary
# ---------------------------------------------------------------------------
print_test_summary() {
    print_header "TEST RESULTS SUMMARY"

    local total=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))

    echo -e "  ${GREEN}PASSED:  $TESTS_PASSED${NC}"
    echo -e "  ${RED}FAILED:  $TESTS_FAILED${NC}"
    echo -e "  ${YELLOW}SKIPPED: $TESTS_SKIPPED${NC}"
    echo -e "  ${BOLD}TOTAL:   $total${NC}"
    echo ""

    if [[ $TESTS_FAILED -gt 0 ]]; then
        print_warning "Some tests failed. Review the output above for details."
    elif [[ $TESTS_PASSED -gt 0 ]]; then
        print_success "All executed tests passed."
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    echo -e "${BLUE}${BOLD}"
    echo "  _____            __  __ _        _____ _"
    echo " |_   _| __ __ _ / _|/ _(_) ___  |  ___| | _____      __"
    echo "   | || '__/ _\` | |_| |_| |/ __| | |_  | |/ _ \\ \\ /\\ / /"
    echo "   | || | | (_| |  _|  _| | (__  |  _| | | (_) \\ V  V /"
    echo "   |_||_|  \\__,_|_| |_| |_|\\___| |_|   |_|\\___/ \\_/\\_/"
    echo ""
    echo "  Traffic Flow Tests for Red Hat OpenStack Platform"
    echo -e "${NC}"

    setup_report
    source_credentials

    # Detect backend
    detect_backend
    detect_ovn_containers

    case "$ACTION" in
        create)
            create_resources
            ;;
        existing)
            discover_resources
            run_tests
            print_test_summary
            ;;
        cleanup)
            cleanup_resources
            ;;
    esac

    # Final info
    print_header "DONE"
    print_info "Hostname: $(hostname -f 2>/dev/null || hostname)"
    print_info "Date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    print_info "Backend: ${BACKEND^^}"

    if [[ "$REPORT_ENABLED" == true && -n "$REPORT_FILE" ]]; then
        print_success "Report saved to: ${REPORT_FILE}"
    fi
}

main "$@"
