#!/usr/bin/env python3
"""test_txclk.py -- the one-clock fix (modem/instruments/txclk): axi_adrv9001 USE_RX_CLK_FOR_TX1=1 set
through the kit-root pre_synth.tcl hook, copied by build_hdl.sh step [6] (SP3_SKIP_TXCLK=1 leaves it
out), with the reference-design nets restored and hard gates. docs/evidence/sp3/SP3_GATE3_RETEST.md
section 9. No Vivado here."""
import os, unittest

HERE = os.path.dirname(os.path.abspath(__file__)); MODEM = os.path.dirname(HERE)
TXCLK = os.path.join(MODEM, "instruments", "txclk")


def rd(*p):
    with open(os.path.join(*p)) as f:
        return f.read()


class TxClk(unittest.TestCase):
    def test_kit_files_exist(self):
        for f in ("txclk_bd.tcl", "pre_synth.tcl", "README.md"):
            self.assertTrue(os.path.exists(os.path.join(TXCLK, f)), f)
        self.assertIn("txclk_bd.tcl", rd(TXCLK, "pre_synth.tcl"))

    def test_bd_script_sets_the_parameter_restores_the_nets_and_gates(self):
        s = rd(TXCLK, "txclk_bd.tcl")
        for tok in ("set_property CONFIG.USE_RX_CLK_FOR_TX1 {1} [get_bd_cells axi_adrv9001]",
                    "TXCLK_PARAM_OK", "TXCLK_WIRE_OK", "TXCLK_VALIDATE_OK", "TXCLK_WIRE_FAILED", "SP3_SKIP_TXCLK",
                    "sync_output/data_out_tx_0        axi_adrv9001/dac_1_data_i0",
                    "sync_output/data_out_tx_1        axi_adrv9001/dac_1_data_q0",
                    "sync_input/data_valid_out_tx_0   TxRxCompo_ip_0/dut_data_valid_in_tx",
                    "delete_bd_objs [get_bd_cells tx_cdc]"):
            self.assertIn(tok, s, tok)

    def test_build_hdl_copies_the_hook_and_honours_the_skip_knob(self):
        b = rd(MODEM, "build_hdl.sh")
        self.assertIn("modem/instruments/txclk/$f", b); self.assertIn("TXCLK_KIT_OK", b); self.assertIn("SP3_SKIP_TXCLK", b)

    def test_templates_source_pre_synth_before_generate_target(self):
        for tmpl in ("txfix_build.tcl.tmpl", "txfix_build_vendh.tcl.tmpl"):
            t = rd(MODEM, "vivado", tmpl)
            self.assertTrue(t.index("open_project vivado_prj.xpr") < t.index("pre_synth.tcl") < t.index("generate_target all [get_files"), tmpl)


if __name__ == "__main__":
    unittest.main()
