#!/usr/bin/env python3
"""One descheduler pass against a freshly reset stand; prints one JSON object.

Taints the node, starts the descheduler (--descheduling-interval=0: one pass), and
removes the taint on the first "Evicted pod" log line. Everything after that line is
an eviction decided on a node that no longer carries the taint.

The trigger is the log line, not a timer: it is the same event on every machine, so
the numbers differ in latency and not in what they mean.

usage: measure.py --label L --binary B --kubeconfig K --policy P --manifest M
                  --namespace NS --node N --replicas R -- [descheduler flags...]
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile
import time

TAINT_KEY = "example.com/transient"          # key only, no value
TAINT = TAINT_KEY + ":NoSchedule"

ap = argparse.ArgumentParser()
for name in ("label", "binary", "kubeconfig", "policy", "manifest", "namespace", "node", "replicas"):
    ap.add_argument("--" + name, required=True)
ap.add_argument("extra", nargs="*")
a = ap.parse_args()
replicas = int(a.replicas)


def k(*args, check=True):
    return subprocess.run(["kubectl", "--kubeconfig", a.kubeconfig, *args],
                          check=check, capture_output=True, text=True)


def die(msg):
    print("measure: " + msg, file=sys.stderr)
    sys.exit(1)


# Reset: untainted node, the full set of pods Running on it. Idempotent on purpose.
k("taint", "node", a.node, TAINT_KEY + "-", check=False)
k("-n", a.namespace, "delete", "deploy", "victims", "--ignore-not-found", "--wait=true", check=False)
k("apply", "-f", a.manifest)
k("-n", a.namespace, "rollout", "status", "deploy/victims", "--timeout=300s")
running = k("-n", a.namespace, "get", "pods", "-l", "app=victims",
            "--field-selector=status.phase=Running", "-o", "name").stdout.split()
if len(running) != replicas:
    die("expected %d running pods, found %d" % (replicas, len(running)))

k("taint", "node", a.node, TAINT)
t_taint = time.time()
log_path = tempfile.mkstemp(prefix="descheduler-", suffix=".log")[1]
with open(log_path, "w") as log:
    proc = subprocess.Popen(
        [a.binary, "--kubeconfig", a.kubeconfig, "--policy-config-file", a.policy,
         "--descheduling-interval=0", "--v=4", "--disable-metrics", *a.extra],
        stdout=log, stderr=subprocess.STDOUT)
    deadline = time.time() + 120
    while proc.poll() is None and time.time() < deadline:
        if "Evicted pod" in open(log_path).read():
            break
        time.sleep(0.005)
    t_removed_start = time.time()
    k("taint", "node", a.node, TAINT_KEY + "-")
    t_removed = time.time()            # kubectl returned: the apiserver no longer has the taint
    try:
        proc.wait(timeout=180)
    except subprocess.TimeoutExpired:
        proc.kill()
        die("descheduler did not finish; log: " + log_path)
taints_after = k("get", "node", a.node, "-o", "jsonpath={.spec.taints}").stdout

today = datetime.date.today()


def stamp(line):
    # klog: Lmmdd hh:mm:ss.uuuuuu, local time, no year.
    m = re.match(r"[IEWF](\d{2})(\d{2}) (\d\d):(\d\d):(\d\d)\.(\d{6})", line)
    if not m:
        return None
    mo, d, H, M, S, us = map(int, m.groups())
    return datetime.datetime(today.year, mo, d, H, M, S, us).timestamp()


evicted, first_processing = [], None
for line in open(log_path):
    t = stamp(line)
    if t is None:
        continue
    if "Processing node" in line and first_processing is None:
        first_processing = t                  # the pass starts at the plugin's first line
    if "Evicted pod" in line:
        evicted.append(t)
if not evicted or first_processing is None:
    die("no evictions in the log; exit %s, log: %s" % (proc.returncode, log_path))

throttled = sum(1 for line in open(log_path) if "client-side throttling" in line)
gaps = sorted(b - c for b, c in zip(evicted[1:], evicted))
result = dict(
    label=a.label, extra=a.extra, exit=proc.returncode,
    evicted=len(evicted),
    evictions_after_taint_removed=sum(1 for t in evicted if t > t_removed),
    taint_removed_to_last_eviction_s=round(evicted[-1] - t_removed, 3),
    pass_duration_s=round(evicted[-1] - first_processing, 3),
    median_gap_between_evictions_s=round(gaps[len(gaps) // 2], 3) if gaps else 0,
    throttled_requests=throttled,
    taint_applied_to_pass_start_s=round(first_processing - t_taint, 3),
    first_eviction_to_taint_removed_s=round(t_removed - evicted[0], 3),
    node_taints_after=taints_after,
)
os.unlink(log_path)
print(json.dumps(result))
