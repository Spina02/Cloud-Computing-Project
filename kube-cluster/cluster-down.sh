#!/bin/bash

set -euo pipefail

export LIBVIRT_DEFAULT_URI="qemu:///system"

NETS=(CloudWanNet CloudBasicNet)
BRIDGES=(virbr-wan virbr-hpc)
MASTER="k8s-master"
WORKERS=(k8s-monitoring k8s-hpl-worker)

# --- Shut down the given VMs, wait ---
stop_vms() {
    local n
    for n in "$@"; do
        if grep -q running <<< "$(virsh domstate "$n")"; then
            virsh shutdown "$n"
        fi
    done

    for n in "$@"; do
        while grep -q running <<< "$(virsh domstate "$n")"; do
            sleep 2
        done
        echo "$n: $(virsh domstate "$n")"
    done
}

# Workers first, then the master (which serves DHCP, DNS and NAT)
stop_vms "${WORKERS[@]}"
stop_vms "$MASTER"

# Remove the firewall rules added by cluster-up.sh
if sudo iptables -S DOCKER-USER &>/dev/null; then
    for br in "${BRIDGES[@]}"; do
        sudo iptables -C DOCKER-USER -i "$br" -j ACCEPT 2>/dev/null \
            && sudo iptables -D DOCKER-USER -i "$br" -j ACCEPT || true
        sudo iptables -C DOCKER-USER -o "$br" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
            && sudo iptables -D DOCKER-USER -o "$br" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || true
    done
fi

# Stop the networks
for net in "${NETS[@]}"; do
    virsh net-destroy "$net" || true
    echo "Network $net stopped."
done

echo "=== Cluster stopped ==="
virsh list --all