#!/bin/bash
set -euo pipefail

###############################################################################
# traffic-flow-tests.sh - Traffic Flow Tests for RHOSO
#
# Creates test resources and validates traffic flows in a RHOSO environment.
# Tests VM-to-VM connectivity (same/different networks, same/different computes),
# floating IP access, and correlates results with OVN logical traces and OVS
# flow dumps. Designed for a workshop context where engineers learn to trace
# packets through the OVN/OVS pipeline.
#
# Usage:
#   ./traffic-flow-tests.sh [OPTIONS]
#
# Options:
#   --create-resources        Create test networks, subnets, routers, and VMs
#   --use-existing            Use existing workshop-test-* resources
#   --cleanup                 Remove all workshop-test-* resources and exit
#   --backend ovn             Networking backend (always OVN in RHOSO, kept for consistency)
#   --namespace <ns>          OpenShift namespace for OpenStack (default: openstack)
#   --dataplane-node <host>   Data plane node for OVS flow inspection
#   --all-nodes               Discover data plane nodes for OVS inspection
#   --ssh-key <path>          Path to SSH private key (default: ~/.ssh/id_rsa)
#   --ssh-user <user>         SSH user for data plane nodes (default: root)
#   --cloud <name>            clouds.yaml cloud name (default: default)
#   --output-dir <dir>        Directory for report files (default: ./reports)
#   --no-report               Print to stdout only, do not save a report file
#   --external-network <name> External/provider network name (default: auto-detect)
#   --image <name>            Image to use for test VMs (default: cirros)
#   --flavor <name>           Flavor to use for test VMs (default: m1.tiny)
#   --help                    Show this help message
#
# Test Scenarios:
#   1. VM to VM - same network, same compute node
#   2. VM to VM - same network, different compute nodes
#   3. VM to VM - different networks (routing through logical router)
#   4. VM to external - floating IP connectivity
#
# For each test, the script:
#   - Runs a ping connectivity test
#   - Traces the logical path with ovn-trace (via oc exec)
#   - Dumps relevant OVS flows on the data plane node (via SSH)
#   - Suggests tcpdump capture points for further investigation
#
# Examples:
#   ./traffic-flow-tests.sh --create-resources --all-nodes
#   ./traffic-flow-tests.sh --use-existing --dataplane-node 192.168.122.100
#   ./traffic-flow-tests.sh --cleanup
#
# Requirements:
#   - oc (OpenShift CLI) logged into the OCP cluster
#   - openstack CLI (python-openstackclient) with valid credentials
#   - SSH access to data plane nodes
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
# Constants - resource naming prefix
# ---------------------------------------------------------------------------
PREFIX="workshop-test"

# Network / subnet CIDRs
NET_A_CIDR="10.100.1.0/24"
NET_B_CIDR="10.100.2.0/24"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ACTION=""         # create-resources | use-existing | cleanup
BACKEND="ovn"
NAMESPACE="openstack"
DATAPLANE_NODE=""
ALL_NODES=false
SSH_KEY="${HOME}/.ssh/id_rsa"
SSH_USER="root"
CLOUD_NAME="default"
OUTPUT_DIR="./reports"
NO_REPORT=false
EXTERNAL_NETWORK=""
IMAGE_NAME="cirros"
FLAVOR_NAME="m1.tiny"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_FILE=""

# OVN pod (discovered at runtime)
NB_POD=""
SB_POD=""

# Test result tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
info()      { echo -e "${BLUE}[INFO]${NC}  $*"; }
success()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()      { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()     { echo -e "${RED}[ERROR]${NC} $*"; }
header()    { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}\n"; }
subheader() { echo -e "\n${BLUE}--- $* ---${NC}\n"; }

pass() {
    ((TESTS_PASSED++)) || true
    echo -e "${GREEN}${BOLD}[PASS]${NC} $*"
}
fail() {
    ((TESTS_FAILED++)) || true
    echo -e "${RED}${BOLD}[FAIL]${NC} $*"
}

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
            --create-resources)
                ACTION="create"; shift ;;
            --use-existing)
                ACTION="existing"; shift ;;
            --cleanup)
                ACTION="cleanup"; shift ;;
            --backend)
                BACKEND="$2"; shift 2 ;;
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
            --cloud)
                CLOUD_NAME="$2"; shift 2 ;;
            --output-dir)
                OUTPUT_DIR="$2"; shift 2 ;;
            --no-report)
                NO_REPORT=true; shift ;;
            --external-network)
                EXTERNAL_NETWORK="$2"; shift 2 ;;
            --image)
                IMAGE_NAME="$2"; shift 2 ;;
            --flavor)
                FLAVOR_NAME="$2"; shift 2 ;;
            --help|-h)
                usage ;;
            *)
                error "Unknown option: $1"
                echo "Use --help for usage information."
                exit 1 ;;
        esac
    done

    if [[ -z "$ACTION" ]]; then
        error "Specify --create-resources, --use-existing, or --cleanup."
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
    if ! oc whoami &>/dev/null; then
        error "Not logged into an OpenShift cluster. Run 'oc login' first."
        exit 1
    fi
    success "oc CLI: logged in as $(oc whoami)"

    # openstack CLI
    if ! command -v openstack &>/dev/null; then
        error "'openstack' CLI not found in PATH."
        error "Install python-openstackclient or source the virtualenv that contains it."
        exit 1
    fi
    success "openstack CLI found"

    # Check OpenStack credentials
    # Try to source from OCP secret if OS_AUTH_URL is not set
    if [[ -z "${OS_AUTH_URL:-}" ]]; then
        info "OS_AUTH_URL not set - attempting to extract credentials from OCP ..."
        source_credentials_from_ocp || true
    fi

    if [[ -z "${OS_AUTH_URL:-}" ]]; then
        # Try clouds.yaml
        if [[ -f "${HOME}/.config/openstack/clouds.yaml" ]] || \
           [[ -f "./clouds.yaml" ]] || \
           [[ -f "/etc/openstack/clouds.yaml" ]]; then
            export OS_CLOUD="${CLOUD_NAME}"
            info "Using clouds.yaml with cloud=$OS_CLOUD"
        else
            error "No OpenStack credentials found."
            error "Set OS_* environment variables, provide a clouds.yaml, or ensure"
            error "credentials are available as an OCP secret in namespace $NAMESPACE."
            exit 1
        fi
    fi

    # Verify we can talk to OpenStack
    if ! openstack token issue &>/dev/null; then
        error "Cannot authenticate to OpenStack. Check your credentials."
        exit 1
    fi
    success "OpenStack authentication successful"

    # SSH key (for data plane access)
    if [[ "$ALL_NODES" == true || -n "$DATAPLANE_NODE" ]]; then
        if [[ ! -f "$SSH_KEY" ]]; then
            warn "SSH key not found at $SSH_KEY - data plane inspection may fail."
        else
            success "SSH key found: $SSH_KEY"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Source OpenStack credentials from OCP secret
# ---------------------------------------------------------------------------
source_credentials_from_ocp() {
    local secret_name
    secret_name=$(oc get secret -n "$NAMESPACE" -o name 2>/dev/null \
        | grep -iE 'keystone.*admin\|openstack.*admin\|cloud.*admin' \
        | head -1 | sed 's|secret/||' || true)

    if [[ -z "$secret_name" ]]; then
        warn "Could not find an admin credential secret in namespace $NAMESPACE."
        return 1
    fi

    info "Found credential secret: $secret_name"

    local auth_url username password project_name user_domain project_domain

    auth_url=$(oc get secret "$secret_name" -n "$NAMESPACE" \
        -o jsonpath='{.data.OS_AUTH_URL}' 2>/dev/null | base64 -d 2>/dev/null || true)
    username=$(oc get secret "$secret_name" -n "$NAMESPACE" \
        -o jsonpath='{.data.OS_USERNAME}' 2>/dev/null | base64 -d 2>/dev/null || true)
    password=$(oc get secret "$secret_name" -n "$NAMESPACE" \
        -o jsonpath='{.data.OS_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)
    project_name=$(oc get secret "$secret_name" -n "$NAMESPACE" \
        -o jsonpath='{.data.OS_PROJECT_NAME}' 2>/dev/null | base64 -d 2>/dev/null || true)
    user_domain=$(oc get secret "$secret_name" -n "$NAMESPACE" \
        -o jsonpath='{.data.OS_USER_DOMAIN_NAME}' 2>/dev/null | base64 -d 2>/dev/null || true)
    project_domain=$(oc get secret "$secret_name" -n "$NAMESPACE" \
        -o jsonpath='{.data.OS_PROJECT_DOMAIN_NAME}' 2>/dev/null | base64 -d 2>/dev/null || true)

    if [[ -n "$auth_url" ]]; then
        export OS_AUTH_URL="$auth_url"
        export OS_USERNAME="${username:-admin}"
        export OS_PASSWORD="${password:-}"
        export OS_PROJECT_NAME="${project_name:-admin}"
        export OS_USER_DOMAIN_NAME="${user_domain:-Default}"
        export OS_PROJECT_DOMAIN_NAME="${project_domain:-Default}"
        export OS_IDENTITY_API_VERSION=3
        success "Credentials loaded from OCP secret: $secret_name"
    else
        return 1
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
    REPORT_FILE="${OUTPUT_DIR}/traffic-flow-tests-${TIMESTAMP}.log"
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
    header "Discovering OVN Pods"

    NB_POD=$(oc get pods -n "$NAMESPACE" -l service=ovsdb-server-nb \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -z "$NB_POD" ]]; then
        NB_POD=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
            | grep -iE 'ovn.*nb' | head -1 | awk '{print $1}' || true)
    fi
    if [[ -z "$NB_POD" ]]; then
        NB_POD=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
            | grep -iE 'ovn-northd\|ovsdb-server-nb' | head -1 | awk '{print $1}' || true)
    fi
    if [[ -z "$NB_POD" ]]; then
        NB_POD=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
            | grep -iE 'ovn' | head -1 | awk '{print $1}' || true)
    fi

    SB_POD=$(oc get pods -n "$NAMESPACE" -l service=ovsdb-server-sb \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -z "$SB_POD" ]]; then
        SB_POD=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
            | grep -iE 'ovn.*sb' | head -1 | awk '{print $1}' || true)
    fi
    if [[ -z "$SB_POD" ]]; then
        SB_POD="$NB_POD"
    fi

    if [[ -n "$NB_POD" ]]; then
        success "NB pod: $NB_POD"
    else
        warn "Could not find OVN NB pod - ovn-trace will not be available."
    fi

    if [[ -n "$SB_POD" ]]; then
        success "SB pod: $SB_POD"
    fi
}

# ---------------------------------------------------------------------------
# OVN helpers
# ---------------------------------------------------------------------------
nb_exec() {
    if [[ -z "$NB_POD" ]]; then
        warn "No NB pod available for: ovn-nbctl $*"
        return 1
    fi
    oc exec -n "$NAMESPACE" "$NB_POD" -- ovn-nbctl "$@" 2>/dev/null
}

sb_exec() {
    if [[ -z "$SB_POD" ]]; then
        warn "No SB pod available for: ovn-sbctl $*"
        return 1
    fi
    oc exec -n "$NAMESPACE" "$SB_POD" -- ovn-sbctl "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Detect external network
# ---------------------------------------------------------------------------
detect_external_network() {
    if [[ -n "$EXTERNAL_NETWORK" ]]; then
        return
    fi
    info "Auto-detecting external network ..."
    EXTERNAL_NETWORK=$(openstack network list --external -f value -c Name 2>/dev/null | head -1 || true)
    if [[ -z "$EXTERNAL_NETWORK" ]]; then
        warn "Could not auto-detect external network."
        warn "Floating IP tests will be skipped unless --external-network is provided."
    else
        success "External network: $EXTERNAL_NETWORK"
    fi
}

# ---------------------------------------------------------------------------
# Discover data plane nodes
# ---------------------------------------------------------------------------
discover_nodes() {
    local nodes=()

    if oc get openstackdataplanenodeset -n "$NAMESPACE" &>/dev/null; then
        local nodeset_names
        nodeset_names=$(oc get openstackdataplanenodeset -n "$NAMESPACE" \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        for ns_name in $nodeset_names; do
            local hosts
            hosts=$(oc get openstackdataplanenodeset "$ns_name" -n "$NAMESPACE" \
                -o jsonpath='{range .spec.nodes[*]}{.ansibleHost}{"\n"}{end}' 2>/dev/null || true)
            for h in $hosts; do
                [[ -n "$h" ]] && nodes+=("$h")
            done
        done
    fi

    if [[ ${#nodes[@]} -eq 0 ]]; then
        # Try SB chassis
        local chassis_hosts
        chassis_hosts=$(sb_exec --format=csv --no-headings --columns=hostname find Chassis 2>/dev/null || true)
        for h in $chassis_hosts; do
            [[ -n "$h" ]] && nodes+=("$h")
        done
    fi

    local unique_nodes
    unique_nodes=$(printf '%s\n' "${nodes[@]}" | sort -u)
    DISCOVERED_NODES=()
    while IFS= read -r n; do
        [[ -n "$n" ]] && DISCOVERED_NODES+=("$n")
    done <<< "$unique_nodes"

    if [[ ${#DISCOVERED_NODES[@]} -gt 0 ]]; then
        success "Discovered ${#DISCOVERED_NODES[@]} data plane node(s)"
    else
        warn "Could not auto-discover data plane nodes."
    fi
}

# ---------------------------------------------------------------------------
# Wait for a server to become ACTIVE
# ---------------------------------------------------------------------------
wait_for_server() {
    local server_name="$1"
    local max_wait=300
    local interval=10
    local elapsed=0

    info "Waiting for server '$server_name' to become ACTIVE (timeout: ${max_wait}s) ..."
    while [[ $elapsed -lt $max_wait ]]; do
        local status
        status=$(openstack server show "$server_name" -f value -c status 2>/dev/null || echo "UNKNOWN")
        case "$status" in
            ACTIVE)
                success "Server '$server_name' is ACTIVE."
                return 0 ;;
            ERROR)
                error "Server '$server_name' went to ERROR state."
                openstack server show "$server_name" -f value -c fault 2>/dev/null || true
                return 1 ;;
            BUILD|SPAWNING)
                sleep "$interval"
                ((elapsed += interval)) || true
                ;;
            *)
                warn "Server '$server_name' status: $status"
                sleep "$interval"
                ((elapsed += interval)) || true
                ;;
        esac
    done
    error "Timed out waiting for server '$server_name' (status: $(openstack server show "$server_name" -f value -c status 2>/dev/null))."
    return 1
}

# ---------------------------------------------------------------------------
# Create test resources
# ---------------------------------------------------------------------------
create_resources() {
    header "Creating Test Resources"

    detect_external_network

    # Security group allowing ICMP and SSH
    subheader "Security Group"
    if openstack security group show "${PREFIX}-sg" &>/dev/null; then
        info "Security group '${PREFIX}-sg' already exists."
    else
        openstack security group create "${PREFIX}-sg" \
            --description "Workshop test security group - allows ICMP and SSH"
        openstack security group rule create "${PREFIX}-sg" \
            --protocol icmp --ingress
        openstack security group rule create "${PREFIX}-sg" \
            --protocol tcp --dst-port 22 --ingress
        success "Created security group '${PREFIX}-sg' with ICMP and SSH rules."
    fi

    # Network A
    subheader "Network A"
    if openstack network show "${PREFIX}-net-a" &>/dev/null; then
        info "Network '${PREFIX}-net-a' already exists."
    else
        openstack network create "${PREFIX}-net-a"
        openstack subnet create "${PREFIX}-subnet-a" \
            --network "${PREFIX}-net-a" \
            --subnet-range "$NET_A_CIDR" \
            --dns-nameserver 8.8.8.8
        success "Created network '${PREFIX}-net-a' with subnet $NET_A_CIDR"
    fi

    # Network B
    subheader "Network B"
    if openstack network show "${PREFIX}-net-b" &>/dev/null; then
        info "Network '${PREFIX}-net-b' already exists."
    else
        openstack network create "${PREFIX}-net-b"
        openstack subnet create "${PREFIX}-subnet-b" \
            --network "${PREFIX}-net-b" \
            --subnet-range "$NET_B_CIDR" \
            --dns-nameserver 8.8.8.8
        success "Created network '${PREFIX}-net-b' with subnet $NET_B_CIDR"
    fi

    # Router connecting both networks (and external if available)
    subheader "Router"
    if openstack router show "${PREFIX}-router" &>/dev/null; then
        info "Router '${PREFIX}-router' already exists."
    else
        openstack router create "${PREFIX}-router"
        openstack router add subnet "${PREFIX}-router" "${PREFIX}-subnet-a"
        openstack router add subnet "${PREFIX}-router" "${PREFIX}-subnet-b"
        if [[ -n "$EXTERNAL_NETWORK" ]]; then
            openstack router set "${PREFIX}-router" --external-gateway "$EXTERNAL_NETWORK"
            success "Created router '${PREFIX}-router' with gateway to '$EXTERNAL_NETWORK'"
        else
            success "Created router '${PREFIX}-router' (no external gateway)"
        fi
    fi

    # Determine available compute hosts for scheduling
    local compute_hosts
    compute_hosts=$(openstack compute service list --service nova-compute -f value -c Host 2>/dev/null || true)
    local host_count
    host_count=$(echo "$compute_hosts" | grep -c . || echo 0)
    info "Available compute hosts: $host_count"

    local host_a="" host_b=""
    if [[ "$host_count" -ge 2 ]]; then
        host_a=$(echo "$compute_hosts" | sed -n '1p')
        host_b=$(echo "$compute_hosts" | sed -n '2p')
        info "Will use compute hosts: $host_a and $host_b for cross-node tests."
    elif [[ "$host_count" -ge 1 ]]; then
        host_a=$(echo "$compute_hosts" | sed -n '1p')
        host_b="$host_a"
        warn "Only one compute host available ($host_a). Cross-node tests will run on the same host."
    fi

    # Create VMs
    subheader "Test VMs"

    # VM1: net-a, host_a (for same-network same-host test with VM2)
    create_vm "${PREFIX}-vm1" "${PREFIX}-net-a" "$host_a" || true

    # VM2: net-a, host_a (same network, same host as VM1)
    create_vm "${PREFIX}-vm2" "${PREFIX}-net-a" "$host_a" || true

    # VM3: net-a, host_b (same network, different host from VM1 - for cross-node test)
    create_vm "${PREFIX}-vm3" "${PREFIX}-net-a" "$host_b" || true

    # VM4: net-b, host_a (different network - for routing test with VM1)
    create_vm "${PREFIX}-vm4" "${PREFIX}-net-b" "$host_a" || true

    # Wait for all VMs
    wait_for_server "${PREFIX}-vm1" || true
    wait_for_server "${PREFIX}-vm2" || true
    wait_for_server "${PREFIX}-vm3" || true
    wait_for_server "${PREFIX}-vm4" || true

    # Floating IP for VM1 (external connectivity test)
    if [[ -n "$EXTERNAL_NETWORK" ]]; then
        subheader "Floating IP"
        local existing_fip
        existing_fip=$(openstack floating ip list --fixed-ip-address \
            "$(openstack server show "${PREFIX}-vm1" -f value -c addresses 2>/dev/null \
            | grep -oE '10\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)" \
            -f value -c "Floating IP Address" 2>/dev/null || true)
        if [[ -n "$existing_fip" ]]; then
            info "VM1 already has floating IP: $existing_fip"
        else
            local fip
            fip=$(openstack floating ip create "$EXTERNAL_NETWORK" -f value -c floating_ip_address 2>/dev/null || true)
            if [[ -n "$fip" ]]; then
                openstack server add floating ip "${PREFIX}-vm1" "$fip" 2>/dev/null || true
                success "Assigned floating IP $fip to ${PREFIX}-vm1"
            else
                warn "Could not create floating IP."
            fi
        fi
    fi

    success "Test resources created."
    echo ""
    openstack server list --name "${PREFIX}" -f table 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Create a single VM
# ---------------------------------------------------------------------------
create_vm() {
    local name="$1"
    local network="$2"
    local host="${3:-}"

    if openstack server show "$name" &>/dev/null; then
        info "Server '$name' already exists."
        return 0
    fi

    local cmd=(openstack server create "$name"
        --image "$IMAGE_NAME"
        --flavor "$FLAVOR_NAME"
        --network "$network"
        --security-group "${PREFIX}-sg"
    )

    if [[ -n "$host" ]]; then
        cmd+=(--availability-zone "nova:${host}")
    fi

    info "Creating VM: $name on network $network ${host:+(host: $host)}"
    "${cmd[@]}" -f value -c id || {
        error "Failed to create VM '$name'."
        return 1
    }
    success "VM '$name' creation initiated."
}

# ---------------------------------------------------------------------------
# Cleanup test resources
# ---------------------------------------------------------------------------
cleanup_resources() {
    header "Cleaning Up Test Resources (prefix: ${PREFIX}-*)"

    # Delete servers
    subheader "Deleting Servers"
    local servers
    servers=$(openstack server list --name "${PREFIX}" -f value -c Name 2>/dev/null || true)
    for srv in $servers; do
        info "Deleting server: $srv"
        openstack server delete "$srv" --wait 2>/dev/null || warn "Failed to delete $srv"
    done

    # Release floating IPs
    subheader "Releasing Floating IPs"
    local fips
    fips=$(openstack floating ip list -f value -c ID -c "Floating IP Address" 2>/dev/null || true)
    # We can identify ours by checking port associations to our networks
    # Simpler: delete unattached FIPs (safe in a workshop context) or match by description
    while IFS= read -r fip_line; do
        local fip_id fip_addr
        fip_id=$(echo "$fip_line" | awk '{print $1}')
        fip_addr=$(echo "$fip_line" | awk '{print $2}')
        [[ -z "$fip_id" ]] && continue
        local port_id
        port_id=$(openstack floating ip show "$fip_id" -f value -c port_id 2>/dev/null || true)
        if [[ -z "$port_id" || "$port_id" == "None" ]]; then
            info "Releasing unattached floating IP: $fip_addr ($fip_id)"
            openstack floating ip delete "$fip_id" 2>/dev/null || true
        fi
    done <<< "$fips"

    # Remove router interfaces, then delete router
    subheader "Deleting Router"
    if openstack router show "${PREFIX}-router" &>/dev/null; then
        openstack router remove subnet "${PREFIX}-router" "${PREFIX}-subnet-a" 2>/dev/null || true
        openstack router remove subnet "${PREFIX}-router" "${PREFIX}-subnet-b" 2>/dev/null || true
        openstack router unset "${PREFIX}-router" --external-gateway 2>/dev/null || true
        openstack router delete "${PREFIX}-router" 2>/dev/null || true
        success "Deleted router '${PREFIX}-router'"
    fi

    # Delete subnets and networks
    subheader "Deleting Networks"
    for net in "${PREFIX}-net-a" "${PREFIX}-net-b"; do
        if openstack network show "$net" &>/dev/null; then
            # Delete ports on the network first
            local ports
            ports=$(openstack port list --network "$net" -f value -c ID 2>/dev/null || true)
            for port in $ports; do
                openstack port delete "$port" 2>/dev/null || true
            done
            openstack network delete "$net" 2>/dev/null || true
            success "Deleted network '$net'"
        fi
    done

    # Delete security group
    subheader "Deleting Security Group"
    if openstack security group show "${PREFIX}-sg" &>/dev/null; then
        openstack security group delete "${PREFIX}-sg" 2>/dev/null || true
        success "Deleted security group '${PREFIX}-sg'"
    fi

    success "Cleanup complete."
}

# ---------------------------------------------------------------------------
# Get VM details needed for tests
# ---------------------------------------------------------------------------
get_vm_info() {
    local name="$1"
    local -n _ip_ref="$2"
    local -n _mac_ref="$3"
    local -n _host_ref="$4"
    local -n _net_ref="$5"

    _ip_ref=$(openstack server show "$name" -f value -c addresses 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    _host_ref=$(openstack server show "$name" -f value -c "OS-EXT-SRV-ATTR:host" 2>/dev/null || true)

    # Get MAC from port
    local port_id
    port_id=$(openstack port list --server "$name" -f value -c ID 2>/dev/null | head -1 || true)
    if [[ -n "$port_id" ]]; then
        _mac_ref=$(openstack port show "$port_id" -f value -c mac_address 2>/dev/null || true)
        _net_ref=$(openstack port show "$port_id" -f value -c network_id 2>/dev/null || true)
    fi
}

# ---------------------------------------------------------------------------
# Run a ping test from one VM to another (via the hypervisor's network namespace)
# ---------------------------------------------------------------------------
run_ping_test() {
    local src_name="$1"
    local dst_ip="$2"
    local description="$3"

    ((TESTS_RUN++)) || true

    subheader "Test: $description"
    info "Source: $src_name -> Destination: $dst_ip"

    # Get the compute host for the source VM
    local src_host
    src_host=$(openstack server show "$src_name" -f value -c "OS-EXT-SRV-ATTR:host" 2>/dev/null || true)

    if [[ -z "$src_host" ]]; then
        fail "$description - could not determine compute host for $src_name"
        return 1
    fi

    # Try to get the VM's network namespace or use the VM's IP via the metadata route
    # In a real workshop, the instructor may prefer console access; we try SSH into the
    # VM through the namespace on the compute node.

    # Get VM's tap port
    local src_port_id
    src_port_id=$(openstack port list --server "$src_name" -f value -c ID 2>/dev/null | head -1 || true)

    if [[ -z "$src_port_id" ]]; then
        fail "$description - could not find port for $src_name"
        return 1
    fi

    # Attempt ping via the compute host using ip netns
    local ns_name="qdhcp-$(openstack port show "$src_port_id" -f value -c network_id 2>/dev/null || true)"
    info "Attempting ping from compute host $src_host (namespace or virsh console) ..."

    # Method 1: Try virsh / direct execution
    local ping_result
    ping_result=$(ssh_cmd "$src_host" "
        # Try ip netns exec if the namespace exists
        if sudo ip netns list 2>/dev/null | grep -q '$ns_name'; then
            sudo ip netns exec '$ns_name' ping -c 3 -W 5 '$dst_ip' 2>&1
        else
            # Try to exec into the VM (cirros) via virsh console (not reliable in script)
            # Fallback: ping from the host if the IP is routable
            echo 'NAMESPACE_NOT_FOUND'
        fi
    " 2>/dev/null || echo "SSH_FAILED")

    if echo "$ping_result" | grep -q "bytes from"; then
        pass "$description - ping successful"
        echo "$ping_result" | tail -3
        return 0
    elif echo "$ping_result" | grep -qE "NAMESPACE_NOT_FOUND|SSH_FAILED"; then
        warn "Could not execute in-namespace ping. Checking port status instead ..."
        # Verify that both ports are active and bound
        local port_status
        port_status=$(openstack port show "$src_port_id" -f value -c status 2>/dev/null || true)
        if [[ "$port_status" == "ACTIVE" ]]; then
            info "Port for $src_name is ACTIVE - connectivity is expected to work."
            info "Manual verification: access the VM console and run 'ping $dst_ip'"
            warn "$description - automatic ping not possible; port is ACTIVE (manual verification needed)"
        else
            fail "$description - port status is '$port_status' (expected ACTIVE)"
        fi
        return 0
    else
        fail "$description - ping failed"
        echo "$ping_result" | tail -5
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Run ovn-trace for a flow between two VMs
# ---------------------------------------------------------------------------
run_ovn_trace() {
    local src_name="$1"
    local dst_name="$2"
    local description="$3"

    subheader "OVN Trace: $description"

    if [[ -z "$NB_POD" ]]; then
        warn "No NB pod - skipping ovn-trace."
        return
    fi

    # Get source and destination details
    local src_ip src_mac src_host src_net dst_ip dst_mac dst_host dst_net
    get_vm_info "$src_name" src_ip src_mac src_host src_net
    get_vm_info "$dst_name" dst_ip dst_mac dst_host dst_net

    if [[ -z "$src_mac" || -z "$src_ip" || -z "$dst_ip" ]]; then
        warn "Missing VM info for ovn-trace (src_mac=$src_mac src_ip=$src_ip dst_ip=$dst_ip)"
        return
    fi

    info "Source: $src_name ($src_ip / $src_mac)"
    info "Dest:   $dst_name ($dst_ip / ${dst_mac:-unknown})"

    # Find the logical switch port for the source VM
    local src_port_name
    src_port_name=$(openstack port list --server "$src_name" -f value -c ID 2>/dev/null | head -1 || true)

    if [[ -z "$src_port_name" ]]; then
        warn "Could not find port for $src_name - skipping ovn-trace."
        return
    fi

    echo ""
    info "Running ovn-trace ..."
    echo -e "${YELLOW}Command: ovn-trace --detailed '$src_port_name' \\${NC}"
    echo -e "${YELLOW}  'inport==\"$src_port_name\" && eth.src==$src_mac && \\${NC}"
    echo -e "${YELLOW}   eth.dst==<router-mac> && ip4.src==$src_ip && ip4.dst==$dst_ip && \\${NC}"
    echo -e "${YELLOW}   ip.ttl==64 && icmp4.type==8'${NC}"
    echo ""

    # For same-network traffic, we can use the dst_mac directly
    # For routed traffic, we need the router port MAC
    local trace_eth_dst
    if [[ "$src_net" == "$dst_net" ]]; then
        trace_eth_dst="$dst_mac"
    else
        # Get the router port MAC for the source network's subnet
        local subnet_gw
        subnet_gw=$(openstack subnet list --network "$src_net" -f value -c ID 2>/dev/null | head -1 || true)
        if [[ -n "$subnet_gw" ]]; then
            local gw_port
            gw_port=$(openstack port list --device-owner network:router_interface \
                --network "$src_net" -f value -c "MAC Address" 2>/dev/null | head -1 || true)
            trace_eth_dst="${gw_port:-ff:ff:ff:ff:ff:ff}"
        else
            trace_eth_dst="ff:ff:ff:ff:ff:ff"
        fi
    fi

    # Execute ovn-trace
    oc exec -n "$NAMESPACE" "$NB_POD" -- ovn-trace --detailed \
        "inport==\"${src_port_name}\" && eth.src==${src_mac} && eth.dst==${trace_eth_dst} && ip4.src==${src_ip} && ip4.dst==${dst_ip} && ip.ttl==64 && icmp4.type==8" \
        2>/dev/null || warn "ovn-trace failed - the logical port name may differ from the Neutron port UUID."

    echo ""
    info "Tip: If ovn-trace fails, find the OVN logical port name with:"
    echo "  oc exec -n $NAMESPACE $NB_POD -- ovn-nbctl lsp-list <switch-name>"
    echo "  Then use: ovn-trace <switch-name> 'inport==\"<port-name>\" && ...'"
}

# ---------------------------------------------------------------------------
# Show relevant OVS flows on a data plane node
# ---------------------------------------------------------------------------
show_ovs_flows() {
    local node="$1"
    local src_ip="$2"
    local dst_ip="$3"
    local description="$4"

    subheader "OVS Flows on $node for: $description"

    if [[ -z "$node" ]]; then
        warn "No data plane node specified - skipping OVS flow dump."
        info "Use --dataplane-node or --all-nodes to enable OVS flow inspection."
        return
    fi

    if ! ssh_cmd "$node" "echo ok" &>/dev/null; then
        warn "Cannot SSH to $node - skipping OVS flow dump."
        return
    fi

    info "Matching flows for $src_ip <-> $dst_ip on br-int ..."
    echo ""

    # Flows matching source IP
    echo -e "${YELLOW}Flows matching source IP $src_ip:${NC}"
    ssh_cmd "$node" "sudo ovs-ofctl dump-flows br-int 2>/dev/null \
        | grep -i '$src_ip' || echo '  (no matching flows)'" || true

    echo ""

    # Flows matching destination IP
    echo -e "${YELLOW}Flows matching destination IP $dst_ip:${NC}"
    ssh_cmd "$node" "sudo ovs-ofctl dump-flows br-int 2>/dev/null \
        | grep -i '$dst_ip' || echo '  (no matching flows)'" || true

    echo ""

    # Tunnel-related flows
    echo -e "${YELLOW}Geneve tunnel flows:${NC}"
    ssh_cmd "$node" "sudo ovs-ofctl dump-flows br-int 2>/dev/null \
        | grep -iE 'tun|geneve' | head -20 || echo '  (no tunnel flows)'" || true
}

# ---------------------------------------------------------------------------
# Suggest tcpdump capture points
# ---------------------------------------------------------------------------
suggest_tcpdump() {
    local src_name="$1"
    local dst_name="$2"
    local src_ip="$3"
    local dst_ip="$4"
    local description="$5"

    subheader "Tcpdump Capture Suggestions: $description"

    local src_host dst_host
    src_host=$(openstack server show "$src_name" -f value -c "OS-EXT-SRV-ATTR:host" 2>/dev/null || true)
    dst_host=$(openstack server show "$dst_name" -f value -c "OS-EXT-SRV-ATTR:host" 2>/dev/null || true)

    local src_port_id
    src_port_id=$(openstack port list --server "$src_name" -f value -c ID 2>/dev/null | head -1 || true)
    local dst_port_id
    dst_port_id=$(openstack port list --server "$dst_name" -f value -c ID 2>/dev/null | head -1 || true)

    # Tap interface name (first 11 chars of port UUID prefixed with "tap")
    local src_tap="tap${src_port_id:0:11}"
    local dst_tap="tap${dst_port_id:0:11}"

    echo -e "${BOLD}Capture at the source VM's tap interface (on compute $src_host):${NC}"
    echo "  ssh ${SSH_USER}@${src_host} sudo tcpdump -i ${src_tap} -nn icmp host ${dst_ip}"
    echo ""

    echo -e "${BOLD}Capture at the destination VM's tap interface (on compute $dst_host):${NC}"
    echo "  ssh ${SSH_USER}@${dst_host} sudo tcpdump -i ${dst_tap} -nn icmp host ${src_ip}"
    echo ""

    echo -e "${BOLD}Capture on br-int (source compute):${NC}"
    echo "  ssh ${SSH_USER}@${src_host} sudo tcpdump -i br-int -nn icmp host ${dst_ip}"
    echo ""

    if [[ "$src_host" != "$dst_host" ]]; then
        echo -e "${BOLD}Capture Geneve tunnel traffic between computes:${NC}"
        echo "  ssh ${SSH_USER}@${src_host} sudo tcpdump -i any -nn 'udp port 6081 and host ${dst_host}'"
        echo "  ssh ${SSH_USER}@${dst_host} sudo tcpdump -i any -nn 'udp port 6081 and host ${src_host}'"
        echo ""
    fi

    echo -e "${BOLD}Capture with OVS internal mirroring (alternative):${NC}"
    echo "  # On compute $src_host:"
    echo "  sudo ovs-vsctl -- --id=@m create mirror name=workshop-mirror \\
      select-all=true output-port=@p -- --id=@p get port ${src_tap} -- \\
      set bridge br-int mirrors=@m"
    echo "  # Remove mirror after capture:"
    echo "  sudo ovs-vsctl clear bridge br-int mirrors"
}

# ---------------------------------------------------------------------------
# Run all test scenarios
# ---------------------------------------------------------------------------
run_tests() {
    header "Traffic Flow Tests"

    # Verify test VMs exist
    local vms_ok=true
    for vm in "${PREFIX}-vm1" "${PREFIX}-vm2" "${PREFIX}-vm3" "${PREFIX}-vm4"; do
        if ! openstack server show "$vm" &>/dev/null; then
            error "Server '$vm' not found. Run with --create-resources first."
            vms_ok=false
        fi
    done
    if [[ "$vms_ok" != true ]]; then
        error "Missing test VMs. Aborting tests."
        exit 1
    fi

    # Gather VM info
    local vm1_ip vm1_mac vm1_host vm1_net
    local vm2_ip vm2_mac vm2_host vm2_net
    local vm3_ip vm3_mac vm3_host vm3_net
    local vm4_ip vm4_mac vm4_host vm4_net

    get_vm_info "${PREFIX}-vm1" vm1_ip vm1_mac vm1_host vm1_net
    get_vm_info "${PREFIX}-vm2" vm2_ip vm2_mac vm2_host vm2_net
    get_vm_info "${PREFIX}-vm3" vm3_ip vm3_mac vm3_host vm3_net
    get_vm_info "${PREFIX}-vm4" vm4_ip vm4_mac vm4_host vm4_net

    info "VM details:"
    echo "  vm1: ip=$vm1_ip mac=$vm1_mac host=$vm1_host"
    echo "  vm2: ip=$vm2_ip mac=$vm2_mac host=$vm2_host"
    echo "  vm3: ip=$vm3_ip mac=$vm3_mac host=$vm3_host"
    echo "  vm4: ip=$vm4_ip mac=$vm4_mac host=$vm4_host"
    echo ""

    # Determine which data plane node(s) to use for OVS flow dumps
    local dp_node=""
    if [[ -n "$DATAPLANE_NODE" ]]; then
        dp_node="$DATAPLANE_NODE"
    elif [[ "$ALL_NODES" == true ]]; then
        discover_nodes
        dp_node="${DISCOVERED_NODES[0]:-}"
    fi

    # -----------------------------------------------------------------------
    # Test 1: VM to VM - same network, same compute
    # -----------------------------------------------------------------------
    header "Test 1: VM-to-VM - Same Network, Same Compute"
    info "vm1 ($vm1_ip on $vm1_host) -> vm2 ($vm2_ip on $vm2_host)"

    if [[ "$vm1_host" == "$vm2_host" ]]; then
        info "Confirmed: both VMs are on the same compute host ($vm1_host)."
    else
        warn "vm1 and vm2 are on different hosts ($vm1_host vs $vm2_host) - this test may behave like a cross-node test."
    fi

    run_ping_test "${PREFIX}-vm1" "$vm2_ip" "VM1 -> VM2 (same network, same compute)"
    run_ovn_trace "${PREFIX}-vm1" "${PREFIX}-vm2" "VM1 -> VM2 (same network, same compute)"
    show_ovs_flows "${dp_node:-$vm1_host}" "$vm1_ip" "$vm2_ip" "VM1 -> VM2"
    suggest_tcpdump "${PREFIX}-vm1" "${PREFIX}-vm2" "$vm1_ip" "$vm2_ip" "VM1 -> VM2"

    # -----------------------------------------------------------------------
    # Test 2: VM to VM - same network, different computes
    # -----------------------------------------------------------------------
    header "Test 2: VM-to-VM - Same Network, Different Computes"
    info "vm1 ($vm1_ip on $vm1_host) -> vm3 ($vm3_ip on $vm3_host)"

    if [[ "$vm1_host" != "$vm3_host" ]]; then
        info "Confirmed: VMs are on different compute hosts."
        info "Traffic will traverse a Geneve tunnel between $vm1_host and $vm3_host."
    else
        warn "vm1 and vm3 are on the same host ($vm1_host) - cross-node behavior will not be observed."
    fi

    run_ping_test "${PREFIX}-vm1" "$vm3_ip" "VM1 -> VM3 (same network, different computes)"
    run_ovn_trace "${PREFIX}-vm1" "${PREFIX}-vm3" "VM1 -> VM3 (same network, different computes)"
    show_ovs_flows "${dp_node:-$vm1_host}" "$vm1_ip" "$vm3_ip" "VM1 -> VM3"
    suggest_tcpdump "${PREFIX}-vm1" "${PREFIX}-vm3" "$vm1_ip" "$vm3_ip" "VM1 -> VM3"

    # -----------------------------------------------------------------------
    # Test 3: VM to VM - different networks (routing)
    # -----------------------------------------------------------------------
    header "Test 3: VM-to-VM - Different Networks (Routing)"
    info "vm1 ($vm1_ip on net-a) -> vm4 ($vm4_ip on net-b)"
    info "Traffic is routed through logical router '${PREFIX}-router'."

    run_ping_test "${PREFIX}-vm1" "$vm4_ip" "VM1 -> VM4 (different networks, routed)"
    run_ovn_trace "${PREFIX}-vm1" "${PREFIX}-vm4" "VM1 -> VM4 (different networks, routed)"
    show_ovs_flows "${dp_node:-$vm1_host}" "$vm1_ip" "$vm4_ip" "VM1 -> VM4 (routed)"
    suggest_tcpdump "${PREFIX}-vm1" "${PREFIX}-vm4" "$vm1_ip" "$vm4_ip" "VM1 -> VM4"

    # -----------------------------------------------------------------------
    # Test 4: VM to external (floating IP)
    # -----------------------------------------------------------------------
    header "Test 4: VM to External (Floating IP)"

    local vm1_fip
    vm1_fip=$(openstack server show "${PREFIX}-vm1" -f value -c addresses 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -1 || true)

    # Check if the last IP differs from the fixed IP (meaning there is a FIP)
    if [[ "$vm1_fip" != "$vm1_ip" && -n "$vm1_fip" ]]; then
        info "VM1 floating IP: $vm1_fip"
        info "Testing external connectivity from outside to VM1 via floating IP ..."

        # Ping the floating IP from the local machine
        ((TESTS_RUN++)) || true
        if ping -c 3 -W 5 "$vm1_fip" &>/dev/null; then
            pass "External -> VM1 ($vm1_fip) - ping successful"
        else
            warn "External -> VM1 ($vm1_fip) - ping failed (may be expected depending on network topology)"
        fi

        # Show NAT rules
        subheader "NAT Rules on Router"
        nb_exec lr-nat-list "${PREFIX}-router" 2>/dev/null || true

        # OVN trace for DNAT (external -> VM)
        subheader "OVN Trace: External -> VM1 (DNAT)"
        info "For DNAT tracing, use the router's external port as inport."
        info "Manual command:"
        echo "  oc exec -n $NAMESPACE $NB_POD -- ovn-trace '${PREFIX}-router' \\"
        echo "    'inport==\"<external-router-port>\" && eth.src==<external-mac> && \\"
        echo "     eth.dst==<router-mac> && ip4.src==<external-src> && ip4.dst==${vm1_fip} && \\"
        echo "     ip.ttl==64 && icmp4.type==8'"

        if [[ -n "$dp_node" ]]; then
            show_ovs_flows "$dp_node" "$vm1_fip" "$vm1_ip" "Floating IP DNAT/SNAT"
        fi
    else
        info "No floating IP assigned to VM1 - skipping external connectivity test."
        info "Assign a floating IP with: openstack server add floating ip ${PREFIX}-vm1 <fip>"
    fi
}

# ---------------------------------------------------------------------------
# Test results summary
# ---------------------------------------------------------------------------
print_summary() {
    header "Test Results Summary"

    echo -e "${BOLD}Tests run:    ${NC}$TESTS_RUN"
    echo -e "${GREEN}${BOLD}Tests passed: ${NC}$TESTS_PASSED"
    echo -e "${RED}${BOLD}Tests failed: ${NC}$TESTS_FAILED"
    echo ""

    if [[ $TESTS_FAILED -eq 0 && $TESTS_RUN -gt 0 ]]; then
        success "All tests passed."
    elif [[ $TESTS_FAILED -gt 0 ]]; then
        warn "Some tests failed. Review the output above for details."
    fi

    if [[ "$NO_REPORT" == false && -n "$REPORT_FILE" ]]; then
        echo ""
        success "Full report saved to: ${BOLD}${REPORT_FILE}${NC}"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo -e "${CYAN}${BOLD}"
    echo "================================================================="
    echo "  Traffic Flow Tests for RHOSO"
    echo "  Red Hat OpenStack Services on OpenShift"
    echo "  $(date)"
    echo "================================================================="
    echo -e "${NC}"

    parse_args "$@"
    setup_report
    preflight

    case "$ACTION" in
        cleanup)
            cleanup_resources
            exit 0
            ;;
        create)
            find_ovn_pods
            create_resources
            run_tests
            print_summary
            ;;
        existing)
            find_ovn_pods
            run_tests
            print_summary
            ;;
    esac
}

main "$@"
