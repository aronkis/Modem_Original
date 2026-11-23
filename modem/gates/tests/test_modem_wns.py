import pathlib, subprocess, sys
HERE = pathlib.Path(__file__).resolve().parent; FIXES = HERE.parent
sys.path.insert(0, str(FIXES))
import modem_wns

def test_parse_finds_modem_clock_row():
    text = (HERE / "data/timing_summary_excerpt.rpt").read_text()
    rows = modem_wns.parse_intra_clock(text)
    assert "axi_adrv9001_adc_1_clk" in rows
    wns, tns, failing, total = rows["axi_adrv9001_adc_1_clk"]
    assert abs(wns - 0.105) < 0.001 and tns == 0.0 and failing == 0 and total > 100000

def test_cli_exit_codes(tmp_path):
    rpt = HERE / "data/timing_summary_excerpt.rpt"
    ok = subprocess.run([sys.executable, str(FIXES / "modem_wns.py"), str(rpt)], capture_output=True, text=True)
    assert ok.returncode == 0 and ok.stdout.startswith("MODEM_CLK_WNS clock=axi_adrv9001_adc_1_clk wns=0.105")
    strict = subprocess.run([sys.executable, str(FIXES / "modem_wns.py"), str(rpt), "--min", "0.2"], capture_output=True, text=True)
    assert strict.returncode == 1
    missing = subprocess.run([sys.executable, str(FIXES / "modem_wns.py"), str(rpt), "--clock", "no_such_clk"], capture_output=True, text=True)
    assert missing.returncode == 2

def test_blank_wns_row_is_skipped():
    text = (HERE / "data/timing_summary_excerpt.rpt").read_text()
    rows = modem_wns.parse_intra_clock(text)
    assert "spi0_clk" not in rows
    wns, tns, failing, total = rows["axi_adrv9001_adc_1_clk"]
    assert abs(wns - 0.105) < 0.001

def test_missing_report_dir_exit_3(tmp_path):
    missing = subprocess.run([sys.executable, str(FIXES / "modem_wns.py"), str(tmp_path)], capture_output=True, text=True)
    assert missing.returncode == 3
    assert "MODEM_CLK_WNS_NO_REPORT" in missing.stderr
    assert str(tmp_path) in missing.stderr
