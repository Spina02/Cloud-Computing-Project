#!/bin/bash
# summary.sh - side-by-side table of the results: mean (sd) over the repetitions.
# Usage: bash summary.sh [results_dir]
cd "${1:-.}" || exit 1
SETUPS=${SETUPS:-"vbox kvm docker host"}

# mean and sample standard deviation of the numbers read from stdin
mean() { awk '{x[NR]=$1; s+=$1}
              END {if (!NR) {printf "-"; exit}
                   m=s/NR; for (i=1;i<=NR;i++) v+=(x[i]-m)^2
                   if (NR>1) printf "%.4g (%.2g)", m, sqrt(v/(NR-1)); else printf "%.4g", m}'; }

row() {   # row "label" function [args]  ->  calls: function <setup> [args]
  label=$1; fn=$2; shift 2
  printf "%-34s" "$label"
  for d in $SETUPS; do printf "%19s" "$($fn $d "$@" 2>/dev/null | mean)"; done
  echo
}

# extractors: each prints one number per run/file
sb_cpu() { grep -h "events per second" $1/sysbench_cpu_*.txt | awk '{print $4}'; }
sb_mem() { grep -h transferred $1/sysbench_mem_*.txt | sed 's/.*(\(.*\) MiB.*/\1/'; }
sng()    { for f in $1/stressng_$2_*.yaml; do grep -h bogo-ops-per-second-real-time $f | head -1 | awk '{print $2}'; done; }
ioz()    { awk -v c=$3 'NF==6 && $1 ~ /^[0-9]+$/ {print $c/1024}' $1/$2; }   # KB/s -> MB/s
iperf()  { grep -h receiver $1/$2 | awk '{v=$(NF-2); if ($(NF-1) ~ /^M/) v/=1000; print v}'; }
rtt()    { awk -F/ '/^rtt/ {print $5}' $1/$2; }
hpcc_v() { for f in $1/hpcc_[0-9]*.txt; do grep -h "^$2=" $f | head -1 | cut -d= -f2; done; }
hpl()    { hpcc_v $1 HPL_Tflops | awk '{print $1*1000}'; }

printf "%-34s" ""; for d in $SETUPS; do printf "%19s" $d; done; echo

echo "--- CPU / memory (mean (sd) of runs)"
row "sysbench cpu (events/s)"     sb_cpu
row "sysbench memory (MiB/s)"     sb_mem
row "stress-ng cpu (bogo ops/s)"  sng cpu
row "stress-ng vm (bogo ops/s)"   sng vm

# note: with docker "shared" is a local bind mount, not NFS
for fs in local shared; do
  echo "--- Disk $fs (MB/s)"
  row "seq write"     ioz iozone_${fs}_seq_*.txt 3
  row "seq rewrite"   ioz iozone_${fs}_seq_*.txt 4
  row "seq read"      ioz iozone_${fs}_seq_*.txt 5
  row "seq reread"    ioz iozone_${fs}_seq_*.txt 6
  row "random read 4k"  ioz iozone_${fs}_rand_*.txt 5
  row "random write 4k" ioz iozone_${fs}_rand_*.txt 6
done

echo "--- Network"
row "iperf3 master->node01 (Gbit/s)"  iperf iperf_m_n1_tcp_*.txt
row "iperf3 node01->master (Gbit/s)"  iperf iperf_m_n1_rev_*.txt
row "iperf3 node01->node02 (Gbit/s)"  iperf iperf_n1_n2_*.txt
row "ping master->node01 (ms)"        rtt ping_m_n1_*.txt
row "ping node01->node02 (ms)"        rtt ping_n1_n2_*.txt

echo "--- HPCC"
row "HPL (Gflop/s)"                hpl
row "StarDGEMM (Gflop/s)"          hpcc_v StarDGEMM_Gflops
row "SingleDGEMM (Gflop/s)"        hpcc_v SingleDGEMM_Gflops
row "StarSTREAM Triad (GB/s)"      hpcc_v StarSTREAM_Triad
row "SingleSTREAM Triad (GB/s)"    hpcc_v SingleSTREAM_Triad
row "PTRANS (GB/s)"                hpcc_v PTRANS_GBs
row "MPIRandomAccess (GUP/s)"      hpcc_v MPIRandomAccess_GUPs
row "SingleRandomAccess (GUP/s)"   hpcc_v SingleRandomAccess_GUPs
row "MPIFFT (Gflop/s)"             hpcc_v MPIFFT_Gflops
row "SingleFFT (Gflop/s)"          hpcc_v SingleFFT_Gflops
row "PingPong latency (us)"        hpcc_v AvgPingPongLatency_usec
row "PingPong bandwidth (GB/s)"    hpcc_v AvgPingPongBandwidth_GBytes