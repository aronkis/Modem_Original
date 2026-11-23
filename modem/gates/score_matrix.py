#!/usr/bin/env python3
"""sp3 task 3: score a run directory's (variant, stimulus) legs against
reference_loss.toml (ruling 2's tolerance rule).

Loss comes from `<prefix>_t7.log` -- the saved stdout of
`env T7_NAIR=428 python3 $SCORE/score_t7.py <prefix>`, which prints
`... LOSS=x.xx%` -- NOT from `<prefix>_res.txt` (ruling (a)). Counts
(r3_skips, r3_extras, rh_pop_on_empty, rh_push_on_full, pd_push_on_full,
pd_pop_on_empty, occTrue_end) come from `<prefix>_res.txt`'s
`token=value` pairs. Missing keys (either side) are skipped, not failed --
e.g. `extras` is not scored on R4B trees, whose `r3_extras` slot is a
lock-sentinel, not a count (see build_sro_rxfix4b.legs).

Usage:
  score_matrix.py --ref reference_loss.toml --run DIR --map "K=prefix" [--map ...]

Prints one `MATRIX <key> PASS|FAIL loss=<m> ref=<r> tol=<t> ...` line per
mapped key, then `MATRIX_EXIT 0|1` (0 iff every mapped key passed).
"""
import argparse, math, pathlib, re, sys

try:
    import tomllib
except ModuleNotFoundError:  # py<3.11
    import tomli as tomllib

# reference_loss.toml key -> _res.txt token
COUNT_KEYS = {
    "skips": "r3_skips",
    "extras": "r3_extras",
    "pop_on_empty": "rh_pop_on_empty",
    "push_on_full": "rh_push_on_full",
    "pd_push_on_full": "pd_push_on_full",
    "pd_pop_on_empty": "pd_pop_on_empty",
    "opens": "occTrue_end",
    # W1 rows carry no loss_pct (a different harness, no score_t7 leg -- see
    # module docstring); without these two, score() finds zero intersecting
    # keys for a W1 row and reports ok=True on an EMPTY detail string, i.e. a
    # W1 row could never fail no matter what its _res.txt actually says.
    "mismatches": "mismatches",
    "delivered": "delivered",
}


def loss_tol(ref):
    return max(0.10, 0.10 * ref)


def count_tol(ref):
    return max(2, math.ceil(0.10 * ref))


def parse_res(path):
    """<prefix>_res.txt: whitespace-separated token=value pairs across lines."""
    out = {}
    if not path.exists():
        return out
    for tok in path.read_text().split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            try:
                out[k] = int(v)
            except ValueError:
                pass
    return out


def parse_loss(path):
    """<prefix>_t7.log: score_t7.py's saved stdout, `... LOSS=x.xx%` somewhere in it."""
    if not path.exists():
        return None
    m = re.search(r"LOSS=([0-9.]+)%", path.read_text())
    return float(m.group(1)) if m else None


def score(ref_table, run_dir, mapping):
    """mapping: dict key -> prefix. Returns list of (key, ok, detail).

    A row that scores NOTHING is a FAILURE, not a pass. Two ways that used to
    happen silently, both demonstrated on real reference rows:
      * the reference entry carries no `loss_pct` and none of its COUNT_KEYS
        appear in the observed `_res.txt` -- `ok` stayed True with an empty
        detail string, so the row could never fail whatever the run produced;
      * `<prefix>_res.txt` is missing entirely -- parse_res() returns {}, every
        count key is "missing: skipped, not failed", and the row passed on the
        strength of a file that was never written.
    Both now fail loudly (`vacuous -- no scored keys` / `res=MISSING`).
    """
    results = []
    for key, prefix in mapping.items():
        ref = ref_table.get(key)
        if ref is None:
            results.append((key, False, "no reference entry"))
            continue
        run_dir = pathlib.Path(run_dir)
        res_path = run_dir / f"{prefix}_res.txt"
        res_missing = not res_path.exists()
        res = parse_res(res_path)
        loss = parse_loss(run_dir / f"{prefix}_t7.log")
        ok = True
        scored = 0          # reference keys that actually intersected the run
        details = []
        if res_missing:
            ok = False
            details.append(f"res=MISSING ({res_path.name})")
        if "loss_pct" in ref:
            if loss is None:
                ok = False
                details.append("loss=MISSING")
            else:
                t = loss_tol(ref["loss_pct"])
                lok = abs(loss - ref["loss_pct"]) <= t
                ok = ok and lok
                scored += 1
                details.append(f"loss={loss:.2f} ref={ref['loss_pct']:.2f} tol={t:.3f} {'OK' if lok else 'BAD'}")
        for tk, rtok in COUNT_KEYS.items():
            if tk not in ref:
                continue
            if rtok not in res:
                # missing key: skipped, not failed
                continue
            t = count_tol(ref[tk])
            cok = abs(res[rtok] - ref[tk]) <= t
            ok = ok and cok
            scored += 1
            details.append(f"{tk}={res[rtok]} ref={ref[tk]} tol={t} {'OK' if cok else 'BAD'}")
        if scored == 0:
            ok = False
            details.append("vacuous -- no scored keys")
        results.append((key, ok, " ".join(details)))
    return results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", required=True)
    ap.add_argument("--run", required=True)
    ap.add_argument("--map", action="append", required=True, help="KEY=prefix")
    a = ap.parse_args()

    with open(a.ref, "rb") as f:
        doc = tomllib.load(f)
    ref_table = doc.get("ref", {})

    mapping = {}
    for m in a.map:
        k, _, v = m.partition("=")
        mapping[k] = v

    results = score(ref_table, a.run, mapping)
    exit_code = 0
    for key, ok, detail in results:
        verdict = "PASS" if ok else "FAIL"
        if not ok:
            exit_code = 1
        print(f"MATRIX {key} {verdict} {detail}")
    print(f"MATRIX_EXIT {exit_code}")
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
