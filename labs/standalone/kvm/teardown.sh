#!/bin/bash
# ==============================================================================
# teardown.sh - Clean up OVS/OVN lab environments
# ==============================================================================
#
# Description:
#   Removes all resources created by setup-ovs-lab.sh or setup-ovn-lab.sh.
#   This includes VMs, libvirt networks, OVS bridges, storage volumes, and
#   cloud-init ISOs.
#
#   Resources are identified by the lab prefix (default: "ovslab" or "ovnlab").
#   The script will list all resources it intends to remove and ask for
#   confirmation before proceeding (unless --force is used).
#
# Usage:
#   sudo ./teardown.sh [OPTIONS]
#
# Options:
#   -h, --help          Show this help message
#   -p, --prefix NAME   Lab prefix to clean up (default: auto-detect)
#   -f, --force         Skip confirmation prompt
#   --all               Remove resources for ALL known prefixes (ovslab + ovnlab)
#   --dry-run           Show what would be removed without actually removing
#
# Examples:
#   # Clean up the OVS lab
#   sudo ./teardown.sh -p ovslab
#
#   # Clean up the OVN lab without confirmation
#   sudo ./teardown.sh -p ovnlab --force
#
#   # Clean up both labs
#   sudo ./teardown.sh --all
#
#   # Preview what would be removed
#   sudo ./teardown.sh -p ovslab --dry-run
#
# ==============================================================================

set -euo pipefail

# ==============================================================================
# Configuration
# ==============================================================================

# Default prefixes used by the setup scripts
DEFAULT_OVS_PREFIX="ovslab"
DEFAULT_OVN_PREFIX="ovnlab"

# Will be set by argument parsing
LAB_PREFIX=""
FORCE=false
DRY_RUN=false
CLEAN_ALL=false

# Storage pool path (must match setup scripts)
STORAGE_POOL_PATH="${STORAGE_POOL_PATH:-/var/lib/libvirt/images}"

# Track what was cleaned up for the final report
declare -a REMOVED_VMS=()
declare -a REMOVED_NETWORKS=()
declare -a REMOVED_BRIDGES=()
declare -a REMOVED_FILES=()
declare -a SKIPPED_ITEMS=()

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

Clean up OVS/OVN lab environments created by the setup scripts.

Options:
  -h, --help          Show this help message and exit
  -p, --prefix NAME   Lab prefix to clean up (e.g., ovslab, ovnlab)
  -f, --force         Skip confirmation prompt
  --all               Remove resources for ALL known prefixes
  --dry-run           Show what would be removed without actually removing

Examples:
  sudo ./$(basename "$0") -p ovslab          # Clean OVS lab
  sudo ./$(basename "$0") -p ovnlab --force  # Clean OVN lab (no prompt)
  sudo ./$(basename "$0") --all              # Clean both labs
  sudo ./$(basename "$0") --dry-run -p ovslab  # Preview only

EOF
    exit 0
}

# parse_args - Parse command-line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            -p|--prefix)
                LAB_PREFIX="$2"
                shift 2
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            --all)
                CLEAN_ALL=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            *)
                error "Unknown option: $1"
                usage
                ;;
        esac
    done

    # If no prefix specified and not --all, try to auto-detect
    if [[ -z "${LAB_PREFIX}" ]] && [[ "${CLEAN_ALL}" == "false" ]]; then
        error "No prefix specified. Use -p PREFIX or --all."
        echo ""
        echo "Detected lab resources:"
        detect_lab_resources
        exit 1
    fi
}

# check_root - Ensure script is run as root
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        error "This script must be run as root (sudo)."
        exit 1
    fi
}

# detect_lab_resources - Scan for existing lab resources and show them
detect_lab_resources() {
    local found=false

    # Look for VMs with known prefixes
    for prefix in "${DEFAULT_OVS_PREFIX}" "${DEFAULT_OVN_PREFIX}"; do
        local vms
        vms="$(virsh list --all --name 2>/dev/null | grep "^${prefix}-" || true)"
        if [[ -n "${vms}" ]]; then
            echo "  Prefix '${prefix}': VMs found:"
            echo "${vms}" | while IFS= read -r vm; do
                echo "    - ${vm}"
            done
            found=true
        fi
    done

    # Look for any other VMs that might be lab-related
    local all_vms
    all_vms="$(virsh list --all --name 2>/dev/null | grep -v '^$' || true)"
    if [[ -n "${all_vms}" ]]; then
        echo ""
        echo "  All defined VMs:"
        echo "${all_vms}" | while IFS= read -r vm; do
            echo "    - ${vm}"
        done
    fi

    if [[ "${found}" == "false" ]]; then
        echo "  No lab resources detected."
    fi
}

# find_prefix_vms - List all VMs matching the given prefix
# Arguments:
#   $1 - Lab prefix
# Returns: Prints VM names to stdout, one per line
find_prefix_vms() {
    local prefix="$1"
    virsh list --all --name 2>/dev/null | grep "^${prefix}-" | grep -v '^$' || true
}

# find_prefix_networks - List all libvirt networks matching the prefix
# Arguments:
#   $1 - Lab prefix
# Returns: Prints network names to stdout, one per line
find_prefix_networks() {
    local prefix="$1"
    virsh net-list --all --name 2>/dev/null | grep "^${prefix}-" | grep -v '^$' || true
}

# find_prefix_bridges - List all OVS bridges matching the prefix
# Arguments:
#   $1 - Lab prefix
# Returns: Prints bridge names to stdout, one per line
find_prefix_bridges() {
    local prefix="$1"
    sudo ovs-vsctl list-br 2>/dev/null | grep "^${prefix}-" || true
}

# find_prefix_files - List storage files matching the prefix
# Arguments:
#   $1 - Lab prefix
# Returns: Prints file paths to stdout, one per line
find_prefix_files() {
    local prefix="$1"

    # Look for VM disks, cloud-init ISOs, and cloud images
    find "${STORAGE_POOL_PATH}" -maxdepth 1 -name "${prefix}-*" -type f 2>/dev/null || true
}

# list_resources - Enumerate all resources that would be removed
# Arguments:
#   $1 - Lab prefix
list_resources() {
    local prefix="$1"

    header "Resources to be removed (prefix: ${prefix})"

    # --- VMs ---
    echo -e "${COLOR_BOLD}Virtual Machines:${COLOR_RESET}"
    local vms
    vms="$(find_prefix_vms "${prefix}")"
    if [[ -n "${vms}" ]]; then
        while IFS= read -r vm; do
            local state
            state="$(virsh domstate "${vm}" 2>/dev/null)" || state="unknown"
            echo "  - ${vm} (${state})"
        done <<< "${vms}"
    else
        echo "  (none found)"
    fi
    echo ""

    # --- Networks ---
    echo -e "${COLOR_BOLD}Libvirt Networks:${COLOR_RESET}"
    local networks
    networks="$(find_prefix_networks "${prefix}")"
    if [[ -n "${networks}" ]]; then
        while IFS= read -r net; do
            local active
            active="$(virsh net-info "${net}" 2>/dev/null | grep -i 'active' | awk '{print $2}')" || active="unknown"
            echo "  - ${net} (active: ${active})"
        done <<< "${networks}"
    else
        echo "  (none found)"
    fi
    echo ""

    # --- OVS Bridges ---
    echo -e "${COLOR_BOLD}OVS Bridges:${COLOR_RESET}"
    local bridges
    bridges="$(find_prefix_bridges "${prefix}")"
    if [[ -n "${bridges}" ]]; then
        while IFS= read -r br; do
            echo "  - ${br}"
        done <<< "${bridges}"
    else
        echo "  (none found)"
    fi
    echo ""

    # --- Storage files ---
    echo -e "${COLOR_BOLD}Storage Files:${COLOR_RESET}"
    local files
    files="$(find_prefix_files "${prefix}")"
    if [[ -n "${files}" ]]; then
        while IFS= read -r f; do
            local size
            size="$(du -h "${f}" 2>/dev/null | awk '{print $1}')" || size="?"
            echo "  - ${f} (${size})"
        done <<< "${files}"
    else
        echo "  (none found)"
    fi
    echo ""
}

# remove_vms - Destroy and undefine all VMs matching the prefix
# Arguments:
#   $1 - Lab prefix
remove_vms() {
    local prefix="$1"
    local vms
    vms="$(find_prefix_vms "${prefix}")"

    if [[ -z "${vms}" ]]; then
        info "No VMs found with prefix '${prefix}'"
        return 0
    fi

    while IFS= read -r vm; do
        if [[ "${DRY_RUN}" == "true" ]]; then
            info "[DRY RUN] Would remove VM: ${vm}"
            continue
        fi

        info "Removing VM '${vm}'..."

        # Step 1: Destroy (force stop) the VM if it is running
        if vm_is_running "${vm}"; then
            info "  Stopping VM '${vm}'..."
            virsh destroy "${vm}" 2>/dev/null || true
        fi

        # Step 2: Remove any snapshots
        local snapshots
        snapshots="$(virsh snapshot-list "${vm}" --name 2>/dev/null || true)"
        if [[ -n "${snapshots}" ]]; then
            while IFS= read -r snap; do
                [[ -z "${snap}" ]] && continue
                info "  Removing snapshot '${snap}'..."
                virsh snapshot-delete "${vm}" "${snap}" 2>/dev/null || true
            done <<< "${snapshots}"
        fi

        # Step 3: Undefine the VM (remove its configuration)
        # --remove-all-storage also removes the VM's disk files
        # --nvram removes UEFI firmware variables if present
        virsh undefine "${vm}" --remove-all-storage --nvram 2>/dev/null || \
            virsh undefine "${vm}" --remove-all-storage 2>/dev/null || \
            virsh undefine "${vm}" 2>/dev/null || true

        REMOVED_VMS+=("${vm}")
        success "VM '${vm}' removed"
    done <<< "${vms}"
}

# remove_networks - Destroy and undefine all libvirt networks matching prefix
# Arguments:
#   $1 - Lab prefix
remove_networks() {
    local prefix="$1"
    local networks
    networks="$(find_prefix_networks "${prefix}")"

    if [[ -z "${networks}" ]]; then
        info "No networks found with prefix '${prefix}'"
        return 0
    fi

    while IFS= read -r net; do
        if [[ "${DRY_RUN}" == "true" ]]; then
            info "[DRY RUN] Would remove network: ${net}"
            continue
        fi

        delete_libvirt_network "${net}"
        REMOVED_NETWORKS+=("${net}")
    done <<< "${networks}"
}

# remove_ovs_bridges - Delete all OVS bridges matching the prefix
# Arguments:
#   $1 - Lab prefix
remove_ovs_bridges() {
    local prefix="$1"
    local bridges
    bridges="$(find_prefix_bridges "${prefix}")"

    if [[ -z "${bridges}" ]]; then
        info "No OVS bridges found with prefix '${prefix}'"
        return 0
    fi

    while IFS= read -r br; do
        if [[ "${DRY_RUN}" == "true" ]]; then
            info "[DRY RUN] Would remove OVS bridge: ${br}"
            continue
        fi

        delete_ovs_bridge "${br}"
        REMOVED_BRIDGES+=("${br}")
    done <<< "${bridges}"
}

# remove_storage_files - Remove cloud-init ISOs and other lab files
# Arguments:
#   $1 - Lab prefix
remove_storage_files() {
    local prefix="$1"
    local files
    files="$(find_prefix_files "${prefix}")"

    if [[ -z "${files}" ]]; then
        info "No storage files found with prefix '${prefix}'"
        return 0
    fi

    while IFS= read -r f; do
        if [[ "${DRY_RUN}" == "true" ]]; then
            info "[DRY RUN] Would remove file: ${f}"
            continue
        fi

        info "Removing file: ${f}"
        rm -f "${f}"
        REMOVED_FILES+=("${f}")
        success "Removed: ${f}"
    done <<< "${files}"
}

# clean_temp_files - Remove any leftover temporary files
clean_temp_files() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        info "[DRY RUN] Would clean temporary files in /tmp"
        return 0
    fi

    # Clean up cloud-init temp directories
    local tmp_dirs
    tmp_dirs="$(find /tmp -maxdepth 1 -name 'cloud-init-*' -type d 2>/dev/null || true)"
    if [[ -n "${tmp_dirs}" ]]; then
        while IFS= read -r d; do
            info "Removing temp directory: ${d}"
            rm -rf "${d}"
        done <<< "${tmp_dirs}"
    fi

    # Clean up network definition temp files
    local tmp_nets
    tmp_nets="$(find /tmp -maxdepth 1 -name 'net-*.xml' -type f 2>/dev/null || true)"
    if [[ -n "${tmp_nets}" ]]; then
        while IFS= read -r f; do
            info "Removing temp file: ${f}"
            rm -f "${f}"
        done <<< "${tmp_nets}"
    fi
}

# teardown_prefix - Remove all resources for a given prefix
# Arguments:
#   $1 - Lab prefix
teardown_prefix() {
    local prefix="$1"

    # Show what will be removed
    list_resources "${prefix}"

    # Ask for confirmation unless --force is set
    if [[ "${FORCE}" != "true" ]] && [[ "${DRY_RUN}" != "true" ]]; then
        if ! confirm_action "This will permanently remove all '${prefix}' lab resources."; then
            info "Teardown cancelled for prefix '${prefix}'"
            return 0
        fi
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        header "Dry run - no changes will be made"
    fi

    # Remove resources in the correct order:
    # 1. VMs first (they depend on networks and storage)
    # 2. OVS bridges (remove host-side OVS configuration)
    # 3. Networks (remove libvirt virtual networks)
    # 4. Storage files (remove any remaining disk images and ISOs)
    # 5. Temp files (clean up /tmp)

    info "Step 1/5: Removing VMs..."
    remove_vms "${prefix}"

    info "Step 2/5: Removing OVS bridges..."
    remove_ovs_bridges "${prefix}"

    info "Step 3/5: Removing libvirt networks..."
    remove_networks "${prefix}"

    info "Step 4/5: Removing storage files..."
    remove_storage_files "${prefix}"

    info "Step 5/5: Cleaning temporary files..."
    clean_temp_files
}

# print_report - Print a summary of what was cleaned up
print_report() {
    header "Teardown Report"

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "${COLOR_YELLOW}  This was a DRY RUN - no changes were made.${COLOR_RESET}"
        echo ""
        return
    fi

    # --- Removed VMs ---
    echo -e "${COLOR_BOLD}VMs Removed:${COLOR_RESET}"
    if [[ ${#REMOVED_VMS[@]} -gt 0 ]]; then
        for vm in "${REMOVED_VMS[@]}"; do
            echo "  - ${vm}"
        done
    else
        echo "  (none)"
    fi
    echo ""

    # --- Removed Networks ---
    echo -e "${COLOR_BOLD}Networks Removed:${COLOR_RESET}"
    if [[ ${#REMOVED_NETWORKS[@]} -gt 0 ]]; then
        for net in "${REMOVED_NETWORKS[@]}"; do
            echo "  - ${net}"
        done
    else
        echo "  (none)"
    fi
    echo ""

    # --- Removed Bridges ---
    echo -e "${COLOR_BOLD}OVS Bridges Removed:${COLOR_RESET}"
    if [[ ${#REMOVED_BRIDGES[@]} -gt 0 ]]; then
        for br in "${REMOVED_BRIDGES[@]}"; do
            echo "  - ${br}"
        done
    else
        echo "  (none)"
    fi
    echo ""

    # --- Removed Files ---
    echo -e "${COLOR_BOLD}Files Removed:${COLOR_RESET}"
    if [[ ${#REMOVED_FILES[@]} -gt 0 ]]; then
        for f in "${REMOVED_FILES[@]}"; do
            echo "  - ${f}"
        done
    else
        echo "  (none)"
    fi
    echo ""

    # --- Summary counts ---
    local total=$(( ${#REMOVED_VMS[@]} + ${#REMOVED_NETWORKS[@]} + ${#REMOVED_BRIDGES[@]} + ${#REMOVED_FILES[@]} ))
    separator
    success "Teardown complete. ${total} resource(s) removed."
}

# ==============================================================================
# Main execution
# ==============================================================================

main() {
    parse_args "$@"
    check_root

    header "Lab Environment Teardown"

    if [[ "${CLEAN_ALL}" == "true" ]]; then
        # Clean up both OVS and OVN lab prefixes
        info "Cleaning up all known lab prefixes..."

        for prefix in "${DEFAULT_OVS_PREFIX}" "${DEFAULT_OVN_PREFIX}"; do
            # Check if any resources exist for this prefix
            local has_resources=false
            [[ -n "$(find_prefix_vms "${prefix}")" ]] && has_resources=true
            [[ -n "$(find_prefix_networks "${prefix}")" ]] && has_resources=true
            [[ -n "$(find_prefix_bridges "${prefix}")" ]] && has_resources=true
            [[ -n "$(find_prefix_files "${prefix}")" ]] && has_resources=true

            if [[ "${has_resources}" == "true" ]]; then
                teardown_prefix "${prefix}"
            else
                info "No resources found for prefix '${prefix}', skipping"
            fi
        done
    else
        teardown_prefix "${LAB_PREFIX}"
    fi

    print_report
}

main "$@"
