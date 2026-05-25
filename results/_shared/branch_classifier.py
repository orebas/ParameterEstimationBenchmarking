"""Branch-aware classification + metrics for benchmark postprocessing.

This module implements the post-hoc analysis side of the "ODEPE returns a
calibrated branch set" claim. Given a method's returned candidate set + the
known synthetic truth + a branch-orbit definition, it determines which
algebraic branch each candidate corresponds to and computes coverage /
duplicate-fraction / hit-any-branch metrics.

NEVER passed to the estimator. The orbit info here is truth-aware (we know
synthetic truth in benchmarks); it is used only to map candidates to
known-equivalent truth points before computing relative error. The
estimator never sees this file's outputs.

Used by:
- results/wallaby_analysis/build_wallaby_branch_occupancy.py
- results/quoll_analysis/build_quoll_branch_metrics.py  (future)

Schema version: 1
"""

import hashlib
import json
from dataclasses import dataclass, field
from itertools import permutations
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

SCHEMA_VERSION = 1
DEFAULT_BRANCH_DIVERSITY_EPS = 0.01
DEFAULT_SUCCESS_THRESHOLD = 0.50


def normalize_var_name(col: str) -> str:
    """`x(t)` -> `x`. ODEPE writes states as `x(t)`; truth uses bare names."""
    if col.endswith("(t)"):
        return col[:-3]
    return col


def canonical_orbit_hash(branch_orbit: Optional[Dict[str, Any]]) -> str:
    """Stable hash of an orbit definition, whitespace/key-order independent.

    Returns the first 12 hex chars of sha256 over the canonical JSON encoding.
    Returns the empty string for orbit=None (the "no orbit" case is its own
    sentinel; no hash needed).
    """
    if branch_orbit is None:
        return ""
    canon = json.dumps(branch_orbit, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canon.encode()).hexdigest()[:12]


@dataclass
class BranchMetadata:
    """Per-system branch info loaded from the sidecar."""

    system_name: str
    algebraic_multiplicity: int = 1
    physical_multiplicity_positive_bounds: int = 1
    branch_orbit: Optional[Dict[str, Any]] = None
    notes: Optional[str] = None

    @property
    def orbit_hash(self) -> str:
        return canonical_orbit_hash(self.branch_orbit)


def load_branch_metadata(path: Path) -> Dict[str, BranchMetadata]:
    """Load sidecar `config/branch_metadata.json`.

    Returns `{system_name: BranchMetadata}` for every non-`_meta` entry.
    Systems not in the sidecar default to M=1 + no orbit when looked up via
    `get_branch_metadata(name, sidecar)`.
    """
    path = Path(path)
    with open(path) as f:
        raw = json.load(f)
    out: Dict[str, BranchMetadata] = {}
    for sys_name, entry in raw.items():
        if sys_name == "_meta":
            continue
        out[sys_name] = BranchMetadata(
            system_name=sys_name,
            algebraic_multiplicity=int(entry.get("algebraic_multiplicity", 1)),
            physical_multiplicity_positive_bounds=int(
                entry.get(
                    "physical_multiplicity_positive_bounds",
                    entry.get("algebraic_multiplicity", 1),
                )
            ),
            branch_orbit=entry.get("branch_orbit"),
            notes=entry.get("notes"),
        )
    return out


def get_branch_metadata(
    system_name: str, sidecar: Dict[str, BranchMetadata]
) -> BranchMetadata:
    """Lookup with default fallback for systems not in the sidecar."""
    if system_name in sidecar:
        return sidecar[system_name]
    return BranchMetadata(system_name=system_name)


# --------------------------------------------------------------------------
# Orbit enumeration
# --------------------------------------------------------------------------


def enumerate_orbit(
    truth: Dict[str, float], orbit_spec: Optional[Dict[str, Any]]
) -> List[Dict[str, float]]:
    """Given truth + orbit spec, return the list of truth-equivalent points.

    - `None` orbit -> `[truth]` (the trivial M=1 orbit).
    - `label_permutation` -> all N! permutations of N grouped triples.
    - `involution` -> `[identity, swap]`.
    """
    if orbit_spec is None:
        return [dict(truth)]

    otype = orbit_spec.get("type")
    if otype == "label_permutation":
        return _enumerate_label_permutation(truth, orbit_spec)
    if otype == "involution":
        return _enumerate_involution(truth, orbit_spec)
    raise ValueError(f"Unknown branch_orbit type: {otype!r}")


def _enumerate_label_permutation(
    truth: Dict[str, float], spec: Dict[str, Any]
) -> List[Dict[str, float]]:
    """Permute groups of variables jointly. All groups must have the same length N.

    Example spec:
        {"type":"label_permutation",
         "permuted_groups":[["a1","a2","a3"],["b1","b2","b3"],["I1","I2","I3"]],
         "fixed":["S","R"]}

    Returns N! permuted truth points.
    """
    groups = spec["permuted_groups"]
    fixed = spec.get("fixed", [])
    n = len(groups[0])
    if not all(len(g) == n for g in groups):
        raise ValueError(f"label_permutation: groups must share length; got {[len(g) for g in groups]}")

    out: List[Dict[str, float]] = []
    for perm in permutations(range(n)):
        permuted = {var: truth[var] for var in fixed if var in truth}
        for group in groups:
            for i, var in enumerate(group):
                source = group[perm[i]]
                if source in truth:
                    permuted[var] = truth[source]
        # Carry forward any truth keys we haven't touched (e.g., unidentifiable axes).
        for k, v in truth.items():
            permuted.setdefault(k, v)
        out.append(permuted)
    return out


def _enumerate_involution(
    truth: Dict[str, float], spec: Dict[str, Any]
) -> List[Dict[str, float]]:
    """A simple 2-element orbit: identity and one swap.

    Example spec:
        {"type":"involution",
         "swap_pairs":[["R1tot","R2tot"],["kon1","kon2"]],
         "fixed":["L"]}

    Returns `[truth, swap(truth)]`.
    """
    swap_pairs = spec["swap_pairs"]
    fixed = spec.get("fixed", [])
    identity = dict(truth)
    swapped = dict(truth)
    for a, b in swap_pairs:
        if a in truth and b in truth:
            swapped[a], swapped[b] = truth[b], truth[a]
    # `fixed` is documentation-only; we don't need to do anything with it here
    # because the swap above leaves any non-mentioned key alone.
    return [identity, swapped]


# --------------------------------------------------------------------------
# Distance / classification
# --------------------------------------------------------------------------


def max_rel_error(
    candidate: Dict[str, float],
    target: Dict[str, float],
    exclude: Optional[set] = None,
) -> Optional[float]:
    """L∞ relative error over (target keys ∩ candidate keys) \\ exclude.

    Relative error = |c - t| / |t|  for |t| > 1e-15, else absolute error.

    Returns `None` if no variables compared (e.g., everything excluded).
    """
    exclude = exclude or set()
    rels: List[float] = []
    for var, tv in target.items():
        nvar = normalize_var_name(var)
        if nvar in exclude or var in exclude:
            continue
        ev = candidate.get(var)
        if ev is None:
            ev = candidate.get(var + "(t)")
        if ev is None:
            ev = candidate.get(nvar)
        if ev is None:
            continue
        try:
            ev = float(ev)
        except (TypeError, ValueError):
            continue
        if abs(tv) > 1e-15:
            rels.append(abs(ev - tv) / abs(tv))
        else:
            rels.append(abs(ev - tv))
    if not rels:
        return None
    return max(rels)


def assign_candidate_to_orbit(
    candidate: Dict[str, float],
    truth: Dict[str, float],
    orbit_spec: Optional[Dict[str, Any]],
    exclude: Optional[set] = None,
) -> Tuple[int, Optional[float]]:
    """Find the orbit element closest to `candidate`. Returns (index, max_rel_error).

    For `orbit_spec=None` (no orbit defined), returns (0, max_rel_error vs truth).
    """
    targets = enumerate_orbit(truth, orbit_spec)
    best_idx = 0
    best_err: Optional[float] = None
    for i, target in enumerate(targets):
        err = max_rel_error(candidate, target, exclude=exclude)
        if err is None:
            continue
        if best_err is None or err < best_err:
            best_err = err
            best_idx = i
    return best_idx, best_err


# --------------------------------------------------------------------------
# Cluster-distinctness fallback (when orbit is None)
# --------------------------------------------------------------------------


def pairwise_max_rel_distance(
    cand_a: Dict[str, float],
    cand_b: Dict[str, float],
    exclude: Optional[set] = None,
) -> Optional[float]:
    """L∞ relative-difference between two candidates over their shared identifiable keys."""
    exclude = exclude or set()
    rels: List[float] = []
    for var, va in cand_a.items():
        nvar = normalize_var_name(var)
        if nvar in exclude or var in exclude:
            continue
        if var not in cand_b and (nvar) not in cand_b:
            continue
        vb = cand_b.get(var)
        if vb is None:
            vb = cand_b.get(nvar)
        try:
            va, vb = float(va), float(vb)
        except (TypeError, ValueError):
            continue
        denom = max(abs(va), abs(vb), 1e-15)
        rels.append(abs(va - vb) / denom)
    if not rels:
        return None
    return max(rels)


def cluster_distinct_indices(
    candidates: Sequence[Dict[str, float]],
    exclude: Optional[set] = None,
    eps: float = DEFAULT_BRANCH_DIVERSITY_EPS,
) -> List[int]:
    """Single-linkage clustering on L∞ identifiable-space distance.

    Returns a list of cluster-id ints, one per candidate. Two candidates are
    in the same cluster iff their pairwise distance is < `eps`.
    """
    n = len(candidates)
    if n == 0:
        return []
    # Union-find
    parent = list(range(n))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(i: int, j: int) -> None:
        ri, rj = find(i), find(j)
        if ri != rj:
            parent[ri] = rj

    for i in range(n):
        for j in range(i + 1, n):
            d = pairwise_max_rel_distance(candidates[i], candidates[j], exclude=exclude)
            if d is not None and d < eps:
                union(i, j)

    # Normalize cluster ids: relabel by first-occurrence order
    seen: Dict[int, int] = {}
    out: List[int] = []
    for i in range(n):
        root = find(i)
        if root not in seen:
            seen[root] = len(seen)
        out.append(seen[root])
    return out


# --------------------------------------------------------------------------
# Per-cell branch metrics
# --------------------------------------------------------------------------


@dataclass
class BranchMetrics:
    """Per-(cell, method) branch-aware metrics."""

    n_candidates: int
    expected_M: int
    expected_M_physical: int
    orbit_type: str  # "label_permutation" | "involution" | "none"
    # Orbit-based:
    assigned_branches: List[int] = field(default_factory=list)
    per_candidate_err: List[Optional[float]] = field(default_factory=list)
    # Aggregate at success_threshold:
    hit_any_branch: bool = False
    distinct_branch_hits: int = 0
    duplicate_branch_fraction: float = 0.0
    branch_coverage_fraction: float = 0.0
    # Cluster-distinctness (used when orbit is None, also reported as a sanity stat):
    cluster_distinct_count: int = 0


def compute_branch_metrics(
    candidates: Sequence[Dict[str, float]],
    truth: Dict[str, float],
    metadata: BranchMetadata,
    exclude: Optional[set] = None,
    success_threshold: float = DEFAULT_SUCCESS_THRESHOLD,
    cluster_eps: float = DEFAULT_BRANCH_DIVERSITY_EPS,
) -> BranchMetrics:
    """Compute branch-aware metrics for one (cell, method).

    `candidates`: list of dicts mapping variable name -> value. Typically the M
    rows from a `result.csv`, with parameter and state columns merged.
    `truth`: parameter_values ∪ state_values for the cell.
    `metadata`: per-system orbit info from the sidecar.
    `exclude`: identifiable-axis exclusion set (typically `all_unidentifiable`
        from `odepe_metadata.json[best]`).

    Behavior:
    - If `metadata.branch_orbit` is given, each candidate is classified to the
      nearest orbit element and `distinct_branch_hits` counts unique successful
      orbit indices.
    - If `metadata.branch_orbit is None`, falls back to cluster-distinctness:
      `distinct_branch_hits` = number of distinct clusters that contain a
      candidate within `success_threshold` of truth.
    """
    exclude = exclude or set()
    orbit_type = (
        metadata.branch_orbit["type"]
        if metadata.branch_orbit and "type" in metadata.branch_orbit
        else "none"
    )

    # Per-candidate orbit assignment + error
    assigned: List[int] = []
    errors: List[Optional[float]] = []
    for cand in candidates:
        idx, err = assign_candidate_to_orbit(
            cand, truth, metadata.branch_orbit, exclude=exclude
        )
        assigned.append(idx)
        errors.append(err)

    # hit_any_branch: any candidate within threshold of some orbit element
    hit_any = any(e is not None and e <= success_threshold for e in errors)

    # distinct_branch_hits + branch_coverage_fraction
    # We cap distinct_branch_hits at physical_multiplicity_positive_bounds so the
    # metric reflects ALGEBRAIC branch coverage (paper-meaningful) rather than
    # raw geometric cluster count. Without the cap, systems with
    # physical_M < algebraic_M (e.g., biohydrogenation, slow_fast under wallaby's
    # positivity bounds) can report distinct > physical_M when ODEPE returns
    # numerically-separable but algebraically-duplicate candidates.
    expected_M = metadata.algebraic_multiplicity
    expected_M_phys = metadata.physical_multiplicity_positive_bounds

    if metadata.branch_orbit is not None:
        # Orbit-based: count unique orbit indices among successful candidates
        successful_branches = {
            assigned[i]
            for i, e in enumerate(errors)
            if e is not None and e <= success_threshold
        }
        raw_distinct = len(successful_branches)
    else:
        # Cluster-distinctness fallback: count distinct clusters that contain a
        # successful candidate
        cluster_ids = cluster_distinct_indices(candidates, exclude=exclude, eps=cluster_eps)
        successful_cluster_ids = {
            cluster_ids[i]
            for i, e in enumerate(errors)
            if e is not None and e <= success_threshold
        }
        raw_distinct = len(successful_cluster_ids)

    # Cap at physical M so coverage doesn't exceed 100%.
    distinct = min(raw_distinct, expected_M_phys) if expected_M_phys > 0 else raw_distinct
    coverage = distinct / expected_M_phys if expected_M_phys > 0 else 0.0

    # duplicate_branch_fraction: fraction of candidates that share an
    # orbit/cluster assignment with another candidate
    n = len(candidates)
    if metadata.branch_orbit is not None:
        bucket_counts: Dict[int, int] = {}
        for a in assigned:
            bucket_counts[a] = bucket_counts.get(a, 0) + 1
        n_dup = sum(c for c in bucket_counts.values() if c > 1) - len(
            [c for c in bucket_counts.values() if c > 1]
        )
    else:
        cluster_ids = cluster_distinct_indices(candidates, exclude=exclude, eps=cluster_eps)
        bucket_counts = {}
        for c in cluster_ids:
            bucket_counts[c] = bucket_counts.get(c, 0) + 1
        n_dup = sum(c for c in bucket_counts.values() if c > 1) - len(
            [c for c in bucket_counts.values() if c > 1]
        )
    duplicate_fraction = n_dup / n if n > 0 else 0.0

    # Always also compute cluster_distinct_count as a sanity stat
    cluster_ids = cluster_distinct_indices(candidates, exclude=exclude, eps=cluster_eps)
    cluster_distinct = len(set(cluster_ids))

    return BranchMetrics(
        n_candidates=n,
        expected_M=expected_M,
        expected_M_physical=expected_M_phys,
        orbit_type=orbit_type,
        assigned_branches=assigned,
        per_candidate_err=errors,
        hit_any_branch=hit_any,
        distinct_branch_hits=distinct,
        duplicate_branch_fraction=duplicate_fraction,
        branch_coverage_fraction=coverage,
        cluster_distinct_count=cluster_distinct,
    )


# --------------------------------------------------------------------------
# Inline unit tests
# --------------------------------------------------------------------------


def _test_normalize_var_name() -> None:
    assert normalize_var_name("x(t)") == "x"
    assert normalize_var_name("k1") == "k1"
    assert normalize_var_name("ab(t)") == "ab"
    print("  normalize_var_name: PASS")


def _test_canonical_orbit_hash() -> None:
    a = {"type": "involution", "swap_pairs": [["x", "y"]], "fixed": ["z"]}
    b = {"fixed": ["z"], "swap_pairs": [["x", "y"]], "type": "involution"}
    # Same orbit definition, different key order -> same hash
    assert canonical_orbit_hash(a) == canonical_orbit_hash(b)
    assert canonical_orbit_hash(None) == ""
    print("  canonical_orbit_hash: PASS")


def _test_enumerate_orbit_label_permutation() -> None:
    truth = {"a1": 0.1, "a2": 0.2, "a3": 0.3, "b1": 1.0, "b2": 2.0, "b3": 3.0, "x": 99.0}
    spec = {
        "type": "label_permutation",
        "permuted_groups": [["a1", "a2", "a3"], ["b1", "b2", "b3"]],
        "fixed": ["x"],
    }
    orbits = enumerate_orbit(truth, spec)
    assert len(orbits) == 6  # 3! permutations
    # Identity must be in the list
    identity_present = any(
        all(orbits[i].get(k) == v for k, v in truth.items()) for i in range(len(orbits))
    )
    assert identity_present
    # All orbits have x=99 (fixed)
    assert all(o["x"] == 99.0 for o in orbits)
    # Each orbit has the same set of values for a*, just reassigned
    for o in orbits:
        assert sorted([o["a1"], o["a2"], o["a3"]]) == [0.1, 0.2, 0.3]
        assert sorted([o["b1"], o["b2"], o["b3"]]) == [1.0, 2.0, 3.0]
    # a* and b* are permuted in lockstep: if a1 = 0.2 in an orbit, then b1 must
    # be the b-value originally assigned to position 2, i.e. 2.0
    for o in orbits:
        if o["a1"] == 0.2:
            assert o["b1"] == 2.0
    print("  enumerate_orbit label_permutation: PASS")


def _test_enumerate_orbit_involution() -> None:
    truth = {"R1": 1.0, "R2": 2.0, "kon1": 0.5, "kon2": 0.7, "L": 10.0}
    spec = {"type": "involution", "swap_pairs": [["R1", "R2"], ["kon1", "kon2"]], "fixed": ["L"]}
    orbits = enumerate_orbit(truth, spec)
    assert len(orbits) == 2
    assert orbits[0] == truth
    assert orbits[1] == {"R1": 2.0, "R2": 1.0, "kon1": 0.7, "kon2": 0.5, "L": 10.0}
    print("  enumerate_orbit involution: PASS")


def _test_enumerate_orbit_none() -> None:
    truth = {"k1": 0.5, "x1": 1.0}
    orbits = enumerate_orbit(truth, None)
    assert len(orbits) == 1
    assert orbits[0] == truth
    print("  enumerate_orbit None: PASS")


def _test_max_rel_error() -> None:
    cand = {"k1": 0.5, "x1(t)": 1.05}
    target = {"k1": 0.5, "x1": 1.0}
    err = max_rel_error(cand, target)
    assert err is not None and abs(err - 0.05) < 1e-10  # 1.05 vs 1.0 = 5%
    # With exclusion
    err = max_rel_error(cand, target, exclude={"x1"})
    assert err == 0.0  # only k1 left, perfect
    print("  max_rel_error: PASS")


def _test_assign_candidate_to_orbit_permutation() -> None:
    truth = {"a1": 0.1, "a2": 0.2, "a3": 0.3, "b1": 1.0, "b2": 2.0, "b3": 3.0}
    spec = {
        "type": "label_permutation",
        "permuted_groups": [["a1", "a2", "a3"], ["b1", "b2", "b3"]],
        "fixed": [],
    }
    # A candidate that matches the "swap a1 ↔ a2, b1 ↔ b2" permutation
    candidate = {"a1": 0.2, "a2": 0.1, "a3": 0.3, "b1": 2.0, "b2": 1.0, "b3": 3.0}
    idx, err = assign_candidate_to_orbit(candidate, truth, spec)
    assert err is not None and err < 1e-10  # exact match to one of the orbits
    print("  assign_candidate_to_orbit permutation: PASS")


def _test_cluster_distinct() -> None:
    candidates = [
        {"k1": 0.5, "x1": 1.0},  # 0
        {"k1": 0.5001, "x1": 1.001},  # 1: within 0.01 of 0
        {"k1": 1.0, "x1": 2.0},  # 2: distinct cluster
    ]
    clusters = cluster_distinct_indices(candidates, eps=0.01)
    assert clusters[0] == clusters[1]
    assert clusters[0] != clusters[2]
    assert len(set(clusters)) == 2
    print("  cluster_distinct_indices: PASS")


def _test_compute_branch_metrics_mult2() -> None:
    """Simulate an M=2 cell where one ODEPE row matches truth, one matches the swap."""
    truth = {"R1": 1.0, "R2": 2.0, "kon1": 0.5, "kon2": 0.7, "L": 10.0}
    metadata = BranchMetadata(
        system_name="test",
        algebraic_multiplicity=2,
        physical_multiplicity_positive_bounds=2,
        branch_orbit={
            "type": "involution",
            "swap_pairs": [["R1", "R2"], ["kon1", "kon2"]],
            "fixed": ["L"],
        },
    )
    candidates = [
        {"R1": 1.001, "R2": 2.002, "kon1": 0.501, "kon2": 0.701, "L": 10.0},  # truth
        {"R1": 2.001, "R2": 1.002, "kon1": 0.702, "kon2": 0.503, "L": 10.0},  # swap
    ]
    m = compute_branch_metrics(candidates, truth, metadata)
    assert m.n_candidates == 2
    assert m.hit_any_branch is True
    assert m.distinct_branch_hits == 2  # both orbit elements covered
    assert m.branch_coverage_fraction == 1.0
    assert m.duplicate_branch_fraction == 0.0
    assert sorted(m.assigned_branches) == [0, 1]
    print("  compute_branch_metrics mult-2 (both branches found): PASS")


def _test_compute_branch_metrics_duplicate() -> None:
    """Simulate an M=2 cell where ODEPE returns 2 near-duplicates of one branch."""
    truth = {"R1": 1.0, "R2": 2.0, "kon1": 0.5, "kon2": 0.7, "L": 10.0}
    metadata = BranchMetadata(
        system_name="test",
        algebraic_multiplicity=2,
        physical_multiplicity_positive_bounds=2,
        branch_orbit={
            "type": "involution",
            "swap_pairs": [["R1", "R2"], ["kon1", "kon2"]],
            "fixed": ["L"],
        },
    )
    candidates = [
        {"R1": 1.001, "R2": 2.002, "kon1": 0.501, "kon2": 0.701, "L": 10.0},  # truth
        {"R1": 1.003, "R2": 2.004, "kon1": 0.503, "kon2": 0.703, "L": 10.0},  # ALSO truth
    ]
    m = compute_branch_metrics(candidates, truth, metadata)
    assert m.distinct_branch_hits == 1
    # 2 candidates in 1 branch: 1 of them is the "duplicate" of the first.
    # duplicate_fraction = 1 / 2 = 0.5
    assert m.duplicate_branch_fraction == 0.5
    assert m.assigned_branches[0] == m.assigned_branches[1]
    print("  compute_branch_metrics mult-2 (duplicate branch): PASS")


def _test_compute_branch_metrics_null_orbit() -> None:
    """Wallaby-style: M=2 with no explicit orbit; rely on cluster-distinctness."""
    truth = {"k1": 0.5, "k2": 1.0}
    metadata = BranchMetadata(
        system_name="wallaby_m2",
        algebraic_multiplicity=2,
        physical_multiplicity_positive_bounds=2,
        branch_orbit=None,  # cluster fallback
    )
    # Two candidates: one near truth, one distinct AND clearly >50% off
    candidates = [
        {"k1": 0.501, "k2": 1.001},  # ~0% off truth
        {"k1": 0.9, "k2": 1.8},      # 80% off both axes -> exceeds 50% threshold
    ]
    m = compute_branch_metrics(candidates, truth, metadata)
    # Only the first is within 50% of truth, so distinct_branch_hits = 1
    assert m.hit_any_branch is True
    assert m.distinct_branch_hits == 1
    assert m.cluster_distinct_count == 2  # still 2 distinct geometric clusters
    print("  compute_branch_metrics null orbit: PASS")


def _run_tests() -> None:
    print(f"branch_classifier.py inline tests (schema_version={SCHEMA_VERSION})")
    _test_normalize_var_name()
    _test_canonical_orbit_hash()
    _test_enumerate_orbit_label_permutation()
    _test_enumerate_orbit_involution()
    _test_enumerate_orbit_none()
    _test_max_rel_error()
    _test_assign_candidate_to_orbit_permutation()
    _test_cluster_distinct()
    _test_compute_branch_metrics_mult2()
    _test_compute_branch_metrics_duplicate()
    _test_compute_branch_metrics_null_orbit()
    print("ALL TESTS PASS")


if __name__ == "__main__":
    _run_tests()
