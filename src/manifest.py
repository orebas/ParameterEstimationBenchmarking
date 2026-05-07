"""
MANIFEST.toml stamping for benchmark runs.

The manifest captures everything needed to reproduce a benchmark run that
isn't already in the per-cell artifacts: git SHAs, environment versions,
config hash, the seed formula, and post-run statistics.

Two phases:
  - "init":     stamp at benchmark-dir creation, before any data generation.
  - "completed": amend with end-of-run statistics after collect_results.py.

Reading is intentionally simple: the file is plain TOML and grep-friendly.
"""
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Literal, Optional


_SEED_FORMULA = (
    'cell_seed(system_name, instance_idx, noise_mnemonic) = '
    'int(hashlib.md5(f"{system_name}_{instance_idx}_{noise_mnemonic}".encode())'
    '.hexdigest()[:8], 16)'
)


def _git_sha(repo_path: Path) -> Optional[str]:
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_path), "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=10, check=True,
        )
        return result.stdout.strip()
    except Exception:
        return None


def _git_dirty(repo_path: Path) -> Optional[bool]:
    """True if working tree has uncommitted changes (tracked files only).

    Uses `git diff-index --quiet HEAD` which is O(working-tree-size) and
    avoids the full status enumeration (which blows past 15s on this repo
    due to the benchmark snapshot dirs). Treats unknown errors as None
    rather than False so callers can distinguish "definitely clean" from
    "couldn't tell."
    """
    try:
        # First refresh the index so timestamp-only changes don't false-positive.
        subprocess.run(
            ["git", "-C", str(repo_path), "update-index", "--refresh"],
            capture_output=True, text=True, timeout=30, check=False,
        )
        result = subprocess.run(
            ["git", "-C", str(repo_path), "diff-index", "--quiet", "HEAD", "--"],
            capture_output=True, text=True, timeout=30, check=False,
        )
        # Exit 0 = clean, exit 1 = dirty, other = error.
        if result.returncode == 0:
            return False
        if result.returncode == 1:
            return True
        return None
    except Exception:
        return None


def _file_sha256(path: Path) -> Optional[str]:
    if not path.exists():
        return None
    try:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(64 * 1024), b""):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return None


def _julia_version() -> Optional[str]:
    julia = shutil.which("julia")
    if not julia:
        return None
    try:
        result = subprocess.run(
            [julia, "--startup-file=no", "--version"],
            capture_output=True, text=True, timeout=10, check=True,
        )
        # Output is like "julia version 1.12.5"
        return result.stdout.strip()
    except Exception:
        return None


def _matlab_version() -> Optional[str]:
    matlab = shutil.which("matlab")
    if not matlab:
        return None
    # We deliberately don't invoke matlab -batch to read the version string;
    # cold-starting MATLAB can take 30+ seconds. Recording the path is enough
    # to identify the install; the actual version is in the bin name path or
    # matlabroot. Keep it best-effort.
    try:
        return os.path.realpath(matlab)
    except Exception:
        return matlab


def _pip_freeze_hash() -> Optional[str]:
    try:
        result = subprocess.run(
            [sys.executable, "-m", "pip", "freeze"],
            capture_output=True, text=True, timeout=20, check=True,
        )
        return hashlib.sha256(result.stdout.encode()).hexdigest()
    except Exception:
        return None


def _toml_escape_str(s: str) -> str:
    """Minimal TOML basic-string escaper for ASCII-only values."""
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def _toml_value(v) -> str:
    if v is None:
        return '""'
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, list):
        return "[" + ", ".join(_toml_value(x) for x in v) + "]"
    return f'"{_toml_escape_str(str(v))}"'


def _emit_section(name: str, fields: Dict[str, object]) -> str:
    lines = [f"[{name}]"]
    for k, v in fields.items():
        lines.append(f"{k} = {_toml_value(v)}")
    return "\n".join(lines) + "\n"


def write_manifest(
    benchmark_dir: Path,
    config: Dict,
    software_list: List[str],
    phase: Literal["init", "completed"],
    expected_cells: Optional[int] = None,
    completion_stats: Optional[Dict] = None,
) -> Path:
    """Write or amend `MANIFEST.toml` in `benchmark_dir`.

    Phase 'init': writes the full manifest with git SHAs, environment versions,
    config hash, seed formula, software list, expected cell count.

    Phase 'completed': appends a [completed] section with end-time + stats.
    Idempotent: re-running with phase='completed' overwrites only the
    [completed] section.
    """
    benchmark_dir = Path(benchmark_dir).resolve()
    manifest_path = benchmark_dir / "MANIFEST.toml"
    repo_root = benchmark_dir.parent if benchmark_dir.parent.name != "" else benchmark_dir.parent

    # Best-effort heuristic for repo_root: walk up from benchmark_dir until we find a .git.
    p = benchmark_dir
    while p != p.parent:
        if (p / ".git").exists() or (p / "src").is_dir():
            repo_root = p
            break
        p = p.parent

    odepe_path = repo_root / "environments" / "ODEParameterEstimation"

    if phase == "init":
        config_path = benchmark_dir / "config" / "config.json"
        systems_path = benchmark_dir / "config" / "systems.json"

        sections = []

        sections.append(_emit_section("run", {
            "benchmark_dir": str(benchmark_dir.name),
            "phase": phase,
            "init_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "host": platform.node(),
            "platform": f"{platform.system()} {platform.machine()}",
            "expected_cells": expected_cells if expected_cells is not None else -1,
            "software_list": list(software_list),
        }))

        sections.append(_emit_section("git.peb", {
            "sha": _git_sha(repo_root) or "",
            "dirty": _git_dirty(repo_root) if _git_dirty(repo_root) is not None else False,
            "url": "",  # could `git remote get-url origin` if needed
        }))

        sections.append(_emit_section("git.odepe", {
            "sha": _git_sha(odepe_path) or "",
            "dirty": _git_dirty(odepe_path) if _git_dirty(odepe_path) is not None else False,
            "path": str(odepe_path),
        }))

        sections.append(_emit_section("julia", {
            "version": _julia_version() or "",
            "manifest_julia_odepe_sha256": _file_sha256(repo_root / "environments" / "julia_odepe" / "Manifest.toml") or "",
            "project_julia_odepe_sha256": _file_sha256(repo_root / "environments" / "julia_odepe" / "Project.toml") or "",
        }))

        sections.append(_emit_section("python", {
            "version": platform.python_version(),
            "executable": sys.executable,
            "pip_freeze_sha256": _pip_freeze_hash() or "",
        }))

        sections.append(_emit_section("matlab", {
            "matlab_path": _matlab_version() or "",
            "amigo2_path": config.get("PATH_TO_AMIGO2", ""),
        }))

        sections.append(_emit_section("config", {
            "config_json_sha256": _file_sha256(config_path) or "",
            "systems_json_sha256": _file_sha256(systems_path) or "",
            "noise_type": config.get("NOISE_TYPE", ""),
            "num_pts": config.get("NUM_PTS", -1),
            "num_tests": config.get("NUM_TESTS", -1),
            "noise_levels": list(config.get("NOISE_LEVEL", {}).keys()),
            "param_interval": config.get("PARAM_INTERVAL", []),
            "search_bounds": config.get("SEARCH_BOUNDS", []),
        }))

        sections.append(_emit_section("seeding", {
            "formula": _SEED_FORMULA,
            "filename": "cell_seed.txt",
            "data_hash_filename": "data.csv.sha256",
        }))

        manifest_path.write_text("\n".join(sections))
        return manifest_path

    elif phase == "completed":
        if not manifest_path.exists():
            raise FileNotFoundError(f"Cannot mark completed; MANIFEST.toml does not exist at {manifest_path}")

        existing = manifest_path.read_text()
        # Strip any prior [completed] section so this is idempotent.
        if "\n[completed]\n" in existing:
            head = existing.split("\n[completed]\n")[0]
        else:
            head = existing.rstrip() + "\n"

        completion_fields = {
            "completed_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        if completion_stats:
            for k, v in completion_stats.items():
                completion_fields[k] = v

        completed_block = _emit_section("completed", completion_fields)
        manifest_path.write_text(head.rstrip() + "\n\n" + completed_block)
        return manifest_path

    else:
        raise ValueError(f"Unknown phase: {phase!r}")
