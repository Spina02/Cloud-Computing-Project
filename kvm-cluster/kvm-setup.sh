#!/bin/bash
set -euo pipefail

# Ensure the script is run from inside the kvm-cluster directory
if [ "$(basename "$(pwd)")" != "kvm-cluster" ]; then
    echo "ERROR: Please run this script from inside the kvm-cluster directory." >&2
    exit 1
fi
BASE="$(pwd)"

# Ensure there are the needed files
if [ ! -x "$BASE/cluster-up.sh" ]; then
    echo "ERROR: cluster-up.sh not found or not executable in $BASE." >&2
    exit 1
fi

for f in master.tmpl worker.tmpl CloudWanNet.xml CloudBasicNet.xml; do
    if [ ! -f "$BASE/cloud-init/$f" ]; then
        echo "ERROR: cloud-init/$f not found in $BASE." >&2
        exit 1
    fi
done

export LIBVIRT_DEFAULT_URI="qemu:///system"

IMG_URL="https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
MASTER="master"
WORKERS=(node01 node02)

WAN_NET="CloudWanNet"
LAN_NET="CloudBasicNet"

# Fixed addresses of the master: cloud-init matches its NICs by MAC (see
# master.network-config); M_IP is the DHCP reservation in CloudWanNet.xml.
MASTER_WAN_MAC="52:54:00:aa:00:01"
MASTER_LAN_MAC="52:54:00:aa:01:01"
M_IP="192.168.100.10"

mkdir -p "$BASE"/{images,ssh}

# --- SSH key: generate once, reusable on every run ---
if [ ! -f ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -N "" -f ssh/id_ed25519
    echo "SSH key generated."
else
    echo "SSH key already exists, skipping."
fi
SSH_PUBKEY=$(cat ssh/id_ed25519.pub)

# --- Base cloud image: download only once ---
if [ ! -f images/ubuntu-base.img ]; then
    echo "Downloading Ubuntu image"
    wget -O images/ubuntu-base.img "$IMG_URL"
else
    echo "Base image already exists, skipping download."
fi

# --- Libvirt networks: define from cloud-init/<name>.xml if missing ---
for net in "$WAN_NET" "$LAN_NET"; do
    if ! virsh net-info "$net" &>/dev/null; then
        virsh net-define "cloud-init/$net.xml"
        echo "Network $net defined."
    else
        echo "Network $net already defined, skipping definition."
    fi
    # Start network
    net_info="$(virsh net-info "$net")"
    if ! grep -q "Active:.*yes" <<< "$net_info"; then
        virsh net-start "$net"
    fi
done

# Ensure compatibility with docker (both bridges)
if sudo iptables -S DOCKER-USER &>/dev/null; then
    for br in "virbr-wan" "virbr-hpc"; do
        sudo iptables -C DOCKER-USER -i "$br" -j ACCEPT 2>/dev/null \
            || sudo iptables -I DOCKER-USER -i "$br" -j ACCEPT
        sudo iptables -C DOCKER-USER -o "$br" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
            || sudo iptables -I DOCKER-USER -o "$br" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        echo "Firewall rules for $br in place."
    done
else
    echo "DOCKER-USER chain not found (Docker not running?), skipping firewall rules."
fi

mkdir -p cloud-init/master/
cat > cloud-init/master/network-config << EOF
version: 2
ethernets:
  # NIC on $WAN_NET (NAT towards the host): DHCP from libvirt
  wan:
    match:
      macaddress: "$MASTER_WAN_MAC"
    dhcp4: true
  # NIC on $LAN_NET (internal): static address, the master is gateway/DHCP/DNS
  lan:
    match:
      macaddress: "$MASTER_LAN_MAC"
    dhcp4: false
    addresses: [192.168.56.1/24]
EOF

# --- Per-node associations: physical CPU pinning ---
declare -A CPUPIN
CPUPIN[$MASTER]="0 2"
CPUPIN[node01]="4 6"
CPUPIN[node02]="8 10"

# create_node <name>: seed ISO + overlay disk + VM + CPU pinning
create_node() {
    local n="$1"
    local net_args
    local tmpl
    local seed_args
    local c0 c1

    # Compose per-node net_args, template, and seed_args in one if/else at the start
    if [ "$n" = "$MASTER" ]; then
        tmpl="master.tmpl"
        seed_args="--network-config cloud-init/master/network-config"
        net_args=(
            --network "network=$WAN_NET,model=virtio,mac=$MASTER_WAN_MAC"
            --network "network=$LAN_NET,model=virtio,mac=$MASTER_LAN_MAC"
        )
    else
        tmpl="worker.tmpl"
        seed_args=""
        net_args=(--network "network=$LAN_NET,model=virtio")
    fi

    echo "=== Configuring node: $n ==="
    echo ""

    # Seed ISO + overlay disk: only on first create
    if [ ! -f images/$n.qcow2 ]; then
        mkdir -p cloud-init/$n
        rm -f ssh/known_hosts   # new VM = new host keys

        sed -e "s|__HOSTNAME__|$n|g" \
            -e "s|__SSH_PUBKEY__|$SSH_PUBKEY|g" \
            cloud-init/$tmpl > cloud-init/$n/user-data

        cat > cloud-init/$n/meta-data << EOF
instance-id: $n-01
local-hostname: $n
EOF

        # shellcheck disable=SC2086
        cloud-localds $seed_args \
            images/$n-seed.iso cloud-init/$n/user-data cloud-init/$n/meta-data

        qemu-img create -f qcow2 -F qcow2 -b "$BASE/images/ubuntu-base.img" images/$n.qcow2 25G
    else
        echo "Disk for $n already exists, skipping (delete manually if you want a fresh start)."
    fi

    read -r c0 c1 <<< "${CPUPIN[$n]}"

    # Create the VM only if it does not already exist
    if ! virsh dominfo "$n" &>/dev/null; then
        virt-install \
            --name "$n" \
            --memory 2048 \
            --vcpus 2 \
            --cpu host-passthrough \
            --cputune "vcpupin0.vcpu=0,vcpupin0.cpuset=$c0,vcpupin1.vcpu=1,vcpupin1.cpuset=$c1" \
            --disk images/$n.qcow2,bus=virtio,cache=none \
            --disk images/$n-seed.iso,device=cdrom \
            "${net_args[@]}" \
            --os-variant ubuntu24.04 \
            --import \
            --graphics none \
            --noautoconsole
    else
        echo "VM $n is already defined, skipping virt-install."
    fi
}

# --- SSH config for the host
cat > "$BASE/ssh/config" << EOF
Host *
    User user01
    IdentityFile $BASE/ssh/id_ed25519
    IdentitiesOnly yes
    UserKnownHostsFile $BASE/ssh/known_hosts
    StrictHostKeyChecking accept-new

Host $MASTER
    HostName $M_IP

Host ${WORKERS[*]}
    ProxyJump $MASTER
EOF

# ---------- 1) master ----------
create_node "$MASTER"

# if ! grep -q running <<< "$(virsh domstate "$MASTER")"; then
#     virsh start "$MASTER"
# fi

echo "=== Waiting for the master: ssh, then cloud-init ==="

# Wait for cloud-init to finish (the master must be ready before the workers boot).
# ssh exit code 255 = connection failed (sshd not up yet), so retry only on that.
for _ in $(seq 1 20); do
    rc=0
    ssh -F "$BASE/ssh/config" "$MASTER" 'cloud-init status --wait' 2>/dev/null || rc=$?
    [ "$rc" -ne 255 ] && break
    sleep 3
done

echo "Master ready."
echo ""

# ---------- 2) workers ----------
for n in "${WORKERS[@]}"; do
    create_node "$n"
done

echo "=== Provisioning complete, bringing the cluster up ==="
echo ""

"$BASE/cluster-up.sh"
virsh list --all