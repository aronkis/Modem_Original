#!/usr/bin/env python3
"""score_leg.py <capture-dir> -- the per-leg health line from a capture's frames.bin (sp4 Task 12):
records, span, delivered rate, crc_ok %, carrier resets / s (0x150 delta), CFC median and IQR (0x154,
sign-extended), detected f/s (0x104 delta), WEDGED if meta.txt says so. Complements accept_analyze.py
(PER) with the telemetry that separates a CFO dead-zone collapse (CFC median near zero, IQR straddling
it, resets) from a decode-margin floor (CFC locked, resets and CRC failures persist)."""
import sys, os, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from frame_taxonomy import read_frames
d = sys.argv[1]; f = os.path.join(d, "frames.bin")
if not os.path.exists(f) or os.path.getsize(f) < 48*100:
    print(f"{os.path.basename(d)}: NO frames.bin"); sys.exit(0)
fr = read_frames(f)
# PLAUSIBILITY (2026-09-25, plan Task 7): 48-byte records parse out of ANY file, so a scorer that
# trusts its input will happily report a confident rate and CRC share for something that is not a
# frames.bin at all -- the exact failure that let Tap-A telemetry be read as a dead DMA for five
# weeks. Check the invariants a real log has and say UNKNOWN instead of guessing.
_t = fr["t_mono_ns"].astype(np.int64)
_ok = fr["crc_ok"].astype(np.int64)
_why = []
if fr.size < 100:
    _why.append(f"only {fr.size} records")
if np.any(np.diff(_t) < 0):
    _why.append("t_mono_ns not monotonic")
if not np.all(np.isin(_ok, (0, 1))):
    _why.append("crc_ok is not 0/1")
if fr.size >= 2 and _t[-1] == _t[0]:
    _why.append("zero time span")
if _why:
    print(f"{os.path.basename(d)}: UNKNOWN -- not a plausible frames.bin ({'; '.join(_why)})")
    sys.exit(0)
t = (_t - int(_t[0]))/1e9
span = max(t[-1], 1e-9)
ok = fr["crc_ok"] == 1
cfc = fr["reg_cfc"].astype(np.int64); cfc[cfc > 2**31] -= 2**32
rst = fr["reg_rstcs"].astype(np.int64); pk = fr["reg_packets"].astype(np.int64)
q1, q3 = np.percentile(cfc, [25, 75])
wedge = ""
m = os.path.join(d, "meta.txt")
if os.path.exists(m):
    for l in open(m):
        if l.startswith("wedge_verdict=") and "WEDGE" in l: wedge = " WEDGED"
print(f"{os.path.basename(d)}: n={fr.size} span={span:.0f}s rate={fr.size/span:.0f}/s crc_ok={ok.mean()*100:.2f}% "
      f"rstcs/s={(rst.max()-rst.min())/span:.0f} cfc_med={int(np.median(cfc))} cfc_iqr=[{int(q1)},{int(q3)}] "
      f"detected/s={(pk.max()-pk.min())/span:.0f}{wedge}")
