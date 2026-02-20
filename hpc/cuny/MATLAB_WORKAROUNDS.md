# MATLAB Workarounds for CUNY Arrow Cluster

Last updated: 2026-02-19

MATLAB R2024b on the CUNY Arrow cluster has two infrastructure issues that
require workarounds. Both are handled automatically by the SLURM scripts in
`hpc/cuny/`, but this document explains what's broken and how it was fixed
in case you need to debug or reproduce the setup.

## Issue 1: License Server Down

### Symptom

MATLAB fails immediately with:

```
License checkout failed.
License Manager Error -97
Licensing error: -97,121.
```

### Root Cause

The MATLAB module (`Utils/Matlab/R2024b`) ships with a network license file at
`/pfssfs1/t/share/tools/matlab/R2024b/licenses/network.lic` pointing to
`SERVER 10.10.1.163 ... 28000`. The FlexNet license manager daemon (`lmgrd`)
on that server is not running. TCP port 28000 accepts connections but does not
respond with the FlexNet protocol.

A second license file exists at `/pfssfs1/t/share/tools/matlab/license/license.lic`
pointing to `hpclicsrv2.csi.cuny.edu` (163.238.128.66), but this host is
unreachable from the cluster ("No route to host").

### Fix: MathWorks Online Licensing

CUNY has a campus-wide Total Academic Headcount (TAH) license from MathWorks.
This means every faculty member, researcher, and student can use MATLAB through
their individual MathWorks account, without needing a network license server.

Compute nodes can reach `login.mathworks.com:443` and
`licensing.mathworks.com:443`, so online licensing works.

**One-time activation (interactive):**

```bash
srun --partition=debug --nodelist=n139 --time=00:10:00 --mem=2G --pty bash
module purge
module load Utils/Matlab/R2024b
export LD_LIBRARY_PATH=/scratch/oren-qc-13/.matlab_libs:$LD_LIBRARY_PATH
matlab -singleCompThread -nodisplay -nosplash -nodesktop -licmode onlinelicensing
# Enter your MathWorks account email (linked to your CUNY email)
# Enter your password
# Once you see the >> prompt, type: exit
```

This stores credentials in `~/.matlab/credentials/`. Future MATLAB invocations
with `-licmode onlinelicensing` will reuse the stored token automatically.

**In batch scripts:**

The `-licmode onlinelicensing` flag must be passed to every `matlab` invocation.
This was added to `src/estimate.py` in the `get_cmd()` function:

```python
# Before (broken):
'matlab -singleCompThread -nodisplay -nosplash -nodesktop -r "run ..."'

# After (working):
'matlab -singleCompThread -nodisplay -nosplash -nodesktop -licmode onlinelicensing -r "run ..."'
```

Without this flag, MATLAB defaults to the broken network license and fails
with error -97.

## Issue 2: Missing X11 Libraries on Most Compute Nodes

### Symptom

MATLAB crashes before starting with:

```
Unexpected exception: '...Error loading mwuixloader.so.
libXt.so.6: cannot open shared object file...'
in createMVMAndWaitForExit phase 'Creating local MVM'
```

### Root Cause

MATLAB R2024b unconditionally loads a GUI startup plugin
(`matlab_startup_plugins/matlab_graphics_ui/mwuixloader.so`) during the
"Creating local MVM" phase, even when running in fully headless mode
(`-nodisplay -nosplash -nodesktop -nojvm -batch`). This plugin depends on
X11 libraries (`libXt`, `libICE`, `libSM`, etc.).

The Arrow cluster has inconsistent OS images across nodes. Nodes in the
higher-numbered range (n99, n130-134, n136, n138-139) have the X11 packages
installed. Most other nodes (n3-n24, n100) do not. The login node (arrow3)
also lacks these packages.

**Nodes with X11 libraries (MATLAB works natively):**
n1, n2, n99, n101, n130, n131, n132, n133, n134, n136, n139

**Nodes missing X11 libraries (MATLAB crashes without workaround):**
n3, n5-n15, n17-n19, n21-n24, n100, arrow3 (login node)

The missing RPMs are:
- `libXt` (libXt.so.6)
- `libICE` (libICE.so.6)
- `libSM` (libSM.so.6)
- `libXinerama` (libXinerama.so.1)
- `gdk-pixbuf2` (libgdk_pixbuf-2.0.so.0)

Plus many transitive GTK2/X11 dependencies.

### Fix: Bundled Libraries

Rather than constraining jobs to the ~11 working nodes, we copied all 38
required X11/GTK libraries from a working node (n139) to a shared directory
on the scratch filesystem:

```
/scratch/oren-qc-13/.matlab_libs/
```

The AMIGO2 SLURM script (`hpc/cuny/array_job_amigo2_cuny.s`) sets
`LD_LIBRARY_PATH` to include this directory:

```bash
export LD_LIBRARY_PATH="${SCRATCH}/.matlab_libs:${LD_LIBRARY_PATH}"
```

This makes MATLAB work on ALL nodes regardless of their installed packages.

**Backup:** A copy is kept at `/global/u/oren-qc-13/.matlab_libs/` (persistent
storage) in case the scratch copy is purged.

**To regenerate the bundled libs** (e.g., after a cluster OS upgrade):

```bash
# Run on a node that has the X11 packages (e.g., n139):
srun --partition=debug --nodelist=n139 --time=00:05:00 --mem=1G --pty bash

DEST=/scratch/oren-qc-13/.matlab_libs
mkdir -p $DEST
for lib in libXt.so.6 libICE.so.6 libSM.so.6 libXinerama.so.1 \
           libgdk_pixbuf-2.0.so.0 libXmu.so.6 libXext.so.6 libXrender.so.1 \
           libXfixes.so.3 libXpm.so.4 libXrandr.so.2 libXcursor.so.1 \
           libXcomposite.so.1 libXdamage.so.1 libXi.so.6 libatk-1.0.so.0 \
           libcairo.so.2 libfontconfig.so.1 libfreetype.so.6 libfribidi.so.0 \
           libharfbuzz.so.0 libpango-1.0.so.0 libpangocairo-1.0.so.0 \
           libpangoft2-1.0.so.0 libwayland-client.so.0 libxkbcommon.so.0 \
           libglib-2.0.so.0 libgobject-2.0.so.0 libgio-2.0.so.0 \
           libpixman-1.so.0 libdatrie.so.1 libthai.so.0 libgraphite2.so.3 \
           libgtk-x11-2.0.so.0 libgdk-x11-2.0.so.0 libgmodule-2.0.so.0 \
           libxcb-shm.so.0 libxcb-render.so.0; do
    src=$(ldconfig -p | grep "^[[:space:]]*$lib " | head -1 | awk '{print $NF}')
    [ -n "$src" ] && cp "$src" "$DEST/"
done

# Backup to persistent storage
cp -r $DEST /global/u/oren-qc-13/.matlab_libs/
```

## Summary of Changes to the Codebase

| File | Change |
|------|--------|
| `src/estimate.py` | Added `-licmode onlinelicensing` to MATLAB command in `get_cmd()` |
| `hpc/cuny/array_job_amigo2_cuny.s` | Added `LD_LIBRARY_PATH` for bundled X11 libs |
| `$SCRATCH/.matlab_libs/` | 38 X11/GTK shared libraries copied from n139 |
| `~/.matlab/credentials/` | MathWorks account token (from one-time activation) |

## Recommended: Report to Cluster Admins

Email `hpchelp@csi.cuny.edu` requesting:

1. Restart the MATLAB license server daemon (`lmgrd`) on 10.10.1.163, or
   update the module to use online licensing by default.
2. Install missing X11 packages on all compute nodes and the login node:
   `yum install libXt libICE libSM libXinerama gdk-pixbuf2`
3. Ensure consistent OS images across all nodes.
