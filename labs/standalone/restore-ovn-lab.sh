#!/bin/bash
#
# OVN Hands-On Lab (Module 05) - Restore Script
#
# Restaura o estado ao fim do exercício informado: restore 6 prepara o 7.
# Execute em uma máquina com acesso SSH aos três nós do laboratório,
# ou diretamente no nó central.
#
# Usage: bash restore-ovn-lab.sh [exercise_number]
#   exercise_number: 1-10 (default: 10, restores everything)
#
# Configuration:
#   Set the following environment variables before running, or edit the
#   defaults below to match your lab. If running directly on the central
#   node, set CENTRAL to "local".
#
#   CENTRAL      - SSH target for the central node (default: root@central)
#                  Set to "local" if running this script on the central node
#   COMPUTE1     - SSH target for compute node 1 (default: root@compute1)
#   COMPUTE2     - SSH target for compute node 2 (default: root@compute2)
#   CENTRAL_IP   - Central node's IP for tunnel encapsulation and SB DB access
#   COMPUTE1_IP  - Compute1's IP for tunnel encapsulation
#   COMPUTE2_IP  - Compute2's IP for tunnel encapsulation
#
# Examples:
#   # Full restore with all variables
#   CENTRAL=root@10.0.0.1 COMPUTE1=root@10.0.0.2 COMPUTE2=root@10.0.0.3 \
#   CENTRAL_IP=10.0.0.1 COMPUTE1_IP=10.0.0.2 COMPUTE2_IP=10.0.0.3 \
#       bash restore-ovn-lab.sh 10
#
#   # Running directly on the central node
#   CENTRAL=local COMPUTE1=root@compute1 COMPUTE2=root@compute2 \
#   CENTRAL_IP=10.0.0.1 COMPUTE1_IP=10.0.0.2 COMPUTE2_IP=10.0.0.3 \
#       bash restore-ovn-lab.sh 6
#
# Mantenha lab-netns.sh no mesmo diretório deste script.
# Os exercícios 9 e 10 requerem Python 3 e curl em central, onde estão vm4–vm6.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lab-netns.sh"

CENTRAL="${CENTRAL:-root@central}"
COMPUTE1="${COMPUTE1:-root@compute1}"
COMPUTE2="${COMPUTE2:-root@compute2}"
CENTRAL_IP="${CENTRAL_IP:-}"
COMPUTE1_IP="${COMPUTE1_IP:-}"
COMPUTE2_IP="${COMPUTE2_IP:-}"

TARGET=${1:-10}

show_usage() {
    echo "Usage: $0 [exercise_number]"
    echo "  exercise_number: 1-10 (default: 10)"
    echo ""
    echo "  1  - Start services, configure databases, register chassis"
    echo "  2  - Logical switch and ports (network1, vm1-vm3)"
    echo "  3  - Namespaces and L2 connectivity"
    echo "  4  - DHCP on network1"
    echo "  5  - Multi-node (vm3 on compute1)"
    echo "  6  - Router and network2 (vm4, vm5, L3 routing)"
    echo "  7  - ACLs on network1"
    echo "  8  - NAT (external switch, SNAT, DNAT)"
    echo "  9  - Load balancing (vm6, web-lb)"
    echo "  10 - Full lab (same as 9, ready for debugging exercises)"
    echo ""
    echo "Environment variables:"
    echo "  CENTRAL=$CENTRAL"
    echo "  COMPUTE1=$COMPUTE1"
    echo "  COMPUTE2=$COMPUTE2"
    echo "  CENTRAL_IP=$CENTRAL_IP"
    echo "  COMPUTE1_IP=$COMPUTE1_IP"
    echo "  COMPUTE2_IP=$COMPUTE2_IP"
}

if [[ ! "$TARGET" =~ ^([1-9]|10)$ ]]; then
    show_usage
    exit 1
fi

if [[ "$TARGET" -ge 1 && ( -z "$CENTRAL_IP" || -z "$COMPUTE1_IP" || -z "$COMPUTE2_IP" ) ]]; then
    echo "ERROR: Exercise 1 (and above) requires node IPs for tunnel configuration."
    echo ""
    echo "Set the following environment variables:"
    echo "  CENTRAL_IP   - Central node's IP (e.g., 192.168.1.10)"
    echo "  COMPUTE1_IP  - Compute node 1's IP (e.g., 192.168.1.11)"
    echo "  COMPUTE2_IP  - Compute node 2's IP (e.g., 192.168.1.12)"
    echo ""
    echo "Example:"
    echo "  CENTRAL=$CENTRAL COMPUTE1=$COMPUTE1 COMPUTE2=$COMPUTE2 \\"
    echo "  CENTRAL_IP=192.168.1.10 COMPUTE1_IP=192.168.1.11 COMPUTE2_IP=192.168.1.12 \\"
    echo "      $0 $TARGET"
    exit 1
fi

# Validar antes de interpolar valores no código remoto ou iniciar o SSH.
# A configuração tcp:IP:porta deste lab aceita somente IPv4 decimal.
valid_ipv4() {
    local address="$1" octet
    local -a octets
    [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
        [[ "$octet" == 0 || "$octet" != 0* ]] && (( 10#$octet <= 255 )) || return 1
    done
}

for variable in CENTRAL_IP COMPUTE1_IP COMPUTE2_IP; do
    if ! valid_ipv4 "${!variable}"; then
        echo "ERRO: $variable deve conter um endereço IPv4 decimal válido, sem opções ou comandos." >&2
        exit 1
    fi
done
for variable in CENTRAL COMPUTE1 COMPUTE2; do
    # Alias SSH, hostname ou IPv4, opcionalmente precedido por usuário@.
    if [[ ! "${!variable}" =~ ^([a-zA-Z_][a-zA-Z0-9_.-]*@)?[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] ||
       [[ "$variable" != CENTRAL && "${!variable}" == local ]]; then
        echo "ERRO: $variable deve conter um destino SSH simples; somente CENTRAL aceita local." >&2
        exit 1
    fi
done

run_node() {
    local node="$1" script="$2"
    # O shell iniciado por SSH não herda as opções do shell local.
    if [[ "$node" == "local" ]]; then
        bash -euo pipefail -s <<< "$script"
    else
        ssh -- "$node" 'bash -euo pipefail -s' <<< "$script"
    fi
}

run_central() { run_node "$CENTRAL" "$1"; }
run_compute1() { run_node "$COMPUTE1" "$1"; }
run_compute2() { run_node "$COMPUTE2" "$1"; }

get_central_system_id() {
    run_central 'ovs-vsctl get open_vswitch . external_ids:system-id 2>/dev/null | tr -d \"'
}

cleanup() {
    echo "=== Cleaning up existing OVN lab state ==="

    # Clean namespaces and OVS ports on central
    run_central "$(declare -f cleanup_lab_namespaces)
        cleanup_lab_namespaces vm1 vm2 vm4 vm5 vm6 ext-gw
    "
    run_central '
        for port in vm1 vm2 vm4 vm5 vm6 ext-gw; do
            ovs-vsctl --if-exists del-port br-int "$port"
        done
    '

    # Clean namespaces and OVS ports on compute1
    run_compute1 "$(declare -f cleanup_lab_namespaces)
        cleanup_lab_namespaces vm3
    "
    run_compute1 '
        ovs-vsctl --if-exists del-port br-int vm3
    '

    # O workshop não cria namespaces em compute2. Não há nada a excluir ali.
    # Não esvaziar conntrack globalmente: isso também afetaria tráfego alheio.
    run_central '
        # DHCP_Options é raiz: excluir switches não coleta esses registros.
        # Preservar legados sem marca e registros usados por portas externas.
        owned=$(ovn-nbctl --format=csv --data=bare --no-heading --columns=_uuid find DHCP_Options external_ids:workshop=restore-ovn-lab)
        for uuid in $owned; do
            shared=0
            for column in dhcpv4_options dhcpv6_options; do
                refs=$(ovn-nbctl --format=csv --data=bare --no-heading --columns=name find Logical_Switch_Port "$column=$uuid")
                while IFS= read -r port; do
                    case "$port" in
                        ""|vm1|vm2|vm3) ;;
                        *) shared=1 ;;
                    esac
                done <<< "$refs"
            done
            if [[ "$shared" == 0 ]]; then
                ovn-nbctl destroy DHCP_Options "$uuid"
            fi
        done
        ovn-nbctl --if-exists lb-del web-lb
        ovn-nbctl --if-exists lr-del router1
        ovn-nbctl --if-exists ls-del network1
        ovn-nbctl --if-exists ls-del network2
        ovn-nbctl --if-exists ls-del external
    '
    echo "Cleanup complete."
}

exercise_1() {
    echo "--- Exercise 1: Start services and register chassis ---"

    # Phase 1: Start OVS and OVN central, stop ovn-controller everywhere.
    # ovn-controller must be stopped before clearing stale chassis entries,
    # otherwise a running controller re-registers the stale entry immediately.
    run_central "
        systemctl enable --now openvswitch
        systemctl enable --now ovn-northd
        ovn-sbctl set-connection ptcp:6642
        ovn-nbctl set-connection ptcp:6641
        if systemctl is-active firewalld >/dev/null 2>&1; then
            firewall-cmd --add-port=6641/tcp --add-port=6642/tcp --permanent
            firewall-cmd --add-port=6081/udp --permanent
            firewall-cmd --reload
        fi
        systemctl stop ovn-controller
    "
    run_compute1 "
        systemctl enable --now openvswitch
        if systemctl is-active firewalld >/dev/null 2>&1; then
            firewall-cmd --add-port=6081/udp --permanent
            firewall-cmd --reload
        fi
        systemctl stop ovn-controller
    "
    run_compute2 "
        systemctl enable --now openvswitch
        if systemctl is-active firewalld >/dev/null 2>&1; then
            firewall-cmd --add-port=6081/udp --permanent
            firewall-cmd --reload
        fi
        systemctl stop ovn-controller
    "

    # Limpar com OVS/NB disponíveis e os três controllers já parados.
    cleanup

    # Phase 2: Clear stale chassis, set external_ids, start ovn-controller.
    # After a reboot, chassis entries from a previous session persist in the
    # SB database. If the system-id changed, the old entry blocks registration
    # ("already has encap ip ... cannot duplicate").
    # Capturar os IDs atuais dos três nós antes de substituí-los.
    # IDs antigos não associados a esses nós exigem investigação manual.
    local central_id compute1_id compute2_id chassis_names
    central_id=$(get_central_system_id)
    compute1_id=$(run_compute1 'ovs-vsctl get open_vswitch . external_ids:system-id | tr -d \"')
    compute2_id=$(run_compute2 'ovs-vsctl get open_vswitch . external_ids:system-id | tr -d \"')
    printf -v chassis_names '%q ' "$central_id" "$compute1_id" "$compute2_id" central compute1 compute2
    run_central "
        for ch in $chassis_names; do
            if [[ -n \"\$ch\" && \"\$ch\" != '[]' ]]; then
                ovn-sbctl --if-exists chassis-del \"\$ch\"
            fi
        done
        ovs-vsctl set open_vswitch . \\
            external_ids:ovn-remote=unix:/run/ovn/ovnsb_db.sock \\
            external_ids:ovn-encap-type=geneve \\
            external_ids:ovn-encap-ip=$CENTRAL_IP \\
            external_ids:system-id=central
        systemctl enable --now ovn-controller
    "
    run_compute1 "
        ovs-vsctl set open_vswitch . \\
            external_ids:ovn-remote=tcp:$CENTRAL_IP:6642 \\
            external_ids:ovn-encap-type=geneve \\
            external_ids:ovn-encap-ip=$COMPUTE1_IP \\
            external_ids:system-id=compute1
        systemctl enable --now ovn-controller
    "
    run_compute2 "
        ovs-vsctl set open_vswitch . \\
            external_ids:ovn-remote=tcp:$CENTRAL_IP:6642 \\
            external_ids:ovn-encap-type=geneve \\
            external_ids:ovn-encap-ip=$COMPUTE2_IP \\
            external_ids:system-id=compute2
        systemctl enable --now ovn-controller
    "

    # Wait for chassis registration
    sleep 3
    echo "  Registered chassis:"
    run_central 'ovn-sbctl show' 2>/dev/null | grep -E "Chassis|hostname|ip:" | sed 's/^/    /'
}

exercise_2() {
    echo "--- Exercise 2: Logical switch and ports ---"

    run_central '
        ovn-nbctl ls-add network1

        ovn-nbctl lsp-add network1 vm1
        ovn-nbctl lsp-set-addresses vm1 "00:00:00:00:00:01 10.0.0.11"
        ovn-nbctl lsp-set-port-security vm1 "00:00:00:00:00:01 10.0.0.11"

        ovn-nbctl lsp-add network1 vm2
        ovn-nbctl lsp-set-addresses vm2 "00:00:00:00:00:02 10.0.0.12"
        ovn-nbctl lsp-set-port-security vm2 "00:00:00:00:00:02 10.0.0.12"

        ovn-nbctl lsp-add network1 vm3
        ovn-nbctl lsp-set-addresses vm3 "00:00:00:00:00:03 10.0.0.13"
        ovn-nbctl lsp-set-port-security vm3 "00:00:00:00:00:03 10.0.0.13"
    '
}

exercise_3() {
    echo "--- Exercise 3: Namespaces and L2 connectivity ---"

    run_central '
        # vm1
        ip netns add vm1
        ovs-vsctl add-port br-int vm1 -- set interface vm1 \
            type=internal external_ids:iface-id=vm1
        ip link set vm1 netns vm1
        ip netns exec vm1 ip link set vm1 address 00:00:00:00:00:01
        ip netns exec vm1 ip link set vm1 up
        ip netns exec vm1 ip addr add 10.0.0.11/24 dev vm1
        ip netns exec vm1 ip route add default via 10.0.0.1

        # vm2
        ip netns add vm2
        ovs-vsctl add-port br-int vm2 -- set interface vm2 \
            type=internal external_ids:iface-id=vm2
        ip link set vm2 netns vm2
        ip netns exec vm2 ip link set vm2 address 00:00:00:00:00:02
        ip netns exec vm2 ip link set vm2 up
        ip netns exec vm2 ip addr add 10.0.0.12/24 dev vm2
        ip netns exec vm2 ip route add default via 10.0.0.1
    '
}

exercise_4() {
    echo "--- Exercise 4: DHCP on network1 ---"

    run_central '
        dhcp_uuid=$(ovn-nbctl create DHCP_Options cidr=10.0.0.0/24 \
            external_ids:workshop=restore-ovn-lab \
            options="\"server_id\"=\"10.0.0.1\" \"server_mac\"=\"00:00:00:ff:00:01\" \"lease_time\"=\"3600\" \"router\"=\"10.0.0.1\" \"dns_server\"=\"8.8.8.8\"")

        ovn-nbctl lsp-set-dhcpv4-options vm1 "$dhcp_uuid"
        ovn-nbctl lsp-set-dhcpv4-options vm2 "$dhcp_uuid"
        ovn-nbctl lsp-set-dhcpv4-options vm3 "$dhcp_uuid"
    '
}

exercise_5() {
    echo "--- Exercise 5: Multi-node (vm3 on compute1) ---"

    run_compute1 '
        ip netns add vm3
        ovs-vsctl add-port br-int vm3 -- set interface vm3 \
            type=internal external_ids:iface-id=vm3
        ip link set vm3 netns vm3
        ip netns exec vm3 ip link set vm3 address 00:00:00:00:00:03
        ip netns exec vm3 ip link set vm3 up
        ip netns exec vm3 ip addr add 10.0.0.13/24 dev vm3
        ip netns exec vm3 ip route add default via 10.0.0.1
    '
}

exercise_6() {
    echo "--- Exercise 6: Router and network2 ---"

    run_central '
        # Create network2
        ovn-nbctl ls-add network2

        ovn-nbctl lsp-add network2 vm4
        ovn-nbctl lsp-set-addresses vm4 "00:00:00:00:00:04 10.0.1.11"
        ovn-nbctl lsp-set-port-security vm4 "00:00:00:00:00:04 10.0.1.11"

        ovn-nbctl lsp-add network2 vm5
        ovn-nbctl lsp-set-addresses vm5 "00:00:00:00:00:05 10.0.1.12"
        ovn-nbctl lsp-set-port-security vm5 "00:00:00:00:00:05 10.0.1.12"

        # Create router
        ovn-nbctl lr-add router1

        # Connect network1 to router
        ovn-nbctl lrp-add router1 rtr-to-network1 00:00:00:00:ff:01 10.0.0.1/24
        ovn-nbctl lsp-add network1 network1-to-rtr
        ovn-nbctl lsp-set-type network1-to-rtr router
        ovn-nbctl lsp-set-addresses network1-to-rtr router
        ovn-nbctl lsp-set-options network1-to-rtr router-port=rtr-to-network1

        # Connect network2 to router
        ovn-nbctl lrp-add router1 rtr-to-network2 00:00:00:00:ff:02 10.0.1.1/24
        ovn-nbctl lsp-add network2 network2-to-rtr
        ovn-nbctl lsp-set-type network2-to-rtr router
        ovn-nbctl lsp-set-addresses network2-to-rtr router
        ovn-nbctl lsp-set-options network2-to-rtr router-port=rtr-to-network2

        # Create vm4 namespace
        ip netns add vm4
        ovs-vsctl add-port br-int vm4 -- set interface vm4 \
            type=internal external_ids:iface-id=vm4
        ip link set vm4 netns vm4
        ip netns exec vm4 ip link set vm4 address 00:00:00:00:00:04
        ip netns exec vm4 ip link set vm4 up
        ip netns exec vm4 ip addr add 10.0.1.11/24 dev vm4
        ip netns exec vm4 ip route add default via 10.0.1.1

        # Create vm5 namespace
        ip netns add vm5
        ovs-vsctl add-port br-int vm5 -- set interface vm5 \
            type=internal external_ids:iface-id=vm5
        ip link set vm5 netns vm5
        ip netns exec vm5 ip link set vm5 address 00:00:00:00:00:05
        ip netns exec vm5 ip link set vm5 up
        ip netns exec vm5 ip addr add 10.0.1.12/24 dev vm5
        ip netns exec vm5 ip route add default via 10.0.1.1
    '
}

exercise_7() {
    echo "--- Exercise 7: ACLs on network1 ---"

    run_central '
        # allow-related gera o tratamento de estado; não copiar regras internas de CT.

        # Allow ICMP
        ovn-nbctl acl-add network1 to-lport 1000 "ip4 && icmp4" allow-related

        # Allow SSH
        ovn-nbctl acl-add network1 to-lport 1000 "ip4 && tcp.dst == 22" allow-related

        # Allow all outbound
        ovn-nbctl acl-add network1 from-lport 1000 "ip4" allow-related

        # Drop all other inbound
        ovn-nbctl acl-add network1 to-lport 900 "ip4" drop

        # Allow HTTP 8080 (added in Exercise 7.6)
        ovn-nbctl acl-add network1 to-lport 1000 "ip4 && tcp.dst == 8080" allow-related

        # Stateless UDP 5000 (added in Exercise 7.8)
        ovn-nbctl acl-add network1 to-lport 1000 "ip4 && udp.dst == 5000" allow-stateless
    '
}

exercise_8() {
    echo "--- Exercise 8: NAT (external switch, gateway, SNAT, DNAT) ---"

    local central_id
    central_id=$(get_central_system_id)
    if [[ -z "$central_id" ]]; then
        echo "ERROR: Could not determine central node system-id from OVS external_ids."
        echo "       Ensure Exercise 1 was completed (ovs-vsctl set open_vswitch . external_ids:system-id=...)."
        exit 1
    fi
    echo "  Using gateway chassis: $central_id"

    run_central "
        # External switch
        ovn-nbctl ls-add external

        ovn-nbctl lsp-add external ext-gw
        ovn-nbctl lsp-set-addresses ext-gw '00:00:00:00:ee:01 172.16.0.1'
        ovn-nbctl lsp-set-port-security ext-gw '00:00:00:00:ee:01 172.16.0.1'

        # Connect router to external
        ovn-nbctl lrp-add router1 rtr-to-external 00:00:00:00:ff:ee 172.16.0.100/24

        ovn-nbctl lsp-add external external-to-rtr
        ovn-nbctl lsp-set-type external-to-rtr router
        ovn-nbctl lsp-set-addresses external-to-rtr router
        ovn-nbctl lsp-set-options external-to-rtr router-port=rtr-to-external

        # ext-gw namespace
        ip netns add ext-gw
        ovs-vsctl add-port br-int ext-gw -- set interface ext-gw \
            type=internal external_ids:iface-id=ext-gw
        ip link set ext-gw netns ext-gw
        ip netns exec ext-gw ip link set ext-gw address 00:00:00:00:ee:01
        ip netns exec ext-gw ip link set ext-gw up
        ip netns exec ext-gw ip addr add 172.16.0.1/24 dev ext-gw

        # Default route on router
        ovn-nbctl lr-route-add router1 0.0.0.0/0 172.16.0.1

        # Gateway chassis (auto-detected from central node)
        ovn-nbctl lrp-set-gateway-chassis rtr-to-external '$central_id' 1

        # SNAT
        ovn-nbctl lr-nat-add router1 snat 172.16.0.100 10.0.0.0/24
        ovn-nbctl lr-nat-add router1 snat 172.16.0.100 10.0.1.0/24

        # DNAT
        ovn-nbctl lr-nat-add router1 dnat_and_snat 172.16.0.101 10.0.0.11
    "
}

exercise_9() {
    echo "--- Exercise 9: Load balancing ---"

    run_central '
        # vm6
        ovn-nbctl lsp-add network2 vm6
        ovn-nbctl lsp-set-addresses vm6 "00:00:00:00:00:06 10.0.1.13"
        ovn-nbctl lsp-set-port-security vm6 "00:00:00:00:00:06 10.0.1.13"

        ip netns add vm6
        ovs-vsctl add-port br-int vm6 -- set interface vm6 \
            type=internal external_ids:iface-id=vm6
        ip link set vm6 netns vm6
        ip netns exec vm6 ip link set vm6 address 00:00:00:00:00:06
        ip netns exec vm6 ip link set vm6 up
        ip netns exec vm6 ip addr add 10.0.1.13/24 dev vm6
        ip netns exec vm6 ip route add default via 10.0.1.1

        # Load balancer
        ovn-nbctl lb-add web-lb 10.0.1.100:80 \
            10.0.1.11:8080,10.0.1.12:8080,10.0.1.13:8080
        ovn-nbctl lr-lb-add router1 web-lb
        ovn-nbctl ls-lb-add network1 web-lb
        ovn-nbctl ls-lb-add network2 web-lb

    '

    # Mesmo handler do Step 9.2: lê HTTP, calcula bytes e não serve arquivos.
    local backend_code backend_code_quoted
    backend_code='
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

body = ("Server: " + sys.argv[1] + "\n").encode("ascii")
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

with HTTPServer(("0.0.0.0", 8080), Handler) as server:
    server.serve_forever()
'
    printf -v backend_code_quoted '%q' "$backend_code"
    # Desconectar todos os descritores do SSH. A verificação HTTP detecta
    # falhas de partida; cleanup_lab_namespaces encerra os processos no restore.
    run_central "
        for ns in vm4 vm5 vm6; do
            nohup ip netns exec \"\$ns\" python3 -u -c $backend_code_quoted \"\$ns\" </dev/null >/dev/null 2>&1 &
        done
    "
}

verify_control_plane() {
    local node status
    for node in "$CENTRAL" "$COMPUTE1" "$COMPUTE2"; do
        status=$(run_node "$node" 'ovn-appctl -t ovn-controller connection-status') || return 1
        if [[ "$status" != connected ]]; then
            echo "FAIL: controller de $node não está conectado ao SB: $status" >&2
            return 1
        fi
    done
    run_central "TARGET=$TARGET"$'\n''
        names=$(ovn-sbctl --format=csv --data=bare --no-heading --columns=name list Chassis)
        mapfile -t chassis <<< "$names"
        declare -A ids
        for name in "${chassis[@]}"; do
            case "$name" in
                central|compute1|compute2) ids[$name]=$(ovn-sbctl get Chassis "$name" _uuid) ;;
                *) : ;; # Chassis alheios não são requisito nem alvo de exclusão.
            esac
        done
        [[ ${#ids[@]} == 3 ]] || { echo "FAIL: faltam chassis do laboratório." >&2; exit 1; }
        for item in vm1:3:central vm2:3:central vm3:5:compute1 vm4:6:central vm5:6:central ext-gw:8:central vm6:9:central; do
            IFS=: read -r port minimum owner <<< "$item"
            if (( TARGET >= minimum )); then
                bound=$(ovn-sbctl get Port_Binding "$port" chassis)
                if [[ "$bound" != "${ids[$owner]}" ]]; then
                    echo "FAIL: $port sem binding no chassis $owner: $bound" >&2
                    exit 1
                fi
            fi
        done
    '
}

verify() {
    local failed=0
    echo ""
    echo "=== Verification ==="

    if verify_control_plane; then
        echo "Três chassis, conexões SB e bindings esperados: OK"
    else
        echo "FAIL: plano de controle incompleto."
        failed=1
    fi

    if [[ "$TARGET" -ge 1 ]]; then
        echo "--- Chassis ---"
        run_central 'ovn-sbctl show' 2>/dev/null | grep -E "Chassis|hostname|ip:" | sed 's/^/  /'
        echo ""
    fi

    if [[ "$TARGET" -ge 2 ]]; then
        echo "--- OVN NB state ---"
        run_central 'ovn-nbctl show'
        echo ""
    fi

    echo "--- Namespaces (central) ---"
    run_central 'ip netns list'
    echo ""

    if [[ "$TARGET" -ge 5 ]]; then
        echo "--- Namespaces (compute1) ---"
        if ! run_compute1 'ip netns list'; then
            echo "FAIL: não foi possível consultar os namespaces de compute1."
            failed=1
        fi
        echo ""
    fi

    if [[ "$TARGET" -ge 3 ]]; then
        echo "--- Connectivity tests ---"
        if run_central 'ip netns exec vm1 ping -c 1 -W 2 10.0.0.12' >/dev/null 2>&1; then
            echo "vm1 -> vm2 (L2): OK"
        else
            echo "vm1 -> vm2 (L2): FAIL"
            failed=1
        fi
    fi

    if [[ "$TARGET" -ge 5 ]]; then
        if run_compute1 'ip netns exec vm3 ping -c 1 -W 2 10.0.0.11' >/dev/null 2>&1; then
            echo "vm3 -> vm1 (cross-node): OK"
        else
            echo "vm3 -> vm1 (cross-node): FAIL"
            failed=1
        fi
    fi

    if [[ "$TARGET" -ge 6 ]]; then
        if run_central 'ip netns exec vm1 ping -c 1 -W 2 10.0.1.11' >/dev/null 2>&1; then
            echo "vm1 -> vm4 (L3 routing): OK"
        else
            echo "vm1 -> vm4 (L3 routing): FAIL"
            failed=1
        fi
    fi

    if [[ "$TARGET" -ge 8 ]]; then
        if run_central 'ip netns exec vm1 ping -c 1 -W 2 172.16.0.1' >/dev/null 2>&1; then
            echo "vm1 -> ext-gw (NAT): OK"
        else
            echo "vm1 -> ext-gw (NAT): FAIL"
            failed=1
        fi
    fi

    if [[ "$TARGET" -ge 9 ]]; then
        local endpoint
        for endpoint in 10.0.1.11:8080 10.0.1.12:8080 10.0.1.13:8080 10.0.1.100:80; do
            if run_central "ip netns exec vm1 curl --fail --silent --show-error --connect-timeout 2 --max-time 10 --retry 4 --retry-connrefused --retry-delay 1 http://$endpoint/" >/dev/null 2>&1; then
                echo "HTTP $endpoint: OK"
            else
                echo "HTTP $endpoint: FAIL"
                failed=1
            fi
        done
    fi

    if [[ "$failed" -ne 0 ]]; then
        echo "ERRO: a verificação falhou; restauração não validada." >&2
        return 1
    fi
    echo ""
    echo "Lab restored to Exercise $TARGET state."
}

# Main
echo "============================================"
echo " OVN Lab Restore - Target: Exercise $TARGET"
echo "============================================"
echo ""
echo "Nodes:"
echo "  Central:  $CENTRAL ($CENTRAL_IP)"
echo "  Compute1: $COMPUTE1 ($COMPUTE1_IP)"
echo "  Compute2: $COMPUTE2 ($COMPUTE2_IP)"
echo ""

echo "AVISO: use somente em laboratório exclusivo. Serviços, conexões dos bancos," >&2
echo "IDs dos chassis e objetos com os nomes do workshop serão alterados." >&2
echo "Processos nos namespaces do workshop serão encerrados." >&2

# Interromper antes da limpeza se qualquer nó estiver inacessível.
run_central 'true'
run_compute1 'true'
run_compute2 'true'
if [[ "$TARGET" -ge 9 ]]; then
    run_central '
        for cmd in python3 curl; do
            if ! command -v "$cmd" >/dev/null; then
                echo "ERRO: $cmd é necessário para o exercício 9; nenhuma restauração foi iniciada." >&2
                exit 1
            fi
        done
    '
fi

# Build up state incrementally
[[ "$TARGET" -ge 1 ]] && exercise_1
[[ "$TARGET" -ge 2 ]] && exercise_2
[[ "$TARGET" -ge 3 ]] && exercise_3
[[ "$TARGET" -ge 4 ]] && exercise_4
[[ "$TARGET" -ge 5 ]] && exercise_5
[[ "$TARGET" -ge 6 ]] && exercise_6
[[ "$TARGET" -ge 7 ]] && exercise_7
[[ "$TARGET" -ge 8 ]] && exercise_8
[[ "$TARGET" -ge 9 ]] && exercise_9

# Give OVN a moment to process
sleep 2

verify
