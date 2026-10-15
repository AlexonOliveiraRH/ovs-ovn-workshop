#!/bin/bash
# DORA real sem aplicar configuração ou executar hooks de DNS.
set -euo pipefail
umask 077
destino=$(mktemp -d /tmp/ovn-dhcp-e2e.XXXXXX)
estado=$(mktemp -d /var/lib/dhclient/ovn-e2e.XXXXXX)
captura=
cliente=
finalizar() {
    if [[ -n "$cliente" ]]; then
        kill "$cliente" 2>/dev/null || true
        wait "$cliente" 2>/dev/null || true
        cliente=
    fi
    if [[ -n "$captura" ]]; then
        kill "$captura" 2>/dev/null || true
        wait "$captura" 2>/dev/null || true
    fi
}
trap finalizar EXIT
printf 'EVIDENCIA_DHCP=%s\n' "$destino"
printf 'ESTADO_DHCP=%s\n' "$estado"
ls -Zd "$estado"
sha256sum /etc/resolv.conf > "$destino/dns-antes.sha256"
ip netns exec vm1 ip -j addr show dev vm1 > "$destino/ip-antes.json"
ip netns exec vm1 tcpdump --immediate-mode -U -n -i vm1 -w "$destino/dora.pcap" 'udp port 67 or udp port 68' &
captura=$!
sleep 1
ip netns exec vm1 dhclient -1 -d -v -sf /bin/true \
    -cf /dev/null -pf "$estado/dhclient.pid" -lf "$estado/lease" vm1 &
cliente=$!
for tentativa in {1..150}; do
    if [[ -s "$estado/lease" ]] && grep -q 'fixed-address 10.0.0.11;' "$estado/lease"; then break; fi
    sleep 0.1
done
grep -q 'fixed-address 10.0.0.11;' "$estado/lease"
finalizar
captura=
sha256sum -c "$destino/dns-antes.sha256"
sha256sum /etc/resolv.conf
ip netns exec vm1 ip -j addr show dev vm1 > "$destino/ip-depois.json"
cmp "$destino/ip-antes.json" "$destino/ip-depois.json"
tcpdump -n -vv -r "$destino/dora.pcap"
grep -E 'fixed-address|dhcp-server-identifier|domain-name-servers|routers' "$estado/lease"
cp "$estado/lease" "$destino/lease"
echo 'DORA concluído; hook /bin/true; IP e DNS do host não foram aplicados pelo cliente.'
