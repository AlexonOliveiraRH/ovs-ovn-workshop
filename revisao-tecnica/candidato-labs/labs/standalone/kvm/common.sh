#!/bin/bash
# ==============================================================================
# common.sh - Shared library for OVS/OVN lab automation scripts
# ==============================================================================
#
# Description:
#   Provides reusable functions for the OVS and OVN lab setup and teardown
#   scripts. This file is sourced by the other scripts and should not be
#   executed directly.
#
# Functions provided:
#   - Color output:    info, warn, error, success, header, separator
#   - Prerequisites:   check_command, check_service, check_prerequisites
#   - VM management:   create_cloud_init_iso, create_vm, wait_for_vm_ready,
#                      get_vm_ip, vm_exists, vm_is_running
#   - OVS helpers:     ovs_bridge_exists, create_ovs_bridge, delete_ovs_bridge,
#                      add_ovs_port, ovs_run
#   - OVN helpers:     ovn_nbctl, ovn_sbctl, ovn_run_on_central
#   - Network helpers: create_libvirt_network, delete_libvirt_network,
#                      network_exists
#   - Utilities:       cleanup_temp_files, generate_mac_address,
#                      wait_for_condition, confirm_action
#
# Usage:
#   Source this file from another script:
#     SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#     source "${SCRIPT_DIR}/common.sh"
#
# ==============================================================================

# Guard against direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: This file should be sourced, not executed directly."
    echo "Usage: source ${BASH_SOURCE[0]}"
    exit 1
fi

# ==============================================================================
# Color and output formatting
# ==============================================================================

# Define colors only if stdout is a terminal
if [[ -t 1 ]]; then
    readonly COLOR_RED='\033[0;31m'
    readonly COLOR_GREEN='\033[0;32m'
    readonly COLOR_YELLOW='\033[0;33m'
    readonly COLOR_BLUE='\033[0;34m'
    readonly COLOR_MAGENTA='\033[0;35m'
    readonly COLOR_CYAN='\033[0;36m'
    readonly COLOR_WHITE='\033[1;37m'
    readonly COLOR_RESET='\033[0m'
    readonly COLOR_BOLD='\033[1m'
else
    readonly COLOR_RED=''
    readonly COLOR_GREEN=''
    readonly COLOR_YELLOW=''
    readonly COLOR_BLUE=''
    readonly COLOR_MAGENTA=''
    readonly COLOR_CYAN=''
    readonly COLOR_WHITE=''
    readonly COLOR_RESET=''
    readonly COLOR_BOLD=''
fi

# info - Print an informational message in blue
# Usage: info "Installing packages..."
info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"
}

# warn - Print a warning message in yellow
# Usage: warn "VM already exists, skipping creation"
warn() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"
}

# error - Print an error message in red to stderr
# Usage: error "Failed to create VM"
error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

# success - Print a success message in green
# Usage: success "VM created successfully"
success() {
    echo -e "${COLOR_GREEN}[OK]${COLOR_RESET} $*"
}

# header - Print a section header with decoration
# Usage: header "Setting up OVS bridges"
header() {
    echo ""
    echo -e "${COLOR_BOLD}${COLOR_CYAN}================================================================${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_CYAN}  $*${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_CYAN}================================================================${COLOR_RESET}"
    echo ""
}

# separator - Print a thin separator line
# Usage: separator
separator() {
    echo -e "${COLOR_CYAN}----------------------------------------------------------------${COLOR_RESET}"
}

# ==============================================================================
# Prerequisite checking functions
# ==============================================================================

# check_command - Verify that a command is available in PATH
# Arguments:
#   $1 - Command name to check
#   $2 - (Optional) Package name that provides the command
# Returns: 0 if found, 1 if not
check_command() {
    local cmd="$1"
    local pkg="${2:-$1}"

    if command -v "${cmd}" &>/dev/null; then
        success "Command '${cmd}' is available"
        return 0
    else
        error "Command '${cmd}' not found. Install it with: sudo dnf install ${pkg}"
        return 1
    fi
}

# check_service - Verify that a systemd service is active
# Arguments:
#   $1 - Service name
# Returns: 0 if active, 1 if not
check_service() {
    local service="$1"

    if systemctl is-active --quiet "${service}" 2>/dev/null; then
        success "Service '${service}' is active"
        return 0
    else
        error "Service '${service}' is not active. Start it with: sudo systemctl enable --now ${service}"
        return 1
    fi
}

# check_prerequisites - Verify all required commands and services are present
# Arguments:
#   $1 - Lab type: "ovs" or "ovn" (determines which packages to check)
# Returns: 0 if all prerequisites met, exits with 1 otherwise
check_prerequisites() {
    local lab_type="${1:-ovs}"
    local failed=0

    header "Checking prerequisites"

    # --- Core virtualization commands ---
    info "Checking virtualization tools..."
    check_command "virsh" "libvirt-client" || ((failed++))
    check_command "virt-install" "virt-install" || ((failed++))
    check_command "qemu-img" "qemu-img" || ((failed++))
    check_command "genisoimage" "genisoimage" || ((failed++))

    # --- Core services ---
    info "Checking required services..."
    check_service "libvirtd" || ((failed++))

    # --- OVS commands (needed for both OVS and OVN labs) ---
    info "Checking Open vSwitch tools..."
    check_command "ovs-vsctl" "openvswitch" || ((failed++))
    check_service "openvswitch" || ((failed++))

    # --- OVN commands (only for OVN lab) ---
    if [[ "${lab_type}" == "ovn" ]]; then
        info "Checking OVN tools..."
        check_command "ovn-nbctl" "ovn-central" || ((failed++))
        check_command "ovn-sbctl" "ovn-central" || ((failed++))
    fi

    # --- Optional but recommended tools ---
    info "Checking optional tools..."
    check_command "wget" "wget" || warn "wget not found - will try curl instead"
    check_command "ssh" "openssh-clients" || warn "ssh not found - VM access will be limited"

    # --- Check if user can manage VMs ---
    info "Checking permissions..."
    if [[ "$(id -u)" -ne 0 ]] && ! groups | grep -qw libvirt; then
        warn "Current user is not in the 'libvirt' group. You may need to run with sudo."
    fi

    if [[ "${failed}" -gt 0 ]]; then
        error "${failed} prerequisite(s) not met. Please install missing packages and try again."
        exit 1
    fi

    success "All prerequisites satisfied"
}

# ==============================================================================
# Cloud-init ISO generation
# ==============================================================================

# create_cloud_init_iso - Generate a cloud-init NoCloud ISO for VM provisioning
#
# This creates a small ISO image containing user-data and meta-data files
# that cloud images consume on first boot to configure the VM (set passwords,
# install packages, run commands, etc).
#
# Arguments:
#   $1 - Output ISO path (e.g., /var/lib/libvirt/images/vm1-cidata.iso)
#   $2 - VM hostname
#   $3 - Password for the default user (plaintext, will be hashed by cloud-init)
#   $4 - SSH public key (optional, pass "" to skip)
#   $5 - Additional packages to install (space-separated, optional)
#   $6 - Additional runcmd lines (newline-separated YAML, optional)
#   $7 - Network config YAML (optional, for static IP configuration)
#
# Returns: 0 on success, 1 on failure
create_cloud_init_iso() {
    local iso_path="$1"
    local hostname="$2"
    local password="$3"
    local ssh_pubkey="${4:-}"
    local extra_packages="${5:-}"
    local extra_runcmd="${6:-}"
    local network_config="${7:-}"

    local tmpdir
    tmpdir="$(mktemp -d /tmp/cloud-init-XXXXXX)"

    info "Generating cloud-init ISO for '${hostname}' at ${iso_path}"

    # --- Build the meta-data file ---
    # meta-data provides instance identity information
    cat > "${tmpdir}/meta-data" <<EOF
instance-id: ${hostname}
local-hostname: ${hostname}
EOF

    # --- Build the user-data file ---
    # user-data configures the VM on first boot: users, packages, commands
    cat > "${tmpdir}/user-data" <<EOF
#cloud-config

# Set the hostname
hostname: ${hostname}
fqdn: ${hostname}.lab.local
manage_etc_hosts: true

# Configure the default user
user: lab
password: ${password}
chpasswd:
  expire: false
ssh_pwauth: true

# Also set root password for console access
users:
  - name: lab
    plain_text_passwd: ${password}
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: wheel
  - name: root
    plain_text_passwd: ${password}
    lock_passwd: false

# Install packages
packages:
  - openvswitch
  - tcpdump
  - iperf3
  - traceroute
  - bridge-utils
  - net-tools
  - iproute
  - iputils
  - lldpad
  - vim
  - bash-completion
EOF

    # Append extra packages if provided
    if [[ -n "${extra_packages}" ]]; then
        for pkg in ${extra_packages}; do
            echo "  - ${pkg}" >> "${tmpdir}/user-data"
        done
    fi

    # --- SSH authorized keys ---
    if [[ -n "${ssh_pubkey}" ]]; then
        cat >> "${tmpdir}/user-data" <<EOF

ssh_authorized_keys:
  - ${ssh_pubkey}
EOF
    fi

    # --- Commands to run on first boot ---
    cat >> "${tmpdir}/user-data" <<EOF

# Commands to run after boot
runcmd:
  # Enable and start Open vSwitch
  - systemctl enable --now openvswitch

  # Disable firewalld to simplify lab networking (not for production!)
  - systemctl disable --now firewalld || true

  # Set SELinux to permissive for lab purposes
  - setenforce 0 || true
  - sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config || true
EOF

    # Append extra runcmd lines if provided
    if [[ -n "${extra_runcmd}" ]]; then
        echo "${extra_runcmd}" >> "${tmpdir}/user-data"
    fi

    # Final boot status marker so we can detect when cloud-init finishes
    cat >> "${tmpdir}/user-data" <<EOF

  # Signal that cloud-init setup is complete
  - touch /var/lib/cloud/instance/boot-finished-signal

# Write a file indicating cloud-init is done (belt and suspenders)
write_files:
  - path: /etc/motd
    content: |
      =============================================
       ${hostname} - OVS/OVN Lab VM
       User: lab / Password: (as configured)
       This VM is part of the OVS/OVN workshop lab.
      =============================================

# Phone home is disabled - this is a standalone lab
phone_home:
  url: ""
  post: []

# Power state: do not reboot after cloud-init
power_state:
  mode: reboot
  condition: false
EOF

    # --- Build the network-config file (optional) ---
    if [[ -n "${network_config}" ]]; then
        echo "${network_config}" > "${tmpdir}/network-config"
    fi

    # --- Generate the ISO image ---
    # genisoimage creates an ISO 9660 filesystem labeled 'cidata' which is
    # the magic label that cloud images look for on boot
    local genisoimage_args=(-output "${iso_path}" -volid cidata -joliet -rock)
    genisoimage_args+=("${tmpdir}/user-data" "${tmpdir}/meta-data")
    if [[ -f "${tmpdir}/network-config" ]]; then
        genisoimage_args+=("${tmpdir}/network-config")
    fi

    if ! genisoimage "${genisoimage_args[@]}" &>/dev/null; then
        error "Failed to create cloud-init ISO at ${iso_path}"
        rm -rf "${tmpdir}"
        return 1
    fi

    # Clean up temporary directory
    rm -rf "${tmpdir}"
    success "Cloud-init ISO created: ${iso_path}"
    return 0
}

# ==============================================================================
# VM management functions
# ==============================================================================

# vm_exists - Check if a libvirt VM (domain) exists
# Arguments:
#   $1 - VM name
# Returns: 0 if exists, 1 if not
vm_exists() {
    local vm_name="$1"
    virsh dominfo "${vm_name}" &>/dev/null
}

# vm_is_running - Check if a VM is in the running state
# Arguments:
#   $1 - VM name
# Returns: 0 if running, 1 if not
vm_is_running() {
    local vm_name="$1"
    local state
    state="$(virsh domstate "${vm_name}" 2>/dev/null)" || return 1
    [[ "${state}" == "running" ]]
}

# create_vm - Create and start a new VM using virt-install
#
# Creates a VM from a cloud image (qcow2), attaching a cloud-init ISO for
# provisioning. The VM disk is created as a copy-on-write overlay on top of
# the base image so multiple VMs can share the same base.
#
# Arguments:
#   $1 - VM name
#   $2 - Base cloud image path (qcow2)
#   $3 - Cloud-init ISO path
#   $4 - Memory in MiB (e.g., 2048)
#   $5 - Number of vCPUs (e.g., 2)
#   $6 - Disk size (e.g., 20G)
#   $7 - Network arguments for virt-install (e.g., "--network network=default")
#   $8 - Storage pool path (e.g., /var/lib/libvirt/images)
#
# Returns: 0 on success, 1 on failure
create_vm() {
    local vm_name="$1"
    local base_image="$2"
    local ci_iso="$3"
    local memory="$4"
    local vcpus="$5"
    local disk_size="$6"
    local net_args="$7"
    local pool_path="$8"

    local vm_disk="${pool_path}/${vm_name}.qcow2"

    # --- Check if VM already exists ---
    if vm_exists "${vm_name}"; then
        warn "VM '${vm_name}' already exists, skipping creation"
        if ! vm_is_running "${vm_name}"; then
            info "Starting existing VM '${vm_name}'..."
            virsh start "${vm_name}" 2>/dev/null || true
        fi
        return 0
    fi

    info "Creating VM '${vm_name}' (${memory}MiB RAM, ${vcpus} vCPUs, ${disk_size} disk)"

    # --- Create the VM disk as a CoW overlay on the base image ---
    # This is efficient: each VM only stores its differences from the base
    if [[ ! -f "${vm_disk}" ]]; then
        info "Creating disk overlay: ${vm_disk}"
        qemu-img create -f qcow2 -F qcow2 -b "${base_image}" "${vm_disk}" "${disk_size}"
    fi

    # --- Install the VM ---
    # --import: skip installation, boot directly from the disk
    # --cloud-init: not used here because we manually provide the ISO for flexibility
    # --noautoconsole: return immediately instead of opening a console
    # --os-variant: helps virt-install optimize VM settings
    #
    # shellcheck disable=SC2086
    virt-install \
        --name "${vm_name}" \
        --memory "${memory}" \
        --vcpus "${vcpus}" \
        --disk "path=${vm_disk},format=qcow2" \
        --disk "path=${ci_iso},device=cdrom" \
        --import \
        --os-variant rhel9-unknown \
        ${net_args} \
        --graphics none \
        --console pty,target_type=serial \
        --noautoconsole \
        --quiet

    if [[ $? -ne 0 ]]; then
        error "Failed to create VM '${vm_name}'"
        return 1
    fi

    success "VM '${vm_name}' created and starting"
    return 0
}

# get_vm_ip - Retrieve the IP address of a running VM
#
# Queries libvirt's DHCP leases or the ARP table to find the VM's IP address.
# Tries multiple methods since cloud images may take a moment to obtain an IP.
#
# Arguments:
#   $1 - VM name
#   $2 - Network name (default: "default")
#   $3 - Timeout in seconds (default: 120)
#
# Returns: 0 on success (prints IP to stdout), 1 on failure
get_vm_ip() {
    local vm_name="$1"
    local network="${2:-default}"
    local timeout="${3:-120}"
    local ip=""
    local elapsed=0

    while [[ ${elapsed} -lt ${timeout} ]]; do
        # Method 1: Query libvirt's DHCP leases via domifaddr
        ip="$(virsh domifaddr "${vm_name}" --source agent 2>/dev/null \
            | grep -oP '(\d{1,3}\.){3}\d{1,3}' | head -1)" || true

        # Method 2: Fall back to lease-based lookup
        if [[ -z "${ip}" ]]; then
            ip="$(virsh domifaddr "${vm_name}" 2>/dev/null \
                | grep -oP '(\d{1,3}\.){3}\d{1,3}' | head -1)" || true
        fi

        # Method 3: Fall back to network DHCP leases
        if [[ -z "${ip}" ]]; then
            local mac
            mac="$(virsh domiflist "${vm_name}" 2>/dev/null \
                | awk 'NR>2 && NF>0 {print $5}' | head -1)" || true
            if [[ -n "${mac}" ]]; then
                ip="$(virsh net-dhcp-leases "${network}" 2>/dev/null \
                    | grep "${mac}" | grep -oP '(\d{1,3}\.){3}\d{1,3}' | head -1)" || true
            fi
        fi

        if [[ -n "${ip}" ]]; then
            echo "${ip}"
            return 0
        fi

        sleep 5
        ((elapsed += 5))
    done

    error "Could not determine IP for VM '${vm_name}' within ${timeout}s"
    return 1
}

# wait_for_vm_ready - Wait until a VM is fully booted and SSH is accessible
#
# Polls the VM's SSH port until it responds, indicating that the VM has
# finished booting and network is configured. This is essential because
# cloud-init may take a minute or more to complete.
#
# Arguments:
#   $1 - VM name
#   $2 - Network name for IP lookup (default: "default")
#   $3 - Timeout in seconds (default: 300)
#
# Returns: 0 if VM is ready, 1 on timeout
wait_for_vm_ready() {
    local vm_name="$1"
    local network="${2:-default}"
    local timeout="${3:-300}"
    local elapsed=0

    info "Waiting for VM '${vm_name}' to become ready (timeout: ${timeout}s)..."

    # First, wait for the VM to get an IP address
    local ip
    ip="$(get_vm_ip "${vm_name}" "${network}" "${timeout}")" || return 1

    info "VM '${vm_name}' has IP: ${ip}. Waiting for SSH..."

    # Then wait for SSH to become available
    while [[ ${elapsed} -lt ${timeout} ]]; do
        if ssh -o ConnectTimeout=3 \
               -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               -o BatchMode=yes \
               "lab@${ip}" "echo ready" &>/dev/null; then
            success "VM '${vm_name}' is ready (IP: ${ip})"
            return 0
        fi

        # Fall back: check if cloud-init has finished via virsh console command
        # This is less reliable but works when SSH key auth is not set up
        if virsh qemu-agent-command "${vm_name}" \
            '{"execute":"guest-exec","arguments":{"path":"/bin/test","arg":["-f","/var/lib/cloud/instance/boot-finished"],"capture-output":true}}' \
            &>/dev/null; then
            success "VM '${vm_name}' cloud-init complete (IP: ${ip})"
            return 0
        fi

        sleep 10
        ((elapsed += 10))
    done

    warn "VM '${vm_name}' may not be fully ready after ${timeout}s (IP: ${ip})"
    return 1
}

# ==============================================================================
# OVS helper functions
# ==============================================================================

# ovs_bridge_exists - Check if an OVS bridge exists
# Arguments:
#   $1 - Bridge name
# Returns: 0 if exists, 1 if not
ovs_bridge_exists() {
    local bridge="$1"
    sudo ovs-vsctl br-exists "${bridge}" 2>/dev/null
}

# create_ovs_bridge - Create an OVS bridge if it does not already exist
# Arguments:
#   $1 - Bridge name
# Returns: 0 on success
create_ovs_bridge() {
    local bridge="$1"

    if ovs_bridge_exists "${bridge}"; then
        warn "OVS bridge '${bridge}' already exists, skipping"
        return 0
    fi

    info "Creating OVS bridge '${bridge}'..."
    sudo ovs-vsctl add-br "${bridge}"
    sudo ip link set "${bridge}" up
    success "OVS bridge '${bridge}' created and brought up"
}

# delete_ovs_bridge - Delete an OVS bridge if it exists
# Arguments:
#   $1 - Bridge name
# Returns: 0 on success
delete_ovs_bridge() {
    local bridge="$1"

    if ! ovs_bridge_exists "${bridge}"; then
        info "OVS bridge '${bridge}' does not exist, nothing to delete"
        return 0
    fi

    info "Deleting OVS bridge '${bridge}'..."
    sudo ip link set "${bridge}" down 2>/dev/null || true
    sudo ovs-vsctl del-br "${bridge}"
    success "OVS bridge '${bridge}' deleted"
}

# add_ovs_port - Add a port to an OVS bridge
# Arguments:
#   $1 - Bridge name
#   $2 - Port name
#   $3 - (Optional) Additional ovs-vsctl arguments (e.g., "tag=100" for VLAN)
# Returns: 0 on success
add_ovs_port() {
    local bridge="$1"
    local port="$2"
    local extra_args="${3:-}"

    # Check if port already exists on this bridge
    if sudo ovs-vsctl port-to-br "${port}" 2>/dev/null | grep -q "${bridge}"; then
        warn "Port '${port}' already on bridge '${bridge}', skipping"
        return 0
    fi

    info "Adding port '${port}' to bridge '${bridge}'..."
    # shellcheck disable=SC2086
    sudo ovs-vsctl add-port "${bridge}" "${port}" ${extra_args}
    success "Port '${port}' added to bridge '${bridge}'"
}

# ovs_run - Run an ovs-vsctl command with sudo
# Arguments:
#   $@ - Command and arguments to pass to ovs-vsctl
# Returns: exit code of ovs-vsctl
ovs_run() {
    sudo ovs-vsctl "$@"
}

# ==============================================================================
# OVN helper functions
# ==============================================================================

# ovn_nbctl - Run an ovn-nbctl command with sudo
# Arguments:
#   $@ - Command and arguments
ovn_nbctl() {
    sudo ovn-nbctl "$@"
}

# ovn_sbctl - Run an ovn-sbctl command with sudo
# Arguments:
#   $@ - Command and arguments
ovn_sbctl() {
    sudo ovn-sbctl "$@"
}

# ovn_run_on_central - Execute a command on the OVN central node via SSH
# Arguments:
#   $1 - Central node IP
#   $2 - Command to execute
#   $3 - User (default: lab)
ovn_run_on_central() {
    local central_ip="$1"
    local cmd="$2"
    local user="${3:-lab}"

    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        "${user}@${central_ip}" "sudo ${cmd}"
}

# ==============================================================================
# Libvirt network helpers
# ==============================================================================

# network_exists - Check if a libvirt network exists
# Arguments:
#   $1 - Network name
# Returns: 0 if exists, 1 if not
network_exists() {
    local net_name="$1"
    virsh net-info "${net_name}" &>/dev/null
}

# create_libvirt_network - Create an isolated libvirt network for the lab
#
# Creates a NAT-based network with DHCP for VM connectivity. The network
# is started and set to autostart.
#
# Arguments:
#   $1 - Network name
#   $2 - Bridge name for the network
#   $3 - Network address (e.g., 192.168.100.0)
#   $4 - Netmask (e.g., 255.255.255.0)
#   $5 - DHCP range start (e.g., 192.168.100.100)
#   $6 - DHCP range end (e.g., 192.168.100.200)
#   $7 - Gateway IP (e.g., 192.168.100.1)
#
# Returns: 0 on success
create_libvirt_network() {
    local net_name="$1"
    local br_name="$2"
    local net_addr="$3"
    local netmask="$4"
    local dhcp_start="$5"
    local dhcp_end="$6"
    local gateway="$7"

    if network_exists "${net_name}"; then
        warn "Network '${net_name}' already exists, skipping creation"
        # Ensure it is active
        virsh net-start "${net_name}" 2>/dev/null || true
        return 0
    fi

    info "Creating libvirt network '${net_name}'..."

    local tmpfile
    tmpfile="$(mktemp /tmp/net-XXXXXX.xml)"

    cat > "${tmpfile}" <<EOF
<network>
  <name>${net_name}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='${br_name}' stp='on' delay='0'/>
  <ip address='${gateway}' netmask='${netmask}'>
    <dhcp>
      <range start='${dhcp_start}' end='${dhcp_end}'/>
    </dhcp>
  </ip>
</network>
EOF

    virsh net-define "${tmpfile}"
    virsh net-start "${net_name}"
    virsh net-autostart "${net_name}"
    rm -f "${tmpfile}"

    success "Network '${net_name}' created (${gateway}/${netmask})"
}

# delete_libvirt_network - Destroy and undefine a libvirt network
# Arguments:
#   $1 - Network name
# Returns: 0 on success
delete_libvirt_network() {
    local net_name="$1"

    if ! network_exists "${net_name}"; then
        info "Network '${net_name}' does not exist, nothing to delete"
        return 0
    fi

    info "Removing libvirt network '${net_name}'..."
    virsh net-destroy "${net_name}" 2>/dev/null || true
    virsh net-undefine "${net_name}" 2>/dev/null || true
    success "Network '${net_name}' removed"
}

# ==============================================================================
# Utility functions
# ==============================================================================

# generate_mac_address - Generate a random MAC address with a local prefix
#
# Uses the 52:54:00 prefix (standard for QEMU/KVM VMs) and generates
# random bytes for the remaining octets.
#
# Arguments:
#   $1 - (Optional) Seed value for reproducibility (uses last 3 chars)
#
# Returns: Prints MAC address to stdout
generate_mac_address() {
    local seed="${1:-}"

    if [[ -n "${seed}" ]]; then
        # Deterministic MAC based on seed - useful for idempotency
        local hash
        hash="$(echo -n "${seed}" | md5sum | cut -c1-6)"
        printf '52:54:00:%s:%s:%s\n' \
            "${hash:0:2}" "${hash:2:2}" "${hash:4:2}"
    else
        # Random MAC
        printf '52:54:00:%02x:%02x:%02x\n' \
            $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256))
    fi
}

# wait_for_condition - Wait for a condition to be true, with timeout
#
# Repeatedly executes the given command until it returns 0 or the timeout
# is reached. Useful for waiting on async operations.
#
# Arguments:
#   $1 - Description of what we are waiting for
#   $2 - Timeout in seconds
#   $3 - Interval between checks in seconds
#   $4+ - Command to execute (must return 0 when condition is met)
#
# Returns: 0 if condition met, 1 on timeout
wait_for_condition() {
    local description="$1"
    local timeout="$2"
    local interval="$3"
    shift 3

    local elapsed=0
    info "Waiting for: ${description} (timeout: ${timeout}s)"

    while [[ ${elapsed} -lt ${timeout} ]]; do
        if "$@" &>/dev/null; then
            success "${description} - done"
            return 0
        fi
        sleep "${interval}"
        ((elapsed += interval))
    done

    error "Timeout waiting for: ${description}"
    return 1
}

# confirm_action - Ask the user to confirm a destructive action
#
# Displays a prompt and waits for user input. Used by the teardown script
# before deleting resources.
#
# Arguments:
#   $1 - Description of the action
#
# Returns: 0 if confirmed, 1 if declined
confirm_action() {
    local description="$1"

    echo ""
    echo -e "${COLOR_YELLOW}${COLOR_BOLD}WARNING:${COLOR_RESET} ${description}"
    echo -n "Are you sure you want to proceed? [y/N] "
    read -r response

    case "${response}" in
        [yY]|[yY][eE][sS])
            return 0
            ;;
        *)
            info "Action cancelled by user"
            return 1
            ;;
    esac
}

# cleanup_temp_files - Remove temporary files created during setup
# Arguments:
#   $1 - Pattern or directory to clean
cleanup_temp_files() {
    local pattern="$1"

    if [[ -d "${pattern}" ]]; then
        info "Cleaning up temporary directory: ${pattern}"
        rm -rf "${pattern}"
    elif ls ${pattern} &>/dev/null; then
        info "Cleaning up temporary files: ${pattern}"
        rm -f ${pattern}
    fi
}

# download_cloud_image - Download a cloud image if not already present
#
# Downloads a cloud image from a URL to a local path. Supports both
# wget and curl as download tools.
#
# Arguments:
#   $1 - URL of the cloud image
#   $2 - Local path to save the image
#
# Returns: 0 on success, 1 on failure
download_cloud_image() {
    local url="$1"
    local dest="$2"

    if [[ -f "${dest}" ]]; then
        info "Cloud image already exists at ${dest}, skipping download"
        return 0
    fi

    info "Downloading cloud image from ${url}..."
    info "This may take several minutes depending on your connection speed."

    local dest_dir
    dest_dir="$(dirname "${dest}")"
    sudo mkdir -p "${dest_dir}"

    if command -v wget &>/dev/null; then
        sudo wget --quiet --show-progress -O "${dest}" "${url}"
    elif command -v curl &>/dev/null; then
        sudo curl -L --progress-bar -o "${dest}" "${url}"
    else
        error "Neither wget nor curl is available. Cannot download image."
        return 1
    fi

    if [[ ! -f "${dest}" ]] || [[ "$(stat -c%s "${dest}" 2>/dev/null)" -lt 1000000 ]]; then
        error "Downloaded file seems invalid or too small. Check the URL."
        sudo rm -f "${dest}"
        return 1
    fi

    success "Cloud image downloaded to ${dest}"
}

# print_table_row - Print a formatted table row for summaries
# Arguments:
#   $1 - Column 1 value (left-aligned, 20 chars)
#   $2 - Column 2 value (left-aligned, 18 chars)
#   $3 - Column 3 value (remaining)
print_table_row() {
    printf "  %-20s %-18s %s\n" "$1" "$2" "$3"
}

# print_vm_access_info - Print how to access a specific VM
# Arguments:
#   $1 - VM name
#   $2 - VM IP address
#   $3 - Username (default: lab)
print_vm_access_info() {
    local vm_name="$1"
    local vm_ip="$2"
    local user="${3:-lab}"

    echo "  ${vm_name}:"
    echo "    Console: virsh console ${vm_name}"
    echo "    SSH:     ssh ${user}@${vm_ip}"
    echo ""
}
