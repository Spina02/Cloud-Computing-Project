#!/bin/bash
export LIBVIRT_DEFAULT_URI="qemu:///system"

# VM: spegni e rimuovi la definizione
for n in master node01 node02; do
  virsh destroy "$n" 2>/dev/null || true
  virsh undefine "$n" --nvram 2>/dev/null || virsh undefine "$n" || true
done

# Reti: spegni e rimuovi definizione per entrambe
for net in CloudBasicNet CloudWanNet; do
  virsh net-destroy "$net" 2>/dev/null || true
  virsh net-undefine "$net" 2>/dev/null || true
done

# File generati e configurazioni
rm -f images/master.qcow2 images/node01.qcow2 images/node02.qcow2
rm -f images/*-seed.iso
rm -rf cloud-init/master cloud-init/node01 cloud-init/node02

# Reset completo di kvm-setup.sh: rimozione immagine base e chiavi SSH
# rm -f images/ubuntu-base.img
rm -rf ssh/