"""build_image.sh checks that are easier to express in shell.

Each shell script EXTRACTS the predicate or parser it tests out of the real
modem/build_image.sh (a sed program, a variable, the modem_wns.py invocation)
and exercises it, so what is tested cannot drift from what ships.  This wrapper
keeps them inside the one pytest run that gates the build layer.

sp3 Task 11 moved these from modem/fixes/tests/ (the fix layer is gone: there
is no manifest, no role and no fix chain -- one model regeneration produces one
image) and replaced test_build_image_wnsdrift.sh, whose subject was the sp2
per-role reference-WNS drift gate, with test_build_image_gate2.sh, whose
subject is the absolute Gate 2 floor.

TERMINAL LINES of modem/build_image.sh, documented here because these tests are
what hold them still:
  BUILD_IMAGE_WNS_OK wns=<f> floor=0.005 ref_pad=0.105 ref_sp2A=0.447 ref_sp2B=0.785
  BUILD_IMAGE_DONE tag=<t> image=<path> md5=<32hex> modem_wns=<f>
  BUILD_IMAGE_DRY tag=<t>
  BUILD_IMAGE_NO_ROLE          --role is gone (exit 2)
  BUILD_IMAGE_STAGE_MERGED     `seqbist` is inside `hdl` (exit 2)
  BUILD_IMAGE_BAD_RANGE        --stop-after earlier than --from (exit 2)
  BUILD_IMAGE_NEED_STAGE <s>   the preceding stage is unstamped at this model_tree_sha
  BUILD_IMAGE_DRY_GATES        --dry preview of the gates stage (does NOT exit)
  BUILD_IMAGE_GATES_BUSY       another sp2-gate-* run holds the shared gate tree (exit 2)
  BUILD_IMAGE_GATE2_FAIL       post-route modem WNS below the floor -- a STOP
  BUILD_IMAGE_VIVADO_FAIL      the remote build did not finish
"""
import subprocess, pathlib

HERE = pathlib.Path(__file__).resolve().parent


def _sh(name, marker):
    out = subprocess.run(["bash", str(HERE / name)], capture_output=True, text=True)
    assert out.returncode == 0, out.stdout + out.stderr
    assert marker in out.stdout, out.stdout


def test_build_image_is_syntactically_valid():
    bi = HERE.parent / "build_image.sh"
    assert bi.is_file()
    assert subprocess.run(["bash", "-n", str(bi)]).returncode == 0


def test_build_hdl_skip_seqbist_knob():
    """SP3_SKIP_SEQBIST=1 drops step [5c] -- the discriminating rebuild in
    modem/rxfix/README.md (suspect 2, the SEQ-BIST BD instrument) needs it to
    be expressible; before it, the copy, the `source` line and the hard
    SEQBIST_WIRE_OK gate were all unconditional."""
    _sh("test_build_hdl_skipseqbist.sh", "SKIPSEQBIST_OK")


def test_build_hdl_is_syntactically_valid():
    bh = HERE.parent / "build_hdl.sh"
    assert bh.is_file()
    assert subprocess.run(["bash", "-n", str(bh)]).returncode == 0


def test_unit_name_parse_survives_allow_concurrent():
    """The unit waited on must come from the template's own launch line.

    Also covers the sp3 stamp contract (model_tree_sha) and the defaults
    (--from hdl, --tag sp3, --dry stamping hdl.dry only).
    """
    _sh("test_build_image_unitparse.sh", "UNITPARSE_OK")


def test_stage_range_and_retired_stage_names():
    """--stop-after earlier than --from exits 2; so do --role and `seqbist`."""
    _sh("test_build_image_stoprange.sh", "STOPRANGE_OK")


def test_gate2_floor_is_absolute_and_enforced_by_modem_wns():
    """Gate 2 is wns >= 0.005 via modem_wns.py --min; the sp2 drift gate is gone."""
    _sh("test_build_image_gate2.sh", "GATE2_OK")


def test_dry_is_honoured_by_gates_and_the_concurrency_guard_refuses():
    """--dry must not run the real leg sweep, and gates must refuse a concurrent run.

    Both were review-round-1 findings: `--dry` was honoured by hdl and vivado
    but ignored by gates (so `build_image.sh --dry` would have started the real
    multi-hour Verilator sweep), and the gates stage shares one gate tree
    (`modem/rtl_sim/s1_rtl_model`) and one set of Verilator object directories
    with every other run on the host -- two concurrent runs of the same table
    each scored the other's binaries. The busy guard is exercised with a fake
    `systemctl` on PATH, so both the busy and the idle answer are proved.
    """
    _sh("test_build_image_dry_gates.sh", "DRYGATES_OK")


def test_remote_base_reaches_both_the_build_and_the_fetches():
    """--remote-base must move the remote tree AND every rsync fetch together.

    Runs the real modem/vivado/txfix_build.sh.tmpl --dry path behind a stub ssh
    (nothing remote is touched), asserts build_image.sh has exactly one
    hard-coded remote root, and asserts a *_build_ref kit is refused outright.
    """
    _sh("test_build_image_remotebase.sh", "REMOTEBASE_OK")


def test_complete_byte_bd_is_the_verbatim_prefix_of_complete_byte_t8():
    """modem/common/bd/complete_byte_bd.tcl must stay lines 1-137 of complete_byte_t8.tcl.

    The split is the whole point of the sp3 hdl stage: the BD half runs locally
    (so the regenerated project actually contains TxRxCompo_ip_0 and the ddrcap
    BD instrument can attach to it), the synth/impl/bootgen half runs on the
    Vivado host from modem/vivado/txfix_build.tcl.tmpl. If someone edits one
    file and not the other, the two flows diverge silently.
    """
    bd_dir = HERE.parent / "common" / "bd"
    t8 = (bd_dir / "complete_byte_t8.tcl").read_text().splitlines()
    bd = (bd_dir / "complete_byte_bd.tcl").read_text().splitlines()
    begin = next(i for i, l in enumerate(bd)
                 if l.startswith("# --- BEGIN complete_byte_t8.tcl lines 1-137"))
    assert bd[begin + 1:begin + 1 + 137] == t8[:137]
    # ...and the half that must NOT be here.  CODE lines only: the header
    # comment names the steps it deliberately stops short of.
    code = [l for l in bd if not l.lstrip().startswith("#")]
    body = "\n".join(code)
    for token in ("launch_runs synth_1", "launch_runs impl_1", "bootgen"):
        assert token not in body, f"{token} belongs to the vivado stage, not the hdl stage"
    assert 'puts "COMPLETE_BYTE_BD_DONE"' in body


def test_seqbist_bd_tcl_matches_what_the_patcher_emits():
    """modem/instruments/seqbist/seqbist_bd.tcl is GENERATED -- keep it so.

    patch_seqbist_tcl.py --emit-tcl is the single source of the SEQ-BIST Tcl:
    the kit-patching path and the sp3 hdl stage must run the same block, same
    marker, same OK tokens. A hand edit to the .tcl would silently fork them.
    """
    import sys
    seq = HERE.parent / "instruments" / "seqbist"
    sys.path.insert(0, str(seq))
    import patch_seqbist_tcl as P
    want = P.emit_text("vendh", 1)
    assert (seq / "seqbist_bd.tcl").read_text() == want, (
        "seqbist_bd.tcl is stale: regenerate with\n"
        "  python3 modem/instruments/seqbist/patch_seqbist_tcl.py "
        "--emit-tcl modem/instruments/seqbist/seqbist_bd.tcl --lineage vendh --with-crc 1")
    # the emitted block must carry the marker the patcher's idempotence keys on
    assert P.MARKER in want
    assert "SEQBIST_WIRE_OK lineage=vendh" in want


def test_symbol_rate_path_rows_report_fetch_and_parse():
    """sp4 Task 8: the Vivado template writes system_top_timing_paths_modem.rpt for the
    Symbol_Synchronizer / Carrier_Synchronizer / Viterbi endpoints, build_image.sh fetches it
    beside the timing summaries and prints modem_wns.py --paths rows, and the parser reports
    the worst slack per block from a report_timing text."""
    import sys
    ROOT = HERE.parent.parent   # modem/tests -> repo root
    tmpl = (ROOT / "modem/vivado/txfix_build.tcl.tmpl").read_text()
    assert "system_top_timing_paths_modem.rpt" in tmpl
    assert "*Symbol_Synchronizer*" in tmpl and "*Carrier_Synchronizer*" in tmpl and "*Viterbi*" in tmpl
    assert "MODEM_PATHS_REPORT_OK" in tmpl and "MODEM_PATHS_REPORT_SKIPPED" in tmpl   # non-fatal
    bi = (ROOT / "modem/build_image.sh").read_text()
    assert "--include '*timing_paths_modem*.rpt'" in bi
    assert 'modem_wns.py" "$WORK/impl1_reports_$TAG" --paths' in bi
    sys.path.insert(0, str(ROOT / "modem/gates"))
    import modem_wns
    txt = (
        "Slack (MET) :             0.312ns  (required time - arrival time)\n"
        "  Source:                 top/u_Symbol_Synchronizer/Rate_Handle/x_reg/C\n"
        "  Destination:            top/u_Symbol_Synchronizer/Rate_Handle/y_reg/D\n"
        "Slack (VIOLATED) :        -0.045ns  (required time - arrival time)\n"
        "  Source:                 a/b/c\n"
        "  Destination:            top/u_Viterbi/ACS/reg/D\n"
        "Slack (MET) :             0.100ns\n"
        "  Source:                 q\n"
        "  Destination:            top/u_Viterbi/other/D\n"
        "Slack (MET) :             0.900ns\n"
        "  Source:                 q\n"
        "  Destination:            top/u_Unrelated/D\n"
    )
    rows = modem_wns.parse_timing_paths(txt)
    assert rows["Symbol_Synchronizer"] == (0.312, 1, "top/u_Symbol_Synchronizer/Rate_Handle/y_reg/D")
    assert rows["Viterbi"] == (-0.045, 2, "top/u_Viterbi/ACS/reg/D")
    assert "Carrier_Synchronizer" not in rows
    d = pathlib.Path(subprocess.run(["mktemp", "-d"], capture_output=True, text=True).stdout.strip())
    (d / "system_top_timing_paths_modem.rpt").write_text(txt)
    out = subprocess.run([sys.executable, str(ROOT / "modem/gates/modem_wns.py"), str(d), "--paths"],
                         capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    assert "MODEM_PATHS block=Viterbi worst_slack=-0.045 n=2" in out.stdout
