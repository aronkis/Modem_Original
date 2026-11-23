#!/usr/bin/env python3
"""sp3 task 3: collect the reference-matrix run legs into reference_loss.toml.

Reads, per prefix (a run leg's name in reference_matrix.legs), the leg's own
<prefix>_res.txt (whitespace token=value pairs -- either the RXFIX_R4 family
format `r3_skips=8 r3_extras=0 ...` or the W1GATE format
`W1GATE prefix=... nsamp=... mismatches=0 ...`) and, when present,
<prefix>_t7.log -- the saved stdout of
`env T7_NAIR=428 python3 $SCORE/score_t7.py <prefix>`, which is where LOSS
comes from (ruling (a); NOT from _res.txt). extras (r3_extras) is only
meaningful on R4DR1 -- on R4B it is a lock-sentinel, not a count -- so it is
omitted for R4B rows.

Usage: collect_reference.py --out reference_loss.toml <prefix> [<prefix> ...]
"""
import argparse, hashlib, pathlib, re, sys

H = pathlib.Path(__file__).resolve().parent          # modem/fixes
ROOT = H.parent.parent                                # repo root

TREE_FOR_VARIANT = {
    "R4B": ROOT / "modem/rtl_sim/s1_rtl_rxfix_R4B/Rate_Handle.v",
    "R4DR1": ROOT / "modem/rtl_sim/s1_rtl_rxfix_R4DR1/Rate_Handle.v",
    "W1": ROOT / "modem/rtl_sim/s1_rtl_rxfix_W1/Rate_Handle.v",
}


MODEL_TREE = ROOT / "modem/rtl_sim/s1_rtl_model/Rate_Handle.v"   # the model gate tree (make_sro_trees --from-regen)


def variant_stim(prefix):
    """Injected-chain prefixes (reference_matrix.legs) and, since the sp4 rung
    (2026-09-19), the model-matrix prefixes: m0_n_* = R4B (FIXCTL 0),
    m20_n_* = R4DR1 (FIXCTL 20), w1_* = W1 -- a model tree has no injected
    per-variant trees, so those rows pin the model gate tree's Rate_Handle.v."""
    if prefix.startswith("r4dr1_n_"):
        return "R4DR1", prefix[len("r4dr1_"):]
    if prefix.startswith("r4b_n_"):
        return "R4B", prefix[len("r4b_"):]
    if prefix.startswith("m20_n_"):
        return "R4DR1", prefix[len("m20_"):]
    if prefix.startswith("m0_n_"):
        return "R4B", prefix[len("m0_"):]
    if prefix.startswith("w1_"):
        return "W1", prefix[len("w1_"):]
    raise SystemExit(f"collect_reference: cannot classify prefix {prefix!r}")


def parse_res(path):
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
    if not path.exists():
        return None
    m = re.search(r"LOSS=([0-9.]+)%", path.read_text())
    return float(m.group(1)) if m else None


def sha256_of(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_table(prefix, cwd):
    variant, stim = variant_stim(prefix)
    res = parse_res(cwd / f"{prefix}_res.txt")
    loss = parse_loss(cwd / f"{prefix}_t7.log")
    if loss is None and variant != "W1":
        # A missing loss_pct silently disables loss gating for this row
        # downstream (score_matrix.py only compares loss `if "loss_pct" in
        # ref`) -- a hole here becomes a permanently-green gate cell. Fail
        # loud instead: the paired *_t7 leg must have produced LOSS= for
        # every R4B/R4DR1 prefix.
        raise SystemExit(f"COLLECT_REFERENCE_NO_LOSS {prefix}")
    fields = []
    if loss is not None:
        fields.append(("loss_pct", round(loss, 2)))
    if "r3_skips" in res:
        fields.append(("skips", res["r3_skips"]))
    if "r3_extras" in res and variant != "R4B":
        fields.append(("extras", res["r3_extras"]))
    if "occTrue_end" in res:
        fields.append(("opens", res["occTrue_end"]))
    if "rh_pop_on_empty" in res:
        fields.append(("pop_on_empty", res["rh_pop_on_empty"]))
    if "rh_push_on_full" in res:
        fields.append(("push_on_full", res["rh_push_on_full"]))
    if "pd_push_on_full" in res:
        fields.append(("pd_push_on_full", res["pd_push_on_full"]))
    if "pd_pop_on_empty" in res:
        fields.append(("pd_pop_on_empty", res["pd_pop_on_empty"]))
    if "mismatches" in res:
        fields.append(("mismatches", res["mismatches"]))
    if "delivered" in res:
        fields.append(("delivered", res["delivered"]))
    if "nsamp" in res:
        fields.append(("nsamp", res["nsamp"]))
    tree = MODEL_TREE if prefix.startswith(("m0_", "m20_")) else TREE_FOR_VARIANT[variant]
    fields.append(("tree_sha", sha256_of(tree)))
    key = f"{variant}/{stim}"
    return key, fields


def render_toml(tables):
    lines = []
    for key, fields in tables:
        lines.append(f'[ref."{key}"]')
        for k, v in fields:
            if isinstance(v, str):
                lines.append(f'{k} = "{v}"')
            else:
                lines.append(f'{k} = {v}')
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("prefixes", nargs="+")
    a = ap.parse_args()
    cwd = pathlib.Path(".").resolve()
    tables = [build_table(p, cwd) for p in a.prefixes]
    out = pathlib.Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(render_toml(tables))
    print(f"COLLECT_REFERENCE_DONE {out} rows={len(tables)}")


if __name__ == "__main__":
    main()
