#!/usr/bin/env python3
"""Kill hung local ODEPE cells — degenerate/divergent homotopy solves that run for many
hours holding a worker hostage (e.g. latent_subpopulation_branch_0_0 at noise 0, which
should finish in ~1h but instead spins forever inside HomotopyContinuation.solve).
NOTE: the cause is NOT the zero-IC jet degeneracy (an earlier guess — refuted 2026-06-02:
no param/IC near 0). latent_subpopulation_branch has an S3 subpopulation-permutation
symmetry (y2=I1+I2+I3 + identical subpop dynamics ⇒ M=6); clean/low-noise data makes the
target polynomial system non-generic and the HC tracker stalls. Only a small low-noise
subset actually hangs. Diagnostic harness: repro/latent_hc_stall_2026_06_02/.

Heuristic: low-noise cells (0 / 1em8 / 1em6) should solve in ~1h, high-noise (1em4 / 1em2)
in ~3-5h. So kill any low-noise cell running >4h, or any cell >7h. Killing the julia child
makes its estimate.py parent's blocking subprocess.run return → it moves to the next cell;
the killed cell simply stays missing (a degenerate failure, accepted or re-run at end-cleanup).
Only ever matches local slow-tier cells (the only `julia ... script.jl` processes on this box).
"""
import subprocess, re

out = subprocess.run("ps -eo pid,etimes,args", shell=True, capture_output=True, text=True).stdout
killed = []
for line in out.splitlines():
    parts = line.split(None, 2)
    if len(parts) < 3 or "julia" not in parts[2] or "script.jl" not in parts[2]:
        continue
    pid, age = parts[0], int(parts[1])
    m = re.search(r"/([^/]+)/script\.jl", parts[2])
    if not m:
        continue
    cell = m.group(1)
    noise = cell.rsplit("_", 1)[-1]
    low_noise = noise in ("0", "1em8", "1em6")
    # Hang-prone low-noise cells (latent S3 symmetry / bioh sign-flip) hang fast and tarpit
    # workers — kill them sooner; completable latent/bioh low-noise finish in <1h, so a 2-3h
    # threshold won't false-kill them. crauste doesn't hang → keep the patient 4h. (2026-06-02)
    if low_noise and "latent_subpopulation_branch" in cell:
        thr = 7200        # latent low-noise: 2h
    elif low_noise and "biohydrogenation" in cell:
        thr = 10800       # bioh low-noise: 3h
    elif low_noise:
        thr = 14400       # other low-noise (crauste): 4h
    else:
        thr = 25200       # high-noise: 7h
    if age > thr:
        # DISABLED 2026-06-03 pending discussion with Oren: these are mostly long-but-FINITE
        # re-solves (~5h: degenerate low-noise → ~219 candidate solutions to re-solve), NOT
        # infinite hangs. Killing them destroyed completable work. Observe-only: report, no kill.
        # subprocess.run(["kill", "-9", pid])
        killed.append(f"WOULD-kill {cell}({age // 3600}h{age % 3600 // 60}m)[DISABLED]")

print(f"killed {len(killed)} hung cell(s): {', '.join(killed)}" if killed
      else "no hung cells (all within expected solve time)")
