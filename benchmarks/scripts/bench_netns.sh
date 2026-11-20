#!/bin/bash

# Usage: sudo ./bench_netns.sh <veth|bridge|vxlan>

MODE=$1

case $MODE in
    veth)   DST=10.0.1.2 ;;
    bridge) DST=10.0.2.2 ;;
    vxlan)  DST=10.0.3.2 ;;
    *)
        echo "Usage: sudo $0 <veth|bridge|vxlan>"
        exit 1
        ;;
esac

REPS=5
OUT=results/netns/$MODE
mkdir -p $OUT

ip netns exec ns2 taskset -c 4 iperf3 -s -D
sleep 5

for i in $(seq 1 $REPS); do
    ip netns exec ns1 taskset -c 0 iperf3 -c $DST -t 10 -O 2     > $OUT/iperf3_tcp_$i.txt
    ip netns exec ns1 taskset -c 0 iperf3 -c $DST -t 10 -O 2 -R  > $OUT/iperf3_rev_$i.txt
    ip netns exec ns1 ping -c 30 -i 0.2 $DST                     > $OUT/ping_$i.txt
done

pkill -x iperf3