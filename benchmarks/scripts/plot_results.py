#!/usr/bin/env python3
"""
plot_results.py - plots for the VMs vs containers report.

Reads the folder produced by bench.sh / cluster.sh (the same one summary.sh reads):

    results/
      vbox/   sysbench_cpu_1.txt, stressng_cpu_1.yaml, iozone_local_seq_1.txt, iperf_*.txt, hpcc_1.txt ...
      kvm/
      docker/
      host/

and writes one figure per benchmark family (mean with sd error bars over the repetitions).
For the advanced project it also reads the namespace results written by bench_netns.sh:

    results/netns/{veth,bridge,vxlan}/   iperf3_tcp_N.txt, iperf3_rev_N.txt, ping_N.txt

and plots them next to the network results of the basic setups (figure "network_netns").

Usage:
    python plot_results.py results                 # -> results/plots/*.png
    python plot_results.py results -o figs -f pdf  # vector output
    python plot_results.py results --setups vbox kvm docker host --no-labels

Requires: numpy, matplotlib.
"""
import argparse
import re
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.patches import Patch

# --------------------------------------------------------------------------- style
SETUPS = ["vbox", "kvm", "docker", "host"]
NAMES = {"vbox": "VirtualBox", "kvm": "KVM/QEMU", "docker": "Docker", "host": "Host"}
COLORS = {"vbox": "#5B7DB1", "kvm": "#6FAE9B", "docker": "#E0A458", "host": "#8A8F98"}
# network namespace configurations (results/netns/<mode>)
NETNS = ["veth", "bridge", "routed", "vxlan"]   # "routed" is optional (skipped if absent)
NAMES.update({f"netns/{m}": f"ns {m}" for m in NETNS})
COLORS.update({"netns/veth": "#7A5C99", "netns/bridge": "#B0709B", "netns/vxlan": "#D98C8C",
               "netns/routed": "#C77D95"})
INK = "#222222"

plt.rcParams.update({
    "font.family": "sans-serif",
    "font.size": 9,
    "text.color": INK,
    "axes.labelcolor": INK,
    "axes.edgecolor": "#B0B0B0",
    "axes.linewidth": 0.8,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "axes.axisbelow": True,
    "axes.grid": True,
    "axes.grid.axis": "y",
    "grid.color": "#E4E4E4",
    "grid.linewidth": 0.7,
    "xtick.color": INK,
    "ytick.color": INK,
    "xtick.major.size": 0,
    "ytick.major.size": 0,
    "axes.titlesize": 10,
    "axes.titleweight": "semibold",
    "axes.titlelocation": "left",
    "legend.frameon": False,
    "savefig.dpi": 300,
    "savefig.bbox": "tight",
})


# --------------------------------------------------------------------------- parsers
# Each parser takes the directory of one setup and returns a list of floats (one per run),
# mirroring the extractors of summary.sh.
def _files(d, pattern):
    return sorted(Path(d).glob(pattern))


def _text(f):
    return Path(f).read_text(errors="replace")


def sb_cpu(d):
    out = []
    for f in _files(d, "sysbench_cpu_*.txt"):
        m = re.search(r"events per second:\s*([\d.]+)", _text(f))
        if m:
            out.append(float(m.group(1)))
    return out


def sb_mem(d):
    out = []
    for f in _files(d, "sysbench_mem_*.txt"):
        m = re.search(r"transferred \(([\d.]+) MiB/sec\)", _text(f))
        if m:
            out.append(float(m.group(1)))
    return out


def stressng(kind):
    def parse(d):
        out = []
        for f in _files(d, f"stressng_{kind}_*.yaml"):
            # first match = total (newer stress-ng also lists every instance)
            m = re.search(r"bogo-ops-per-second-real-time:\s*([-\d.eE+]+)", _text(f))
            if m:
                out.append(float(m.group(1)))
        return out
    return parse


def iozone(pattern, col):
    """col is the awk column of summary.sh (1-based); result in MB/s."""
    def parse(d):
        out = []
        for f in _files(d, pattern):
            for line in _text(f).splitlines():
                p = line.split()
                if len(p) == 6 and p[0].isdigit():
                    out.append(float(p[col - 1]) / 1024)
                    break
        return out
    return parse


def iperf(pattern):
    def parse(d):
        out = []
        for f in _files(d, pattern):
            for line in _text(f).splitlines():
                if "receiver" in line:
                    p = line.split()
                    v = float(p[-3])
                    if p[-2].startswith("M"):
                        v /= 1000
                    out.append(v)
                    break
        return out
    return parse


def ping(pattern):
    def parse(d):
        out = []
        for f in _files(d, pattern):
            m = re.search(r"^rtt .*= [\d.]+/([\d.]+)/", _text(f), re.M)
            if m:
                out.append(float(m.group(1)))
        return out
    return parse


def hpcc(key, scale=1.0):
    def parse(d):
        out = []
        for f in _files(d, "hpcc_[0-9]*.txt"):
            m = re.search(rf"^{key}=([-\d.eE+]+)", _text(f), re.M)
            if m:
                out.append(float(m.group(1)) * scale)
        return out
    return parse


# --------------------------------------------------------------------------- helpers
def collect(root, setups, spec):
    """spec: list of (label, parser). Returns {setup: {label: (mean, sd) or None}}."""
    data = {}
    for s in setups:
        d = Path(root) / s
        data[s] = {}
        for label, fn in spec:
            vals = fn(d) if d.is_dir() else []
            if vals:
                a = np.array(vals, dtype=float)
                data[s][label] = (a.mean(), a.std(ddof=1) if len(a) > 1 else 0.0)
            else:
                data[s][label] = None
    return data


def present(data, labels):
    """Setups that have at least one value for the given labels."""
    return [s for s in data if any(data[s].get(l) for l in labels)]


def fmt(v):
    if v >= 1000:
        return f"{v / 1000:.1f}k"
    if v >= 100:
        return f"{v:.0f}"
    if v >= 10:
        return f"{v:.1f}"
    if v >= 1:
        return f"{v:.2f}"
    return f"{v:.2g}"


def grouped_bars(ax, data, labels, setups, *, log=False, ylabel=None, title=None,
                 show_labels=True):
    """Grouped bars: one group per label, one bar per setup, error bars = sd."""
    n = len(setups)
    width = 0.8 / n
    x = np.arange(len(labels))
    for i, s in enumerate(setups):
        means, sds, pos = [], [], []
        for j, l in enumerate(labels):
            v = data[s].get(l)
            if v:
                means.append(v[0]); sds.append(v[1]); pos.append(x[j] + (i - (n - 1) / 2) * width)
        if not means:
            continue
        means, sds, pos = map(np.array, (means, sds, pos))
        lower = np.minimum(sds, means * 0.9) if log else sds
        ax.bar(pos, means, width * 0.92, color=COLORS[s], yerr=[lower, sds],
               error_kw=dict(ecolor="#444444", elinewidth=0.9, capsize=2, capthick=0.9),
               zorder=3)
        if show_labels:
            for p, m, sd in zip(pos, means, sds):
                ax.annotate(fmt(m), (p, m + sd), xytext=(0, 2.5), textcoords="offset points",
                            ha="center", va="bottom", fontsize=6.5, color="#555555")
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    if log:
        ax.set_yscale("log")
        ax.margins(y=0.15)
    else:
        ax.set_ylim(bottom=0)
        ax.margins(y=0.12)
        ax.set_ylim(bottom=0)
    if ylabel:
        ax.set_ylabel(ylabel)
    if title:
        ax.set_title(title, pad=8)


def finish(fig, name, title, setups, outdir, fmt_ext):
    handles = [Patch(color=COLORS[s], label=NAMES[s]) for s in setups]
    fig.suptitle(title, x=0.01, ha="left", fontsize=13, fontweight="semibold", y=0.99)
    if len(setups) > 5:   # many series: legend in its own row at the bottom, not over the title
        fig.legend(handles=handles, loc="lower center", ncol=len(setups),
                   bbox_to_anchor=(0.5, 0.0), fontsize=9)
        fig.tight_layout(rect=(0, 0.08, 1, 0.995))
    else:
        fig.legend(handles=handles, loc="upper right", ncol=len(setups),
                   bbox_to_anchor=(0.99, 0.995), fontsize=9)
        fig.tight_layout(rect=(0, 0, 1, 0.995))
    path = Path(outdir) / f"{name}.{fmt_ext}"
    fig.savefig(path)
    plt.close(fig)
    print("saved", path)


# --------------------------------------------------------------------------- figures
def fig_cpu_mem(root, setups, outdir, ext, labels_on):
    spec = [
        ("sysbench cpu", sb_cpu), ("sysbench memory", sb_mem),
        ("stress-ng cpu", stressng("cpu")), ("stress-ng vm", stressng("vm")),
    ]
    units = ["events/s", "MiB/s", "bogo ops/s", "bogo ops/s"]
    data = collect(root, setups, spec)
    sset = present(data, [l for l, _ in spec])
    if not sset:
        print("skip cpu_memory: no data")
        return
    fig, axes = plt.subplots(1, 4, figsize=(11, 3.1))
    for ax, (l, _), u in zip(axes, spec, units):
        grouped_bars(ax, data, [l], sset, ylabel=u, title=l, show_labels=labels_on)
        ax.set_xticks([])
        ax.ticklabel_format(axis="y", style="sci", scilimits=(-3, 4)) if max(
            (data[s][l][0] for s in sset if data[s][l]), default=0) > 1e4 else None
    finish(fig, "cpu_memory", "CPU and memory (2 threads, single node)", sset, outdir, ext)


def _disk_fig(root, setups, outdir, ext, labels_on, fs, name, title, log):
    seq = [("write", iozone(f"iozone_{fs}_seq_*.txt", 3)),
           ("rewrite", iozone(f"iozone_{fs}_seq_*.txt", 4)),
           ("read", iozone(f"iozone_{fs}_seq_*.txt", 5)),
           ("reread", iozone(f"iozone_{fs}_seq_*.txt", 6))]
    rnd = [("random read", iozone(f"iozone_{fs}_rand_*.txt", 5)),
           ("random write", iozone(f"iozone_{fs}_rand_*.txt", 6))]
    d_seq, d_rnd = collect(root, setups, seq), collect(root, setups, rnd)
    sset = present(d_seq, [l for l, _ in seq])
    if not sset:
        print(f"skip {name}: no data")
        return
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(11, 3.1), gridspec_kw=dict(width_ratios=[2, 1]))
    grouped_bars(a1, d_seq, [l for l, _ in seq], sset, log=log, ylabel="MB/s",
                 title="Sequential (1 MB records)", show_labels=labels_on)
    grouped_bars(a2, d_rnd, [l for l, _ in rnd], sset, log=log, ylabel="MB/s",
                 title="Random (4 KB records)", show_labels=labels_on)
    finish(fig, name, title, sset, outdir, ext)


def fig_disk_local(root, setups, outdir, ext, labels_on):
    _disk_fig(root, setups, outdir, ext, labels_on, "local", "disk_local",
              "Disk I/O - local filesystem", False)


def fig_disk_shared(root, setups, outdir, ext, labels_on):
    _disk_fig(root, setups, outdir, ext, labels_on, "shared", "disk_shared",
              "Disk I/O - shared filesystem (from node01)", True)


def fig_network(root, setups, outdir, ext, labels_on):
    ip = [("master → node01", iperf("iperf_m_n1_tcp_*.txt")),
          ("node01 → master", iperf("iperf_m_n1_rev_*.txt")),
          ("node01 → node02", iperf("iperf_n1_n2_*.txt"))]
    pg = [("master ↔ node01", ping("ping_m_n1_*.txt")),
          ("node01 ↔ node02", ping("ping_n1_n2_*.txt"))]
    d_ip, d_pg = collect(root, setups, ip), collect(root, setups, pg)
    sset = present(d_ip, [l for l, _ in ip])
    if not sset:
        print("skip network: no data")
        return
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(11, 3.1), gridspec_kw=dict(width_ratios=[3, 2]))
    grouped_bars(a1, d_ip, [l for l, _ in ip], sset, ylabel="Gbit/s",
                 title="iperf3 TCP throughput", show_labels=labels_on)
    grouped_bars(a2, d_pg, [l for l, _ in pg], sset, ylabel="ms (RTT)",
                 title="ICMP round-trip time", show_labels=labels_on)
    finish(fig, "network", "Network", sset, outdir, ext)


def fig_netns(root, setups, outdir, ext, labels_on):
    """Namespaces (results/netns/<mode>) next to the basic setups.
    Basic setups use the master <-> node01 runs (same client/server roles, plain and -R).
    Order: vbox, kvm, docker, vxlan, bridge, veth, host (a setup without data is skipped)."""
    ns_spec = [("forward", iperf("iperf3_tcp_*.txt")), ("reverse", iperf("iperf3_rev_*.txt"))]
    ns_ping = [("RTT", ping("ping_[0-9]*.txt"))]
    bs_spec = [("forward", iperf("iperf_m_n1_tcp_*.txt")), ("reverse", iperf("iperf_m_n1_rev_*.txt"))]
    bs_ping = [("RTT", ping("ping_m_n1_*.txt"))]
    keys = [f"netns/{m}" for m in NETNS]
    # plot order: vbox, kvm, docker, vxlan, bridge, veth, host
    order = [s for s in setups if s != "host"] + keys[::-1] + [s for s in setups if s == "host"]
    d_ip, d_pg = {}, {}
    for k in order:
        ns = k in keys
        d_ip.update(collect(root, [k], ns_spec if ns else bs_spec))
        d_pg.update(collect(root, [k], ns_ping if ns else bs_ping))
    sset = present(d_ip, ["forward", "reverse"])
    if not any(k in sset for k in keys):
        print("skip network_netns: no data in", Path(root) / "netns")
        return
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(11, 3.1), gridspec_kw=dict(width_ratios=[2, 1]))
    grouped_bars(a1, d_ip, ["forward", "reverse"], sset, ylabel="Gbit/s",
                 title="iperf3 TCP throughput (client in ns1 / master)", show_labels=labels_on)
    grouped_bars(a2, d_pg, ["RTT"], sset, ylabel="ms (RTT)",
                 title="ICMP round-trip time", show_labels=labels_on)
    finish(fig, "network_netns", "Network namespaces vs basic setups", sset, outdir, ext)


HPCC_SPEC = [
    ("HPL", hpcc("HPL_Tflops", 1000), "Gflop/s", False),
    ("StarDGEMM", hpcc("StarDGEMM_Gflops"), "Gflop/s", False),
    ("SingleDGEMM", hpcc("SingleDGEMM_Gflops"), "Gflop/s", False),
    ("StarSTREAM Triad", hpcc("StarSTREAM_Triad"), "GB/s", False),
    ("SingleSTREAM Triad", hpcc("SingleSTREAM_Triad"), "GB/s", False),
    ("PTRANS", hpcc("PTRANS_GBs"), "GB/s", False),
    ("MPIRandomAccess", hpcc("MPIRandomAccess_GUPs"), "GUP/s", False),
    ("SingleRandomAccess", hpcc("SingleRandomAccess_GUPs"), "GUP/s", False),
    ("MPIFFT", hpcc("MPIFFT_Gflops"), "Gflop/s", False),
    ("SingleFFT", hpcc("SingleFFT_Gflops"), "Gflop/s", False),
    ("PingPong latency", hpcc("AvgPingPongLatency_usec"), "µs (log)", True),
    ("PingPong bandwidth", hpcc("AvgPingPongBandwidth_GBytes"), "GB/s", False),
]


def fig_hpcc(root, setups, outdir, ext, labels_on):
    data = collect(root, setups, [(n, f) for n, f, _, _ in HPCC_SPEC])
    sset = present(data, [n for n, *_ in HPCC_SPEC])
    if not sset:
        print("skip hpcc: no data")
        return
    fig, axes = plt.subplots(3, 4, figsize=(11, 7))
    for ax, (n, _, unit, log) in zip(axes.flat, HPCC_SPEC):
        grouped_bars(ax, data, [n], sset, log=log, ylabel=unit, title=n, show_labels=labels_on)
        ax.set_xticks([])
    finish(fig, "hpcc", "HPC Challenge (6 MPI processes over 3 nodes)", sset, outdir, ext)


# --------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("results", help="results folder (contains vbox/, kvm/, docker/, host/)")
    ap.add_argument("-o", "--outdir", help="output folder (default: <results>/plots)")
    ap.add_argument("-f", "--format", default="png", choices=["png", "pdf", "svg"])
    ap.add_argument("--setups", nargs="+", default=SETUPS, help="subfolders to plot, in order")
    ap.add_argument("--no-labels", action="store_true", help="hide the value labels on the bars")
    a = ap.parse_args()

    root = Path(a.results)
    if not root.is_dir():
        ap.error(f"{root} is not a directory")
    outdir = Path(a.outdir) if a.outdir else root / "plots"
    outdir.mkdir(parents=True, exist_ok=True)
    labels_on = not a.no_labels

    for fn in (fig_cpu_mem, fig_disk_local, fig_disk_shared, fig_network, fig_netns, fig_hpcc):
        fn(root, a.setups, outdir, a.format, labels_on)


if __name__ == "__main__":
    main()