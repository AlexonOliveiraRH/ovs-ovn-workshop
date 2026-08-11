#!/bin/bash
# ==============================================================================
# setup-ovs-lab.sh - Set up an Open vSwitch standalone lab on QEMU/Libvirt/KVM
# ==============================================================================
#
# Description:
#   Creates a standalone OVS lab environment consisting of 2-3 lightweight VMs
#   connected via OVS bridges. Each VM runs RHEL 9 or Fedora with Open vSwitch
#   installed and configured, along with standard networking tools.
#
#   The lab topology:
#
#     +----------+      +----------+      +----------+
#     |   vm-1   |      |   vm-2   |      |   vm-3   |
#     | (worker) |      | (worker) |      | (worker) |
#     +----+-----+      +----+-----+      +----+-----+
#          |                  |                  |
#     +----+------------------+------------------+----+
#     |                    br-int                     |
#     |              (OVS internal bridge)            |
#     +------------------------+----------------------+
#                              |
#     +------------------------+----------------------+
#     |                    br-ext                     |
#     |              (OVS external bridge)            |
#     +-----------------------+-----------------------+
#                             |
#                        NAT / Host
#
# Usage:
#   ./setup-ovs-lab.sh [OPTIONS]
#
# Options:
#   -h, --help          Show this help message
#   -n, --num-vms NUM   Number of VMs to create (default: 3)
#   -m, --memory MiB    Memory per VM in MiB (default: 2048)
#   -c, --cpus NUM      vCPUs per VM (default: 2)
#   -p, --prefix NAME   Lab prefix for resource names (default: ovslab)
#   -i, --image URL     Cloud image URL to use
#   -s, --ssh-key PATH  Path to SSH public key to inject
#   --skip-download     Skip image download (use existing image)
#
# Prerequisites:
#   - libvirt, qemu-kvm, virt-install
#   - openvswitch
#   - genisoimage
#   - Sufficient disk space for VM images (~5GB per VM)
#   - Sufficient memory for VMs
#
# ==============================================================================

set -euo pipefail

# ==============================================================================
# Configuration variables - customize these for your environment
# ==============================================================================

# --- Lab identification ---
# All resources (VMs, networks, bridges) are prefixed with this string
# so they can be easily identified and cleaned up.
LAB_PREFIX="${LAB_PREFIX:-ovslab}"

# --- VM configuration ---
NUM_VMS="${NUM_VMS:-3}"           # Number of worker VMs to create
VM_MEMORY="${VM_MEMORY:-2048}"    # Memory per VM in MiB
VM_CPUS="${VM_CPUS:-2}"          # vCPUs per VM
VM_DISK_SIZE="${VM_DISK_SIZE:-20G}"  # Disk size per VM
VM_PASSWORD="${VM_PASSWORD:-redhat}"  # Default password for lab/root users

# --- Cloud image ---
# Fedora cloud image URL - change to RHEL 9 if you have a subscription
CLOUD_IMAGE_URL="${CLOUD_IMAGE_URL:-https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2}"
CLOUD_IMAGE_NAME="${CLOUD_IMAGE_NAME:-fedora-cloud-base.qcow2}"

# --- Storage ---
STORAGE_POOL_PATH="${STORAGE_POOL_PATH:-/var/lib/libvirt/images}"
CLOUD_IMAGE_PATH="${STORAGE_POOL_PATH}/${LAB_PREFIX}-${CLOUD_IMAGE_NAME}"

# --- Networking ---
# Management network: used for SSH access to VMs from the host
MGMT_NET_NAME="${LAB_PREFIX}-mgmt"
MGMT_NET_BRIDGE="virbr-${LAB_PREFIX:0:4}m"
MGMT_NET_ADDR="192.168.150.0"
MGMT_NET_MASK="255.255.255.0"
MGMT_NET_GW="192.168.150.1"
MGMT_NET_DHCP_START="192.168.150.100"
MGMT_NET_DHCP_END="192.168.150.200"

# OVS bridge names (created on the host)
OVS_BR_INT="${LAB_PREFIX}-br-int"
OVS_BR_EXT="${LAB_PREFIX}-br-ext"

# Internal network range (used inside VMs on OVS bridges)
INTERNAL_NET="10.0.0"
INTERNAL_NET_PREFIX="24"

# --- SSH ---
SSH_PUBKEY_PATH="${SSH_PUBKEY_PATH:-}"  # Path to SSH public key (optional)

# --- Timeouts ---
VM_READY_TIMEOUT="${VM_READY_TIMEOUT:-300}"  # Seconds to wait for VM readiness

# ==============================================================================
# Script setup
# ==============================================================================

# Determine script directory and source the common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ==============================================================================
# Functions
# ==============================================================================

# usage - Print help message and exit
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Set up an Open vSwitch standalone lab environment with QEMU/Libvirt/KVM.

Options:
  -h, --help          Show this help message and exit
  -n, --num-vms NUM   Number of VMs to create (default: ${NUM_VMS})
  -m, --memory MiB    Memory per VM in MiB (default: ${VM_MEMORY})
  -c, --cpus NUM      vCPUs per VM (default: ${VM_CPUS})
  -p, --prefix NAME   Lab prefix for resource names (default: ${LAB_PREFIX})
  -i, --image URL     Cloud image URL to use
  -s, --ssh-key PATH  Path to SSH public key to inject into VMs
  --skip-download     Skip image download (assume image exists)

Environment variables:
  LAB_PREFIX          Same as --prefix
  NUM_VMS             Same as --num-vms
  VM_MEMORY           Same as --memory
  VM_CPUS             Same as --cpus
  VM_PASSWORD         Password for lab/root users (default: redhat)
  CLOUD_IMAGE_URL     Same as --image
  STORAGE_POOL_PATH   Path for VM disks (default: /var/lib/libvirt/images)

Examples:
  # Create a 3-VM lab with defaults
  sudo ./$(basename "$0")

  # Create a 2-VM lab with custom prefix and more memory
  sudo ./$(basename "$0") -n 2 -m 4096 -p mylab

  # Use a RHEL 9 cloud image
  sudo ./$(basename "$0") -i https://your-server/rhel9-cloud.qcow2

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
            -n|--num-vms)
                NUM_VMS="$2"
                shift 2
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
    MGMT_NET_NAME="${LAB_PREFIX}-mgmt"
    MGMT_NET_BRIDGE="virbr-${LAB_PREFIX:0:4}m"
    OVS_BR_INT="${LAB_PREFIX}-br-int"
    OVS_BR_EXT="${LAB_PREFIX}-br-ext"
    CLOUD_IMAGE_PATH="${STORAGE_POOL_PATH}/${LAB_PREFIX}-${CLOUD_IMAGE_NAME}"

    SKIP_DOWNLOAD="${skip_download}"
}

# check_root - Ensure script is run as root (needed for libvirt and OVS)
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

# setup_management_network - Create the management network for SSH access
#
# This libvirt network provides NAT connectivity so the host can reach the
# VMs via SSH. It is separate from the OVS bridges used for the lab exercises.
setup_management_network() {
    header "Setting up management network"

    create_libvirt_network \
        "${MGMT_NET_NAME}" \
        "${MGMT_NET_BRIDGE}" \
        "${MGMT_NET_ADDR}" \
        "${MGMT_NET_MASK}" \
        "${MGMT_NET_DHCP_START}" \
        "${MGMT_NET_DHCP_END}" \
        "${MGMT_NET_GW}"
}

# setup_ovs_bridges - Create the OVS bridges on the host
#
# Two bridges are created:
#   br-int: Internal bridge for VM-to-VM traffic (simulates tenant traffic)
#   br-ext: External bridge for external/provider connectivity
#
# A patch port connects the two bridges, simulating a typical OVS deployment
# where br-int handles internal traffic and br-ext provides external access.
setup_ovs_bridges() {
    header "Setting up OVS bridges"

    # Create the internal bridge (analogous to br-int in OpenStack)
    create_ovs_bridge "${OVS_BR_INT}"

    # Create the external bridge (analogous to br-ex in OpenStack)
    create_ovs_bridge "${OVS_BR_EXT}"

    # Connect br-int and br-ext with a pair of patch ports
    # Patch ports are OVS-internal connections between bridges.
    # Traffic entering one patch port exits the paired patch port on the
    # other bridge, similar to a virtual cable between switches.
    local patch_int="${LAB_PREFIX}-patch-int"
    local patch_ext="${LAB_PREFIX}-patch-ext"

    if ! sudo ovs-vsctl port-to-br "${patch_int}" &>/dev/null; then
        info "Creating patch ports between ${OVS_BR_INT} and ${OVS_BR_EXT}..."
        sudo ovs-vsctl \
            -- add-port "${OVS_BR_INT}" "${patch_int}" \
            -- set interface "${patch_int}" type=patch options:peer="${patch_ext}" \
            -- add-port "${OVS_BR_EXT}" "${patch_ext}" \
            -- set interface "${patch_ext}" type=patch options:peer="${patch_int}"
        success "Patch ports created between ${OVS_BR_INT} and ${OVS_BR_EXT}"
    else
        warn "Patch ports already exist, skipping"
    fi

    # Assign an IP to br-ext so the host can route traffic for the VMs
    # This acts as the gateway for the internal network
    if ! ip addr show "${OVS_BR_EXT}" 2>/dev/null | grep -q "${INTERNAL_NET}.1"; then
        info "Assigning gateway IP ${INTERNAL_NET}.1/${INTERNAL_NET_PREFIX} to ${OVS_BR_EXT}..."
        sudo ip addr add "${INTERNAL_NET}.1/${INTERNAL_NET_PREFIX}" dev "${OVS_BR_EXT}" 2>/dev/null || true
    fi

    # Show the current OVS configuration
    separator
    info "Current OVS bridge configuration:"
    sudo ovs-vsctl show
    separator
}

# create_lab_vms - Create and provision the lab VMs
#
# Each VM is created with:
#   - A management interface on the libvirt NAT network (for SSH access)
#   - An additional interface that will be connected to OVS bridges
#   - Cloud-init provisioning with OVS packages and tools
create_lab_vms() {
    header "Creating lab VMs"

    # Read SSH public key if path was provided
    local ssh_pubkey=""
    if [[ -n "${SSH_PUBKEY_PATH}" ]] && [[ -f "${SSH_PUBKEY_PATH}" ]]; then
        ssh_pubkey="$(cat "${SSH_PUBKEY_PATH}")"
        info "Using SSH public key from ${SSH_PUBKEY_PATH}"
    elif [[ -f "${HOME}/.ssh/id_rsa.pub" ]]; then
        ssh_pubkey="$(cat "${HOME}/.ssh/id_rsa.pub")"
        info "Using SSH public key from ${HOME}/.ssh/id_rsa.pub"
    elif [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
        ssh_pubkey="$(cat "${HOME}/.ssh/id_ed25519.pub")"
        info "Using SSH public key from ${HOME}/.ssh/id_ed25519.pub"
    else
        warn "No SSH public key found. VMs will be accessible via password only."
    fi

    for i in $(seq 1 "${NUM_VMS}"); do
        local vm_name="${LAB_PREFIX}-vm${i}"
        local ci_iso="${STORAGE_POOL_PATH}/${vm_name}-cidata.iso"

        separator
        info "Setting up VM ${i}/${NUM_VMS}: ${vm_name}"

        # --- Additional runcmd for OVS configuration inside the VM ---
        # Each VM gets OVS configured with its own bridges and internal IP.
        # This lets students explore OVS commands inside the VMs as well.
        local internal_ip="${INTERNAL_NET}.$((10 + i))"
        local extra_runcmd
        extra_runcmd=$(cat <<RUNCMD
  # Configure OVS inside the VM for lab exercises
  - ovs-vsctl add-br br-lab
  - ip addr add ${internal_ip}/${INTERNAL_NET_PREFIX} dev br-lab
  - ip link set br-lab up

  # Create a sample internal port for demonstration
  - ovs-vsctl add-port br-lab lab-internal -- set interface lab-internal type=internal
  - ip link set lab-internal up

  # Add useful aliases for OVS commands
  - echo "alias ovs='sudo ovs-vsctl'" >> /home/lab/.bashrc
  - echo "alias flows='sudo ovs-ofctl dump-flows'" >> /home/lab/.bashrc
  - echo "alias ports='sudo ovs-ofctl dump-ports-desc'" >> /home/lab/.bashrc
  - echo "alias watch-flows='sudo watch -n1 ovs-ofctl dump-flows br-lab'" >> /home/lab/.bashrc
RUNCMD
)

        # --- Generate cloud-init ISO ---
        create_cloud_init_iso \
            "${ci_iso}" \
            "${vm_name}" \
            "${VM_PASSWORD}" \
            "${ssh_pubkey}" \
            "" \
            "${extra_runcmd}" \
            ""

        # --- Build the network arguments for virt-install ---
        # Interface 1: management network (libvirt NAT - for SSH from host)
        # Interface 2: isolated network (will be used with OVS)
        local net_args="--network network=${MGMT_NET_NAME},model=virtio"

        # Add a second interface on the default network that we can later
        # reconfigure or use for OVS bridge experiments
        net_args="${net_args} --network network=${MGMT_NET_NAME},model=virtio"

        # --- Create the VM ---
        create_vm \
            "${vm_name}" \
            "${CLOUD_IMAGE_PATH}" \
            "${ci_iso}" \
            "${VM_MEMORY}" \
            "${VM_CPUS}" \
            "${VM_DISK_SIZE}" \
            "${net_args}" \
            "${STORAGE_POOL_PATH}"
    done
}

# connect_vms_to_ovs - Connect VM interfaces to OVS bridges on the host
#
# After VMs are created, their second network interface (the non-management
# one) is attached to the OVS bridge. This is done on the host side by
# finding the vnet interfaces that libvirt creates and adding them to OVS.
#
# Note: This function works with the host's OVS instance. The VMs also have
# OVS running internally for lab exercises - those are separate.
connect_vms_to_ovs() {
    header "Connecting VM interfaces to OVS bridges"

    for i in $(seq 1 "${NUM_VMS}"); do
        local vm_name="${LAB_PREFIX}-vm${i}"

        if ! vm_is_running "${vm_name}"; then
            warn "VM '${vm_name}' is not running, skipping OVS connection"
            continue
        fi

        # Find the VM's interfaces - the second interface is our OVS candidate
        # virsh domiflist shows: Interface  Type  Source  Model  MAC
        local interfaces
        interfaces="$(virsh domiflist "${vm_name}" 2>/dev/null | awk 'NR>2 && NF>0 {print $1}')"
        local iface_count=0
        local ovs_iface=""

        while IFS= read -r iface; do
            ((iface_count++)) || true
            # The second interface (index 2) is the one we want on OVS
            if [[ ${iface_count} -eq 2 ]] && [[ -n "${iface}" ]]; then
                ovs_iface="${iface}"
            fi
        done <<< "${interfaces}"

        if [[ -n "${ovs_iface}" ]]; then
            add_ovs_port "${OVS_BR_INT}" "${ovs_iface}"
        else
            warn "Could not find second interface for '${vm_name}'"
        fi
    done

    # Show the updated bridge configuration
    separator
    info "Updated OVS bridge configuration:"
    sudo ovs-vsctl show
    separator
}

# wait_for_all_vms - Wait until all VMs are fully booted and accessible
wait_for_all_vms() {
    header "Waiting for VMs to become ready"

    info "This may take a few minutes while cloud-init runs inside each VM..."
    echo ""

    for i in $(seq 1 "${NUM_VMS}"); do
        local vm_name="${LAB_PREFIX}-vm${i}"
        wait_for_vm_ready "${vm_name}" "${MGMT_NET_NAME}" "${VM_READY_TIMEOUT}" || \
            warn "VM '${vm_name}' may not be fully ready. You can still try 'virsh console ${vm_name}'"
    done
}

# print_summary - Print a summary of the lab environment
#
# Shows all created resources, VM IPs, and instructions for how to
# access the lab environment. This is the final output the user sees.
print_summary() {
    header "OVS Lab Environment - Summary"

    # --- VMs ---
    echo -e "${COLOR_BOLD}Virtual Machines:${COLOR_RESET}"
    echo ""
    print_table_row "NAME" "IP ADDRESS" "STATUS"
    print_table_row "----" "----------" "------"

    for i in $(seq 1 "${NUM_VMS}"); do
        local vm_name="${LAB_PREFIX}-vm${i}"
        local vm_ip
        local status

        vm_ip="$(get_vm_ip "${vm_name}" "${MGMT_NET_NAME}" 10 2>/dev/null)" || vm_ip="(pending)"
        status="$(virsh domstate "${vm_name}" 2>/dev/null)" || status="unknown"

        print_table_row "${vm_name}" "${vm_ip}" "${status}"
    done

    echo ""

    # --- OVS Bridges ---
    echo -e "${COLOR_BOLD}OVS Bridges (Host):${COLOR_RESET}"
    echo ""
    echo "  ${OVS_BR_INT} (internal) - VM-to-VM traffic"
    echo "  ${OVS_BR_EXT} (external) - External connectivity"
    echo "  Connected via patch ports: ${LAB_PREFIX}-patch-int <-> ${LAB_PREFIX}-patch-ext"
    echo ""

    # --- Network ---
    echo -e "${COLOR_BOLD}Networks:${COLOR_RESET}"
    echo ""
    echo "  Management: ${MGMT_NET_NAME} (${MGMT_NET_GW}/${MGMT_NET_MASK})"
    echo "  Internal:   ${INTERNAL_NET}.0/${INTERNAL_NET_PREFIX} (inside VMs on br-lab)"
    echo ""

    # --- Access instructions ---
    echo -e "${COLOR_BOLD}Accessing the VMs:${COLOR_RESET}"
    echo ""
    echo "  Console access (no network needed):"
    echo "    virsh console ${LAB_PREFIX}-vm1"
    echo ""
    echo "  SSH access:"
    echo "    ssh lab@<IP_ADDRESS>"
    echo "    Password: ${VM_PASSWORD}"
    echo ""

    # --- Quick start exercises ---
    echo -e "${COLOR_BOLD}Quick Start - Try These Commands:${COLOR_RESET}"
    echo ""
    echo "  Inside any VM:"
    echo "    sudo ovs-vsctl show               # Show OVS configuration"
    echo "    sudo ovs-ofctl dump-flows br-lab   # Show OpenFlow rules"
    echo "    sudo ovs-ofctl dump-ports br-lab   # Show port statistics"
    echo "    sudo ovs-vsctl add-port br-lab p1 -- set interface p1 type=internal"
    echo ""
    echo "  From the host:"
    echo "    sudo ovs-vsctl show               # Show host OVS bridges"
    echo "    sudo ovs-ofctl dump-flows ${OVS_BR_INT}"
    echo ""

    # --- Cleanup ---
    echo -e "${COLOR_BOLD}Cleanup:${COLOR_RESET}"
    echo ""
    echo "  To tear down this lab:"
    echo "    sudo ${SCRIPT_DIR}/teardown.sh -p ${LAB_PREFIX}"
    echo ""

    separator
    success "OVS lab environment is ready!"
}

# ==============================================================================
# Main execution
# ==============================================================================

main() {
    parse_args "$@"

    header "OVS Standalone Lab Setup"
    info "Lab prefix:  ${LAB_PREFIX}"
    info "VMs:         ${NUM_VMS}"
    info "Memory/VM:   ${VM_MEMORY} MiB"
    info "vCPUs/VM:    ${VM_CPUS}"
    info "Disk/VM:     ${VM_DISK_SIZE}"
    info "Image:       ${CLOUD_IMAGE_URL}"

    # Step 1: Check that all required tools and services are available
    check_root
    check_prerequisites "ovs"

    # Step 2: Download the cloud image
    download_image

    # Step 3: Create the management network (libvirt NAT for SSH access)
    setup_management_network

    # Step 4: Create the OVS bridges on the host
    setup_ovs_bridges

    # Step 5: Create and provision the VMs
    create_lab_vms

    # Step 6: Wait for VMs to finish booting and cloud-init to complete
    wait_for_all_vms

    # Step 7: Connect VM interfaces to the host OVS bridges
    connect_vms_to_ovs

    # Step 8: Print the lab summary with access instructions
    print_summary
}

main "$@"
