#!/bin/bash
set -e  # Immediately stop the script if any command fails

# --- 1. PATHS AND PARAMETERS ---
ACTION=$1   # "start" or "stop"
CLUSTER=$2  # "vbox", "kvm", "docker" or "host"

# Project folders
B=$(cd "$(dirname "$0")/.." && pwd)
K="$B/../kvm-cluster"
D="$B/../docker-cluster"
THP_FILE=/sys/kernel/mm/transparent_hugepage/enabled
THP_STATE_FILE="$B/.original-thp-mode"
ORIGINAL_THP=

if [[ -z "$ACTION" || -z "$CLUSTER" ]]; then
    echo "Usage: $0 <start|stop> <vbox|kvm|docker|host>"
    exit 1
fi

[[ "$CLUSTER" =~ ^(vbox|kvm|docker|host)$ ]] || { echo "Unknown cluster: $CLUSTER"; exit 1; }

# Pin only the vCPU threads (EMT-*), like vcpupin in KVM: I/O and network emulation threads stay free
pin_vbox() {
    local pid i=0
    pid=$(pgrep -f "VBoxHeadless.*--comment $1" | head -1)
    local cpus=(${2//,/ })
    for tid in $(ps -T -p "$pid" -o tid=,comm= | awk '/EMT-/ {print $1}'); do
        sudo taskset -cp "${cpus[$i]}" "$tid" > /dev/null && echo "  -> $1 vCPU$i on core ${cpus[$i]}"
        i=$((i+1))
    done
    [ $i -eq 0 ] && echo "  -> WARNING: no EMT threads found for $1"
    return 0
}

restore_thp() {
    printf '%s\n' "$ORIGINAL_THP" | sudo tee "$THP_FILE" >/dev/null
}

# ==============================================================================
# CLUSTER STARTUP
# ==============================================================================
if [ "$ACTION" = "start" ]; then
    cat /sys/class/power_supply/A*/online | grep -q 0 && { echo "On battery: plug in the charger"; exit 1; }
    if [ -n "$(docker ps -q 2>/dev/null)$(VBoxManage list runningvms)$(virsh -c qemu:///system list --name 2>/dev/null)" ]; then
        echo "Other VMs/containers are running: stop them first"; exit 1
    fi

    
    if [ "${FAST:-0}" != 1 ]; then
        sudo fstrim -v /
        sleep 10
    fi

    ORIGINAL_THP=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$THP_FILE")
    printf '%s\n' "$ORIGINAL_THP" > "$THP_STATE_FILE"
    THP_START_COMPLETE=0
    trap 'if [ "$THP_START_COMPLETE" -eq 0 ]; then restore_thp; fi' EXIT
    printf '%s\n' madvise | sudo tee "$THP_FILE" >/dev/null
    grep -q '\[madvise\]' "$THP_FILE" || { echo "THP not set to madvise" >&2; exit 1; }
    mkdir -p "$B/results"
    {
        date
        echo "thp: $(cat "$THP_FILE")"
        echo "platform_profile: $(cat /sys/firmware/acpi/platform_profile 2>/dev/null)"
        echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
    } > "$B/results/host-state-$CLUSTER.txt"

    echo "=== 1. Starting cluster $CLUSTER ==="

    case "$CLUSTER" in
        vbox)

            VBoxManage startvm master --type headless
            echo "Waiting for the master to start the network (dnsmasq)..."
            until ssh -p 3022 -o ConnectTimeout=2 -o BatchMode=yes user01@127.0.0.1 true 2>/dev/null; do sleep 2; done
            VBoxManage startvm node01 --type headless
            VBoxManage startvm node02 --type headless
            echo "Waiting for the workers to start..."
            until ssh -p 3022 -o ConnectTimeout=2 -o BatchMode=yes user01@127.0.0.1 \
                "ssh -o ConnectTimeout=2 node01 true && ssh -o ConnectTimeout=2 node02 true" 2>/dev/null; do sleep 2; done

            echo "Applying CPU pinning to VirtualBox VMs..."
            pin_vbox master 0,2
            pin_vbox node01 4,6
            pin_vbox node02 8,10

            echo "Disabling background timers on nodes..."
            ssh -p 3022 user01@127.0.0.1 "sudo systemctl stop fstrim.timer apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true"
            ssh -p 3022 user01@127.0.0.1 "ssh node01 sudo systemctl stop fstrim.timer apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true"
            ssh -p 3022 user01@127.0.0.1 "ssh node02 sudo systemctl stop fstrim.timer apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true"

            echo "=== 2. Copying bench.sh and hpccinf.txt to /shared ==="
            scp -P 3022 "$B/scripts/bench.sh" "$B/scripts/hpccinf.txt" user01@127.0.0.1:/shared/

            echo "=== Ready! Enter the master node with: ==="
            echo "ssh -p 3022 user01@127.0.0.1"
            ;;

        kvm)
            (cd "$K" && ./cluster-up.sh)
            echo "Waiting for the VMs to be ready..."
            until ssh -F "$K/ssh/config" -o ConnectTimeout=2 -o BatchMode=yes master \
                "ssh -o ConnectTimeout=2 node01 true && ssh -o ConnectTimeout=2 node02 true" 2>/dev/null; do sleep 2; done

            echo "Disabling background timers on nodes..."
            ssh -F "$K/ssh/config" master "sudo systemctl stop fstrim.timer apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true"
            ssh -F "$K/ssh/config" master "ssh node01 sudo systemctl stop fstrim.timer apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true"
            ssh -F "$K/ssh/config" master "ssh node02 sudo systemctl stop fstrim.timer apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true"

            echo "=== 2. Copying bench.sh and hpccinf.txt to /shared ==="
            scp -F "$K/ssh/config" "$B/scripts/bench.sh" "$B/scripts/hpccinf.txt" master:/shared/

            echo "=== Ready! Enter the master node with: ==="
            echo "ssh -F $K/ssh/config master"
            ;;

        docker)
            (cd "$D" && docker compose up -d)
            sleep 5

            echo "=== 2. Copying bench.sh, hpccinf.txt and creating mpi-hostfile ==="
            docker cp "$B/scripts/bench.sh" master:/shared/
            docker cp "$B/scripts/hpccinf.txt" master:/shared/
            docker exec -u user01 master bash -c 'printf "master slots=2\nnode01 slots=2\nnode02 slots=2\n" > /shared/mpi-hostfile'

            echo "=== Ready! Enter the master node with: ==="
            echo "docker exec -it -u user01 master bash"
            ;;

        host)
            echo "=== Ready! Run: cd $B/scripts && bash bench.sh host 2>&1 | tee $B/results/results-host.log ==="
            ;;
    esac

    if [ "$CLUSTER" != host ]; then
        echo "Then inside the master run: cd /shared && bash bench.sh $CLUSTER 2>&1 | tee /shared/results-$CLUSTER.log"
    fi
    THP_START_COMPLETE=1

# ==============================================================================
# SAVE RESULTS AND SHUTDOWN (STOP)
# ==============================================================================
elif [ "$ACTION" = "stop" ]; then
    if [ ! -r "$THP_STATE_FILE" ]; then
        echo "Original THP mode not found; cannot restore it" >&2
    else
        ORIGINAL_THP=$(cat "$THP_STATE_FILE")
        if [ -z "$ORIGINAL_THP" ] || ! restore_thp; then
            echo "Impossible to restore the original THP mode" >&2
        fi
        rm -f "$THP_STATE_FILE"
    fi
    rm -f "$THP_STATE_FILE"

    mkdir -p "$B/results"
    echo "=== 1. Saving results in $B/results/ and cleaning up /shared ==="

    echo "=== 2. Shutting down $CLUSTER cluster ==="
    case "$CLUSTER" in
        vbox)
            if ssh -p 3022 user01@127.0.0.1 "test -d /shared/results" 2>/dev/null; then
                scp -P 3022 -r user01@127.0.0.1:"/shared/results/$CLUSTER" "$B/results/"
                scp -P 3022 user01@127.0.0.1:"/shared/results-$CLUSTER.log" "$B/results/"
                ssh -p 3022 user01@127.0.0.1 "rm -rf /shared/results /shared/results-$CLUSTER.log"
            else
                echo "WARNING: /shared/results does not exist; skipping result collection and cleanup"
            fi

            VBoxManage controlvm node01 acpipowerbutton
            VBoxManage controlvm node02 acpipowerbutton
            sleep 10
            VBoxManage controlvm master acpipowerbutton

            while [ -n "$(VBoxManage list runningvms)" ]; do sleep 2; done
            ;;

        kvm)
            if ssh -F "$K/ssh/config" master "test -d /shared/results" 2>/dev/null; then
                scp -F "$K/ssh/config" -r master:"/shared/results/$CLUSTER" "$B/results/"
                scp -F "$K/ssh/config" master:"/shared/results-$CLUSTER.log" "$B/results/"
                ssh -F "$K/ssh/config" master "rm -rf /shared/results /shared/results-$CLUSTER.log"
            else
                echo "WARNING: /shared/results does not exist; skipping result collection and cleanup"
            fi

            (cd "$K" && ./cluster-down.sh)
            ;;

        docker)
            if docker exec master test -d /shared/results 2>/dev/null; then
                docker cp master:"/shared/results/$CLUSTER" "$B/results/"
                docker cp master:"/shared/results-$CLUSTER.log" "$B/results/"
                docker exec -u user01 master rm -rf /shared/results "/shared/results-$CLUSTER.log"
            else
                echo "WARNING: /shared/results does not exist; skipping result collection and cleanup"
            fi

            (cd "$D" && docker compose down)
            ;;

        host) : ;;
    esac

    echo "=== Done! Results saved and cluster $CLUSTER stopped. ==="
fi