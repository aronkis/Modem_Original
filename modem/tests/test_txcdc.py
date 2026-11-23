#!/usr/bin/env python3
"""test_txcdc.py -- the TX-sample async-FIFO attempt (modem/instruments/txcdc), kept for the record and
SUPERSEDED by modem/instruments/txclk (docs/evidence/sp3/SP3_GATE3_RETEST.md section 9). Pins: the
files and their gates still exist, the Vivado template hook is in place, and build_hdl.sh never ships
the FIFO files. No Vivado here."""
import os, re, unittest

HERE = os.path.dirname(os.path.abspath(__file__)); MODEM = os.path.dirname(HERE)
TXCDC = os.path.join(MODEM, "instruments", "txcdc")


def rd(*p):
    with open(os.path.join(*p)) as f:
        return f.read()


class TxCdcKit(unittest.TestCase):
    def test_kit_files_exist_and_are_executable_where_needed(self):
        for f in ("tx_cdc_fifo.v", "txcdc_bd.tcl", "pre_synth.tcl", "tb_tx_cdc_fifo.sv", "run_tb.sh"):
            self.assertTrue(os.path.exists(os.path.join(TXCDC, f)), f)
        self.assertTrue(os.access(os.path.join(TXCDC, "run_tb.sh"), os.X_OK))

    def test_template_sources_pre_synth_before_generate_target(self):
        t = rd(MODEM, "vivado", "txfix_build.tcl.tmpl")
        i_open, i_hook, i_gen = t.index("open_project vivado_prj.xpr"), t.index("pre_synth.tcl"), t.index("generate_target all")
        self.assertTrue(i_open < i_hook < i_gen)
        self.assertIn("PRE_SYNTH_HOOK_OK", t); self.assertIn("PRE_SYNTH_HOOK_NONE", t)

    def test_build_hdl_never_ships_the_superseded_fifo(self):
        # txcdc was superseded by modem/instruments/txclk (one clock); kits must not carry its files
        b = rd(MODEM, "build_hdl.sh")
        self.assertIn('rm -f "$FRESH/txcdc_bd.tcl" "$FRESH/tx_cdc_fifo.v"', b)
        self.assertNotIn("TXCDC_KIT_OK", b)

    def test_bd_script_gates_and_wiring(self):
        s = rd(TXCDC, "txcdc_bd.tcl")
        for tok in ("TXCDC_WIRE_OK", "TXCDC_VALIDATE_OK", "TXCDC_WIRE_FAILED", "SP3_SKIP_TXCDC",
                    "axi_adrv9001/dac_1_data_i0", "axi_adrv9001/dac_1_data_q0", "axi_adrv9001/dac_1_valid_i0",
                    "TxRxCompo_ip_0/dut_data_out_0_tx", "TxRxCompo_ip_0/dut_data_out_1_tx",
                    "TxRxCompo_ip_0/dut_data_valid_out_tx", "create_bd_cell -type module -reference tx_cdc_fifo_v2"):
            self.assertIn(tok, s, tok)
        self.assertIn("source", rd(TXCDC, "pre_synth.tcl")); self.assertIn("txcdc_bd.tcl", rd(TXCDC, "pre_synth.tcl"))

    def test_fifo_module_is_a_real_async_fifo(self):
        v = rd(TXCDC, "tx_cdc_fifo.v")
        self.assertIn("xpm_fifo_async", v); self.assertIn('.READ_MODE           ("fwft")', v)
        self.assertRegex(v, r"FIFO_WRITE_DEPTH\s*\(64\)"); self.assertIn("PRIME_LEVEL", v)


if __name__ == "__main__":
    unittest.main()
