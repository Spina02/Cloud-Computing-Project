#!/usr/bin/env python3
"""Create a compact HPL performance chart suitable for a two-column report layout.

Dependencies: pip install matplotlib numpy
Run: python3 plot_hpl_performance_compact.py
"""
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

MATRIX_SIZES = np.array([8064, 11328, 14016, 17280, 20352])
MEAN_GFLOPS = np.array([108.18, 119.39, 122.00, 122.72, 127.81])
STD_GFLOPS = np.array([2.12, 0.62, 3.33, 3.94, 0.88])
OUTPUT_FILE = "hpl_performance.png"


def main():
    # Compact dimensions and typography for placement beside a table.
    plt.rcParams.update({
        "font.family": "DejaVu Sans",
        "font.size": 13,
        "axes.titlesize": 16,
        "axes.titleweight": "bold",
        "axes.labelsize": 13,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "axes.titlepad": 10,
        "xtick.labelsize": 11,
        "ytick.labelsize": 11,
        "legend.fontsize": 11,
        "figure.facecolor": "white",
        "axes.facecolor": "white",
        "savefig.facecolor": "white",
    })

    fig, ax = plt.subplots(figsize=(7.2, 4.4), constrained_layout=True)
    ax.plot(
        MATRIX_SIZES, MEAN_GFLOPS,
        marker="o", markersize=6, linewidth=2.4,
        label="Mean performance",
    )
    # Keep the standard-deviation band, but remove error bars.
    ax.fill_between(
        MATRIX_SIZES,
        MEAN_GFLOPS - STD_GFLOPS,
        MEAN_GFLOPS + STD_GFLOPS,
        alpha=0.16,
        label="±1 standard deviation",
    )

    # The final measurement used the updated configuration.
    change_x = (MATRIX_SIZES[-2] + MATRIX_SIZES[-1]) / 2
    ax.axvline(change_x, linestyle="--", linewidth=0.9, alpha=0.65)
    ax.annotate(
        "Configuration change\n(6 GB VM, 4 GiB Pod limit)",
        xy=(change_x, 105.0),
        xytext=(MATRIX_SIZES[-2] - 450, 103.5),
        ha="right", va="bottom", fontsize=10,
        arrowprops={"arrowstyle": "-", "linewidth": 0.7, "alpha": 0.6},
    )

    for x, y in zip(MATRIX_SIZES, MEAN_GFLOPS):
        ax.annotate(
            f"{y:.1f}", (x, y),
            xytext=(0, 5), textcoords="offset points",
            ha="center", fontsize=11, fontweight="bold",
        )

    ax.set_title("HPL performance vs. matrix size", loc="left")
    ax.set_xlabel("Matrix size (N)")
    ax.set_ylabel("Performance (GFLOP/s)")
    ax.set_xticks(MATRIX_SIZES)
    ax.xaxis.set_major_formatter(FuncFormatter(lambda x, _: f"{int(x):,}"))
    ax.set_ylim(100, 134)
    ax.grid(axis="y", linestyle=":", linewidth=0.6, alpha=0.55)
    ax.grid(axis="x", visible=False)
    ax.legend(frameon=False, loc="upper left", ncol=2)

    # No error bars and no explanatory caption below the axes.
    fig.savefig(OUTPUT_FILE, dpi=300, bbox_inches="tight")
    print(f"Chart saved to: {OUTPUT_FILE}")
    plt.show()


if __name__ == "__main__":
    main()
