# Comparing VMs and Containers: Performance Evaluation

Final project for the **Cloud Computing** and **Advanced Cloud Computing** exams
(University of Trieste). Full write-up: [**report.pdf**](report.pdf).

## Overview

The basic assignment asks to compare the performance of virtual machines and
containers on a small cluster. The advanced one covers two exercises: the network
performance of Linux network namespaces connected in different ways, and the
monitoring of a Kubernetes cluster running an HPC workload.

I built three equivalent three-node clusters (VirtualBox, KVM/QEMU and Docker) and
benchmarked them, together with the host, on CPU, memory, local and shared disk I/O,
network and HPC Challenge. I then compared three namespace topologies (veth, bridge,
VXLAN) with the clusters of the basic part. Finally, I deployed a Kubernetes cluster
with the Kube-Prometheus stack, ran HPL in a Pod, and used the collected metrics to
identify its bottlenecks and fix a memory exhaustion failure.

## Repository structure

## Repository structure

```
.
├── benchmarks/
│   └── scripts/          # bench.sh, cluster.sh, summary/plot scripts, HPCC input
├── docker-cluster/       # Dockerfile, compose.yaml, entrypoint.sh
├── kube-cluster/
│   ├── benchmark/        # k8s-bench.sh, HPCC input, HPL plot
│   ├── cloud-init/       # node templates, libvirt networks
│   └── k8s/              # Pod manifest, Flannel, Kube-Prometheus values
├── kvm-cluster/          # cloud-init templates, libvirt networks, setup scripts
├── namespaces/           # netns.sh: veth / bridge / VXLAN topologies
└── report.pdf
```

The VirtualBox cluster was configured manually and is documented step by step in
Chapter 2 of the report.
## Requirements

- Linux host (developed on Arch Linux), hardware virtualization enabled
- VirtualBox, libvirt/QEMU/KVM (`virsh`, `virt-install`, `cloud-image-utils`), Docker with Compose
- `kubectl` and `helm` (Kubernetes part)
- Python 3 with `numpy` and `matplotlib` (plots)

## Usage

Run the benchmarks from a TTY right after a reboot, with only one cluster running
at a time. The KVM and Kubernetes clusters use the same libvirt networks and
addresses, so they cannot run together.

**Basic part (VMs and containers)**

```bash
cd kvm-cluster && ./kvm-setup.sh            # one-time KVM setup
cd docker-cluster && docker compose build   # Docker image

cd benchmarks/scripts
./cluster.sh start <vbox|kvm|docker|host>   # start the cluster, copy the scripts
# on the master node:
cd /shared && bash bench.sh <label> [cpu] [disk_local] [disk_shared] [net] [hpcc]
./cluster.sh stop <vbox|kvm|docker|host>    # collect results, shut down
```

**Network namespaces**

```bash
sudo ./namespaces/netns.sh <veth|bridge|vxlan>   # create the topology
sudo ./benchmarks/scripts/bench_netns.sh <mode>  # run iperf3 + ping
sudo ./namespaces/netns.sh clean
```

**Kubernetes + HPL**

```bash
cd kube-cluster && ./kube-setup.sh        # create the three VMs
# manual steps (kubeadm init/join, Flannel, Helm): see Chapter 8
cd benchmark && ./k8s-bench.sh <label>    # run the HPL Pod and collect metrics
```

**Plots**

```bash
python benchmarks/scripts/plot_results.py <results-folder>
```