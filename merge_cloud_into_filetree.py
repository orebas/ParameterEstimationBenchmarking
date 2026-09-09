#!/usr/bin/env python3
"""Consolidate the quoll-broad run: fill cloud-completed cells into the local filetree.

The fleet ran the 3 ODEPE arms on cloud droplets and AMIGO2 locally; the slow-tail
systems (latent/crauste/bioh) were re-solved locally afterward. As a result each
cell's authoritative result.csv lives EITHER in the local filetree OR under
cloud/hetzner/results/broad/<shard>/benchmark_*/filetree/. This script copies the
result sidecars from cloud into the local filetree for every cell the local tree is
still missing, so the standard pipeline (build_flat_metrics.py --bench-dir ...) sees
the complete run in one tree.

Precedence: LOCAL WINS. A cell that already has a local result.csv is never touched
(matches process_quoll_results.py, where the local re-solves are authoritative for the
slow tail). Only "cloud-only" cells are filled. Idempotent + re-runnable.
"""
import os, glob, json, shutil

BENCH = "benchmark_quoll_broad_2026-05-29"
ARMS  = ["odepe_v2_polish", "odepe_v2_nopolish", "odepe_shade", "amigo2"]
# Output sidecars the pipeline reads (build_flat_metrics.py). Inputs (data.csv,
# script.jl, the seed file already present locally) are left alone.
SIDECARS = ["result.csv", "odepe_metadata.json", "wall_time_seconds.txt",
            "failure_reason.txt", "cell_seed.txt"]

cells = [i["id"] for i in json.load(open(f"{BENCH}/huge_json.json"))["instances"]]

def nonempty(p): return os.path.exists(p) and os.path.getsize(p) > 0

def newest_cloud_dir(arm, cell):
    """Return the cloud cell dir holding the newest nonempty result.csv, or None."""
    hits = [p for p in glob.glob(
        f"cloud/hetzner/results/broad/*/benchmark_*/filetree/{arm}_run/{cell}/result.csv")
        if nonempty(p)]
    if not hits:
        return None
    newest = max(hits, key=os.path.getmtime)
    return os.path.dirname(newest)

filled = skipped_local = no_cloud = 0
for arm in ARMS:
    for cell in cells:
        local_dir = f"{BENCH}/filetree/{arm}_run/{cell}"
        if nonempty(f"{local_dir}/result.csv"):
            skipped_local += 1
            continue
        cdir = newest_cloud_dir(arm, cell)
        if cdir is None:
            no_cloud += 1
            continue
        os.makedirs(local_dir, exist_ok=True)
        for fn in SIDECARS:
            src = os.path.join(cdir, fn)
            if os.path.exists(src):
                shutil.copy2(src, os.path.join(local_dir, fn))
        filled += 1

print(f"filled (cloud->local) : {filled}")
print(f"skipped (local wins)  : {skipped_local}")
print(f"no result anywhere    : {no_cloud}")
print(f"total cells x arms    : {len(cells)*len(ARMS)}")
