#!/bin/bash
# Usage: ./cluster-up.sh              -> networks, firewall, master, workers

set -euo pipefail

export LIBVIRT_DEFAULT_URI="qemu:///system"

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NETS=(CloudWanNet CloudBasicNet)
BRIDGES=(virbr-wan virbr-hpc)
MASTER="k8s-master"
M_IP="192.168.100.10"     # DHCP reservation in cloud-init/CloudWanNet.xml
WORKERS=(k8s-monitoring k8s-hpl-worker)
LEASES="/var/lib/misc/dnsmasq.leases"

SSH_CONFIG="$BASE/ssh/config"

SSH_OPTS=(
    -F "$SSH_CONFIG"
    -o BatchMode=yes
    -o ConnectTimeout=3
    -o LogLevel=ERROR
)

# --- Networks ---
for net in "${NETS[@]}"; do
    net_info="$(virsh net-info "$net")"
    if ! grep -q "Active:.*yes" <<< "$net_info"; then
        virsh net-start "$net"
    fi
done

# Ensure compatibility with docker (both bridges)
if sudo iptables -S DOCKER-USER &>/dev/null; then
    for br in "${BRIDGES[@]}"; do
        sudo iptables -C DOCKER-USER -i "$br" -j ACCEPT 2>/dev/null \
            || sudo iptables -I DOCKER-USER -i "$br" -j ACCEPT
        sudo iptables -C DOCKER-USER -o "$br" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
            || sudo iptables -I DOCKER-USER -o "$br" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        echo "Firewall rules for $br in place."
    done
else
    echo "DOCKER-USER chain not found (Docker not running?), skipping firewall rules."
fi

# --- Master first: it provides DHCP, DNS and NAT to the workers ---
if ! grep -q running <<< "$(virsh domstate "$MASTER")"; then
    virsh start "$MASTER"
fi

# Wait until dnsmasq is running on the master, before the workers ask for a lease
ready=0
for _ in $(seq 1 60); do
    if ssh "${SSH_OPTS[@]}" "user01@$M_IP" 'systemctl is-active --quiet dnsmasq' 2>/dev/null; then
        ready=1
        break
    fi
    sleep 3
done
if [ "$ready" -ne 1 ]; then
    echo "ERROR: dnsmasq is not active on $MASTER (try: ssh -i ssh/id_ed25519 user01@$M_IP)." >&2
    exit 1
fi

# --- Workers ---
for n in "${WORKERS[@]}"; do
    if ! grep -q running <<< "$(virsh domstate "$n")"; then
        virsh start "$n"
    fi
done

echo ""

echo "$MASTER: $M_IP (WAN)"

# Workers have no libvirt lease: read the leases from dnsmasq on the master
for n in "${WORKERS[@]}"; do
    ip=""
    for _ in $(seq 1 60); do
        leases="$(ssh "${SSH_OPTS[@]}" "user01@$M_IP" "cat $LEASES" 2>/dev/null || true)"
        ip="$(awk -v h="$n" '$4 == h {print $3}' <<< "$leases")"
        [ -n "$ip" ] && break
        sleep 2
    done
    echo "$n: ${ip:-no IP yet}"
done

echo ""
echo "Access:  ssh -F $BASE/ssh/config k8s-master"