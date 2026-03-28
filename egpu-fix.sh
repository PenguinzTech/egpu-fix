#!/usr/bin/env bash
# egpu-fix.sh — Reset a Thunderbolt eGPU with a broken PCIe link state
#
# Fixes the "fallen off the bus" / Unknown PCI header type 0x7f issue
# caused by the Alpine Ridge TB3 bridge caching a broken link state on boot.
#
# Hardware: Razer Core X (TB3) + NVIDIA GeForce RTX 5070 (GB205)
# Host:     Intel Alder Lake-P with Alpine Ridge 2C (JHL6340) TB4
# Driver:   nvidia-driver-590-open
# Kernel:   6.17.0+ (Ubuntu)
#
# Usage: sudo ./egpu-fix.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── PCI addresses for the Thunderbolt chain ──────────────────────────────────
TB_UPSTREAM="0000:03:00.0"      # Alpine Ridge upstream bridge
TB_DOWNSTREAM="0000:04:01.0"   # Alpine Ridge downstream bridge
GPU="0000:05:00.0"              # NVIDIA RTX 5070
GPU_AUDIO="0000:05:00.1"        # NVIDIA HD Audio

# ── Thunderbolt device UUID (Razer Core X) ───────────────────────────────────
TB_UUID="e9010000-0080-7518-a3db-e281d4357001"
TB_DEVICE_PATH="/sys/bus/thunderbolt/devices/0-1"

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root: sudo $0"
        exit 1
    fi
}

diagnose() {
    info "Running diagnostics..."
    echo

    local gpu_present
    gpu_present=$(lspci 2>/dev/null | grep -i nvidia | wc -l)
    if [[ $gpu_present -eq 0 ]]; then
        warn "No NVIDIA devices found in lspci — GPU may already be removed from bus"
    else
        info "NVIDIA devices on PCI bus:"
        lspci | grep -i nvidia || true
    fi
    echo

    info "Checking PCI config space health (looking for header type 0x7f):"
    for dev in "$GPU" "$GPU_AUDIO" "$TB_DOWNSTREAM" "$TB_UPSTREAM"; do
        local path="/sys/bus/pci/devices/${dev}"
        if [[ -e "$path" ]]; then
            local header
            header=$(lspci -v -s "$dev" 2>/dev/null | grep -i "header type\|Unknown header" | head -1 || echo "unknown")
            if echo "$header" | grep -qi "7f\|unknown header"; then
                warn "${dev}: BROKEN link state detected (${header})"
            else
                ok "${dev}: appears healthy"
            fi
        else
            warn "${dev}: not present in sysfs"
        fi
    done
    echo

    info "NVIDIA module status:"
    if lsmod | grep -q "^nvidia "; then
        ok "nvidia module loaded"
    else
        warn "nvidia module NOT loaded"
    fi
    echo
}

remove_pci_chain() {
    info "Step 1: Removing TB PCIe chain (endpoints before bridges)..."

    for dev in "$GPU_AUDIO" "$GPU" "$TB_DOWNSTREAM" "$TB_UPSTREAM"; do
        local path="/sys/bus/pci/devices/${dev}/remove"
        if [[ -e "$path" ]]; then
            echo 1 > "$path"
            ok "Removed ${dev}"
        else
            warn "Device ${dev} not in sysfs — already removed or not enumerated"
        fi
    done
    echo
}

prompt_replug() {
    echo -e "${YELLOW}Step 2: Physical replug required${NC}"
    echo "  1. Unplug the Thunderbolt cable from your laptop"
    echo "  2. Wait 3 seconds"
    echo "  3. Plug it back in"
    echo
    read -rp "Press ENTER when the cable is plugged back in..."
    echo
    info "Waiting 3 seconds for TB link negotiation..."
    sleep 3
}

rescan_pci() {
    info "Step 3: Rescanning PCI bus..."
    echo 1 > /sys/bus/pci/rescan
    ok "PCI rescan complete"
    sleep 2
    echo
}

authorize_thunderbolt() {
    info "Step 4: Authorizing Thunderbolt device..."

    if [[ -e "${TB_DEVICE_PATH}/authorized" ]]; then
        local current_auth
        current_auth=$(cat "${TB_DEVICE_PATH}/authorized" 2>/dev/null || echo "0")
        if [[ "$current_auth" == "1" ]]; then
            ok "Already authorized (boltd with auto policy beat us to it)"
        else
            echo 1 > "${TB_DEVICE_PATH}/authorized"
            ok "Authorized via sysfs (${TB_DEVICE_PATH}/authorized)"
        fi
    elif command -v boltctl &>/dev/null; then
        boltctl authorize "$TB_UUID" 2>/dev/null && ok "Authorized via boltctl" || \
            warn "boltctl authorize returned non-zero — may already be authorized"
    else
        warn "Neither sysfs TB device path nor boltctl available — skipping authorization"
        warn "You may need to manually authorize: boltctl authorize ${TB_UUID}"
    fi

    info "Waiting 3 seconds for TB authorization to settle..."
    sleep 3
    echo
}

rescan_pci_post_auth() {
    info "Step 5: Second PCI rescan (post-authorization)..."
    echo 1 > /sys/bus/pci/rescan
    ok "PCI rescan complete"
    sleep 3
    echo
}

load_nvidia() {
    info "Step 6: Loading NVIDIA driver..."
    if modprobe nvidia; then
        ok "nvidia module loaded"
    else
        err "modprobe nvidia failed — run 'sudo dmesg | grep -i nvidia' for details"
        return 1
    fi
    echo
}

verify() {
    info "Step 7: Verifying..."
    echo

    info "NVIDIA devices on PCI bus:"
    if lspci | grep -i nvidia; then
        echo
    else
        err "No NVIDIA devices found in lspci after fix"
        return 1
    fi

    info "nvidia-smi output:"
    if nvidia-smi; then
        echo
        ok "eGPU is up and running!"
    else
        err "nvidia-smi failed — GPU may still be in a bad state"
        err "Try rebooting with the Razer Core X powered on BEFORE the laptop."
        return 1
    fi
}

main() {
    require_root

    echo
    echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║        eGPU TB3 PCIe Link Reset Tool        ║${NC}"
    echo -e "${CYAN}║  Razer Core X + RTX 5070 / Alpine Ridge TB3 ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
    echo

    diagnose
    remove_pci_chain
    prompt_replug
    rescan_pci
    authorize_thunderbolt
    rescan_pci_post_auth
    load_nvidia
    verify
}

main "$@"
