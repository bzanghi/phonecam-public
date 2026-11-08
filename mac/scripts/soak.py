#!/usr/bin/env python3
"""Summarize a sustained session from ~/Library/Logs/PhoneCam/stats.csv.
Usage: soak.py [minutes=30]  waits until state==live, then samples for N minutes and prints a summary.
The phone camera only runs while an app reads "Phone Camera" (or PhoneCamAlwaysOn is set), so keep a consumer open."""
import csv, os, statistics, sys, time
path = os.path.expanduser("~/Library/Logs/PhoneCam/stats.csv")
minutes = float(sys.argv[1]) if len(sys.argv) > 1 else 30

def rows():
    try:
        with open(path) as f: return list(csv.DictReader(f))
    except FileNotFoundError:
        return []

while True:
    r = rows()
    if r and r[-1].get("state") == "live": break
    time.sleep(5)
start_n = len(r); t0 = r[-1]["time"]; print("live at", t0, flush=True)
time.sleep(minutes * 60)
r = rows()[start_n:]
if not r:
    sys.exit("no samples in the window (stats.csv rotated or the app stopped)")
live = [x for x in r if x["state"] == "live"]

def med(k):
    v = [float(x[k]) for x in live if x.get(k)]
    return (statistics.median(v), min(v), max(v)) if v else None

print(f"window {t0} → {r[-1]['time']}: samples {len(r)}, live {len(live)} ({100 * len(live) // len(r)}%), "
      f"states {sorted(set(x['state'] for x in r))}")
if len(live) < 0.9 * len(r):
    print("  WARNING: live for less than 90% of the window; this is not a valid sustained run")
for k in ["fps", "width", "height", "kbps", "jitter_ms", "decode_ms", "rtt_ms", "out_fps", "cpu_pct", "rss_mb", "consumers"]:
    print(f"  {k}: median/min/max = {med(k)}")
print("  codecs:", sorted(set(x["codec"] for x in live)), " sink yes:", sum(x["sink"] == "yes" for x in r), "/", len(r))
last = r[-1]
print("  lost/dropped/pipe_drop/freezes/pli (last):", *(last.get(k, "") for k in ["lost", "dropped", "pipe_drop", "freezes", "pli"]))
print("  phone (last):", last.get("phone", ""))
