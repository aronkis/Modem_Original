#!/usr/bin/env python3
"""geometry_gen.py -- render modem/rtl_sim/geometry.h and sro_score/geometry.py for ONE rate rung.

    geometry_gen.py --rung r4|r3 [--check] [--out DIR]

The simulation harness (Verilator drivers, scorers, stimulus generator, leg tables) takes its
air-frame geometry from the two generated twins. Since the sp4 rung (2026-09-18) they were pinned
to f3072 and the chain could no longer gate an f1536 image (2026-09-30: every T7 row read LOSS=100 %
on the shipped rung because sim_sro.cpp parsed 1528-byte frames as 3056-byte ones). Both rungs now
live in RUNGS below -- the f3072 numbers from contract/PACKET_F3072.txt / frame_config_k5.m 'f3072',
the f1536 ones from frame_config_k5.m 'f1536' and the harness as it stood at ae2996bd -- and the
committed geometry.h / geometry.py are the r4 render (test: `--rung r4 --check` is byte-identical).

    r4 (sp4, f3072, 2 sps): 24634 slots, 49268 samples, 382 words, 3056 B, steering lead SLOTS-100 / tref off 226
    r3 (sp3, f1536, 4 sps): 12333 slots, 49332 samples, 191 words, 1528 B, steering lead 0 / tref off 0

run_gates.sh --rung renders the rung before building the gate objects and restores the r4 render
on exit; build_image.sh passes the rung it regenerated at.
"""
import argparse
import os
import sys

RUNGS = {
    "r4": dict(frame="f3072", SPS=2, SLOTS=24634, DATA_SYMS=24608, PREAMBLE_SYMS=26, PAYLOAD_BITS=49216, WPP=382,
               DDRCAP2_WIDE=1, STEER_LEAD=24534, STEER_TREF_OFF=226, other="f1536"),
    "r3": dict(frame="f1536", SPS=4, SLOTS=12333, DATA_SYMS=12320, PREAMBLE_SYMS=13, PAYLOAD_BITS=24640, WPP=191,
               DDRCAP2_WIDE=0, STEER_LEAD=0, STEER_TREF_OFF=0, other="f3072"),
}
RUNGS["r2"] = dict(RUNGS["r3"])          # r2 = the same f1536 frame at a 30.72 MSPS rail
FRAME_TO_RUNG = {"f3072": "r4", "f1536": "r3"}


def derived(g):
    d = dict(g)
    d["FRSAMP"] = g["SLOTS"] * g["SPS"]
    d["PKT_BYTES"] = g["WPP"] * 8
    d["MAX_FILL"] = d["PKT_BYTES"] - 12
    d["STROBE_INTERVAL"] = g["SPS"]
    d["S1B_FRAME_CLKS"] = g["SLOTS"] * 2 * g["SPS"] * 2
    return d


def _o(rung, key):
    """the OTHER rung's value, for the trailing comment"""
    o = RUNGS["r3" if rung == "r4" else "r4"]
    return derived(o)[key]


def render_h(rung):
    g = derived(RUNGS[rung]); o = lambda k: _o(rung, k)
    name = "sp4 rung (2 sps, f3072): contract/PACKET_F3072.txt, frame_config_k5.m 'f3072'." if rung == "r4" \
        else "sp3 rung (4 sps, f1536): frame_config_k5.m 'f1536' (the shipped rung)."
    other = g["other"]
    lines = [
        "// geometry.h -- the ONE place the live simulation benches take the air-frame geometry from.",
        f"// {name}",
        f"// The {'sps-4 / f1536' if rung == 'r4' else 'sps-2 / f3072'} values are in the comments for the studies that were written against them.",
        "#ifndef QPSK_GEOMETRY_H",
        "#define QPSK_GEOMETRY_H",
        f"#define GEOM_SPS            {g['SPS']}       /* samples per symbol at the rail            ({other}: {o('SPS')})      */",
        f"#define GEOM_SLOTS          {g['SLOTS']}   /* symbol slots per air frame (Peak_Search.timing_Reference modulus) ({other}: {o('SLOTS')}) */",
        f"#define GEOM_DATA_SYMS      {g['DATA_SYMS']}   /* payload symbols per frame                 ({other}: {o('DATA_SYMS')})  */",
        f"#define GEOM_PREAMBLE_SYMS  {g['PREAMBLE_SYMS']}      /* Barker-13 twice                           ({other}: {o('PREAMBLE_SYMS')})     */",
        f"#define GEOM_FRSAMP         {g['FRSAMP']}L  /* rail samples per air frame = SLOTS*SPS    ({other}: {o('FRSAMP')})  */",
        f"#define GEOM_PAYLOAD_BITS   {g['PAYLOAD_BITS']}   /* Data Bits FIFO pops per frame             ({other}: {o('PAYLOAD_BITS')})  */",
        f"#define GEOM_WPP            {g['WPP']}     /* delivered 64-bit words per frame          ({other}: {o('WPP')})    */",
        f"#define GEOM_PKT_BYTES      {g['PKT_BYTES']}    /* host frame bytes = WPP*8                  ({other}: {o('PKT_BYTES')})   */",
        f"#define GEOM_MAX_FILL       {g['MAX_FILL']}    /* payload bytes after the 12-byte header    ({other}: {o('MAX_FILL')})   */",
        f"#define GEOM_STROBE_INTERVAL {g['STROBE_INTERVAL']}      /* Rate_Handle validIn beats between symbol pushes = SPS ({other}: {o('STROBE_INTERVAL')}) */",
        f"#define GEOM_S1B_FRAME_CLKS {g['S1B_FRAME_CLKS']}L /* S1B bench clocks per frame = SLOTS*2*SPS*2 ({other}: {o('S1B_FRAME_CLKS')}) */",
        f"#define GEOM_DDRCAP2_WIDE   {g['DDRCAP2_WIDE']}       /* DDRCAP-v2 15-bit record layout (ddrcap2_inject.py header) ({other}: {o('DDRCAP2_WIDE')}) */",
        f"#define GEOM_STEER_LEAD     {g['STEER_LEAD']}   /* steering window opens SLOTS-100 nominal pops after pcEnd ({other}: {o('STEER_LEAD')}) */",
        f"#define GEOM_STEER_TREF_OFF {g['STEER_TREF_OFF']}     /* skip position before the tref epoch boundary at sps 2 ({other}: {o('STEER_TREF_OFF')}) */",
        "#endif",
    ]
    return "\n".join(lines) + "\n"


def render_py(rung):
    g = derived(RUNGS[rung]); o = lambda k: _o(rung, k); other = g["other"]
    name = "sp4 rung (2 sps, f3072): contract/PACKET_F3072.txt, frame_config_k5.m 'f3072'." if rung == "r4" \
        else "sp3 rung (4 sps, f1536): frame_config_k5.m 'f1536' (the shipped rung)."
    lead = "SLOTS - 100" if rung == "r4" else "0"
    return f'''"""geometry.py -- the ONE place the live scorers / stimulus generator take the air-frame geometry from.
{name} Twin of ../geometry.h;
modem/tests/test_sim_geometry.py keeps the two in step. ({other} values in the comments.)"""
SPS = {g['SPS']}              # ({other}: {o('SPS')})
SLOTS = {g['SLOTS']}        # symbols per air frame = Peak_Search.timing_Reference modulus ({other}: {o('SLOTS')})
DATA_SYMS = {g['DATA_SYMS']}    # ({other}: {o('DATA_SYMS')})
PREAMBLE_SYMS = {g['PREAMBLE_SYMS']}   # ({other}: {o('PREAMBLE_SYMS')})
FRSAMP = SLOTS * SPS # rail samples per air frame = {g['FRSAMP']} ({other}: {o('FRSAMP')})
PAYLOAD_BITS = {g['PAYLOAD_BITS']} # Data Bits FIFO pops per frame ({other}: {o('PAYLOAD_BITS')})
WPP = {g['WPP']}            # delivered 64-bit words per frame ({other}: {o('WPP')})
PKT_BYTES = WPP * 8  # {g['PKT_BYTES']} ({other}: {o('PKT_BYTES')})
MAX_FILL = PKT_BYTES - 12  # {g['MAX_FILL']} ({other}: {o('MAX_FILL')})
# Rate Handle steering window (rxfix_steer_overlay.m): at sps 2 the 13-slot skip/extra window opens
# STEER_LEAD nominal pops after pcEnd (= 100 pops before the next pcEnd) so the dropped/held symbol
# lands in the filler+preamble of the frame entering the ring; the skips then sit STEER_TREF_OFF
# symbols before the air-frame (tref) epoch boundary (measured, Gate 1 run 3). f1536: 0 and 0.
STEER_LEAD = {lead}   # {g['STEER_LEAD']} ({other}: {o('STEER_LEAD')})
STEER_TREF_OFF = {g['STEER_TREF_OFF']}       # ({other}: {o('STEER_TREF_OFF')}{' -- skips within TREF_TOL of the boundary' if rung == 'r4' else ''})
'''


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rung", required=True, choices=sorted(RUNGS))
    ap.add_argument("--out", default=os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--check", action="store_true", help="compare only; exit 1 if the files differ from the render")
    a = ap.parse_args(argv)
    targets = {os.path.join(a.out, "geometry.h"): render_h(a.rung),
               os.path.join(a.out, "sro_score", "geometry.py"): render_py(a.rung)}
    rc = 0
    for path, text in targets.items():
        have = open(path).read() if os.path.exists(path) else None
        if a.check:
            if have != text:
                print(f"GEOMETRY_DIFFERS {path} (rung {a.rung})"); rc = 1
            else:
                print(f"GEOMETRY_OK {path} (rung {a.rung})")
        elif have != text:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, "w").write(text); print(f"GEOMETRY_WROTE {path} (rung {a.rung})")
        else:
            print(f"GEOMETRY_UNCHANGED {path} (rung {a.rung})")
    g = derived(RUNGS[a.rung])
    print(f"GEOMETRY rung={a.rung} frame={g['frame']} SPS={g['SPS']} SLOTS={g['SLOTS']} FRSAMP={g['FRSAMP']} WPP={g['WPP']} PKT_BYTES={g['PKT_BYTES']}")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
