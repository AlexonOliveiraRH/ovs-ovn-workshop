#!/bin/bash
# Limit cleanup to namespace names supplied by the workshop restore scripts.
# ip-netns(8): removing a name does not stop processes that keep the namespace alive.
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
            # A process may exit between the query and the signal.
            kill "$pid" 2>/dev/null || true
        done
        for attempt in 1 2 3 4 5; do
            pids=$(ip netns pids "$ns")
            [[ -z "$pids" ]] && break
            sleep 1
        done
        if [[ -n "$pids" ]]; then
            echo "ERROR: Processes are still active in $ns; deletion canceled: $pids" >&2
            return 1
        fi
        ip netns del "$ns"
    done
}
