#!/bin/bash
set -euo pipefail

# =============================================================================
# teardown.sh - Clean up OVS and OVN lab resources on VMware vSphere
# =============================================================================
#
# This script destroys all VMs and associated resources created by
# setup-ovs-lab.sh and/or setup-ovn-lab.sh. It removes VMs, cleans up
# vSphere folders, and deletes local state files.
#
# Usage:
#   ./teardown.sh                    # Interactive mode (prompts for confirmation)
#   ./teardown.sh --force            # Skip confirmation prompts
#   ./teardown.sh --prefix ovs-lab   # Tear down only OVS lab resources
#   ./teardown.sh --prefix ovn-lab   # Tear down only OVN lab resources
#   ./teardown.sh --dry-run          # Show what would be destroyed without acting
#
# Prerequisites:
#   1. govc installed and GOVC_* environment variables set
#   2. Same environment variables used during setup
#
# Environment Variables (GOVC):
#   GOVC_URL        - vCenter or ESXi URL
#   GOVC_USERNAME   - vSphere login username
#   GOVC_PASSWORD   - vSphere login password
#   GOVC_DATACENTER - Target datacenter name
#   GOVC_DATASTORE  - Datastore for VM disks
#   GOVC_INSECURE   - Set to "true" to skip TLS certificate verification
#
# =============================================================================

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------

# By default, tear down both OVS and OVN labs.
# Override with --prefix to target a specific lab.
PREFIXES=("ovs-lab" "ovn-lab")

# Flags.
FORCE=false
DRY_RUN=false

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
# Parse Arguments
# -----------------------------------------------------------------------------

parse_args() {
    local custom_prefix=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f)
                FORCE=true
                shift
                ;;
            --dry-run|-n)
                DRY_RUN=true
                shift
                ;;
            --prefix|-p)
                if [[ -z "${2:-}" ]]; then
                    fatal "--prefix requires a value (e.g., --prefix ovs-lab)"
                fi
                if [[ "${custom_prefix}" == false ]]; then
                    PREFIXES=()
                    custom_prefix=true
                fi
                PREFIXES+=("$2")
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --force, -f          Skip confirmation prompts"
                echo "  --dry-run, -n        Show what would be destroyed without acting"
                echo "  --prefix, -p NAME    Target a specific lab prefix (can be repeated)"
                echo "  --help, -h           Show this help message"
                echo ""
                echo "Examples:"
                echo "  $0                   # Tear down all labs (interactive)"
                echo "  $0 --force           # Tear down all labs (no prompts)"
                echo "  $0 --prefix ovs-lab  # Only tear down OVS lab"
                echo "  $0 --dry-run         # Preview what would be destroyed"
                exit 0
                ;;
            *)
                fatal "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Prerequisite Checks
# -----------------------------------------------------------------------------

check_prerequisites() {
    info "Checking prerequisites..."

    if ! command -v govc &>/dev/null; then
        fatal "govc is not installed or not in PATH."
    fi
    ok "govc found: $(govc version)"

    local required_vars=(GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_DATACENTER)
    local missing=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        fatal "Missing required environment variables: ${missing[*]}"
    fi
    ok "GOVC_* environment variables are set"

    if ! govc about &>/dev/null; then
        fatal "Cannot connect to vSphere at ${GOVC_URL}."
    fi
    ok "Connected to vSphere"
}

# -----------------------------------------------------------------------------
# Discover Lab Resources
# Find all VMs and folders matching the lab prefixes.
# -----------------------------------------------------------------------------

discover_resources() {
    local prefix="$1"

    info "Discovering resources for prefix '${prefix}'..."

    # Find VMs whose names start with the lab prefix.
    # govc find searches the vSphere inventory by type and name pattern.
    local -a vms=()
    while IFS= read -r vm; do
        [[ -n "${vm}" ]] && vms+=("${vm}")
    done < <(govc find / -type m -name "${prefix}-*" 2>/dev/null || true)

    if [[ ${#vms[@]} -gt 0 ]]; then
        info "Found ${#vms[@]} VM(s) matching '${prefix}-*':"
        for vm in "${vms[@]}"; do
            echo "    - ${vm}"
        done
    else
        info "No VMs found matching '${prefix}-*'"
    fi

    # Check if the folder exists.
    local folder_exists=false
    if govc folder.info "vm/${prefix}" &>/dev/null; then
        folder_exists=true
        info "Found folder: vm/${prefix}"
    fi

    # Export discovered resources via global arrays.
    DISCOVERED_VMS=("${vms[@]}")
    DISCOVERED_FOLDER_EXISTS="${folder_exists}"
    DISCOVERED_PREFIX="${prefix}"
}

# -----------------------------------------------------------------------------
# Confirmation Prompt
# Asks the user to confirm before destroying resources.
# -----------------------------------------------------------------------------

confirm_teardown() {
    if [[ "${FORCE}" == true ]]; then
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        return 0
    fi

    echo ""
    echo -e "${RED}WARNING: This will permanently destroy the following resources:${NC}"
    echo ""

    for prefix in "${PREFIXES[@]}"; do
        echo "  Prefix: ${prefix}"
        # List VMs for this prefix.
        local vms
        vms=$(govc find / -type m -name "${prefix}-*" 2>/dev/null || true)
        if [[ -n "${vms}" ]]; then
            while IFS= read -r vm; do
                echo "    VM: ${vm}"
            done <<< "${vms}"
        fi
        if govc folder.info "vm/${prefix}" &>/dev/null; then
            echo "    Folder: vm/${prefix}"
        fi
        echo ""
    done

    echo -n "Are you sure you want to continue? [y/N] "
    read -r response
    case "${response}" in
        [yY]|[yY][eE][sS])
            return 0
            ;;
        *)
            info "Teardown cancelled."
            exit 0
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Destroy VMs
# Power off and delete VMs matching the lab prefix.
# -----------------------------------------------------------------------------

destroy_vms() {
    local prefix="$1"

    # Find VMs with this prefix.
    local -a vms=()
    while IFS= read -r vm; do
        [[ -n "${vm}" ]] && vms+=("${vm}")
    done < <(govc find / -type m -name "${prefix}-*" 2>/dev/null || true)

    if [[ ${#vms[@]} -eq 0 ]]; then
        info "No VMs to destroy for prefix '${prefix}'"
        return 0
    fi

    for vm in "${vms[@]}"; do
        local vm_name
        vm_name=$(basename "${vm}")

        if [[ "${DRY_RUN}" == true ]]; then
            info "[DRY RUN] Would destroy VM: ${vm_name}"
            continue
        fi

        info "Destroying VM: ${vm_name}"

        # Power off the VM first. The -force flag tells govc not to wait
        # for a graceful shutdown - it performs a hard power off.
        # This is acceptable for lab VMs. The || true handles VMs that
        # are already powered off.
        govc vm.power -off -force "${vm_name}" 2>/dev/null || true
        ok "Powered off '${vm_name}'"

        # Destroy the VM. This removes the VM from the inventory AND
        # deletes its disk files from the datastore.
        govc vm.destroy "${vm_name}" 2>/dev/null || {
            warn "Failed to destroy '${vm_name}' - it may have already been removed"
            continue
        }
        ok "Destroyed '${vm_name}'"
    done
}

# -----------------------------------------------------------------------------
# Remove vSphere Folder
# Remove the lab folder from the VM inventory. The folder must be empty
# (all VMs must be destroyed first).
# -----------------------------------------------------------------------------

remove_folder() {
    local prefix="$1"

    if ! govc folder.info "vm/${prefix}" &>/dev/null; then
        info "Folder 'vm/${prefix}' does not exist - nothing to remove"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        info "[DRY RUN] Would remove folder: vm/${prefix}"
        return 0
    fi

    info "Removing folder: vm/${prefix}"

    # govc object.destroy removes inventory objects. For folders, it only
    # succeeds if the folder is empty.
    govc object.destroy "vm/${prefix}" 2>/dev/null || {
        warn "Could not remove folder 'vm/${prefix}' - it may not be empty.
  Check for leftover objects: govc find vm/${prefix} -type m"
        return 0
    }
    ok "Removed folder 'vm/${prefix}'"
}

# -----------------------------------------------------------------------------
# Clean Up Local State Files
# Remove the state files and any leftover cloud-init userdata files
# generated by the setup scripts.
# -----------------------------------------------------------------------------

cleanup_local_files() {
    local prefix="$1"
    local state_file="/tmp/${prefix}-state.env"

    # Remove the state file.
    if [[ -f "${state_file}" ]]; then
        if [[ "${DRY_RUN}" == true ]]; then
            info "[DRY RUN] Would remove state file: ${state_file}"
        else
            rm -f "${state_file}"
            ok "Removed state file: ${state_file}"
        fi
    else
        info "No state file found at ${state_file}"
    fi

    # Remove any leftover cloud-init userdata files.
    local userdata_files
    userdata_files=$(find /tmp -maxdepth 1 -name "${prefix}-*-userdata.yaml" 2>/dev/null || true)

    if [[ -n "${userdata_files}" ]]; then
        while IFS= read -r f; do
            if [[ "${DRY_RUN}" == true ]]; then
                info "[DRY RUN] Would remove temp file: ${f}"
            else
                rm -f "${f}"
                ok "Removed temp file: ${f}"
            fi
        done <<< "${userdata_files}"
    fi
}

# -----------------------------------------------------------------------------
# Teardown a Single Prefix
# Orchestrates the full cleanup for one lab prefix.
# -----------------------------------------------------------------------------

teardown_prefix() {
    local prefix="$1"

    echo ""
    info "--- Tearing down '${prefix}' resources ---"
    echo ""

    destroy_vms "${prefix}"
    echo ""

    remove_folder "${prefix}"
    echo ""

    cleanup_local_files "${prefix}"
}

# -----------------------------------------------------------------------------
# Print Teardown Summary
# -----------------------------------------------------------------------------

print_summary() {
    echo ""
    echo "============================================================================="

    if [[ "${DRY_RUN}" == true ]]; then
        echo " Teardown Dry Run Complete"
        echo "============================================================================="
        echo ""
        echo " No resources were modified. Re-run without --dry-run to execute."
    else
        echo " Teardown Complete"
        echo "============================================================================="
        echo ""
        echo " All lab resources for the following prefixes have been cleaned up:"
        for prefix in "${PREFIXES[@]}"; do
            echo "   - ${prefix}"
        done
    fi

    echo ""
    echo "============================================================================="
    echo ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    parse_args "$@"

    echo ""
    info "=== Lab Teardown ==="
    if [[ "${DRY_RUN}" == true ]]; then
        info "(DRY RUN mode - no changes will be made)"
    fi
    echo ""

    check_prerequisites
    echo ""

    confirm_teardown

    for prefix in "${PREFIXES[@]}"; do
        teardown_prefix "${prefix}"
    done

    print_summary
}

main "$@"
