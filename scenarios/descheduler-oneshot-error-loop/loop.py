#!/usr/bin/env python3
"""Run a descheduler binary against a failing pass for a fixed time; print one JSON object.

--descheduling-interval=0 means "one pass, then exit". The failing pass is the
in-cluster ServiceAccount token read: KUBERNETES_SERVICE_HOST/PORT are set and no
token file is mounted, which is what a pod with automountServiceAccountToken=false
sees. The binary is the unmodified production one; only the two variables are ours.

usage: loop.py --label L --binary B --kubeconfig K --policy P --limit SECONDS
"""
import argparse
import json
import os
import resource
import socket
import subprocess
import sys
import threading
import time

MARKER = b"unable to reconcile an in cluster SA token"
METRICS_PORT = 10258       # descheduler binds it unconditionally in the releases compared

ap = argparse.ArgumentParser()
for name in ("label", "binary", "kubeconfig", "policy", "limit"):
    ap.add_argument("--" + name, required=True)
a = ap.parse_args()
limit = float(a.limit)

with socket.socket() as s:
    if s.connect_ex(("127.0.0.1", METRICS_PORT)) == 0:
        print("loop: port %d is in use; the descheduler would fail on it, not on the token" % METRICS_PORT,
              file=sys.stderr)
        sys.exit(1)

env = dict(os.environ, KUBERNETES_SERVICE_HOST="127.0.0.1", KUBERNETES_SERVICE_PORT="443")
before = resource.getrusage(resource.RUSAGE_CHILDREN)
t0 = time.time()
proc = subprocess.Popen(
    [a.binary, "--kubeconfig", a.kubeconfig, "--policy-config-file", a.policy,
     "--descheduling-interval", "0"],
    env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

counts = {"marker": 0, "lines": 0}


def drain():
    # Counting in chunks keeps the reader from throttling the child by much; a marker
    # split across two chunks is lost, which is noise against hundreds of thousands.
    while True:
        chunk = os.read(proc.stderr.fileno(), 1 << 20)
        if not chunk:
            return
        counts["marker"] += chunk.count(MARKER)
        counts["lines"] += chunk.count(b"\n")


reader = threading.Thread(target=drain)
reader.start()
try:
    proc.wait(timeout=limit)
    exited = True
except subprocess.TimeoutExpired:
    exited = False
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
wall = time.time() - t0
reader.join()
after = resource.getrusage(resource.RUSAGE_CHILDREN)

# ru_maxrss is bytes on macOS and kibibytes on Linux.
rss_mib = after.ru_maxrss / (1048576 if sys.platform == "darwin" else 1024)
print(json.dumps(dict(
    label=a.label, exited_on_its_own=exited, exit=proc.returncode if exited else None,
    wall_s=round(min(wall, limit) if not exited else wall, 2),
    cpu_s=round((after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime), 2),
    max_rss_mib=round(rss_mib),
    error_lines=counts["marker"], stderr_lines=counts["lines"])))
