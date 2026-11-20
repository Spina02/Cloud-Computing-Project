#!/bin/bash
export LIBVIRT_DEFAULT_URI="qemu:///system"

# VM: spegni e rimuovi la definizione
for n in k8s-master k8s-monitoring k8s-hpl-worker; do
  virsh destroy "$n" 2>/dev/null || true
  virsh undefine "$n" --nvram 2>/dev/null || virsh undefine "$n" || true
done

# Reti: spegni e rimuovi definizione per entrambe
for net in CloudBasicNet CloudWanNet; do
  virsh net-destroy "$net" 2>/dev/null || true
  virsh net-undefine "$net" 2>/dev/null || true
done

# File generati e configurazioni
rm -f images/k8s-master.qcow2 images/k8s-monitoring.qcow2 images/k8s-hpl-worker.qcow2
rm -f images/*-seed.iso
rm -rf cloud-init/k8s-master cloud-init/k8s-monitoring cloud-init/k8s-hpl-worker

# Reset completo di kvm-setup.sh: rimozione immagine base e chiavi SSH
# rm -f images/ubuntu-base.img
rm -rf ssh/