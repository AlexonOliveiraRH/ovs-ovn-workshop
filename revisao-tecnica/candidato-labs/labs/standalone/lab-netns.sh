#!/bin/bash
# Limpeza restrita aos nomes de namespaces informados pelo restore do workshop.
# ip-netns(8): remover o nome não encerra os processos que mantêm o namespace vivo.
cleanup_lab_namespaces() {
    local namespaces ns existing found pids pid attempt
    namespaces=$(ip netns list)
    for ns in "$@"; do
        found=false
        while read -r existing _; do
            if [[ "$existing" == "$ns" ]]; then
                found=true
                break
            fi
        done <<< "$namespaces"
        [[ "$found" == true ]] || continue

        pids=$(ip netns pids "$ns")
        for pid in $pids; do
            # Um processo pode terminar entre a consulta e o sinal.
            kill "$pid" 2>/dev/null || true
        done
        for attempt in 1 2 3 4 5; do
            pids=$(ip netns pids "$ns")
            [[ -z "$pids" ]] && break
            sleep 1
        done
        if [[ -n "$pids" ]]; then
            echo "ERRO: processos ainda ativos em $ns; exclusão cancelada: $pids" >&2
            return 1
        fi
        ip netns del "$ns"
    done
}
