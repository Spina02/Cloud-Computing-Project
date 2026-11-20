#!/bin/bash

# bench.sh - benchmark runner, to be launched on the MASTER node (or on the HOST for the "host" label).
# Usage:   bash bench.sh <label> [cpu] [disk_local] [disk_shared] [net] [hpcc]
#          (when no test names are provided, all tests are run; "host" has only cpu and disk_local available)

LABEL=${1:?usage: bash bench.sh <label> [tests...]}
shift

[[ "$LABEL" =~ ^(vbox|kvm|docker|host)$ ]] || { echo "Unknown label: $LABEL"; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
if [ -z "${RESULTS:-}" ]; then
    if [ "$LABEL" = host ]; then
        RESULTS=$(cd "$HERE/.." && pwd)/results
    else
        RESULTS=/shared/results
    fi
fi

if [ $# -eq 0 ]; then
    if [ "$LABEL" = host ]; then
        set -- cpu disk_local hpcc
    else
        set -- net cpu disk_local disk_shared hpcc
    fi
fi

REPS=${REPS:-5}                   # number of repetitions for each test
SEQ_SIZE=${SEQ_SIZE:-1g}          # 1GB for sequential tests
RAND_LOCAL=${RAND_LOCAL:-128m}    # local random 4K sample
RAND_SHARED=${RAND_SHARED:-32m}   # shared random 4K sample

HOSTFILE=/shared/mpi-hostfile
OUT=$RESULTS/$LABEL
LOCAL=$HOME/iozone_tmp            # local (non-NFS) directory for IOzone

# On the host, pin the 2 threads to the same physical cores used by the master guest
PIN=""; [ "$LABEL" = host ] && PIN="taskset -c 0,2"

# If the label is "docker", use the Docker network; otherwise, use the default.
if [[ "$LABEL" == "docker" ]]; then
    MPI_NET=${MPI_NET:-172.28.1.0/24}
elif [[ "$LABEL" != host ]]; then
    MPI_NET=${MPI_NET:-192.168.56.0/24}
fi
[ "$LABEL" != host ] && export OMPI_MCA_btl_tcp_if_include=$MPI_NET

mkdir -p "$OUT" "$LOCAL"
export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1
{ date; uname -r; nproc; uptime; cat /sys/firmware/acpi/platform_profile 2>/dev/null; cat /sys/kernel/mm/transparent_hugepage/enabled; df -T "$LOCAL"; mpirun --version 2>/dev/null | head -1; } > "$OUT/env.txt"

# --- CPU and memory (single node, 2 threads) --------------------------------
run_cpu() {
    # $PIN stress-ng --cpu 2 --timeout 5s > /dev/null 2>&1   # warm-up: first run is systematically slower
    for i in $(seq $REPS); do
        $PIN sysbench cpu --cpu-max-prime=20000 --threads=2 --time=15 run > "$OUT/sysbench_cpu_$i.txt"; sleep 2
        $PIN sysbench memory --memory-block-size=1M --memory-total-size=10G --threads=2 run > "$OUT/sysbench_mem_$i.txt"; sleep 2
        $PIN stress-ng --cpu 2 --timeout 15s --metrics-brief --yaml "$OUT/stressng_cpu_$i.yaml" > "$OUT/stressng_cpu_$i.txt" 2>&1; sleep 2
        $PIN stress-ng --vm 2 --vm-bytes 512M --timeout 15s --metrics-brief --yaml "$OUT/stressng_vm_$i.yaml" > "$OUT/stressng_vm_$i.txt" 2>&1; sleep 2
    done
}

# --- Disk I/O on the local filesystem of the master -------------------------
# -i 0 write/rewrite, -i 1 read/reread, -i 2 random read/write, -e = include flush in timing
run_disk_local() {
  # iozone -i 0 -i 1 -r 1m -s $SEQ_SIZE -e -I -f "$LOCAL/f" > /dev/null; rm -f "$LOCAL/f" #warmup
  for i in $(seq $REPS); do
    rm -f "$LOCAL/f"
    sync; sleep 3
    iozone -i 0 -i 1 -r 1m -s $SEQ_SIZE -e -I -f "$LOCAL/f" > "$OUT/iozone_local_seq_$i.txt"
    rm -f "$LOCAL/f"
    sync; sleep 3
    iozone -i 0 -i 2 -r 4k -s $RAND_LOCAL -e -I -f "$LOCAL/f" > "$OUT/iozone_local_rand_$i.txt"
    rm -f "$LOCAL/f"
    sync; sleep 3
  done
}

# --- Disk I/O on /shared, run from node01 (NFS client / Docker bind mount) ---
run_disk_shared() {
  # ssh node01 "iozone -i 0 -i 1 -r 1m -s $SEQ_SIZE -e -I -f /shared/iozone.tmp" > /dev/null; rm -f /shared/iozone.tmp   # warm-up
  for i in $(seq $REPS); do
    rm -f /shared/iozone.tmp
    sync; sleep 3
    ssh node01 "iozone -i 0 -i 1 -r 1m -s $SEQ_SIZE -e -I -f /shared/iozone.tmp" > "$OUT/iozone_shared_seq_$i.txt"
    rm -f /shared/iozone.tmp
    sync; sleep 3
    ssh node01 "iozone -i 0 -i 2 -r 4k -s $RAND_SHARED -e -I -f /shared/iozone.tmp" > "$OUT/iozone_shared_rand_$i.txt"
    rm -f /shared/iozone.tmp
    sync; sleep 3
  done
}

# --- Network: iperf3 throughput + ping latency -------------------------------
run_net() {
  # Start iperf3 server in background on node01 and node02 (pkill -x avoids killing the current subshell)
  ssh node01 "pkill -x iperf3 2>/dev/null; iperf3 -s -D"
  ssh node02 "pkill -x iperf3 2>/dev/null; iperf3 -s -D"
  sleep 1

  for i in $(seq $REPS); do
    iperf3 -c node01 -t 10 -O 2 > "$OUT/iperf_m_n1_tcp_$i.txt"             # master -> node01
    sleep 1
    iperf3 -c node01 -t 10 -O 2 -R > "$OUT/iperf_m_n1_rev_$i.txt"          # node01 -> master (reverse)
    sleep 1
    ssh node01 "iperf3 -c node02 -t 10 -O 2" > "$OUT/iperf_n1_n2_$i.txt"   # worker -> worker
    sleep 1
    ping -c 30 -i 0.2 node01 > "$OUT/ping_m_n1_$i.txt"
    sleep 1
    ssh node01 "ping -c 30 -i 0.2 node02" > "$OUT/ping_n1_n2_$i.txt"
    sleep 1
  done

  # Stop the iperf3 servers at the end of the test
  ssh node01 "pkill -x iperf3 2>/dev/null"
  ssh node02 "pkill -x iperf3 2>/dev/null"
}

# --- HPC Challenge on all 3 nodes (6 MPI processes) -------------------------
# -x passes the variable to the remote nodes; stderr is kept to spot MPI warnings
run_hpcc() {
  if [ "$LABEL" = host ]; then
    LAUNCH="taskset -c 0,2,4,6,8,10 mpirun -np 6 --bind-to core --mca mpi_yield_when_idle 0"
  else
    LAUNCH="mpirun -np 6 --hostfile $HOSTFILE"
  fi
  for i in $(seq $REPS); do
    $LAUNCH -x OPENBLAS_NUM_THREADS -x OMP_NUM_THREADS hpcc 2> "$OUT/hpcc_stderr_$i.txt"
    mv hpccoutf.txt "$OUT/hpcc_$i.txt"
    sleep 3
  done
}

for test in "$@"; do
    echo ">>> $test ($(date +%T))"
    run_$test
    sleep 5
done
echo "Done. Results in $OUT"
