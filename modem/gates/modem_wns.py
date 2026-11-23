#!/usr/bin/env python3
"""modem_wns.py -- the authoritative post-route timing gate.

Parses the "Intra Clock Table" of a Vivado `report_timing_summary` report
(`system_top_timing_summary_*.rpt`) and prints the WNS/TNS/failing/total
row for one clock (default: `axi_adrv9001_adc_1_clk`, the modem clock).

Which report is authoritative
------------------------------
Vivado's impl_1 run directory carries (at least) two timing summary
reports that both cover the routed design:

  * `system_top_timing_summary_routed.rpt`             -- written right
    after `route_design`, before post-route physical optimization.
  * `system_top_timing_summary_postroute_physopted.rpt` -- written after
    `phys_opt_design -post_route`, i.e. the timing of the netlist that
    actually gets bitstream-generated and flashed.

The postroute_physopted report reflects the final, as-built netlist, so
it is authoritative here -- `<impl_1_dir>` mode prefers
`*_postroute_physopted.rpt` and falls back to `*_routed.rpt` only if the
physopted report is missing from that directory.

For both banked 148 (rxfixpad) and 146 (rxfixr4dr1) reference kits the
two reports happen to agree on `axi_adrv9001_adc_1_clk` (148: wns=0.105
in both; 146: wns=0.620 in both) -- phys_opt_design found nothing to
improve on this path after routing -- so the choice is not load-bearing
for those two builds, but it is the rule this script follows going
forward.

Exit codes
----------
  0 -- gate row found, wns >= --min
  1 -- gate row found, wns < --min
  2 -- clock row not present in the report's Intra Clock Table
  3 -- no timing report found at the given path (a directory with
       neither `*postroute_physopted.rpt` nor `*timing_summary_routed.rpt`,
       or a file/directory that does not exist); prints
       `MODEM_CLK_WNS_NO_REPORT <path>` to stderr
"""
import argparse
import re
import pathlib
import sys

CLOCK_HEADER_PREFIX = "Clock"
INTRA_TABLE_MARKER = "Intra Clock Table"


class NoReportFound(Exception):
    """Raised when `_resolve_report_path` can't find a timing report at
    the given file or directory path. Mapped to exit code 3 in main()."""


def parse_intra_clock(text):
    """Parse the Intra Clock Table of a Vivado timing summary report.

    Returns dict[clock_name] = (wns, tns, failing, total).
    """
    lines = text.splitlines()
    rows = {}

    # Find the Intra Clock Table marker.
    start = None
    for i, line in enumerate(lines):
        if INTRA_TABLE_MARKER in line:
            start = i
            break
    if start is None:
        return rows

    # Find the header row (starts with "Clock" and contains "WNS(ns)").
    header_idx = None
    for i in range(start, len(lines)):
        line = lines[i]
        stripped = line.strip()
        if stripped.startswith(CLOCK_HEADER_PREFIX) and "WNS(ns)" in line:
            header_idx = i
            break
    if header_idx is None:
        return rows

    # This is a fixed-width table: the "WNS(ns)" header label's character
    # span lines up with the WNS value's character span in every data row
    # (both are right-justified within the same column). A row whose WNS
    # column is blank there (Vivado leaves it blank -- not "NA" -- for a
    # clock like spi0_clk that has no constrained setup paths) must be
    # skipped by column position: a naive whitespace-split would instead
    # slide the next populated column (WPWS) into the WNS slot and report
    # a fabricated (and misleadingly large, passing) WNS for that clock.
    header_line = lines[header_idx]
    wns_start = header_line.index("WNS(ns)")
    wns_end = wns_start + len("WNS(ns)")

    # Data rows follow the header and a dashed separator line; stop at the
    # first blank line after data rows begin.
    i = header_idx + 1
    seen_data = False
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if not stripped:
            if seen_data:
                break
            i += 1
            continue
        # Skip the dashed separator row under the header.
        if set(stripped) <= {"-", " "}:
            i += 1
            continue
        parts = stripped.split()
        if "NA" in parts:
            i += 1
            continue
        # Blank WNS column (e.g. spi0_clk, which has only WPWS data): no
        # constrained setup paths for this clock, skip it like an NA row.
        if not line[wns_start:wns_end].strip():
            i += 1
            continue
        clock = parts[0]
        try:
            wns = float(parts[1])
            tns = float(parts[2])
            failing = int(parts[3])
            total = int(parts[4])
        except (IndexError, ValueError):
            i += 1
            continue
        rows[clock] = (wns, tns, failing, total)
        seen_data = True
        i += 1

    return rows


def _resolve_report_path(path):
    """Given a file or an impl_1-style directory, return the report file
    to parse. Directory mode prefers *_postroute_physopted.rpt, falling
    back to *_routed.rpt (see module docstring for why)."""
    p = pathlib.Path(path)
    if p.is_file():
        return p
    if p.is_dir():
        physopted = sorted(p.glob("*postroute_physopted.rpt"))
        if physopted:
            return physopted[0]
        routed = sorted(p.glob("*timing_summary_routed.rpt"))
        if routed:
            return routed[0]
        raise NoReportFound(
            "no *postroute_physopted.rpt or *timing_summary_routed.rpt found in %s" % p
        )
    raise NoReportFound("no such file or directory: %s" % p)


PATH_BLOCKS = ("Symbol_Synchronizer", "Carrier_Synchronizer", "Viterbi")


def parse_timing_paths(text, blocks=PATH_BLOCKS):
    """Parse a `report_timing` text (one 'Slack (MET|VIOLATED) : x ns' header per path followed
    by 'Source:' / 'Destination:' lines) into {block: (worst_slack_ns, n_paths, worst_endpoint)}
    for the endpoints whose Destination cell name contains one of `blocks` (sp4 Task 8: the
    symbol-rate loop and the Viterbi decoder get their own rows beside the clock's WNS)."""
    out = {}
    slack_re = re.compile(r"^Slack \((?:MET|VIOLATED)\)\s*:\s*(-?[0-9.]+)\s*ns", re.M)
    dest_re = re.compile(r"^\s*Destination:\s*(\S+)", re.M)
    heads = [(m.start(), float(m.group(1))) for m in slack_re.finditer(text)]
    for i, (pos, slack) in enumerate(heads):
        end = heads[i + 1][0] if i + 1 < len(heads) else len(text)
        dm = dest_re.search(text, pos, end)
        if not dm:
            continue
        dest = dm.group(1)
        for b in blocks:
            if b in dest:
                worst, n, ep = out.get(b, (None, 0, ""))
                if worst is None or slack < worst:
                    worst, ep = slack, dest
                out[b] = (worst, n + 1, ep)
                break
    return out


def _resolve_paths_report(path):
    p = pathlib.Path(path)
    if p.is_dir():
        cands = sorted(p.glob("*timing_paths_modem*.rpt"))
        if not cands:
            raise NoReportFound(path)
        return cands[-1]
    if p.is_file():
        return p
    raise NoReportFound(path)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("report", help="timing_summary_*.rpt file, or an impl_1 report directory")
    ap.add_argument("--clock", default="axi_adrv9001_adc_1_clk", help="clock row to gate on")
    ap.add_argument("--min", dest="min_wns", type=float, default=0.0, help="minimum acceptable WNS (ns)")
    ap.add_argument("--paths", action="store_true",
                    help="print MODEM_PATHS rows (worst slack per symbol-rate block) from the "
                         "system_top_timing_paths_modem.rpt report instead of the clock gate")
    args = ap.parse_args(argv)

    if args.paths:
        try:
            rp = _resolve_paths_report(args.report)
        except NoReportFound:
            print("MODEM_PATHS_NO_REPORT %s" % args.report, file=sys.stderr)
            return 3
        rows = parse_timing_paths(rp.read_text())
        if not rows:
            print("MODEM_PATHS none of %s found in %s" % ("/".join(PATH_BLOCKS), rp.name))
            return 0
        for b in PATH_BLOCKS:
            if b in rows:
                worst, n, ep = rows[b]
                print("MODEM_PATHS block=%s worst_slack=%.3f n=%d endpoint=%s" % (b, worst, n, ep))
        return 0

    try:
        report_path = _resolve_report_path(args.report)
    except NoReportFound:
        print("MODEM_CLK_WNS_NO_REPORT %s" % args.report, file=sys.stderr)
        return 3
    text = report_path.read_text()
    rows = parse_intra_clock(text)

    if args.clock not in rows:
        print("MODEM_CLK_WNS clock=%s NOT_FOUND" % args.clock)
        return 2

    wns, tns, failing, total = rows[args.clock]
    print(
        "MODEM_CLK_WNS clock=%s wns=%s tns=%s failing=%d total=%d"
        % (args.clock, wns, tns, failing, total)
    )
    return 0 if wns >= args.min_wns else 1


if __name__ == "__main__":
    sys.exit(main())
