#!/bin/bash
# ==============================================================================
# setup-ovn-lab.sh - Set up an OVN lab environment on QEMU/Libvirt/KVM
# ==============================================================================
#
# Description:
#   Creates an OVN lab environment consisting of 3 VMs:
#     - 1 central node running OVN central services (northd, NB/SB databases)
#     - 2 compute nodes running ovn-controller (connected to central)
#
#   The lab demonstrates OVN's architecture: the central node manages the
#   logical network through the Northbound database, northd translates logical
#   configuration into the Southbound database, and ovn-controller on each
#   compute node programs the local OVS instance based on Southbound DB state.
#
#   Lab topology:
#
#     +---------------------------+
#     |      Central Node         |
#     |  ovn-northd               |
#     |  ovsdb-server (NB + SB)   |
#     |  IP: 192.168.160.10       |
#     +------------+--------------+
#                  |
#          Management Network
#          (192.168.160.0/24)
#                  |
#        +---------+---------+
#        |                   |
#   +----+------+     +------+----+
#   | Compute 1 |     | Compute 2 |
#   | ovn-host  |     | ovn-host  |
#   | ovn-ctrl  |     | ovn-ctrl  |
#   | .11       |     | .12       |
#   +-----------+     +-----------+
#
#   After setup, OVN logical networking is configured:
#     - A logical switch (ls1) with ports for each compute node
#     - DHCP options for automatic IP assignment on the logical network
#     - Compute nodes connected via Geneve tunnels (managed by OVN)
#
# Usage:
#   sudo ./setup-ovn-lab.sh [OPTIONS]
#
# Options:
#   -h, --help          Show this help message
#   -m, --memory MiB    Memory per VM in MiB (default: 2048)
#   -c, --cpus NUM      vCPUs per VM (default: 2)
#   -p, --prefix NAME   Lab prefix for resource names (default: ovnlab)
#   -i, --image URL     Cloud image URL to use
#   -s, --ssh-key PATH  Path to SSH public key to inject
#   --skip-download     Skip image download (use existing image)
#
# Prerequisites:
#   - libvirt, qemu-kvm, virt-install
#   - openvswitch, ovn-central, ovn-host
#   - genisoimage
#   - Sufficient disk space (~5GB per VM, ~15GB total)
#   - Sufficient memory (3 VMs x 2GB = 6GB minimum)
#
# ==============================================================================

set -euo pipefail

# ==============================================================================
# Configuration variables - customize these for your environment
# ==============================================================================

# --- Lab identification ---
LAB_PREFIX="${LAB_PREFIX:-ovnlab}"

# --- VM configuration ---
VM_MEMORY="${VM_MEMORY:-2048}"        # Memory per VM in MiB
VM_CPUS="${VM_CPUS:-2}"              # vCPUs per VM
VM_DISK_SIZE="${VM_DISK_SIZE:-20G}"  # Disk size per VM
VM_PASSWORD="${VM_PASSWORD:-redhat}" # Default password for lab/root users

# --- VM names ---
# The central node runs OVN central services (northd + databases)
# The compute nodes run ovn-controller and host workloads
CENTRAL_VM_NAME="${LAB_PREFIX}-central"
COMPUTE1_VM_NAME="${LAB_PREFIX}-compute1"
COMPUTE2_VM_NAME="${LAB_PREFIX}-compute2"

# --- Cloud image ---
CLOUD_IMAGE_URL="${CLOUD_IMAGE_URL:-https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2}"
CLOUD_IMAGE_NAME="${CLOUD_IMAGE_NAME:-fedora-cloud-base.qcow2}"

# --- Storage ---
STORAGE_POOL_PATH="${STORAGE_POOL_PATH:-/var/lib/libvirt/images}"
CLOUD_IMAGE_PATH="${STORAGE_POOL_PATH}/${LAB_PREFIX}-${CLOUD_IMAGE_NAME}"

# --- Management network ---
# This network provides SSH access from the host to all VMs.
# It also carries OVN control-plane traffic (DB connections from
# ovn-controller on compute nodes to the central OVN databases).
MGMT_NET_NAME="${LAB_PREFIX}-mgmt"
MGMT_NET_BRIDGE="virbr-${LAB_PREFIX:0:4}m"
MGMT_NET_ADDR="192.168.160.0"
MGMT_NET_MASK="255.255.255.0"
MGMT_NET_GW="192.168.160.1"
MGMT_NET_DHCP_START="192.168.160.100"
MGMT_NET_DHCP_END="192.168.160.200"

# Static IPs for VMs (assigned via DHCP reservation based on MAC)
CENTRAL_IP="192.168.160.10"
COMPUTE1_IP="192.168.160.11"
COMPUTE2_IP="192.168.160.12"

# MAC addresses (deterministic for DHCP reservations)
CENTRAL_MAC="52:54:00:0a:00:10"
COMPUTE1_MAC="52:54:00:0a:00:11"
COMPUTE2_MAC="52:54:00:0a:00:12"

# --- Tunnel network ---
# Separate network for Geneve tunnel traffic between compute nodes.
# This keeps data-plane traffic isolated from management traffic.
TUNNEL_NET_NAME="${LAB_PREFIX}-tunnel"
TUNNEL_NET_BRIDGE="virbr-${LAB_PREFIX:0:4}t"
TUNNEL_NET_ADDR="10.0.0.0"
TUNNEL_NET_MASK="255.255.255.0"
TUNNEL_NET_GW="10.0.0.1"
TUNNEL_NET_DHCP_START="10.0.0.100"
TUNNEL_NET_DHCP_END="10.0.0.200"

# Tunnel IPs
CENTRAL_TUNNEL_IP="10.0.0.10"
COMPUTE1_TUNNEL_IP="10.0.0.11"
COMPUTE2_TUNNEL_IP="10.0.0.12"

# --- OVN Logical networking ---
# These define the OVN logical network created after VMs are up
OVN_LOGICAL_SWITCH="ls1"
OVN_LOGICAL_SUBNET="172.16.0.0/24"
OVN_LOGICAL_GW="172.16.0.1"
OVN_DHCP_RANGE="172.16.0.10..172.16.0.100"
OVN_DHCP_SERVER_MAC="00:00:00:00:01:00"

# --- SSH ---
SSH_PUBKEY_PATH="${SSH_PUBKEY_PATH:-}"

# --- Timeouts ---
VM_READY_TIMEOUT="${VM_READY_TIMEOUT:-300}"

# ==============================================================================
# Script setup
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ==============================================================================
# Functions
# ==============================================================================

# usage - Print help message and exit
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Set up an OVN lab environment with QEMU/Libvirt/KVM.
Creates 3 VMs: 1 central node + 2 compute nodes with OVN networking.

Options:
  -h, --help          Show this help message and exit
  -m, --memory MiB    Memory per VM in MiB (default: ${VM_MEMORY})
  -c, --cpus NUM      vCPUs per VM (default: ${VM_CPUS})
  -p, --prefix NAME   Lab prefix for resource names (default: ${LAB_PREFIX})
  -i, --image URL     Cloud image URL to use
  -s, --ssh-key PATH  Path to SSH public key to inject into VMs
  --skip-download     Skip image download (assume image exists)

Environment variables:
  LAB_PREFIX          Same as --prefix
  VM_MEMORY           Same as --memory
  VM_CPUS             Same as --cpus
  VM_PASSWORD         Password for lab/root users (default: redhat)
  CLOUD_IMAGE_URL     Same as --image
  STORAGE_POOL_PATH   Path for VM disks (default: /var/lib/libvirt/images)

Examples:
  # Create the lab with defaults
  sudo ./$(basename "$0")

  # Create with more memory and custom prefix
  sudo ./$(basename "$0") -m 4096 -p myovn

EOF
    exit 0
}

# parse_args - Parse command-line arguments
parse_args() {
    local skip_download=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            -m|--memory)
                VM_MEMORY="$2"
                shift 2
                ;;
            -c|--cpus)
                VM_CPUS="$2"
                shift 2
                ;;
            -p|--prefix)
                LAB_PREFIX="$2"
                shift 2
                ;;
            -i|--image)
                CLOUD_IMAGE_URL="$2"
                shift 2
                ;;
            -s|--ssh-key)
                SSH_PUBKEY_PATH="$2"
                shift 2
                ;;
            --skip-download)
                skip_download=true
                shift
                ;;
            *)
                error "Unknown option: $1"
                usage
                ;;
        esac
    done

    # Update derived variables after parsing
    CENTRAL_VM_NAME="${LAB_PREFIX}-central"
    COMPUTE1_VM_NAME="${LAB_PREFIX}-compute1"
    COMPUTE2_VM_NAME="${LAB_PREFIX}-compute2"
    MGMT_NET_NAME="${LAB_PREFIX}-mgmt"
    MGMT_NET_BRIDGE="virbr-${LAB_PREFIX:0:4}m"
    TUNNEL_NET_NAME="${LAB_PREFIX}-tunnel"
    TUNNEL_NET_BRIDGE="virbr-${LAB_PREFIX:0:4}t"
    CLOUD_IMAGE_PATH="${STORAGE_POOL_PATH}/${LAB_PREFIX}-${CLOUD_IMAGE_NAME}"

    SKIP_DOWNLOAD="${skip_download}"
}

# check_root - Ensure script is run as root
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        error "This script must be run as root (sudo)."
        error "Usage: sudo ./$(basename "$0")"
        exit 1
    fi
}

# download_image - Download the cloud image if needed
download_image() {
    header "Downloading cloud image"

    if [[ "${SKIP_DOWNLOAD:-false}" == "true" ]]; then
        if [[ -f "${CLOUD_IMAGE_PATH}" ]]; then
            info "Skipping download as requested. Using existing image."
            return 0
        else
            error "Image not found at ${CLOUD_IMAGE_PATH} and --skip-download was set."
            exit 1
        fi
    fi

    download_cloud_image "${CLOUD_IMAGE_URL}" "${CLOUD_IMAGE_PATH}"
}

# setup_networks - Create the management and tunnel networks
#
# Two networks are created:
#   1. Management network: NAT-based, provides SSH access and carries
#      OVN control-plane traffic (NB/SB database connections)
#   2. Tunnel network: Isolated network for Geneve encapsulated data traffic
#      between compute nodes (the overlay network)
setup_networks() {
    header "Setting up lab networks"

    # --- Management network with DHCP reservations ---
    # We use static DHCP assignments so VMs always get the same IPs.
    # This is important because ovn-controller needs to know the central IP.

    if ! network_exists "${MGMT_NET_NAME}"; then
        info "Creating management network '${MGMT_NET_NAME}' with static DHCP..."

        local tmpfile
        tmpfile="$(mktemp /tmp/net-XXXXXX.xml)"

        cat > "${tmpfile}" <<EOF
<network>
  <name>${MGMT_NET_NAME}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='${MGMT_NET_BRIDGE}' stp='on' delay='0'/>
  <ip address='${MGMT_NET_GW}' netmask='${MGMT_NET_MASK}'>
    <dhcp>
      <range start='${MGMT_NET_DHCP_START}' end='${MGMT_NET_DHCP_END}'/>
      <host mac='${CENTRAL_MAC}' name='${CENTRAL_VM_NAME}' ip='${CENTRAL_IP}'/>
      <host mac='${COMPUTE1_MAC}' name='${COMPUTE1_VM_NAME}' ip='${COMPUTE1_IP}'/>
      <host mac='${COMPUTE2_MAC}' name='${COMPUTE2_VM_NAME}' ip='${COMPUTE2_IP}'/>
    </dhcp>
  </ip>
</network>
EOF

        virsh net-define "${tmpfile}"
        virsh net-start "${MGMT_NET_NAME}"
        virsh net-autostart "${MGMT_NET_NAME}"
        rm -f "${tmpfile}"
        success "Management network created with static DHCP reservations"
    else
        warn "Management network '${MGMT_NET_NAME}' already exists"
        virsh net-start "${MGMT_NET_NAME}" 2>/dev/null || true
    fi

    # --- Tunnel network ---
    # This network carries Geneve-encapsulated traffic between compute nodes.
    # In production, this would typically be a dedicated VLAN or physical network.
    if ! network_exists "${TUNNEL_NET_NAME}"; then
        info "Creating tunnel network '${TUNNEL_NET_NAME}'..."

        local tmpfile
        tmpfile="$(mktemp /tmp/net-XXXXXX.xml)"

        cat > "${tmpfile}" <<EOF
<network>
  <name>${TUNNEL_NET_NAME}</name>
  <bridge name='${TUNNEL_NET_BRIDGE}' stp='on' delay='0'/>
  <ip address='${TUNNEL_NET_GW}' netmask='${TUNNEL_NET_MASK}'>
    <dhcp>
      <range start='${TUNNEL_NET_DHCP_START}' end='${TUNNEL_NET_DHCP_END}'/>
    </dhcp>
  </ip>
</network>
EOF

        virsh net-define "${tmpfile}"
        virsh net-start "${TUNNEL_NET_NAME}"
        virsh net-autostart "${TUNNEL_NET_NAME}"
        rm -f "${tmpfile}"
        success "Tunnel network created"
    else
        warn "Tunnel network '${TUNNEL_NET_NAME}' already exists"
        virsh net-start "${TUNNEL_NET_NAME}" 2>/dev/null || true
    fi
}

# get_ssh_pubkey - Load SSH public key from configured or default location
get_ssh_pubkey() {
    local ssh_pubkey=""

    if [[ -n "${SSH_PUBKEY_PATH}" ]] && [[ -f "${SSH_PUBKEY_PATH}" ]]; then
        ssh_pubkey="$(cat "${SSH_PUBKEY_PATH}")"
    elif [[ -f "${HOME}/.ssh/id_rsa.pub" ]]; then
        ssh_pubkey="$(cat "${HOME}/.ssh/id_rsa.pub")"
    elif [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
        ssh_pubkey="$(cat "${HOME}/.ssh/id_ed25519.pub")"
    fi

    echo "${ssh_pubkey}"
}

# create_central_node - Create and provision the OVN central node
#
# The central node runs:
#   - ovsdb-server for the Northbound database (NB DB)
#   - ovsdb-server for the Southbound database (SB DB)
#   - ovn-northd: translates NB DB logical config into SB DB physical config
#
# This is the brain of the OVN deployment. Compute nodes connect to the
# Southbound database to receive their programming instructions.
create_central_node() {
    header "Creating OVN central node"

    local ssh_pubkey
    ssh_pubkey="$(get_ssh_pubkey)"

    local ci_iso="${STORAGE_POOL_PATH}/${CENTRAL_VM_NAME}-cidata.iso"

    # --- Central node cloud-init runcmd ---
    # Install OVN central packages, configure and start services, and
    # open the SB database to listen on all interfaces so compute nodes
    # can connect.
    local extra_packages="ovn-central ovn-host"
    local extra_runcmd
    extra_runcmd=$(cat <<'RUNCMD'
  # ---- OVN Central Setup ----
  # Enable and start the OVN central services.
  # ovn-central includes ovn-northd and the NB/SB ovsdb-server instances.
  - systemctl enable --now ovn-central

  # Configure the Northbound database to listen on TCP port 6641
  # so it can be managed remotely (useful for ovn-nbctl from other hosts)
  - ovn-nbctl set-connection ptcp:6641:0.0.0.0

  # Configure the Southbound database to listen on TCP port 6642
  # This is critical: compute nodes' ovn-controller connects here
  - ovn-sbctl set-connection ptcp:6642:0.0.0.0

  # Set the OVS external-ids that OVN uses to identify this node
  # system-id: unique identifier for this chassis
  # ovn-remote: where ovn-controller connects (this is the central node itself)
  # ovn-encap-type: tunnel encapsulation type (geneve is the OVN default)
  # ovn-encap-ip: IP address used as the tunnel endpoint
  - ovs-vsctl set open_vswitch . external_ids:system-id=central
  - ovs-vsctl set open_vswitch . external_ids:ovn-remote=unix:/var/run/ovn/ovnsb_db.sock
  - ovs-vsctl set open_vswitch . external_ids:ovn-encap-type=geneve
  - ovs-vsctl set open_vswitch . external_ids:ovn-encap-ip=10.0.0.10
  - ovs-vsctl set open_vswitch . external_ids:hostname=ovnlab-central

  # Start ovn-controller on the central node as well (optional, but useful
  # for testing - allows creating ports on the central node too)
  - systemctl enable --now ovn-controller

  # Add OVN aliases for convenience
  - echo "alias nb='sudo ovn-nbctl'" >> /home/lab/.bashrc
  - echo "alias sb='sudo ovn-sbctl'" >> /home/lab/.bashrc
  - echo "alias ovs='sudo ovs-vsctl'" >> /home/lab/.bashrc
  - echo "alias trace='sudo ovn-trace'" >> /home/lab/.bashrc
  - echo "alias flows='sudo ovs-ofctl dump-flows br-int'" >> /home/lab/.bashrc
RUNCMD
)

    # Network config for static tunnel IP
    local network_config
    network_config=$(cat <<EOF
version: 2
ethernets:
  eth0:
    dhcp4: true
  eth1:
    addresses:
      - ${CENTRAL_TUNNEL_IP}/24
EOF
)

    # Generate cloud-init ISO
    create_cloud_init_iso \
        "${ci_iso}" \
        "${CENTRAL_VM_NAME}" \
        "${VM_PASSWORD}" \
        "${ssh_pubkey}" \
        "${extra_packages}" \
        "${extra_runcmd}" \
        "${network_config}"

    # Network: management + tunnel
    local net_args="--network network=${MGMT_NET_NAME},model=virtio,mac=${CENTRAL_MAC}"
    net_args="${net_args} --network network=${TUNNEL_NET_NAME},model=virtio"

    create_vm \
        "${CENTRAL_VM_NAME}" \
        "${CLOUD_IMAGE_PATH}" \
        "${ci_iso}" \
        "${VM_MEMORY}" \
        "${VM_CPUS}" \
        "${VM_DISK_SIZE}" \
        "${net_args}" \
        "${STORAGE_POOL_PATH}"
}

# create_compute_node - Create and provision a compute node
#
# Each compute node runs:
#   - openvswitch: the local OVS instance that handles actual packet forwarding
#   - ovn-controller: connects to the central SB database, programs the local
#     OVS with flows based on the logical network configuration
#
# Arguments:
#   $1 - VM name
#   $2 - MAC address for management interface
#   $3 - System ID for OVN (must be unique per chassis)
#   $4 - Tunnel IP for this compute node
create_compute_node() {
    local vm_name="$1"
    local mac="$2"
    local system_id="$3"
    local tunnel_ip="$4"

    info "Creating compute node: ${vm_name} (system-id: ${system_id})"

    local ssh_pubkey
    ssh_pubkey="$(get_ssh_pubkey)"

    local ci_iso="${STORAGE_POOL_PATH}/${vm_name}-cidata.iso"

    # --- Compute node cloud-init runcmd ---
    # Install ovn-host (provides ovn-controller), then configure it to
    # connect to the central node's Southbound database.
    local extra_packages="ovn-host"
    local extra_runcmd
    extra_runcmd=$(cat <<RUNCMD
  # ---- OVN Compute Node Setup ----

  # Set OVS external-ids that ovn-controller uses:
  # system-id: unique chassis identifier (must be unique across all nodes)
  # ovn-remote: TCP connection to the central Southbound database
  # ovn-encap-type: geneve tunneling (OVN's default and recommended)
  # ovn-encap-ip: this node's IP on the tunnel network
  - ovs-vsctl set open_vswitch . external_ids:system-id=${system_id}
  - ovs-vsctl set open_vswitch . external_ids:ovn-remote=tcp:${CENTRAL_IP}:6642
  - ovs-vsctl set open_vswitch . external_ids:ovn-encap-type=geneve
  - ovs-vsctl set open_vswitch . external_ids:ovn-encap-ip=${tunnel_ip}
  - ovs-vsctl set open_vswitch . external_ids:hostname=${vm_name}

  # Enable and start ovn-controller
  # ovn-controller will:
  #   1. Connect to the SB database at ${CENTRAL_IP}:6642
  #   2. Register this chassis
  #   3. Monitor for logical port bindings assigned to this chassis
  #   4. Program the local OVS with appropriate flows
  - systemctl enable --now ovn-controller

  # Add OVN/OVS aliases for convenience
  - echo "alias ovs='sudo ovs-vsctl'" >> /home/lab/.bashrc
  - echo "alias flows='sudo ovs-ofctl dump-flows br-int'" >> /home/lab/.bashrc
  - echo "alias nb='sudo ovn-nbctl --db=tcp:${CENTRAL_IP}:6641'" >> /home/lab/.bashrc
  - echo "alias sb='sudo ovn-sbctl --db=tcp:${CENTRAL_IP}:6642'" >> /home/lab/.bashrc
RUNCMD
)

    # Network config for static tunnel IP
    local network_config
    network_config=$(cat <<EOF
version: 2
ethernets:
  eth0:
    dhcp4: true
  eth1:
    addresses:
      - ${tunnel_ip}/24
EOF
)

    # Generate cloud-init ISO
    create_cloud_init_iso \
        "${ci_iso}" \
        "${vm_name}" \
        "${VM_PASSWORD}" \
        "${ssh_pubkey}" \
        "${extra_packages}" \
        "${extra_runcmd}" \
        "${network_config}"

    # Network: management + tunnel
    local net_args="--network network=${MGMT_NET_NAME},model=virtio,mac=${mac}"
    net_args="${net_args} --network network=${TUNNEL_NET_NAME},model=virtio"

    create_vm \
        "${vm_name}" \
        "${CLOUD_IMAGE_PATH}" \
        "${ci_iso}" \
        "${VM_MEMORY}" \
        "${VM_CPUS}" \
        "${VM_DISK_SIZE}" \
        "${net_args}" \
        "${STORAGE_POOL_PATH}"
}

# wait_for_all_vms - Wait for all 3 VMs to be accessible
wait_for_all_vms() {
    header "Waiting for all VMs to become ready"

    info "This may take several minutes while cloud-init installs OVN packages..."
    echo ""

    local vms=("${CENTRAL_VM_NAME}" "${COMPUTE1_VM_NAME}" "${COMPUTE2_VM_NAME}")

    for vm in "${vms[@]}"; do
        wait_for_vm_ready "${vm}" "${MGMT_NET_NAME}" "${VM_READY_TIMEOUT}" || \
            warn "VM '${vm}' may not be fully ready. Try 'virsh console ${vm}'"
    done
}

# run_on_vm - Execute a command on a VM via SSH
# Arguments:
#   $1 - VM IP address
#   $2 - Command to execute
run_on_vm() {
    local ip="$1"
    local cmd="$2"

    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o BatchMode=yes \
        "lab@${ip}" "sudo ${cmd}" 2>/dev/null
}

# configure_ovn_logical_network - Set up OVN logical networking
#
# This function connects to the central node and configures the OVN
# logical network. It creates:
#
#   1. A logical switch (ls1) - virtual L2 segment
#   2. Logical switch ports - one per compute node
#   3. DHCP options - for automatic IP assignment
#
# After this, workloads on compute nodes can communicate through the
# OVN overlay network (Geneve tunnels) without any physical network
# configuration between them.
configure_ovn_logical_network() {
    header "Configuring OVN logical network"

    info "Connecting to central node at ${CENTRAL_IP} to configure OVN..."

    # --- Verify OVN central is running ---
    info "Verifying OVN central services are running..."
    if ! run_on_vm "${CENTRAL_IP}" "ovn-nbctl --timeout=5 show" &>/dev/null; then
        warn "OVN NB database not yet ready, waiting..."
        sleep 30
        if ! run_on_vm "${CENTRAL_IP}" "ovn-nbctl --timeout=10 show"; then
            error "Cannot connect to OVN NB database. Check central node."
            return 1
        fi
    fi
    success "OVN central services are running"

    # --- Create logical switch ---
    # A logical switch is OVN's virtual L2 domain. Ports on the same
    # logical switch can communicate at L2, regardless of which physical
    # (compute) node they are on. OVN handles the encapsulation.
    info "Creating logical switch '${OVN_LOGICAL_SWITCH}'..."
    run_on_vm "${CENTRAL_IP}" "ovn-nbctl --may-exist ls-add ${OVN_LOGICAL_SWITCH}"
    success "Logical switch '${OVN_LOGICAL_SWITCH}' created"

    # --- Set up DHCP options ---
    # OVN can provide native DHCP for logical ports, eliminating the need
    # for a separate DHCP server. The DHCP options are associated with
    # the logical switch's subnet.
    info "Configuring DHCP for subnet ${OVN_LOGICAL_SUBNET}..."

    local dhcp_options_uuid
    dhcp_options_uuid="$(run_on_vm "${CENTRAL_IP}" \
        "ovn-nbctl create dhcp_options cidr=${OVN_LOGICAL_SUBNET} \
        options='\"server_id\"=\"${OVN_LOGICAL_GW}\" \"server_mac\"=\"${OVN_DHCP_SERVER_MAC}\" \
        \"lease_time\"=\"3600\" \"router\"=\"${OVN_LOGICAL_GW}\"'")" || true

    if [[ -n "${dhcp_options_uuid}" ]]; then
        success "DHCP options created (UUID: ${dhcp_options_uuid})"
    else
        warn "DHCP options may already exist or failed to create"
    fi

    # --- Create logical switch ports for compute nodes ---
    # Each compute node gets a logical port on the switch. The port's
    # MAC and IP are statically assigned. In production (e.g., OpenStack),
    # these would be created dynamically by the CMS (Cloud Management System).

    info "Creating logical switch ports..."

    # Port for compute node 1
    local lsp1="${OVN_LOGICAL_SWITCH}-port1"
    local lsp1_mac="00:00:00:00:00:01"
    local lsp1_ip="172.16.0.11"

    run_on_vm "${CENTRAL_IP}" "ovn-nbctl --may-exist lsp-add ${OVN_LOGICAL_SWITCH} ${lsp1}"
    run_on_vm "${CENTRAL_IP}" "ovn-nbctl lsp-set-addresses ${lsp1} '${lsp1_mac} ${lsp1_ip}'"
    run_on_vm "${CENTRAL_IP}" "ovn-nbctl lsp-set-port-security ${lsp1} '${lsp1_mac} ${lsp1_ip}'"
    if [[ -n "${dhcp_options_uuid}" ]]; then
        run_on_vm "${CENTRAL_IP}" "ovn-nbctl lsp-set-dhcpv4-options ${lsp1} ${dhcp_options_uuid}" || true
    fi
    success "Port '${lsp1}' created (MAC: ${lsp1_mac}, IP: ${lsp1_ip})"

    # Port for compute node 2
    local lsp2="${OVN_LOGICAL_SWITCH}-port2"
    local lsp2_mac="00:00:00:00:00:02"
    local lsp2_ip="172.16.0.12"

    run_on_vm "${CENTRAL_IP}" "ovn-nbctl --may-exist lsp-add ${OVN_LOGICAL_SWITCH} ${lsp2}"
    run_on_vm "${CENTRAL_IP}" "ovn-nbctl lsp-set-addresses ${lsp2} '${lsp2_mac} ${lsp2_ip}'"
    run_on_vm "${CENTRAL_IP}" "ovn-nbctl lsp-set-port-security ${lsp2} '${lsp2_mac} ${lsp2_ip}'"
    if [[ -n "${dhcp_options_uuid}" ]]; then
        run_on_vm "${CENTRAL_IP}" "ovn-nbctl lsp-set-dhcpv4-options ${lsp2} ${dhcp_options_uuid}" || true
    fi
    success "Port '${lsp2}' created (MAC: ${lsp2_mac}, IP: ${lsp2_ip})"

    # --- Bind ports to compute nodes ---
    # Create OVS internal ports on each compute node and set the
    # iface-id to match the logical port name. ovn-controller uses
    # iface-id to bind the logical port to the physical port.

    info "Binding logical ports to compute nodes..."

    # On compute1: create an OVS port with iface-id matching the logical port
    run_on_vm "${COMPUTE1_IP}" \
        "ovs-vsctl --may-exist add-port br-int ${lsp1} -- \
        set interface ${lsp1} type=internal -- \
        set interface ${lsp1} external_ids:iface-id=${lsp1}"
    run_on_vm "${COMPUTE1_IP}" \
        "ip link set ${lsp1} address ${lsp1_mac} && \
         ip addr add ${lsp1_ip}/24 dev ${lsp1} && \
         ip link set ${lsp1} up" || true
    success "Port '${lsp1}' bound to ${COMPUTE1_VM_NAME}"

    # On compute2: same process
    run_on_vm "${COMPUTE2_IP}" \
        "ovs-vsctl --may-exist add-port br-int ${lsp2} -- \
        set interface ${lsp2} type=internal -- \
        set interface ${lsp2} external_ids:iface-id=${lsp2}"
    run_on_vm "${COMPUTE2_IP}" \
        "ip link set ${lsp2} address ${lsp2_mac} && \
         ip addr add ${lsp2_ip}/24 dev ${lsp2} && \
         ip link set ${lsp2} up" || true
    success "Port '${lsp2}' bound to ${COMPUTE2_VM_NAME}"

    # --- Show the OVN configuration ---
    separator
    info "OVN Northbound database state:"
    run_on_vm "${CENTRAL_IP}" "ovn-nbctl show" || true
    separator
    info "OVN Southbound database - chassis list:"
    run_on_vm "${CENTRAL_IP}" "ovn-sbctl show" || true
    separator
}

# print_summary - Print a summary of the OVN lab environment
print_summary() {
    header "OVN Lab Environment - Summary"

    # --- VMs ---
    echo -e "${COLOR_BOLD}Virtual Machines:${COLOR_RESET}"
    echo ""
    print_table_row "NAME" "IP ADDRESS" "ROLE"
    print_table_row "----" "----------" "----"
    print_table_row "${CENTRAL_VM_NAME}" "${CENTRAL_IP}" "OVN Central (northd + NB/SB DBs)"
    print_table_row "${COMPUTE1_VM_NAME}" "${COMPUTE1_IP}" "Compute (ovn-controller)"
    print_table_row "${COMPUTE2_VM_NAME}" "${COMPUTE2_IP}" "Compute (ovn-controller)"
    echo ""

    # --- Networks ---
    echo -e "${COLOR_BOLD}Networks:${COLOR_RESET}"
    echo ""
    echo "  Management: ${MGMT_NET_NAME} (${MGMT_NET_GW}/${MGMT_NET_MASK})"
    echo "    Used for: SSH access, OVN control-plane (NB/SB DB connections)"
    echo ""
    echo "  Tunnel:     ${TUNNEL_NET_NAME} (${TUNNEL_NET_GW}/${TUNNEL_NET_MASK})"
    echo "    Used for: Geneve tunnel traffic between compute nodes"
    echo ""

    # --- OVN Logical Network ---
    echo -e "${COLOR_BOLD}OVN Logical Network:${COLOR_RESET}"
    echo ""
    echo "  Logical Switch: ${OVN_LOGICAL_SWITCH}"
    echo "  Subnet:         ${OVN_LOGICAL_SUBNET}"
    echo "  DHCP:           Enabled"
    echo ""
    echo "  Logical Ports:"
    echo "    ${OVN_LOGICAL_SWITCH}-port1 -> ${COMPUTE1_VM_NAME} (172.16.0.11)"
    echo "    ${OVN_LOGICAL_SWITCH}-port2 -> ${COMPUTE2_VM_NAME} (172.16.0.12)"
    echo ""

    # --- OVN Services ---
    echo -e "${COLOR_BOLD}OVN Services:${COLOR_RESET}"
    echo ""
    echo "  Northbound DB:  tcp:${CENTRAL_IP}:6641"
    echo "  Southbound DB:  tcp:${CENTRAL_IP}:6642"
    echo "  ovn-northd:     running on ${CENTRAL_VM_NAME}"
    echo "  ovn-controller: running on all nodes"
    echo ""

    # --- Access ---
    echo -e "${COLOR_BOLD}Accessing the VMs:${COLOR_RESET}"
    echo ""
    echo "  Console: virsh console ${CENTRAL_VM_NAME}"
    echo "  SSH:     ssh lab@${CENTRAL_IP}"
    echo "  Password: ${VM_PASSWORD}"
    echo ""

    # --- Quick start ---
    echo -e "${COLOR_BOLD}Quick Start - Try These Commands:${COLOR_RESET}"
    echo ""
    echo "  On the central node (${CENTRAL_IP}):"
    echo "    sudo ovn-nbctl show                       # Show logical topology"
    echo "    sudo ovn-nbctl list logical_switch         # List logical switches"
    echo "    sudo ovn-nbctl list logical_switch_port    # List logical ports"
    echo "    sudo ovn-sbctl show                        # Show chassis and bindings"
    echo "    sudo ovn-sbctl lflow-list ${OVN_LOGICAL_SWITCH}  # Show logical flows"
    echo ""
    echo "  On a compute node (${COMPUTE1_IP}):"
    echo "    sudo ovs-vsctl show                       # Show local OVS config"
    echo "    sudo ovs-ofctl dump-flows br-int          # Show physical flows"
    echo "    sudo ovn-trace --db=tcp:${CENTRAL_IP}:6642 ${OVN_LOGICAL_SWITCH} \\  "
    echo "      'inport==\"${OVN_LOGICAL_SWITCH}-port1\" && eth.src==00:00:00:00:00:01 \\  "
    echo "      && eth.dst==00:00:00:00:00:02 && ip4.src==172.16.0.11 \\  "
    echo "      && ip4.dst==172.16.0.12'"
    echo ""
    echo "  Test connectivity between compute nodes:"
    echo "    # From compute1: ping 172.16.0.12"
    echo "    # From compute2: ping 172.16.0.11"
    echo ""

    # --- Cleanup ---
    echo -e "${COLOR_BOLD}Cleanup:${COLOR_RESET}"
    echo ""
    echo "  To tear down this lab:"
    echo "    sudo ${SCRIPT_DIR}/teardown.sh -p ${LAB_PREFIX}"
    echo ""

    separator
    success "OVN lab environment is ready!"
}

# ==============================================================================
# Main execution
# ==============================================================================

main() {
    parse_args "$@"

    header "OVN Lab Setup"
    info "Lab prefix:  ${LAB_PREFIX}"
    info "Central:     ${CENTRAL_VM_NAME} (${CENTRAL_IP})"
    info "Compute 1:   ${COMPUTE1_VM_NAME} (${COMPUTE1_IP})"
    info "Compute 2:   ${COMPUTE2_VM_NAME} (${COMPUTE2_IP})"
    info "Memory/VM:   ${VM_MEMORY} MiB"
    info "vCPUs/VM:    ${VM_CPUS}"
    info "Image:       ${CLOUD_IMAGE_URL}"

    # Step 1: Verify prerequisites
    check_root
    check_prerequisites "ovn"

    # Step 2: Download cloud image
    download_image

    # Step 3: Create management and tunnel networks
    setup_networks

    # Step 4: Create the central node (OVN northd + databases)
    create_central_node

    # Step 5: Create compute nodes (ovn-controller)
    create_compute_node \
        "${COMPUTE1_VM_NAME}" \
        "${COMPUTE1_MAC}" \
        "compute1" \
        "${COMPUTE1_TUNNEL_IP}"

    create_compute_node \
        "${COMPUTE2_VM_NAME}" \
        "${COMPUTE2_MAC}" \
        "compute2" \
        "${COMPUTE2_TUNNEL_IP}"

    # Step 6: Wait for all VMs to finish booting
    wait_for_all_vms

    # Step 7: Configure OVN logical networking
    configure_ovn_logical_network

    # Step 8: Print summary
    print_summary
}

main "$@"
