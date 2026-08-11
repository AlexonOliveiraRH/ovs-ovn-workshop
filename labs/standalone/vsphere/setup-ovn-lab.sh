#!/bin/bash
set -euo pipefail

# =============================================================================
# setup-ovn-lab.sh - Deploy an OVN lab on VMware vSphere
# =============================================================================
#
# This script provisions 3 VMs on vSphere using govc and configures them as
# an OVN cluster for the hands-on lab exercises in the OVS & OVN workshop.
#
# Architecture:
#   +---------------------+
#   |    ovn-central      |
#   |  - OVN Northbound DB|
#   |  - OVN Southbound DB|
#   |  - ovn-northd       |
#   |  - ovn-controller   |
#   +----------+----------+
#              |
#    +---------+---------+
#    |                   |
# +--+--------+   +-----+------+
# | ovn-comp1 |   | ovn-comp2  |
# | ovn-ctrl  |   | ovn-ctrl   |
# | (chassis) |   | (chassis)  |
# +-----------+   +------------+
#
# The "central" node runs the OVN northbound database, southbound database,
# and the ovn-northd daemon. All three nodes run ovn-controller and act as
# chassis that can host logical ports.
#
# Usage:
#   # Set environment variables first (see setup-ovs-lab.sh for details)
#   ./setup-ovn-lab.sh
#
# Prerequisites:
#   1. govc installed and GOVC_* environment variables set
#   2. A VM template with RHEL 9 or Fedora in vSphere
#   3. SSH key-based access configured on the template
#   4. Sufficient resources in the target cluster/resource pool
#
# Installing govc:
#   curl -L -o govc.tar.gz \
#     "https://github.com/vmware/govmomi/releases/latest/download/govc_$(uname -s)_$(uname -m).tar.gz"
#   tar -xzf govc.tar.gz govc
#   sudo mv govc /usr/local/bin/
#   govc version
#
# Environment Variables (GOVC):
#   GOVC_URL        - vCenter or ESXi URL (e.g., vcenter.example.com)
#   GOVC_USERNAME   - vSphere login username
#   GOVC_PASSWORD   - vSphere login password
#   GOVC_DATACENTER - Target datacenter name
#   GOVC_DATASTORE  - Datastore for VM disks
#   GOVC_NETWORK    - Default network/port group for VMs
#   GOVC_INSECURE   - Set to "true" to skip TLS certificate verification
#
# =============================================================================

# -----------------------------------------------------------------------------
# Configurable Variables
# -----------------------------------------------------------------------------

# Prefix applied to all lab resources for easy identification and cleanup.
LAB_PREFIX="${LAB_PREFIX:-ovn-lab}"

# VM template to clone from.
VM_TEMPLATE="${VM_TEMPLATE:-rhel9-cloud-template}"

# Resource pool where VMs will be placed.
RESOURCE_POOL="${RESOURCE_POOL:-/Resources}"

# vSphere folder to organize lab VMs.
VM_FOLDER="${VM_FOLDER:-${LAB_PREFIX}}"

# Hardware sizing per VM. The central node is sized identically for simplicity;
# in production OVN, the central databases may need more memory.
VM_CPUS="${VM_CPUS:-2}"
VM_MEMORY_MB="${VM_MEMORY_MB:-4096}"

# SSH configuration.
SSH_USER="${SSH_USER:-cloud-user}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_rsa}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

# Wait timeout (seconds) for VMs to become reachable.
VM_WAIT_TIMEOUT="${VM_WAIT_TIMEOUT:-300}"

# OVN integration bridge name (the bridge ovn-controller manages).
OVN_BRIDGE="${OVN_BRIDGE:-br-int}"

# Geneve tunnel UDP port (OVN default).
GENEVE_PORT="${GENEVE_PORT:-6081}"

# OVN northbound/southbound database ports.
OVN_NB_PORT="${OVN_NB_PORT:-6641}"
OVN_SB_PORT="${OVN_SB_PORT:-6642}"

# File to store VM IP addresses and roles.
STATE_FILE="${STATE_FILE:-/tmp/${LAB_PREFIX}-state.env}"

# VM roles and names.
CENTRAL_NAME="${LAB_PREFIX}-central"
COMPUTE1_NAME="${LAB_PREFIX}-comp1"
COMPUTE2_NAME="${LAB_PREFIX}-comp2"

# All VM names in order: central first, then compute nodes.
VM_NAMES=("${CENTRAL_NAME}" "${COMPUTE1_NAME}" "${COMPUTE2_NAME}")

# -----------------------------------------------------------------------------
# Color output helpers
# -----------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
fatal() { error "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Prerequisite Checks
# -----------------------------------------------------------------------------

check_prerequisites() {
    info "Checking prerequisites..."

    if ! command -v govc &>/dev/null; then
        fatal "govc is not installed or not in PATH.
  Install it with:
    curl -L -o govc.tar.gz \\
      \"https://github.com/vmware/govmomi/releases/latest/download/govc_\$(uname -s)_\$(uname -m).tar.gz\"
    tar -xzf govc.tar.gz govc
    sudo mv govc /usr/local/bin/"
    fi
    ok "govc found: $(govc version)"

    local required_vars=(GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_DATACENTER GOVC_DATASTORE)
    local missing=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        fatal "Missing required environment variables: ${missing[*]}
  Set them before running this script. Example:
    export GOVC_URL='vcenter.example.com'
    export GOVC_USERNAME='administrator@vsphere.local'
    export GOVC_PASSWORD='secretpassword'
    export GOVC_DATACENTER='DC1'
    export GOVC_DATASTORE='datastore1'
    export GOVC_NETWORK='VM Network'
    export GOVC_INSECURE='true'"
    fi
    ok "All required GOVC_* environment variables are set"

    if ! govc about &>/dev/null; then
        fatal "Cannot connect to vSphere at ${GOVC_URL}. Verify credentials and network."
    fi
    ok "Connected to vSphere: $(govc about | grep -i 'name' | head -1 | xargs)"

    if ! govc vm.info "${VM_TEMPLATE}" &>/dev/null; then
        fatal "VM template '${VM_TEMPLATE}' not found in datacenter '${GOVC_DATACENTER}'."
    fi
    ok "Template found: ${VM_TEMPLATE}"

    if [[ ! -f "${SSH_KEY}" ]]; then
        fatal "SSH private key not found at '${SSH_KEY}'. Set SSH_KEY to the correct path."
    fi
    ok "SSH key found: ${SSH_KEY}"

    info "All prerequisites satisfied."
}

# -----------------------------------------------------------------------------
# Create vSphere Folder
# -----------------------------------------------------------------------------

create_folder() {
    info "Ensuring VM folder '${VM_FOLDER}' exists..."

    if govc folder.info "vm/${VM_FOLDER}" &>/dev/null; then
        ok "Folder 'vm/${VM_FOLDER}' already exists"
    else
        govc folder.create "vm/${VM_FOLDER}"
        ok "Created folder 'vm/${VM_FOLDER}'"
    fi
}

# -----------------------------------------------------------------------------
# Generate Cloud-Init Userdata
# Generates role-specific cloud-init configs for central vs. compute nodes.
# -----------------------------------------------------------------------------

generate_cloud_init_central() {
    local userdata_file="/tmp/${LAB_PREFIX}-${CENTRAL_NAME}-userdata.yaml"

    cat > "${userdata_file}" <<'CLOUD_INIT_EOF'
#cloud-config

hostname: CENTRAL_NAME_PLACEHOLDER

package_update: true
packages:
  - openvswitch3.3
  - ovn24.03-central
  - ovn24.03-host
  - tcpdump
  - wireshark-cli
  - net-tools
  - iproute
  - iperf3
  - python3-openvswitch

runcmd:
  # --- OVS Setup ---
  # Start OVS first, since OVN depends on it.
  - systemctl enable --now openvswitch

  # --- OVN Central Setup ---
  # Enable and start the OVN northbound and southbound databases.
  # These are ovsdb-server instances that store the OVN logical and
  # physical network state respectively.
  - systemctl enable --now ovn-ovsdb-server-nb
  - systemctl enable --now ovn-ovsdb-server-sb

  # Start ovn-northd, the daemon that translates northbound logical
  # configuration into southbound logical flows.
  - systemctl enable --now ovn-northd

  # Configure the northbound database to listen on all interfaces so
  # remote clients (ovn-nbctl from admin workstations) can connect.
  - ovn-nbctl set-connection ptcp:OVN_NB_PORT_PLACEHOLDER:0.0.0.0

  # Configure the southbound database to listen on all interfaces so
  # compute nodes' ovn-controller can connect.
  - ovn-sbctl set-connection ptcp:OVN_SB_PORT_PLACEHOLDER:0.0.0.0

  # --- OVN Controller (local chassis) ---
  # The central node also runs ovn-controller so it can host logical ports.
  # Configure the external-ids that ovn-controller needs to find the
  # southbound database and identify this chassis.
  - ovs-vsctl set open_vswitch . \
      external-ids:ovn-remote="tcp:127.0.0.1:OVN_SB_PORT_PLACEHOLDER" \
      external-ids:ovn-encap-type=geneve \
      external-ids:ovn-encap-ip="LOCAL_IP_PLACEHOLDER" \
      external-ids:system-id="CENTRAL_NAME_PLACEHOLDER"

  - systemctl enable --now ovn-controller

  # Open firewall ports for OVN databases and Geneve tunnels.
  - firewall-cmd --permanent --add-port=OVN_NB_PORT_PLACEHOLDER/tcp || true
  - firewall-cmd --permanent --add-port=OVN_SB_PORT_PLACEHOLDER/tcp || true
  - firewall-cmd --permanent --add-port=GENEVE_PORT_PLACEHOLDER/udp || true
  - firewall-cmd --reload || true

  # Mark setup as complete.
  - echo "OVN_LAB_SETUP_COMPLETE" > /tmp/ovn-lab-ready
CLOUD_INIT_EOF

    sed -i "s/CENTRAL_NAME_PLACEHOLDER/${CENTRAL_NAME}/g" "${userdata_file}"
    sed -i "s/OVN_NB_PORT_PLACEHOLDER/${OVN_NB_PORT}/g" "${userdata_file}"
    sed -i "s/OVN_SB_PORT_PLACEHOLDER/${OVN_SB_PORT}/g" "${userdata_file}"
    sed -i "s/GENEVE_PORT_PLACEHOLDER/${GENEVE_PORT}/g" "${userdata_file}"
    # LOCAL_IP_PLACEHOLDER will be replaced post-boot via SSH (we do not know
    # the IP until the VM has started).

    echo "${userdata_file}"
}

generate_cloud_init_compute() {
    local vm_name="$1"
    local userdata_file="/tmp/${LAB_PREFIX}-${vm_name}-userdata.yaml"

    cat > "${userdata_file}" <<'CLOUD_INIT_EOF'
#cloud-config

hostname: VM_NAME_PLACEHOLDER

package_update: true
packages:
  - openvswitch3.3
  - ovn24.03-host
  - tcpdump
  - wireshark-cli
  - net-tools
  - iproute
  - iperf3
  - python3-openvswitch

runcmd:
  # --- OVS Setup ---
  - systemctl enable --now openvswitch

  # --- OVN Controller Setup ---
  # ovn-controller is the per-chassis agent that connects to the southbound
  # database, claims chassis-specific port bindings, and programs local OVS
  # flows to implement the logical network.
  #
  # The external-ids are written here with a placeholder for the central
  # node IP. The setup script replaces CENTRAL_IP_PLACEHOLDER via SSH after
  # the central node's IP is known.
  - ovs-vsctl set open_vswitch . \
      external-ids:ovn-remote="tcp:CENTRAL_IP_PLACEHOLDER:OVN_SB_PORT_PLACEHOLDER" \
      external-ids:ovn-encap-type=geneve \
      external-ids:ovn-encap-ip="LOCAL_IP_PLACEHOLDER" \
      external-ids:system-id="VM_NAME_PLACEHOLDER"

  - systemctl enable --now ovn-controller

  # Open firewall port for Geneve tunnels.
  - firewall-cmd --permanent --add-port=GENEVE_PORT_PLACEHOLDER/udp || true
  - firewall-cmd --reload || true

  # Mark setup as complete.
  - echo "OVN_LAB_SETUP_COMPLETE" > /tmp/ovn-lab-ready
CLOUD_INIT_EOF

    sed -i "s/VM_NAME_PLACEHOLDER/${vm_name}/g" "${userdata_file}"
    sed -i "s/OVN_SB_PORT_PLACEHOLDER/${OVN_SB_PORT}/g" "${userdata_file}"
    sed -i "s/GENEVE_PORT_PLACEHOLDER/${GENEVE_PORT}/g" "${userdata_file}"
    # CENTRAL_IP_PLACEHOLDER and LOCAL_IP_PLACEHOLDER are resolved post-boot.

    echo "${userdata_file}"
}

# -----------------------------------------------------------------------------
# Clone and Deploy VMs
# -----------------------------------------------------------------------------

deploy_vm() {
    local vm_name="$1"
    local userdata_file="$2"

    info "Deploying VM: ${vm_name}"

    # Idempotent check.
    if govc vm.info "${vm_name}" &>/dev/null; then
        warn "VM '${vm_name}' already exists - skipping clone"
        return 0
    fi

    # Clone the VM from the template in a powered-off state.
    govc vm.clone \
        -vm "${VM_TEMPLATE}" \
        -on=false \
        -c="${VM_CPUS}" \
        -m="${VM_MEMORY_MB}" \
        -folder="vm/${VM_FOLDER}" \
        -pool="${RESOURCE_POOL}" \
        -net="${GOVC_NETWORK:-VM Network}" \
        "${vm_name}"

    ok "Cloned '${vm_name}' from template '${VM_TEMPLATE}'"

    # Attach cloud-init userdata via vApp/guestinfo properties.
    govc vm.change -vm "${vm_name}" \
        -e "guestinfo.userdata=$(base64 -w0 "${userdata_file}")" \
        -e "guestinfo.userdata.encoding=base64"

    ok "Attached cloud-init userdata to '${vm_name}'"

    # Add a second NIC for Geneve tunnel traffic.
    # In a production OVN deployment, the tunnel network is typically on a
    # dedicated VLAN or physical network. For this lab, both NICs share the
    # same port group.
    govc vm.network.add -vm "${vm_name}" \
        -net "${GOVC_NETWORK:-VM Network}" \
        -net.adapter e1000e

    ok "Added second NIC to '${vm_name}' for tunnel traffic"

    # Power on.
    govc vm.power -on "${vm_name}"
    ok "Powered on '${vm_name}'"

    rm -f "${userdata_file}"
}

deploy_all_vms() {
    info "Deploying 3 VMs (1 central + 2 compute)..."

    # Generate cloud-init configs.
    local central_userdata
    central_userdata=$(generate_cloud_init_central)

    local comp1_userdata
    comp1_userdata=$(generate_cloud_init_compute "${COMPUTE1_NAME}")

    local comp2_userdata
    comp2_userdata=$(generate_cloud_init_compute "${COMPUTE2_NAME}")

    # Deploy all three VMs.
    deploy_vm "${CENTRAL_NAME}" "${central_userdata}"
    deploy_vm "${COMPUTE1_NAME}" "${comp1_userdata}"
    deploy_vm "${COMPUTE2_NAME}" "${comp2_userdata}"

    ok "All 3 VMs deployed"
}

# -----------------------------------------------------------------------------
# Wait for VMs to Get IP Addresses
# -----------------------------------------------------------------------------

wait_for_vms() {
    info "Waiting for VMs to obtain IP addresses (timeout: ${VM_WAIT_TIMEOUT}s)..."

    : > "${STATE_FILE}"
    echo "# OVN Lab State - generated $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${STATE_FILE}"
    echo "LAB_PREFIX=${LAB_PREFIX}" >> "${STATE_FILE}"

    for idx in "${!VM_NAMES[@]}"; do
        local vm_name="${VM_NAMES[$idx]}"
        local ip=""
        local elapsed=0
        local interval=10

        info "Waiting for '${vm_name}' to get an IP..."

        while [[ -z "${ip}" ]] && [[ ${elapsed} -lt ${VM_WAIT_TIMEOUT} ]]; do
            ip=$(govc vm.ip "${vm_name}" 2>/dev/null || true)
            if [[ -z "${ip}" ]]; then
                sleep "${interval}"
                elapsed=$((elapsed + interval))
                info "  Still waiting for '${vm_name}'... (${elapsed}s elapsed)"
            fi
        done

        if [[ -z "${ip}" ]]; then
            fatal "Timed out waiting for IP on '${vm_name}' after ${VM_WAIT_TIMEOUT}s."
        fi

        ok "'${vm_name}' has IP: ${ip}"

        # Store role-specific state.
        local role
        case "${vm_name}" in
            *central*) role="CENTRAL" ;;
            *comp1*)   role="COMPUTE1" ;;
            *comp2*)   role="COMPUTE2" ;;
        esac

        echo "${role}_NAME=${vm_name}" >> "${STATE_FILE}"
        echo "${role}_IP=${ip}" >> "${STATE_FILE}"
    done

    ok "All VMs have IP addresses. State saved to ${STATE_FILE}"
}

# -----------------------------------------------------------------------------
# Wait for Cloud-Init to Complete
# -----------------------------------------------------------------------------

wait_for_cloud_init() {
    info "Waiting for cloud-init to finish OVN setup on all VMs..."

    for vm_name in "${VM_NAMES[@]}"; do
        local role
        case "${vm_name}" in
            *central*) role="CENTRAL" ;;
            *comp1*)   role="COMPUTE1" ;;
            *comp2*)   role="COMPUTE2" ;;
        esac

        local ip
        ip=$(grep "${role}_IP" "${STATE_FILE}" | cut -d= -f2)

        local elapsed=0
        local interval=15

        info "Waiting for cloud-init on '${vm_name}' (${ip})..."

        while [[ ${elapsed} -lt ${VM_WAIT_TIMEOUT} ]]; do
            if ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${ip}" \
                    "test -f /tmp/ovn-lab-ready" 2>/dev/null; then
                ok "Cloud-init completed on '${vm_name}'"
                break
            fi
            sleep "${interval}"
            elapsed=$((elapsed + interval))
            info "  Still waiting for cloud-init on '${vm_name}'... (${elapsed}s)"
        done

        if [[ ${elapsed} -ge ${VM_WAIT_TIMEOUT} ]]; then
            warn "Timed out waiting for cloud-init on '${vm_name}'.
  Check: ssh ${SSH_USER}@${ip} 'cloud-init status'"
        fi
    done
}

# -----------------------------------------------------------------------------
# Post-Boot OVN Configuration
# Cloud-init installs packages and starts services, but some configuration
# requires knowing the IP addresses of the VMs (which are only available
# after boot). This function updates the OVN external-ids with the correct
# IP addresses.
# -----------------------------------------------------------------------------

configure_ovn_networking() {
    info "Configuring OVN networking with actual IP addresses..."

    local central_ip
    central_ip=$(grep "CENTRAL_IP" "${STATE_FILE}" | cut -d= -f2)

    # --- Central Node ---
    # Update the encap-ip on the central node to its actual IP.
    info "Configuring OVN on central node (${central_ip})..."

    ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${central_ip}" \
        "sudo ovs-vsctl set open_vswitch . \
            external-ids:ovn-encap-ip=${central_ip}" 2>/dev/null

    ok "Central node OVN encap-ip set to ${central_ip}"

    # --- Compute Nodes ---
    # Each compute node needs to know the central node IP (for the SB database
    # connection) and its own IP (for the tunnel endpoint).
    for role in COMPUTE1 COMPUTE2; do
        local comp_ip comp_name
        comp_ip=$(grep "${role}_IP" "${STATE_FILE}" | cut -d= -f2)
        comp_name=$(grep "${role}_NAME" "${STATE_FILE}" | cut -d= -f2)

        info "Configuring OVN on '${comp_name}' (${comp_ip})..."

        # Set the ovn-remote to point at the central node's SB database.
        # Set the encap-ip to this compute node's own IP.
        ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${comp_ip}" \
            "sudo ovs-vsctl set open_vswitch . \
                external-ids:ovn-remote=tcp:${central_ip}:${OVN_SB_PORT} \
                external-ids:ovn-encap-ip=${comp_ip}" 2>/dev/null

        # Restart ovn-controller so it picks up the new configuration and
        # registers this chassis with the southbound database.
        ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${comp_ip}" \
            "sudo systemctl restart ovn-controller" 2>/dev/null

        ok "'${comp_name}' connected to central OVN at ${central_ip}:${OVN_SB_PORT}"
    done

    ok "All nodes configured for OVN"
}

# -----------------------------------------------------------------------------
# Set Up Basic Logical Network
# Create a simple OVN logical switch and router to verify the deployment
# works end-to-end and to give workshop participants a starting point.
# -----------------------------------------------------------------------------

setup_logical_network() {
    info "Creating basic OVN logical network for lab exercises..."

    local central_ip
    central_ip=$(grep "CENTRAL_IP" "${STATE_FILE}" | cut -d= -f2)

    # All ovn-nbctl commands run on the central node where the NB database is.
    # These commands create a minimal logical topology:
    #
    #   +-- logical-router (lab-router) --+
    #   |         192.168.100.1/24        |
    #   +----------------+----------------+
    #                    |
    #   +----------------+----------------+
    #   |    logical-switch (lab-switch)   |
    #   |         192.168.100.0/24        |
    #   +--+----------+----------+--------+
    #      |          |          |
    #    port1      port2      port3
    #  (central)  (comp1)    (comp2)

    ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${central_ip}" bash <<'REMOTE_SCRIPT'
set -euo pipefail

# Create a logical switch - the fundamental L2 construct in OVN.
# This is equivalent to a virtual Ethernet segment.
sudo ovn-nbctl --may-exist ls-add lab-switch

# Create logical switch ports, one per chassis.
# Each port represents a virtual NIC attached to the logical switch.
for port in lab-port1 lab-port2 lab-port3; do
    sudo ovn-nbctl --may-exist lsp-add lab-switch "${port}"
    sudo ovn-nbctl lsp-set-addresses "${port}" dynamic
    sudo ovn-nbctl lsp-set-port-security "${port}" dynamic
done

# Create a logical router for L3 connectivity.
sudo ovn-nbctl --may-exist lr-add lab-router

# Create a router port connected to the switch.
# This gives the switch a default gateway.
sudo ovn-nbctl --may-exist lrp-add lab-router router-to-switch 02:ac:10:ff:00:01 192.168.100.1/24

# Connect the switch to the router via a "router" type port.
sudo ovn-nbctl --may-exist lsp-add lab-switch switch-to-router
sudo ovn-nbctl lsp-set-type switch-to-router router
sudo ovn-nbctl lsp-set-addresses switch-to-router router
sudo ovn-nbctl lsp-set-options switch-to-router router-port=router-to-switch

echo "Logical network created successfully."
echo ""
echo "--- OVN Northbound State ---"
sudo ovn-nbctl show
echo ""
echo "--- OVN Southbound Chassis ---"
sudo ovn-sbctl show
REMOTE_SCRIPT

    ok "Basic OVN logical network created (lab-switch + lab-router)"
}

# -----------------------------------------------------------------------------
# Verify OVN Deployment
# -----------------------------------------------------------------------------

verify_ovn() {
    info "Verifying OVN deployment..."

    local central_ip
    central_ip=$(grep "CENTRAL_IP" "${STATE_FILE}" | cut -d= -f2)

    # Check that all chassis have registered with the southbound database.
    info "Checking chassis registration in the southbound database..."
    local chassis_count
    chassis_count=$(ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${central_ip}" \
        "sudo ovn-sbctl --columns=name list chassis 2>/dev/null | grep -c 'name'" 2>/dev/null || echo "0")

    if [[ "${chassis_count}" -ge 3 ]]; then
        ok "All 3 chassis registered in the southbound database"
    elif [[ "${chassis_count}" -ge 1 ]]; then
        warn "Only ${chassis_count}/3 chassis registered - some compute nodes may still be connecting"
    else
        warn "No chassis found - ovn-controller may not be running on the nodes"
    fi

    # Check OVN services on the central node.
    for svc in ovn-ovsdb-server-nb ovn-ovsdb-server-sb ovn-northd ovn-controller; do
        local status
        status=$(ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${central_ip}" \
            "sudo systemctl is-active ${svc}" 2>/dev/null || echo "unknown")
        if [[ "${status}" == "active" ]]; then
            ok "Central: ${svc} is active"
        else
            warn "Central: ${svc} is ${status}"
        fi
    done

    # Check ovn-controller on compute nodes.
    for role in COMPUTE1 COMPUTE2; do
        local comp_ip comp_name
        comp_ip=$(grep "${role}_IP" "${STATE_FILE}" | cut -d= -f2)
        comp_name=$(grep "${role}_NAME" "${STATE_FILE}" | cut -d= -f2)

        local status
        status=$(ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${comp_ip}" \
            "sudo systemctl is-active ovn-controller" 2>/dev/null || echo "unknown")
        if [[ "${status}" == "active" ]]; then
            ok "${comp_name}: ovn-controller is active"
        else
            warn "${comp_name}: ovn-controller is ${status}"
        fi
    done
}

# -----------------------------------------------------------------------------
# Print Lab Summary
# -----------------------------------------------------------------------------

print_summary() {
    local central_ip compute1_ip compute2_ip
    central_ip=$(grep "CENTRAL_IP" "${STATE_FILE}" | cut -d= -f2)
    compute1_ip=$(grep "COMPUTE1_IP" "${STATE_FILE}" | cut -d= -f2)
    compute2_ip=$(grep "COMPUTE2_IP" "${STATE_FILE}" | cut -d= -f2)

    echo ""
    echo "============================================================================="
    echo " OVN Lab - Deployment Summary"
    echo "============================================================================="
    echo ""
    echo " Lab prefix:      ${LAB_PREFIX}"
    echo " VM template:     ${VM_TEMPLATE}"
    echo " State file:      ${STATE_FILE}"
    echo ""
    echo " Nodes:"
    echo " ------"
    echo "   ${CENTRAL_NAME}   (central + chassis)  ->  ${central_ip}"
    echo "   ${COMPUTE1_NAME}  (chassis)             ->  ${compute1_ip}"
    echo "   ${COMPUTE2_NAME}  (chassis)             ->  ${compute2_ip}"
    echo ""
    echo " OVN Databases:"
    echo " ---------------"
    echo "   Northbound DB:  tcp:${central_ip}:${OVN_NB_PORT}"
    echo "   Southbound DB:  tcp:${central_ip}:${OVN_SB_PORT}"
    echo ""
    echo " Quick access:"
    echo " -------------"
    echo "   ssh ${SSH_USER}@${central_ip}    # Central node"
    echo "   ssh ${SSH_USER}@${compute1_ip}   # Compute 1"
    echo "   ssh ${SSH_USER}@${compute2_ip}   # Compute 2"
    echo ""
    echo " Logical network:"
    echo " -----------------"
    echo "   Switch:  lab-switch   (192.168.100.0/24)"
    echo "   Router:  lab-router   (gateway 192.168.100.1)"
    echo "   Ports:   lab-port1, lab-port2, lab-port3"
    echo ""
    echo " Useful commands on the central node:"
    echo " -------------------------------------"
    echo "   sudo ovn-nbctl show                      # Northbound logical topology"
    echo "   sudo ovn-sbctl show                      # Southbound chassis/bindings"
    echo "   sudo ovn-nbctl list logical_switch        # List logical switches"
    echo "   sudo ovn-nbctl list logical_router        # List logical routers"
    echo "   sudo ovn-sbctl list chassis               # List registered chassis"
    echo "   sudo ovn-sbctl lflow-list                 # List logical flows"
    echo "   sudo ovn-trace lab-switch <flow>          # Trace a logical packet"
    echo ""
    echo " Useful commands on any node:"
    echo " ----------------------------"
    echo "   sudo ovs-vsctl show                      # OVS configuration"
    echo "   sudo ovs-ofctl dump-flows ${OVN_BRIDGE}         # Physical flows programmed by OVN"
    echo "   sudo ovs-vsctl get open_vswitch . external-ids  # OVN external-ids"
    echo ""
    echo " Teardown:"
    echo " ---------"
    echo "   ./teardown.sh                             # Interactive cleanup"
    echo "   ./teardown.sh --force                     # Non-interactive cleanup"
    echo ""
    echo "============================================================================="
    echo ""
}

# =============================================================================
# PowerCLI Alternative (Reference)
# =============================================================================
#
# The PowerCLI commands for cloning and deploying VMs are identical to the
# OVS lab script (see setup-ovs-lab.sh). The only differences are:
#
# 1. VM names: ovn-lab-central, ovn-lab-comp1, ovn-lab-comp2
# 2. Cloud-init userdata: includes OVN packages (ovn-central, ovn-host)
# 3. Post-boot config: runs ovn-nbctl/ovn-sbctl commands via Invoke-VMScript
#
# Example post-boot configuration via PowerCLI:
#
# $centralVM = Get-VM -Name "ovn-lab-central"
# $centralIP = $centralVM.Guest.IPAddress[0]
#
# # Configure OVN on compute nodes
# foreach ($compName in @("ovn-lab-comp1", "ovn-lab-comp2")) {
#     $vm = Get-VM -Name $compName
#     $compIP = $vm.Guest.IPAddress[0]
#     Invoke-VMScript -VM $vm -ScriptText @"
#         ovs-vsctl set open_vswitch . \
#             external-ids:ovn-remote=tcp:${centralIP}:6642 \
#             external-ids:ovn-encap-type=geneve \
#             external-ids:ovn-encap-ip=${compIP} \
#             external-ids:system-id=$compName
#         systemctl restart ovn-controller
# "@ -GuestUser "root" -GuestPassword "password"
# }
#
# =============================================================================

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    echo ""
    info "=== OVN Lab Setup ==="
    echo ""

    check_prerequisites
    echo ""

    create_folder
    echo ""

    deploy_all_vms
    echo ""

    wait_for_vms
    echo ""

    wait_for_cloud_init
    echo ""

    configure_ovn_networking
    echo ""

    verify_ovn
    echo ""

    setup_logical_network
    echo ""

    print_summary
}

main "$@"
