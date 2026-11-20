#!/bin/bash
# summary_netns.sh - network namespaces next to the basic setups: mean (sd) over the repetitions.
# Usage: bash summary_netns.sh [results_dir]
#   results_dir/netns/{veth,bridge,vxlan}   written by bench_netns.sh
#   results_dir/{vbox,docker,...}           written by bench.sh (basic project)
cd "${1:-.}" || exit 1
NETNS=${NETNS:-"veth bridge vxlan"}
BASIC=${BASIC:-"vbox kvm docker"}

# mean and sample standard deviation of the numbers read from stdin
mean() { awk '{x[NR]=$1; s+=$1}
              END {if (!NR) {printf "-"; exit}
                   m=s/NR; for (i=1;i<=NR;i++) v+=(x[i]-m)^2
                   if (NR>1) printf "%.4g (%.2g)", m, sqrt(v/(NR-1)); else printf "%.4g", m}'; }

# row "label" extractor netns_files basic_files
row() {
  printf "%-32s" "$1"
  for d in $NETNS; do printf "%17s" "$($2 netns/$d $3 2>/dev/null | mean)"; done
  for d in $BASIC; do printf "%17s" "$($2 $d $4 2>/dev/null | mean)"; done
  echo
}

# extractors: one number per file
iperf() {
    grep -h receiver "$1"/$2 |
        awk '{
            value = $(NF-2)
            unit = $(NF-1)
            if (unit ~ /^M/) value /= 1000
            else if (unit ~ /^K/) value /= 1000000
            else if (unit ~ /^bits/) value /= 1000000000
            print value
        }'
}
rtt() {
    awk -F/ '/^[[:space:]]*rtt[[:space:]]/ {print $5}' "$1"/$2
}

printf "%-32s" ""
for d in $NETNS; do printf "%17s" "ns-$d"; done
for d in $BASIC; do printf "%17s" "$d"; done
echo
echo "--- Network (basic = master <-> node01)"
row "iperf3 forward (Gbit/s)" iperf 'iperf3_tcp_*.txt' 'iperf_m_n1_tcp_*.txt'
row "iperf3 reverse -R (Gbit/s)" iperf 'iperf3_rev_*.txt' 'iperf_m_n1_rev_*.txt'
row "ping (ms)" rtt 'ping_[0-9]*.txt' 'ping_m_n1_*.txt'