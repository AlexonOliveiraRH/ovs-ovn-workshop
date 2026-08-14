#!/bin/bash
# restore-lab.sh - Recreate OVS hands-on lab state after a reboot
#
# After a reboot, OVS bridges survive (stored in OVSDB) but namespaces,
# veth pairs, and IP addresses do not. This script recreates everything
# up to the start of Exercise 7 (Port Mirroring).
#
# Usage: sudo bash restore-lab.sh

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

echo "=== Restoring OVS Hands-On Lab ==="
echo ""

# Clean up any stale OVS config from before reboot
echo "[1/8] Cleaning stale OVS configuration..."
ovs-vsctl --if-exists del-br br0
ovs-vsctl --if-exists del-br br1
ovs-vsctl -- --all destroy qos 2>/dev/null
ovs-vsctl -- --all destroy queue 2>/dev/null

# Clean up any leftover namespaces
for ns in vm1 vm2 vm3 vm4 vm5 vm6 monitor trunk-ns; do
    ip netns del "$ns" 2>/dev/null || true
done

# Clean up any leftover veth pairs
for veth in veth-vm1 veth-vm2 veth-vm3 veth-vm4 veth-vm5 veth-vm6 veth-mirror veth-trunk eth-a eth-b; do
    ip link del "$veth" 2>/dev/null || true
done

# Exercise 2: Create bridge
echo "[2/8] Creating br0 bridge..."
ovs-vsctl add-br br0
ip addr add 10.0.0.254/24 dev br0
ip link set br0 up

# Exercise 3: Create vm1 and vm2
echo "[3/8] Creating vm1 and vm2 namespaces..."
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

# Exercise 4: Create vm3 and vm4
echo "[4/8] Creating vm3 and vm4 namespaces..."
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

# Exercise 5: Ensure NORMAL flow is set
echo "[5/8] Setting NORMAL flow on br0..."
ovs-ofctl del-flows br0
ovs-ofctl add-flow br0 "priority=0,actions=NORMAL"

# Exercise 6: Create br1 with vm5/vm6 and Geneve tunnel
echo "[6/8] Creating br1 bridge with vm5 and vm6..."
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

echo "[7/8] Creating Geneve tunnel between br0 and br1..."
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

# Verify
echo "[8/8] Verifying lab state..."
echo ""

PASS=0
FAIL=0

for src in vm1 vm2 vm3 vm4; do
    for dst in 10.0.0.1 10.0.0.2 10.0.0.3 10.0.0.4; do
        if ip netns exec "$src" ping -c 1 -W 1 "$dst" >/dev/null 2>&1; then
            PASS=$((PASS+1))
        else
            echo "  FAIL: $src -> $dst"
            FAIL=$((FAIL+1))
        fi
    done
done

# Tunnel connectivity
for pair in "vm1:10.0.0.5" "vm2:10.0.0.6" "vm5:10.0.0.1" "vm6:10.0.0.2"; do
    src="${pair%%:*}"
    dst="${pair##*:}"
    if ip netns exec "$src" ping -c 1 -W 1 "$dst" >/dev/null 2>&1; then
        PASS=$((PASS+1))
    else
        echo "  FAIL: $src -> $dst (tunnel)"
        FAIL=$((FAIL+1))
    fi
done

echo "=== Lab Restored ==="
echo "  Bridges: br0 (vm1-vm4 + geneve0), br1 (vm5-vm6 + geneve1)"
echo "  Tests: $PASS passed, $FAIL failed"
echo "  Ready for: Exercise 7 (Port Mirroring)"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "WARNING: Some connectivity tests failed. Check 'ovs-vsctl show' for details."
    exit 1
fi
