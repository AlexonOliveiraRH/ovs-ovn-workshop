#!/bin/bash
set -euo pipefail

# =============================================================================
# setup-ovs-lab.sh - Deploy an OVS standalone lab on VMware vSphere
# =============================================================================
#
# This script provisions 3 VMs on vSphere using govc and configures them with
# Open vSwitch (OVS) for the hands-on lab exercises in the OVS & OVN workshop.
#
# Architecture:
#   +-------------+     +-------------+     +-------------+
#   |   ovs-node1 |     |   ovs-node2 |     |   ovs-node3 |
#   | (OVS bridge)|     | (OVS bridge)|     | (OVS bridge)|
#   |  br-int     |     |  br-int     |     |  br-int     |
#   +------+------+     +------+------+     +------+------+
#          |                   |                   |
#          +-------------------+-------------------+
#                     vSphere Network
#
# Usage:
#   # Set environment variables first (see "Environment Variables" below)
#   ./setup-ovs-lab.sh
#
#   # Override defaults:
#   VM_TEMPLATE="rhel9-template" VM_COUNT=2 ./setup-ovs-lab.sh
#
# Prerequisites:
#   1. govc installed (see install instructions below)
#   2. GOVC_* environment variables configured
#   3. A VM template with RHEL 9 or Fedora available in vSphere
#   4. SSH key-based access configured on the template (or cloud-init support)
#   5. Sufficient resources in the target cluster/resource pool
#
# Installing govc:
#   # Download the latest release from GitHub
#   curl -L -o govc.tar.gz \
#     "https://github.com/vmware/govmomi/releases/latest/download/govc_$(uname -s)_$(uname -m).tar.gz"
#   tar -xzf govc.tar.gz govc
#   sudo mv govc /usr/local/bin/
#   govc version
#
# Environment Variables (GOVC):
#   GOVC_URL        - vCenter or ESXi URL (e.g., vcenter.example.com or https://vcenter.example.com/sdk)
#   GOVC_USERNAME   - vSphere login username (e.g., administrator@vsphere.local)
#   GOVC_PASSWORD   - vSphere login password
#   GOVC_DATACENTER - Target datacenter name (e.g., "DC1")
#   GOVC_DATASTORE  - Datastore for VM disks (e.g., "datastore1" or "vsanDatastore")
#   GOVC_NETWORK    - Default network/port group for VMs (e.g., "VM Network")
#   GOVC_INSECURE   - Set to "true" to skip TLS certificate verification (common in labs)
#
# =============================================================================

# -----------------------------------------------------------------------------
# Configurable Variables
# Customize these to match your vSphere environment.
# -----------------------------------------------------------------------------

# Prefix applied to all lab resources for easy identification and cleanup.
LAB_PREFIX="${LAB_PREFIX:-ovs-lab}"

# VM template to clone from. Must exist in the configured datacenter.
# Recommended: RHEL 9.x or Fedora 39+ with cloud-init installed.
VM_TEMPLATE="${VM_TEMPLATE:-rhel9-cloud-template}"

# Number of VMs to deploy (2 minimum, 3 recommended for richer lab scenarios).
VM_COUNT="${VM_COUNT:-3}"

# Resource pool where VMs will be placed. Use "/" for the cluster root.
RESOURCE_POOL="${RESOURCE_POOL:-/Resources}"

# vSphere folder to organize lab VMs. Created if it does not exist.
VM_FOLDER="${VM_FOLDER:-${LAB_PREFIX}}"

# Hardware sizing per VM.
VM_CPUS="${VM_CPUS:-2}"
VM_MEMORY_MB="${VM_MEMORY_MB:-4096}"

# SSH user configured in the template (must have passwordless sudo).
SSH_USER="${SSH_USER:-cloud-user}"

# Path to the SSH private key used to connect to the VMs.
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_rsa}"

# SSH connection options (disable strict host checking for lab VMs).
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

# Wait timeout (seconds) for VMs to become reachable after power-on.
VM_WAIT_TIMEOUT="${VM_WAIT_TIMEOUT:-300}"

# OVS bridge name that will be created on each VM.
OVS_BRIDGE="${OVS_BRIDGE:-br-int}"

# Internal VLAN tag used for the lab overlay network (0 = no VLAN).
OVS_VLAN="${OVS_VLAN:-0}"

# File to store VM IP addresses for later use and teardown.
STATE_FILE="${STATE_FILE:-/tmp/${LAB_PREFIX}-state.env}"

# -----------------------------------------------------------------------------
# Color output helpers
# -----------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

    # 1. govc must be installed and on PATH.
    if ! command -v govc &>/dev/null; then
        fatal "govc is not installed or not in PATH.
  Install it with:
    curl -L -o govc.tar.gz \\
      \"https://github.com/vmware/govmomi/releases/latest/download/govc_\$(uname -s)_\$(uname -m).tar.gz\"
    tar -xzf govc.tar.gz govc
    sudo mv govc /usr/local/bin/"
    fi
    ok "govc found: $(govc version)"

    # 2. Required GOVC environment variables.
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

    # 3. Validate connectivity to vSphere.
    if ! govc about &>/dev/null; then
        fatal "Cannot connect to vSphere at ${GOVC_URL}. Verify credentials and network."
    fi
    ok "Connected to vSphere: $(govc about | grep -i 'name' | head -1 | xargs)"

    # 4. Verify the template exists.
    if ! govc vm.info "${VM_TEMPLATE}" &>/dev/null; then
        fatal "VM template '${VM_TEMPLATE}' not found in datacenter '${GOVC_DATACENTER}'.
  Available templates:
$(govc find / -type m 2>/dev/null | head -20)"
    fi
    ok "Template found: ${VM_TEMPLATE}"

    # 5. SSH key must exist.
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

    # govc folder.create is idempotent - it does not fail if the folder exists.
    # The path is relative to the datacenter's vm inventory folder.
    if govc folder.info "vm/${VM_FOLDER}" &>/dev/null; then
        ok "Folder 'vm/${VM_FOLDER}' already exists"
    else
        govc folder.create "vm/${VM_FOLDER}"
        ok "Created folder 'vm/${VM_FOLDER}'"
    fi
}

# -----------------------------------------------------------------------------
# Generate cloud-init userdata
# Generate a cloud-init configuration that installs and configures OVS on
# first boot. This avoids the need for post-deployment SSH.
# -----------------------------------------------------------------------------

generate_cloud_init() {
    local vm_name="$1"
    local userdata_file="/tmp/${LAB_PREFIX}-${vm_name}-userdata.yaml"

    cat > "${userdata_file}" <<'CLOUD_INIT_EOF'
#cloud-config

# Set the hostname to match the VM name.
hostname: VM_NAME_PLACEHOLDER

# Ensure the system is updated and OVS packages are installed.
package_update: true
packages:
  - openvswitch3.3
  - tcpdump
  - wireshark-cli
  - net-tools
  - bridge-utils
  - iproute
  - iperf3
  - lldpd
  - python3-openvswitch

# Enable and start OVS after package installation.
runcmd:
  # Start the OVS service.
  - systemctl enable --now openvswitch

  # Create the integration bridge used throughout the lab exercises.
  - ovs-vsctl --may-exist add-br OVS_BRIDGE_PLACEHOLDER

  # Set the bridge protocol version to OpenFlow 1.3 (used in the workshop).
  - ovs-vsctl set bridge OVS_BRIDGE_PLACEHOLDER protocols=OpenFlow10,OpenFlow13,OpenFlow15

  # Set a unique datapath ID derived from the hostname so flow dumps are
  # easy to correlate during labs.
  - |
    DPID=$(echo -n "VM_NAME_PLACEHOLDER" | md5sum | cut -c1-16)
    ovs-vsctl set bridge OVS_BRIDGE_PLACEHOLDER other-config:datapath-id="${DPID}"

  # Create an internal port on the bridge for the host to use.
  - ovs-vsctl --may-exist add-port OVS_BRIDGE_PLACEHOLDER ovs-internal -- set Interface ovs-internal type=internal

  # Log the OVS configuration for verification.
  - ovs-vsctl show > /var/log/ovs-lab-setup.log 2>&1

  # Print a marker so we can check cloud-init completed.
  - echo "OVS_LAB_SETUP_COMPLETE" > /tmp/ovs-lab-ready
CLOUD_INIT_EOF

    # Replace placeholders with actual values.
    sed -i "s/VM_NAME_PLACEHOLDER/${vm_name}/g" "${userdata_file}"
    sed -i "s/OVS_BRIDGE_PLACEHOLDER/${OVS_BRIDGE}/g" "${userdata_file}"

    echo "${userdata_file}"
}

# -----------------------------------------------------------------------------
# Clone and Configure VMs
# -----------------------------------------------------------------------------

deploy_vm() {
    local index="$1"
    local vm_name="${LAB_PREFIX}-node${index}"

    info "Deploying VM: ${vm_name}"

    # Check if the VM already exists (idempotent).
    if govc vm.info "${vm_name}" &>/dev/null; then
        warn "VM '${vm_name}' already exists - skipping clone"
        return 0
    fi

    # Generate cloud-init userdata for this VM.
    local userdata_file
    userdata_file=$(generate_cloud_init "${vm_name}")

    # Clone the VM from the template.
    # - vm.clone creates a full clone from the specified template.
    # - The -on=false flag prevents the VM from powering on immediately,
    #   so we can attach the cloud-init ISO first.
    # - -c and -m set CPU and memory.
    # - -folder places the VM in our lab folder.
    # - -pool sets the resource pool.
    # - -net sets the network adapter to the specified port group.
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

    # Attach cloud-init userdata as a vApp property.
    # This method works with templates that have cloud-init configured to read
    # from OVF/vApp properties. If your template uses a config drive instead,
    # see the alternative SSH-based approach further below.
    govc vm.change -vm "${vm_name}" \
        -e "guestinfo.userdata=$(base64 -w0 "${userdata_file}")" \
        -e "guestinfo.userdata.encoding=base64"

    ok "Attached cloud-init userdata to '${vm_name}'"

    # Add a second NIC for the OVS overlay/tunnel network (optional but useful
    # for VXLAN/Geneve exercises in later modules).
    # This connects to the same port group; in production you would use a
    # dedicated trunk port group.
    govc vm.network.add -vm "${vm_name}" \
        -net "${GOVC_NETWORK:-VM Network}" \
        -net.adapter e1000e

    ok "Added second NIC to '${vm_name}' for tunnel traffic"

    # Power on the VM.
    govc vm.power -on "${vm_name}"
    ok "Powered on '${vm_name}'"

    # Clean up the temporary userdata file.
    rm -f "${userdata_file}"
}

deploy_all_vms() {
    info "Deploying ${VM_COUNT} VMs..."

    for i in $(seq 1 "${VM_COUNT}"); do
        deploy_vm "${i}"
    done

    ok "All ${VM_COUNT} VMs deployed"
}

# -----------------------------------------------------------------------------
# Wait for VMs to Become Reachable
# Wait for each VM to get an IP address (via VMware Tools) and become
# reachable via SSH.
# -----------------------------------------------------------------------------

wait_for_vms() {
    info "Waiting for VMs to obtain IP addresses (timeout: ${VM_WAIT_TIMEOUT}s)..."

    # Truncate the state file.
    : > "${STATE_FILE}"
    echo "# OVS Lab State - generated $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${STATE_FILE}"
    echo "LAB_PREFIX=${LAB_PREFIX}" >> "${STATE_FILE}"

    for i in $(seq 1 "${VM_COUNT}"); do
        local vm_name="${LAB_PREFIX}-node${i}"
        local ip=""
        local elapsed=0
        local interval=10

        info "Waiting for '${vm_name}' to get an IP..."

        while [[ -z "${ip}" ]] && [[ ${elapsed} -lt ${VM_WAIT_TIMEOUT} ]]; do
            # govc vm.ip retrieves the IP reported by VMware Tools.
            # The -wait flag tells govc to poll, but we implement our own loop
            # for better timeout control and user feedback.
            ip=$(govc vm.ip "${vm_name}" 2>/dev/null || true)
            if [[ -z "${ip}" ]]; then
                sleep "${interval}"
                elapsed=$((elapsed + interval))
                info "  Still waiting for '${vm_name}'... (${elapsed}s elapsed)"
            fi
        done

        if [[ -z "${ip}" ]]; then
            fatal "Timed out waiting for IP on '${vm_name}' after ${VM_WAIT_TIMEOUT}s.
  Check the VM console in vSphere for boot errors."
        fi

        ok "'${vm_name}' has IP: ${ip}"
        echo "VM_${i}_NAME=${vm_name}" >> "${STATE_FILE}"
        echo "VM_${i}_IP=${ip}" >> "${STATE_FILE}"
    done

    ok "All VMs have IP addresses. State saved to ${STATE_FILE}"
}

# -----------------------------------------------------------------------------
# Wait for Cloud-Init to Complete
# Poll each VM over SSH until the marker file indicates OVS is ready.
# -----------------------------------------------------------------------------

wait_for_cloud_init() {
    info "Waiting for cloud-init to finish OVS setup on all VMs..."

    for i in $(seq 1 "${VM_COUNT}"); do
        local vm_name="${LAB_PREFIX}-node${i}"
        local ip
        ip=$(grep "VM_${i}_IP" "${STATE_FILE}" | cut -d= -f2)

        local elapsed=0
        local interval=15

        info "Waiting for cloud-init on '${vm_name}' (${ip})..."

        while [[ ${elapsed} -lt ${VM_WAIT_TIMEOUT} ]]; do
            if ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${ip}" \
                    "test -f /tmp/ovs-lab-ready" 2>/dev/null; then
                ok "Cloud-init completed on '${vm_name}'"
                break
            fi
            sleep "${interval}"
            elapsed=$((elapsed + interval))
            info "  Still waiting for cloud-init on '${vm_name}'... (${elapsed}s)"
        done

        if [[ ${elapsed} -ge ${VM_WAIT_TIMEOUT} ]]; then
            warn "Timed out waiting for cloud-init on '${vm_name}'.
  OVS may still be installing. Check: ssh ${SSH_USER}@${ip} 'cloud-init status'"
        fi
    done
}

# -----------------------------------------------------------------------------
# Verify OVS Installation
# SSH into each VM and confirm OVS is running and the bridge exists.
# -----------------------------------------------------------------------------

verify_ovs() {
    info "Verifying OVS installation on all VMs..."

    for i in $(seq 1 "${VM_COUNT}"); do
        local vm_name="${LAB_PREFIX}-node${i}"
        local ip
        ip=$(grep "VM_${i}_IP" "${STATE_FILE}" | cut -d= -f2)

        info "Checking OVS on '${vm_name}' (${ip})..."

        # Verify OVS daemon is running.
        local ovs_version
        ovs_version=$(ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${ip}" \
            "sudo ovs-vsctl --version | head -1" 2>/dev/null) || {
            warn "Could not verify OVS on '${vm_name}' - SSH may not be ready yet"
            continue
        }
        ok "'${vm_name}': ${ovs_version}"

        # Verify the bridge exists.
        local bridge_check
        bridge_check=$(ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${ip}" \
            "sudo ovs-vsctl br-exists ${OVS_BRIDGE} && echo 'exists' || echo 'missing'" 2>/dev/null)

        if [[ "${bridge_check}" == "exists" ]]; then
            ok "'${vm_name}': Bridge '${OVS_BRIDGE}' is configured"
        else
            warn "'${vm_name}': Bridge '${OVS_BRIDGE}' not found - cloud-init may still be running"
        fi
    done
}

# -----------------------------------------------------------------------------
# Configure OVS Connectivity Between VMs
# Set up VXLAN tunnels between the VMs so they can communicate through OVS
# bridges, simulating a multi-host OVS environment.
# -----------------------------------------------------------------------------

configure_ovs_tunnels() {
    info "Configuring VXLAN tunnels between VMs for overlay connectivity..."

    # Read IP addresses from the state file.
    local -a ips=()
    local -a names=()
    for i in $(seq 1 "${VM_COUNT}"); do
        ips+=("$(grep "VM_${i}_IP" "${STATE_FILE}" | cut -d= -f2)")
        names+=("$(grep "VM_${i}_NAME" "${STATE_FILE}" | cut -d= -f2)")
    done

    # For each VM, create a VXLAN tunnel port to every other VM.
    # This creates a full mesh of tunnels - each VM can reach every other VM
    # through the OVS bridge via VXLAN encapsulation.
    for i in $(seq 0 $((VM_COUNT - 1))); do
        local src_ip="${ips[$i]}"
        local src_name="${names[$i]}"

        for j in $(seq 0 $((VM_COUNT - 1))); do
            if [[ $i -eq $j ]]; then
                continue
            fi

            local dst_ip="${ips[$j]}"
            local port_name="vxlan-node$((j + 1))"

            info "  ${src_name} -> VXLAN tunnel to ${dst_ip} (port: ${port_name})"

            # Create a VXLAN tunnel port on the OVS bridge.
            # - type=vxlan: Use VXLAN encapsulation (covered in Module 01).
            # - options:remote_ip: The far-end tunnel endpoint.
            # - options:key=100: A VNI (VXLAN Network Identifier) for isolation.
            ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${src_ip}" \
                "sudo ovs-vsctl --may-exist add-port ${OVS_BRIDGE} ${port_name} \
                    -- set Interface ${port_name} type=vxlan \
                    options:remote_ip=${dst_ip} \
                    options:key=100" 2>/dev/null

        done

        ok "Tunnels configured on ${src_name}"
    done

    ok "Full mesh VXLAN tunnels established"
}

# -----------------------------------------------------------------------------
# Print Lab Summary
# -----------------------------------------------------------------------------

print_summary() {
    echo ""
    echo "============================================================================="
    echo " OVS Standalone Lab - Deployment Summary"
    echo "============================================================================="
    echo ""
    echo " Lab prefix:   ${LAB_PREFIX}"
    echo " VM template:  ${VM_TEMPLATE}"
    echo " OVS bridge:   ${OVS_BRIDGE}"
    echo " State file:   ${STATE_FILE}"
    echo ""
    echo " VMs deployed:"
    echo " -------------"

    for i in $(seq 1 "${VM_COUNT}"); do
        local vm_name vm_ip
        vm_name=$(grep "VM_${i}_NAME" "${STATE_FILE}" | cut -d= -f2)
        vm_ip=$(grep "VM_${i}_IP" "${STATE_FILE}" | cut -d= -f2)
        echo "   ${vm_name}  ->  ${vm_ip}"
    done

    echo ""
    echo " Quick access:"
    echo " -------------"
    for i in $(seq 1 "${VM_COUNT}"); do
        local vm_ip
        vm_ip=$(grep "VM_${i}_IP" "${STATE_FILE}" | cut -d= -f2)
        echo "   ssh ${SSH_USER}@${vm_ip}"
    done

    echo ""
    echo " Useful commands on the VMs:"
    echo " ---------------------------"
    echo "   sudo ovs-vsctl show                    # Show OVS configuration"
    echo "   sudo ovs-ofctl dump-flows ${OVS_BRIDGE}       # Dump OpenFlow rules"
    echo "   sudo ovs-dpctl dump-flows              # Dump datapath flows"
    echo "   sudo ovs-appctl dpif/show              # Show datapath interfaces"
    echo "   sudo ovs-vsctl list-ports ${OVS_BRIDGE}       # List ports on bridge"
    echo ""
    echo " Teardown:"
    echo " ---------"
    echo "   ./teardown.sh                           # Interactive cleanup"
    echo "   ./teardown.sh --force                   # Non-interactive cleanup"
    echo ""
    echo "============================================================================="
    echo ""
}

# =============================================================================
# PowerCLI Alternative (Reference)
# =============================================================================
#
# If you prefer VMware PowerCLI over govc, below are the equivalent commands.
# Run these in a PowerShell session with the VMware.PowerCLI module installed.
#
# # Connect to vCenter
# Connect-VIServer -Server "vcenter.example.com" -User "administrator@vsphere.local" -Password "secret"
#
# # Clone VMs from template
# $template = Get-Template -Name "rhel9-cloud-template"
# $resourcePool = Get-ResourcePool -Name "Resources"
# $datastore = Get-Datastore -Name "datastore1"
# $folder = Get-Folder -Name "ovs-lab" -ErrorAction SilentlyContinue
# if (-not $folder) {
#     $folder = New-Folder -Name "ovs-lab" -Location (Get-Folder "vm")
# }
#
# for ($i = 1; $i -le 3; $i++) {
#     $vmName = "ovs-lab-node$i"
#     if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
#         Write-Host "VM $vmName already exists, skipping."
#         continue
#     }
#     New-VM -Name $vmName `
#            -Template $template `
#            -ResourcePool $resourcePool `
#            -Datastore $datastore `
#            -Location $folder `
#            -NumCpu 2 `
#            -MemoryMB 4096
#
#     # Add a second NIC for tunnel traffic
#     $vm = Get-VM -Name $vmName
#     New-NetworkAdapter -VM $vm -NetworkName "VM Network" -Type E1000E -StartConnected
#
#     # Inject cloud-init userdata via Extra Config
#     $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
#     $opt1 = New-Object VMware.Vim.OptionValue
#     $opt1.Key = "guestinfo.userdata"
#     $opt1.Value = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-Content "userdata-$vmName.yaml" -Raw)))
#     $opt2 = New-Object VMware.Vim.OptionValue
#     $opt2.Key = "guestinfo.userdata.encoding"
#     $opt2.Value = "base64"
#     $spec.ExtraConfig = @($opt1, $opt2)
#     $vm.ExtensionData.ReconfigVM($spec)
#
#     # Power on
#     Start-VM -VM $vm
# }
#
# # Wait for IPs
# for ($i = 1; $i -le 3; $i++) {
#     $vm = Get-VM -Name "ovs-lab-node$i"
#     while (-not ($vm.Guest.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })) {
#         Start-Sleep -Seconds 10
#         $vm = Get-VM -Name "ovs-lab-node$i"
#     }
#     Write-Host "$($vm.Name) -> $($vm.Guest.IPAddress[0])"
# }
#
# # Disconnect
# Disconnect-VIServer -Confirm:$false
#
# =============================================================================

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    echo ""
    info "=== OVS Standalone Lab Setup ==="
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

    verify_ovs
    echo ""

    configure_ovs_tunnels
    echo ""

    print_summary
}

main "$@"
