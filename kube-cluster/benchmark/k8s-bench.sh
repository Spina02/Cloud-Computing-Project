

#!/bin/bash
# Usage: ./k8s-bench.sh <label>
# Runs the HPCC pod, waits for it to finish and saves in results/<label>/ the
# inputs, the pod log, `kubectl describe` and a summary of the Prometheus metrics.
set -euo pipefail
cd "$(dirname "$0")"                                    # the benchmark/ folder
export KUBECONFIG="${KUBECONFIG:-$PWD/../k8s/admin.conf}"

LABEL="${1:?Usage: $0 <label>}"
OUT="results/$LABEL"
INSTANCE="192.168.56.3:9100"                            # node-exporter of k8s-hpl-worker

mkdir -p results; mkdir "$OUT"                          # fails if the label exists: no overwrite
cp ../k8s/hpl-pod.yaml hpccinf.txt "$OUT/"              # keep the exact inputs of this run

# pod and ConfigMap are removed before the run and again at the end (or on Ctrl-C)
clean() { kubectl delete pod/hpcc configmap/hpcc-config --ignore-not-found >/dev/null; }
clean; trap clean EXIT

kubectl create configmap hpcc-config --from-file=hpccinf.txt    # mounted in /config by the pod
kubectl apply -f ../k8s/hpl-pod.yaml

echo "Waiting for the pod to finish (Ctrl-C to give up)..."
until [[ "$(kubectl get pod hpcc -o jsonpath='{.status.phase}')" =~ ^(Succeeded|Failed)$ ]]; do sleep 5; done
kubectl logs hpcc > "$OUT/pod.log"
kubectl describe pod hpcc > "$OUT/describe.txt"

START=""
END=""
REASON="Unknown"

# Test window = lifetime of the container (UTC), and why it ended (Completed, OOMKilled, ...)
T='{.status.containerStatuses[0].state.terminated'
read -r START END REASON < <(
  kubectl get pod hpcc -o jsonpath="$T.startedAt} $T.finishedAt} $T.reason}"
) || true

# q <name> <PromQL>: max / min / avg over the test window, asking Prometheus through the API server
q() {
  kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query_range?query=$(jq -rn --arg q "$2" '$q|@uri')&start=$START&end=$END&step=5" |
  jq -r --arg n "$1" 'def r: (. * 100 | round) / 100;
    [.data.result[0].values[][1] | tonumber] | "\($n)\t\(max | r)\t\(min | r)\t\(add / length | r)"' ||
  echo "$1 (no data)"
}

{
  echo "pod: $REASON   window: $START -> $END"
  echo
  {
    printf 'metric\tmax\tmin\tavg\n'
    q pod_mem_MiB    "container_memory_working_set_bytes{pod='hpcc',container='hpcc'} / 1048576"
    q pod_cpu_cores  "rate(container_cpu_usage_seconds_total{pod='hpcc',container='hpcc'}[30s])"
    q node_cpu_pct   "100 * (1 - avg(rate(node_cpu_seconds_total{mode='idle',instance='$INSTANCE'}[30s])))"
    q node_mem_pct   "100 * (1 - node_memory_MemAvailable_bytes{instance='$INSTANCE'} / node_memory_MemTotal_bytes{instance='$INSTANCE'})"
    q disk_read_kB_s "rate(node_disk_read_bytes_total{instance='$INSTANCE',device='vda'}[30s]) / 1024"
    q net_rx_kB_s    "rate(node_network_receive_bytes_total{instance='$INSTANCE',device='enp1s0'}[30s]) / 1024"
  } | column -t -s$'\t'
  echo
  grep -E '^HPL_(N|Tflops|time)=' "$OUT/pod.log" || echo "no HPL result in the log"
} | tee "$OUT/summary.txt"