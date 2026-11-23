"""The sps=2 / f3072 rung is a frame_config_k5 preset (sp4 plan Task 2).

Drives MATLAB in batch (the test_assemble_phases.py pattern is text-only; this
one needs the real functions) from modem/common/model, where the shared .m live
-- they are NOT on the path outside a kit, so cwd is the path. Pins the Task 1
contract numbers at the single source and the parameter derivations that hang
off them (RRC 0.25/8 at 2 sps, 26-symbol preamble, SearchSamples = slots), and
that the deployed f1536 / sps 4 rung still loads unchanged (decision A, 09-18:
the banked one-way images stay rebuildable).
"""
import os
import shutil
import subprocess
import unittest

MODEM = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL = os.path.join(MODEM, "common", "model")   # shared .m; not on the path outside a kit
MATLAB = shutil.which("matlab") or "/mnt/onetb/MATLAB/R2025b/bin/matlab"
CMD = ("cfg=frame_config_k5(); P=commhdlQPSKTxRxParameters(); "
       "fprintf('F %s %d %d %d %d %d %d %d\\n', cfg.Frame, cfg.Sps, cfg.InfoBits, cfg.PayloadBits, "
       "cfg.WordsPerPacketRx, cfg.RomWords32, cfg.PreambleSyms, cfg.SlotsPerFrame); "
       "fprintf('P %d %d %d %d %.3f %g %g\\n', P.SearchSamples, P.txDataRAMAddrWidth, numel(P.RRCCoef), "
       "numel(P.rxPreambleMFCoeffs), abs(P.rxPreambleMFCoeffs(1)), P.RRCFilterSpanInSymbols, P.RRCRolloff)")


def _run(frame, sps):
    env = dict(os.environ, QPSK_FRAME=frame, QPSK_SPS=sps)
    r = subprocess.run([MATLAB, "-batch", CMD], cwd=MODEL, env=env,
                       capture_output=True, text=True, timeout=900)
    return r.stdout + r.stderr


@unittest.skipUnless(os.path.exists(MATLAB), "MATLAB not installed")
class FrameConfigF3072(unittest.TestCase):
    def test_sps2_f3072(self):
        out = _run("f3072", "2")
        self.assertIn("F f3072 2 24580 49216 382 1538 26 24634", out)
        self.assertIn("P 24634 17 17 26 0.038 8 0.25", out)

    def test_sps4_f1536_still_loads(self):
        out = _run("f1536", "4")
        self.assertIn("F f1536 4 12292 24640 191 770 13 12333", out)
        self.assertIn("P 12333 16 17 13 0.077 4 0.5", out)

    def test_sps2_needs_f3072(self):
        """sps 2 with the 13-symbol preamble would halve the correlator length;
        the pairing gate lives at the single source."""
        out = _run("f1536", "2")
        self.assertNotIn("F f1536 2", out)
        self.assertIn("f3072", out)   # the error names the rung it wants


if __name__ == "__main__":
    unittest.main()
