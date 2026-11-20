#!/bin/bash

# Usage: sudo ./netns.sh <veth|bridge|vxlan|clean>

MODE=$1

# Clean up any existing network namespaces and links
clean() {
    for ns in ns1 ns2 sw1 sw2; do ip netns del $ns 2>/dev/null || true; done
    ip link del br0 2>/dev/null || true
}

# 1. direct veth connection between two namespaces:
#
#           ns1 [veth0 10.0.1.1] ═══════ [veth1 10.0.1.2] ns2

setup_veth() {
    # setup two namespaces
    ip netns add ns1; ip netns add ns2
    # add a link between the two namespaces
    ip -n ns1 link add veth0 type veth peer name veth1 netns ns2
    # assign IP addresses to the interfaces
    ip -n ns1 addr add 10.0.1.1/24 dev veth0
    ip -n ns2 addr add 10.0.1.2/24 dev veth1
    # bring up the interfaces
    ip -n ns1 link set veth0 up
    ip -n ns2 link set veth1 up
}

# 2. bridge between two namespaces:
#
#           ns1 [v1 10.0.2.1] ══ v1-br ─┐
#                                      br0
#           ns2 [v2 10.0.2.2] ══ v2-br ─┘

setup_bridge() {
    # setup two namespaces
    ip netns add ns1; ip netns add ns2
    # create a bridge in the default namespace
    ip link add br0 type bridge
    ip link set br0 up
    # add veth pairs to connect the namespaces to the bridge
    ip link add v1-br type veth peer name v1 netns ns1
    ip link add v2-br type veth peer name v2 netns ns2
    # bring up the bridge and the veth interfaces
    ip link set v1-br master br0 up
    ip link set v2-br master br0 up
    # assign IP addresses to the interfaces in the namespaces
    ip -n ns1 addr add 10.0.2.1/24 dev v1
    ip -n ns2 addr add 10.0.2.2/24 dev v2
    # bring up the interfaces in the namespaces
    ip -n ns1 link set v1 up
    ip -n ns2 link set v2 up
}

# 3. vxlan between two namespaces:
#
#           ns1 [v1 10.0.3.1] ══ v1-br ─ br0 ─ vxlan0 ─ u1 ═══ u2 ─ vxlan1 ─ br1 ─ v2-br ══ [v2 10.0.3.2] ns2
#                                   └────────── sw1 ──────┘   └────────── sw2 ──────┘
#                                    underlay 10.10.0.1/30 <-> 10.10.0.2/30

setup_vxlan() {
    # define namespaces
    for ns in ns1 ns2 sw1 sw2; do ip netns add $ns; done

    # underlay net
    ip -n sw1 link add u1 type veth peer name u2 netns sw2 # link sw1-u1 <-> sw2-u2
    ip -n sw1 addr add 10.10.0.1/30 dev u1                 # assign ip to sw1-u1
    ip -n sw2 addr add 10.10.0.2/30 dev u2                 # assign ip to sw2-u2
    ip -n sw1 link set u1 mtu 1600 up                      # bring up sw1-u1
    ip -n sw2 link set u2 mtu 1600 up                      # bring up sw2-u2

    # bridge and vxlan
    ip -n sw1 link add br0 type bridge
    ip -n sw2 link add br1 type bridge
    ip -n sw1 link add vxlan0 type vxlan id 100 local 10.10.0.1 remote 10.10.0.2 dstport 4789
    ip -n sw2 link add vxlan1 type vxlan id 100 local 10.10.0.2 remote 10.10.0.1 dstport 4789
    ip -n sw1 link set vxlan0 master br0
    ip -n sw2 link set vxlan1 master br1

    # a veth per namespace to connect the namespaces to the bridges
    ip -n sw1 link add v1-br type veth peer name v1 netns ns1
    ip -n sw2 link add v2-br type veth peer name v2 netns ns2
    ip -n sw1 link set v1-br master br0
    ip -n sw2 link set v2-br master br1

    # assign IP addresses to the interfaces in the namespaces
    ip -n ns1 addr add 10.0.3.1/24 dev v1
    ip -n ns2 addr add 10.0.3.2/24 dev v2

    # bring up the interfaces
    for l in br0 vxlan0 v1-br; do ip -n sw1 link set $l up; done
    for l in br1 vxlan1 v2-br; do ip -n sw2 link set $l up; done
    ip -n ns1 link set v1 up
    ip -n ns2 link set v2 up
}


case $MODE in
    veth)   clean; setup_veth;   DST=10.0.1.2 ;;
    bridge) clean; setup_bridge; DST=10.0.2.2 ;;
    vxlan)  clean; setup_vxlan;  DST=10.0.3.2 ;;
    clean)  clean; exit 0 ;;
    *)      echo "usage: $0 veth|bridge|vxlan|clean"; exit 1 ;;
esac

# connectivity test: ping from ns1 to ns2
ip netns exec ns1 ping -c 2 $DST
