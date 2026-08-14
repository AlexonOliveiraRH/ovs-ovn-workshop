#!/bin/bash
# restore-lab.sh - Recreate OVS hands-on lab state after a reboot
#
# After a reboot, OVS bridges survive (stored in OVSDB) but namespaces,
# veth pairs, and IP addresses do not. This script recreates everything
# up to the specified exercise.
#
# Usage: sudo bash restore-lab.sh [EXERCISE_NUMBER]
#
# Examples:
#   sudo bash restore-lab.sh       # Restore up to Exercise 6 (default)
#   sudo bash restore-lab.sh 3     # Restore up to Exercise 3 (br0 + vm1 + vm2)
#   sudo bash restore-lab.sh 6     # Restore up to Exercise 6 (full topology)
#
# Exercise dependencies (each builds on the previous):
#   Exercise 1: OVS installation/verification (nothing to restore)
#   Exercise 2: br0 bridge
#   Exercise 3: vm1 and vm2 on br0
#   Exercise 4: vm3 and vm4 on br0
#   Exercise 5: OpenFlow NORMAL flow on br0
#   Exercise 6: br1 with vm5/vm6 + Geneve tunnel
#   Exercise 7-10: Start from Exercise 6 state (each does its own setup/cleanup)

set -e

TARGET=${1:-6}

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

if [ "$TARGET" -lt 2 ] || [ "$TARGET" -gt 10 ]; then
    echo "ERROR: Exercise number must be between 2 and 10"
    echo "Usage: $0 [EXERCISE_NUMBER]"
    exit 1
fi

# Exercises 7-10 all start from the same base state (end of Exercise 6)
if [ "$TARGET" -gt 6 ]; then
    EFFECTIVE_TARGET=6
else
    EFFECTIVE_TARGET=$TARGET
fi

cleanup() {
    echo "[cleanup] Removing stale OVS configuration..."
    ovs-vsctl --if-exists del-br br0
    ovs-vsctl --if-exists del-br br1
    ovs-vsctl -- --all destroy qos 2>/dev/null || true
    ovs-vsctl -- --all destroy queue 2>/dev/null || true

    for ns in vm1 vm2 vm3 vm4 vm5 vm6 monitor trunk-ns; do
        ip netns del "$ns" 2>/dev/null || true
    done

    for veth in veth-vm1 veth-vm2 veth-vm3 veth-vm4 veth-vm5 veth-vm6 veth-mirror veth-trunk eth-a eth-b; do
        ip link del "$veth" 2>/dev/null || true
    done
}

exercise_2() {
    echo "[exercise 2] Creating br0 bridge..."
    ovs-vsctl add-br br0
    ip addr add 10.0.0.254/24 dev br0
    ip link set br0 up
}

exercise_3() {
    echo "[exercise 3] Creating vm1 and vm2..."
    for i in 1 2; do
        ip netns add "vm$i"
        ip link add "veth-vm$i" type veth peer name "eth0-vm$i"
        ip link set "eth0-vm$i" netns "vm$i"
        ovs-vsctl add-port br0 "veth-vm$i"
        ip link set "veth-vm$i" up
        ip netns exec "vm$i" ip addr add "10.0.0.$i/24" dev "eth0-vm$i"
        ip netns exec "vm$i" ip link set "eth0-vm$i" up
        ip netns exec "vm$i" ip link set lo up
    done
}

exercise_4() {
    echo "[exercise 4] Creating vm3 and vm4..."
    for i in 3 4; do
        ip netns add "vm$i"
        ip link add "veth-vm$i" type veth peer name "eth0-vm$i"
        ip link set "eth0-vm$i" netns "vm$i"
        ovs-vsctl add-port br0 "veth-vm$i"
        ip link set "veth-vm$i" up
        ip netns exec "vm$i" ip addr add "10.0.0.$i/24" dev "eth0-vm$i"
        ip netns exec "vm$i" ip link set "eth0-vm$i" up
        ip netns exec "vm$i" ip link set lo up
    done
}

exercise_5() {
    echo "[exercise 5] Setting NORMAL flow on br0..."
    ovs-ofctl del-flows br0
    ovs-ofctl add-flow br0 "priority=0,actions=NORMAL"
}

exercise_6() {
    echo "[exercise 6] Creating br1 with vm5/vm6 and Geneve tunnel..."
    ovs-vsctl add-br br1
    ip addr add 172.16.0.1/24 dev br0
    ip addr add 172.16.0.2/24 dev br1
    ip link set br1 up

    for i in 5 6; do
        ip netns add "vm$i"
        ip link add "veth-vm$i" type veth peer name "eth0-vm$i"
        ip link set "eth0-vm$i" netns "vm$i"
        ovs-vsctl add-port br1 "veth-vm$i"
        ip link set "veth-vm$i" up
        ip netns exec "vm$i" ip addr add "10.0.0.$i/24" dev "eth0-vm$i"
        ip netns exec "vm$i" ip link set "eth0-vm$i" up
        ip netns exec "vm$i" ip link set lo up
    done

    ovs-vsctl add-port br0 geneve0 -- set interface geneve0 \
        type=geneve \
        options:remote_ip=172.16.0.2 \
        options:local_ip=172.16.0.1 \
        options:key=2000

    ovs-vsctl add-port br1 geneve1 -- set interface geneve1 \
        type=geneve \
        options:remote_ip=172.16.0.1 \
        options:local_ip=172.16.0.2 \
        options:key=2000

    ovs-ofctl add-flow br1 "priority=0,actions=NORMAL"
}

verify() {
    echo ""
    echo "[verify] Testing connectivity..."
    local PASS=0
    local FAIL=0

    # Test local bridge connectivity (vm1-vm4 on br0)
    if [ "$EFFECTIVE_TARGET" -ge 3 ]; then
        local MAX_VM=2
        [ "$EFFECTIVE_TARGET" -ge 4 ] && MAX_VM=4

        for src_i in $(seq 1 $MAX_VM); do
            for dst_i in $(seq 1 $MAX_VM); do
                if ip netns exec "vm$src_i" ping -c 1 -W 1 "10.0.0.$dst_i" >/dev/null 2>&1; then
                    PASS=$((PASS+1))
                else
                    echo "  FAIL: vm$src_i -> 10.0.0.$dst_i"
                    FAIL=$((FAIL+1))
                fi
            done
        done
    fi

    # Test tunnel connectivity (vm1/vm2 <-> vm5/vm6)
    if [ "$EFFECTIVE_TARGET" -ge 6 ]; then
        for pair in "vm1:10.0.0.5" "vm2:10.0.0.6" "vm5:10.0.0.1" "vm6:10.0.0.2"; do
            local src="${pair%%:*}"
            local dst="${pair##*:}"
            if ip netns exec "$src" ping -c 1 -W 1 "$dst" >/dev/null 2>&1; then
                PASS=$((PASS+1))
            else
                echo "  FAIL: $src -> $dst (tunnel)"
                FAIL=$((FAIL+1))
            fi
        done
    fi

    echo ""
    echo "=== Lab Restored (up to Exercise $TARGET) ==="

    case $EFFECTIVE_TARGET in
        2) echo "  Topology: br0 (empty bridge)" ;;
        3) echo "  Topology: br0 (vm1, vm2)" ;;
        4) echo "  Topology: br0 (vm1-vm4)" ;;
        5) echo "  Topology: br0 (vm1-vm4, NORMAL flow)" ;;
        6) echo "  Topology: br0 (vm1-vm4 + geneve0), br1 (vm5-vm6 + geneve1)" ;;
    esac

    if [ $PASS -gt 0 ] || [ $FAIL -gt 0 ]; then
        echo "  Tests: $PASS passed, $FAIL failed"
    fi

    echo "  Ready for: Exercise $TARGET"
    echo ""

    if [ "$FAIL" -gt 0 ]; then
        echo "WARNING: Some connectivity tests failed. Check 'ovs-vsctl show' for details."
        exit 1
    fi
}

# --- Main ---
echo "=== Restoring OVS Hands-On Lab (up to Exercise $TARGET) ==="
echo ""

cleanup

for ex in $(seq 2 $EFFECTIVE_TARGET); do
    "exercise_$ex"
done

verify
