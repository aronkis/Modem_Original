# Receiver in-band tilt corrector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put a host-steered three-stage complex one-pole tilt corrector in front of the receiver AGC, prove it in the gates and on recorded live IQ, and ship it as a new sp3 image.

**Architecture:** A dev-model overlay (`tilt_eq_overlay.m`) inserts a `TiltEq` MATLAB Function block between the `QPSK Rx` input and `Automatic Gain Control`, fed by two uint32 AXI4-Lite write registers (0x260 `tilt_eq_a12`, 0x264 `tilt_eq_a3en`) threaded down like the loop-gain registers; a = 0 / enable = 0 is an exact pass-through. The Verilator harness drives the two new DUT ports from env knobs; `perturb_score.py` gains a tilt-budget verdict; a new legs file gates identity, tilt rows and the recorded 46 %/2.4 % days. The host side is `ops/tilt_eq_solve.py` (tilt dB → a_k, the sim driver's bisection) and `ops/tilt_eq.sh` (measure → solve → write → verify), hooked into bring-up behind `QPSK_TILT_EQ=1`.

**Tech Stack:** MATLAB R2025b + HDL Coder (regen on nemo), Verilator 5 harness (`modem/rtl_sim`), Vivado 2025.1 on hdl-dev-2 (`build_image.sh` remote vivado), bash + python3 (`ops/`), pytest.

**Spec:** `docs/superpowers/specs/2026-10-03-rx-tilt-equaliser-design.md`

## Global Constraints

- Data path sfix16_En14 complex at the AGC input; coefficient sfix16_En15 with |a| ≤ 0.95 enforced in the decode; state sfix18_En14; 3 stages; a_k = 0 bypasses exactly (spec §3).
- Registers 0x260 `{a2[31:16] a1[15:0]}` and 0x264 `{en[31] 15'b0 a3[15:0]}`; cleared by the 0x000 soft reset like 0x208, re-applied by bring-up (spec §3, §4).
- Gate 1 identity: a = 0 decode bit-identical to the shipped sp3clamp004 tree (spec §5). Tilt rows: 112/112 syncs, |bias| < 30, noise < 200 at −8/−12/−16/+10 dB with the inverse set, and still ≤ 6 dB residual with a_k mis-set by 20 % (spec §5).
- Gate 2: intra-clock WNS gate row ≥ current (`modem_wns.py --min 0.005`); Gate 3 pair on silicon (spec §5).
- Repo rules: `git commit -s` + push, PR merged on the local gates (`tools/check_paths.sh` after `git add`, `gen_regmap.py --check`, `sphinx-build -W`); no symlinks; prod `.slx` is derived, never hand-edited; long jobs under `ops/launch_rig_unit.sh`; never edit a script a live unit runs; every PER claim states command, sample count, lost-in-denominator.

---

### Task 1: Host solver `ops/tilt_eq_solve.py` (pure python, TDD)

**Files:**
- Create: `ops/tilt_eq_solve.py`
- Test: `ops/tests/test_tilt_eq_solve.py`

**Interfaces:**
- Produces: `stages_for(tilt_db: float) -> int` (1 if |t| ≤ 7, 2 if ≤ 14, else 3); `solve_a(tilt_db: float, fs=61.44e6, f_edge=8e6) -> list[float]` (3 coefficients, a_k for the *corrector* = opposite sign of the channel, unused stages 0.0, each clamped to ±0.95); `to_regs(a: list[float]) -> tuple[int, int]` (0x260 word, 0x264 word with enable set when any a ≠ 0); `from_regs(w260, w264) -> list[float]`; `encode(a: float) -> int` sfix16_En15 two's complement in 16 bits.
- CLI: `python3 ops/tilt_eq_solve.py <tilt_db>` prints `a1 a2 a3 0x260=0x... 0x264=0x...`.

- [ ] **Step 1: Write the failing test**

```python
# ops/tests/test_tilt_eq_solve.py
import math, subprocess, sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import tilt_eq_solve as T

def _stage_tilt(a, fs=61.44e6, f=8e6):
    s = math.sin(2 * math.pi * f / fs)
    return 10 * math.log10((1 + a * a + 2 * a * s) / (1 + a * a - 2 * a * s))

def test_stage_count_matches_sim_driver():
    assert T.stages_for(4) == 1 and T.stages_for(-7) == 1 and T.stages_for(-8) == 2 and T.stages_for(14) == 2 and T.stages_for(-16) == 3

def test_corrector_cancels_the_channel_sign_and_magnitude():
    for t in (-4.0, -6.0, -8.0, -12.0, -16.0, 10.0):
        a = T.solve_a(t)
        k = T.stages_for(t)
        assert all(x == 0.0 for x in a[k:]) and all(x != 0.0 for x in a[:k])
        # the corrector stages are the channel's inverse: their own tilt is -t (within 0.05 dB)
        own = sum(_stage_tilt(x) for x in a[:k])
        assert abs(own + t) < 0.05, (t, a, own)

def test_zero_is_bypass_and_clamp_holds():
    assert T.solve_a(0.0) == [0.0, 0.0, 0.0]
    assert T.to_regs([0.0, 0.0, 0.0]) == (0, 0)
    a = T.solve_a(-40.0)
    assert all(abs(x) <= 0.95 + 1e-12 for x in a)

def test_register_pack_roundtrip():
    a = T.solve_a(-12.0)
    w260, w264 = T.to_regs(a)
    assert (w264 >> 31) & 1 == 1
    back = T.from_regs(w260, w264)
    assert all(abs(x - y) < 2 ** -15 + 1e-12 for x, y in zip(a, back))
    assert T.encode(-0.5) == 0xC000 and T.encode(0.5) == 0x4000

def test_cli_prints_regs():
    out = subprocess.run([sys.executable, T.__file__, "-8"], capture_output=True, text=True, check=True).stdout
    assert "0x260=0x" in out and "0x264=0x8" in out
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 -m pytest -q ops/tests/test_tilt_eq_solve.py`
Expected: FAIL with `ModuleNotFoundError: tilt_eq_solve`

- [ ] **Step 3: Write the solver**

```python
#!/usr/bin/env python3
"""tilt_eq_solve.py -- in-band tilt (dB across +-8 MHz) -> the three TiltEq corrector coefficients and the
0x260/0x264 register words. Same stage model and bisection as modem/rtl_sim/sim_sro_perturb.cpp PERT_TILT_DB:
one stage y = x + a*j*x[n-1] has |H|^2 = 1 + a^2 + 2a sin(2 pi f/FS); the CORRECTOR is the inverse one-pole
y[n] = x[n] - a*j*y[n-1] with the SAME a as the channel stage it cancels, so the sign passed to the fabric is the
channel's sign (the fabric implements the inverse). Spec: docs/superpowers/specs/2026-10-03-rx-tilt-equaliser-design.md
"""
import math, sys
FS = 61.44e6; F_EDGE = 8e6; A_MAX = 0.95; FRAC = 15

def stages_for(tilt_db):
    t = abs(tilt_db)
    return 3 if t > 14.0 else 2 if t > 7.0 else 1

def _stage_tilt(a, fs=FS, f_edge=F_EDGE):
    s = math.sin(2 * math.pi * f_edge / fs)
    return 10 * math.log10((1 + a * a + 2 * a * s) / (1 + a * a - 2 * a * s))

def solve_a(tilt_db, fs=FS, f_edge=F_EDGE):
    if tilt_db == 0.0:
        return [0.0, 0.0, 0.0]
    k = stages_for(tilt_db); want = abs(tilt_db) / k
    lo, hi = 0.0, 0.999
    for _ in range(60):
        a = 0.5 * (lo + hi)
        if _stage_tilt(a, fs, f_edge) < want: lo = a
        else: hi = a
    a = min(0.5 * (lo + hi), A_MAX)
    a = a if tilt_db > 0 else -a
    return [a] * k + [0.0] * (3 - k)

def encode(a):
    q = int(round(a * (1 << FRAC)))
    q = max(-(1 << 15), min((1 << 15) - 1, q))
    return q & 0xFFFF

def decode(w):
    w &= 0xFFFF
    return (w - (1 << 16) if w & 0x8000 else w) / (1 << FRAC)

def to_regs(a):
    a1, a2, a3 = a
    en = 1 if any(x != 0.0 for x in a) else 0
    return (encode(a2) << 16) | encode(a1), (en << 31) | encode(a3)

def from_regs(w260, w264):
    return [decode(w260), decode(w260 >> 16), decode(w264)]

def main(argv):
    t = float(argv[1]); a = solve_a(t); w260, w264 = to_regs(a)
    print(f"tilt_db={t:+.2f} stages={stages_for(t)} a1={a[0]:+.5f} a2={a[1]:+.5f} a3={a[2]:+.5f} 0x260=0x{w260:08X} 0x264=0x{w264:08X}")

if __name__ == "__main__":
    main(sys.argv)
```

- [ ] **Step 4: Run the tests**

Run: `python3 -m pytest -q ops/tests/test_tilt_eq_solve.py`
Expected: 5 passed

- [ ] **Step 5: Commit**

```bash
git add ops/tilt_eq_solve.py ops/tests/test_tilt_eq_solve.py && tools/check_paths.sh
git commit -s -m "tilt_eq_solve.py: in-band tilt -> TiltEq corrector coefficients and 0x260/0x264 words (same stage model as PERT_TILT_DB)"
```

### Task 2: Regmap rows for 0x260/0x264

**Files:**
- Modify: `modem/regmap/regmap.toml` (append a `[fixes.TILTEQ]` table)
- Test: `modem/regmap/tests/` existing suite + `gen_regmap.py --check`

**Interfaces:**
- Produces: witness names `tilt_eq_a12` (0x260) and `tilt_eq_a3en` (0x264), section "W", flags `MS_F_PACKED`; no new 0x208 control bit (the words themselves are the control).

- [ ] **Step 1: Append the manifest entry**

```toml

[fixes.TILTEQ]
# Receiver in-band tilt corrector (spec docs/superpowers/specs/2026-10-03-rx-tilt-equaliser-design.md):
# two AXI4-Lite WRITE words, readable back, cleared by the 0x000 soft reset like 0x208 and re-applied by
# bring-up (ops/tilt_eq.sh). a_k are sfix16_En15 (|a| <= 0.95 enforced in the fabric decode); 0 = bypass.
witness_section = "W"
witness = [
  { addr = 0x260, name = "tilt_eq_a12",  flags = ["MS_F_PACKED"], fields = "{a2[31:16] a1[15:0]} sfix16_En15 each" },
  { addr = 0x264, name = "tilt_eq_a3en", flags = ["MS_F_PACKED"], fields = "{en[31] 15'b0 a3[15:0]}" } ]
```

- [ ] **Step 2: Regenerate and check**

Run: `python3 modem/regmap/gen_regmap.py && python3 modem/regmap/gen_regmap.py --check && python3 -m pytest -q modem/regmap/tests`
Expected: `--check` exits 0; generated `host/qpsk_fixregs.h` and `host/modem_status/ms_regmap_fixes.inc` contain `tilt_eq_a12`; tests pass.

- [ ] **Step 3: Commit**

```bash
git add modem/regmap/regmap.toml host/qpsk_fixregs.h host/modem_status/ms_regmap_fixes.inc && tools/check_paths.sh
git commit -s -m "regmap: TILTEQ words 0x260 tilt_eq_a12 / 0x264 tilt_eq_a3en"
```

### Task 3: Dev-model overlay `tilt_eq_overlay.m` (+ hdlworkflow mapping, assemble hook, static test)

**Files:**
- Create: `modem/dev/simulink/tilt_eq_overlay.m`
- Create: `modem/dev/hdlcoder/patch_hdlworkflow_tilteq.m`
- Modify: `modem/dev/simulink/assemble_jupiter_240k5_byte.m` (apply after `loop_gain_axi_overlay`, LEAN only, env `QPSK_TILT_EQ_OVERLAY` default on; gate line "gate(j): TILTEQ regs 0x260/0x264 present + mapped")
- Modify: `modem/build_hdl.sh` (call `patch_hdlworkflow_tilteq` next to `patch_hdlworkflow_loopgain`)
- Test: `ops/tests/test_tilt_eq_overlay.py` (static text checks, pattern of `test_carrier_lock_overlay.py`)

**Interfaces:**
- Consumes: Task 2 register names.
- Produces: TxRxComposite inports `tilt_eq_a12`, `tilt_eq_a3en` (uint32) → TxRxComposite RTL ports of the same names; a subsystem block `QPSK Rx/TiltEq` containing MATLAB Function `TiltEq3` with signature `[yI, yQ] = TiltEq3(xI, xQ, v, a12, a3en)`.

- [ ] **Step 1: Write the static test**

```python
# ops/tests/test_tilt_eq_overlay.py
import os, re
M = os.path.join(os.path.dirname(__file__), '..', '..', 'modem', 'dev', 'simulink', 'tilt_eq_overlay.m')
A = os.path.join(os.path.dirname(__file__), '..', '..', 'modem', 'dev', 'simulink', 'assemble_jupiter_240k5_byte.m')
P = os.path.join(os.path.dirname(__file__), '..', '..', 'modem', 'dev', 'hdlcoder', 'patch_hdlworkflow_tilteq.m')

def _code(p):
    return "\n".join(l for l in open(p).read().splitlines() if not l.lstrip().startswith('%'))

def test_overlay_inserts_before_agc_with_exact_bypass():
    s = _code(M)
    assert "Automatic Gain Control" in s and "TiltEq" in s
    assert "fixdt(1,16,15)" in s          # coefficient type
    assert "fixdt(1,18,14)" in s          # state type
    assert "0.95" in s                    # clamp
    assert "tilt_eq_a12" in s and "tilt_eq_a3en" in s
    assert re.search(r"already present\s*--\s*skip", s)   # idempotent

def test_assemble_applies_after_loop_gain_and_lean_only():
    s = _code(A)
    i = s.find("loop_gain_axi_overlay(sys, loop)"); j = s.find("tilt_eq_overlay(sys, loop)")
    assert 0 < i < j
    assert "QPSK_TILT_EQ_OVERLAY" in s

def test_hdlworkflow_patch_maps_260_264():
    s = _code(P)
    assert "x\"260\"" in s and "x\"264\"" in s and "tilt_eq_a12" in s and "tilt_eq_a3en" in s
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 -m pytest -q ops/tests/test_tilt_eq_overlay.py`
Expected: FAIL (file not found)

- [ ] **Step 3: Write the overlay**

```matlab
function tilt_eq_overlay(sys, base)
% tilt_eq_overlay -- receiver IN-BAND TILT CORRECTOR (spec docs/superpowers/specs/2026-10-03-rx-tilt-equaliser-design.md).
% Three cascaded complex one-pole stages y[n] = x[n] - a_k*j*y[n-1] between the QPSK Rx input and the
% Automatic Gain Control, coefficients from two uint32 AXI4-Lite write words threaded down exactly like the
% loop-gain registers (0x260 {a2[31:16] a1[15:0]}, 0x264 {en[31] a3[15:0]}, sfix16_En15, |a| clamped to 0.95 in
% the decode). en=0 or a_k=0 is an EXACT pass-through (the Switch selects the untouched input), so the
% clean-channel decode is bit-identical to the shipped tree (hard gate). LEAN-only like loop_gain_axi_overlay.
% Idempotent; apply AFTER loop_gain_axi_overlay (shares the Receiver/QPSK Rx inport threading pattern).
if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end
loop = base; rcv = [loop '/Receiver']; qrx = [rcv '/QPSK Rx']; agc = [qrx '/Automatic Gain Control'];
if isempty(getenv('QPSK_LEAN')), error('tilt_eq_overlay: LEAN-only (AXI inport threading)'); end
if ~isempty(find_system(qrx,'SearchDepth',1,'Name','TiltEq'))
    fprintf('tilt_eq_overlay: TiltEq already present -- skip\n'); return;
end
dm = [qrx '/debugMuxCtrl']; dmDT = get_param(dm,'OutDataTypeStr'); dmST = get_param(dm,'SampleTime'); busST = '1/15.36e6';
srcA12 = thread_axi_down(loop, rcv, qrx, 'tilt_eq_a12',  qrx, dmDT, dmST, busST);
srcA3  = thread_axi_down(loop, rcv, qrx, 'tilt_eq_a3en', qrx, dmDT, dmST, busST);
% ---- the AGC's data input lines (dataIn re/im arrive as ONE complex line or two real lines; handle both)
aph = get_param(agc,'PortHandles');
assert(numel(aph.Inport) >= 2, 'tilt_eq_overlay: AGC inports unexpected');
inL = get_param(aph.Inport(1),'Line'); assert(inL ~= -1, 'AGC data input unconnected');
srcPH = get_param(inL,'SrcPortHandle'); srcBlk = get_param(get_param(inL,'SrcBlockHandle'),'Name'); srcPort = get_param(srcPH,'PortNumber');
isCplx = strcmp(get_param(srcPH,'CompiledPortComplexSignal'),'on') || strcmpi(get_param(agc,'...'),''); %#ok<NASGU> placeholder removed below
% ---- MATLAB Function block TiltEq3 (fixed-point, HDL-codable)
mlfb = [qrx '/TiltEq'];
add_block('simulink/User-Defined Functions/MATLAB Function', mlfb, 'Position',[120 300 220 380]);
set_fcn_script(mlfb, tilteq_src());
delete_line(inL);
add_line(qrx, sprintf('%s/%d', srcBlk, srcPort), 'TiltEq/1', 'autorouting','on');     % x (complex sfix16_En14)
vL = get_param(aph.Inport(2),'Line'); vsrc = get_param(get_param(vL,'SrcBlockHandle'),'Name'); vport = get_param(get_param(vL,'SrcPortHandle'),'PortNumber');
add_line(qrx, sprintf('%s/%d', vsrc, vport), 'TiltEq/2', 'autorouting','on');          % validIn
add_line(qrx, srcA12, 'TiltEq/3', 'autorouting','on');
add_line(qrx, srcA3,  'TiltEq/4', 'autorouting','on');
add_line(qrx, 'TiltEq/1', [get_param(agc,'Name') '/1'], 'autorouting','on');
fprintf('tilt_eq_overlay: DONE -- TiltEq (3 x one-pole, sfix16_En15 coeffs, state fixdt(1,18,14)) before the AGC; AXI 0x260/0x264\n');
end

function src = tilteq_src()
src = sprintf([ ...
'function y = TiltEq3(x, v, a12, a3en)\n' ...
'%%#codegen\n' ...
'%% three cascaded complex one-pole tilt-corrector stages; a_k sfix16_En15 from the AXI words, |a|<=0.95;\n' ...
'%% exact pass-through when en=0 or a_k=0 (y == x bit-for-bit).\n' ...
'persistent s1 s2 s3\n' ...
'if isempty(s1), s1 = fi(complex(0,0),1,18,14); s2 = s1; s3 = s1; end\n' ...
'cT = numerictype(1,16,15); lim = fi(0.95,1,16,15);\n' ...
'a1 = reinterpretcast(fi(bitand(a12, uint32(65535)),0,16,0), cT);\n' ...
'a2 = reinterpretcast(fi(bitshift(a12,-16),0,16,0), cT);\n' ...
'a3 = reinterpretcast(fi(bitand(a3en, uint32(65535)),0,16,0), cT);\n' ...
'en = bitget(a3en, 32);\n' ...
'a1 = min(max(a1,-lim),lim); a2 = min(max(a2,-lim),lim); a3 = min(max(a3,-lim),lim);\n' ...
'xi = fi(x,1,18,14);\n' ...
'if v && en\n' ...
'  % y = x - a*j*y[n-1]  ->  yI = xI + a*yQp, yQ = xQ - a*yIp\n' ...
'  y1 = fi(complex(real(xi) + a1*imag(s1), imag(xi) - a1*real(s1)),1,18,14); s1 = y1;\n' ...
'  y2 = fi(complex(real(y1) + a2*imag(s2), imag(y1) - a2*real(s2)),1,18,14); s2 = y2;\n' ...
'  y3 = fi(complex(real(y2) + a3*imag(s3), imag(y2) - a3*real(s3)),1,18,14); s3 = y3;\n' ...
'  y = fi(y3,1,16,14,''RoundingMethod'',''Floor'',''OverflowAction'',''Saturate'');\n' ...
'else\n' ...
'  if ~en, s1(:) = 0; s2(:) = 0; s3(:) = 0; end\n' ...
'  y = fi(x,1,16,14);\n' ...
'end\n' ...
'end\n']);
end
```

Notes for the implementer: `thread_axi_down` and `set_fcn_script` are local functions of `loop_gain_axi_overlay.m`; copy both verbatim into this file (local functions are file-private in MATLAB) with a header comment naming the source. Remove the `isCplx` placeholder line: the `QPSK Rx` input is one complex line in this model (the generated RTL splits it into `dataIn_re/_im`); if the model turns out to carry two real lines, build `x` with a `Real-Imag to Complex` block in front of `TiltEq/1` and split `y` with `Complex to Real-Imag` after it. Verify by `get_param(srcPH,'CompiledPortComplexSignal')` after `set_param(sys,'SimulationCommand','update')`.

- [ ] **Step 4: Write the hdlworkflow patch**

```matlab
function patch_hdlworkflow_tilteq(wfFile)
% map the two TiltEq AXI write words (same mechanism as patch_hdlworkflow_loopgain)
if nargin < 1, wfFile = 'hdlworkflow_loopback.m'; end
sys = 'commhdlQPSKTxRxLoopback'; txt = fileread(wfFile);
if contains(txt, 'tilt-eq mappings'), fprintf('patch_hdlworkflow_tilteq: already patched -- skipping\n'); return; end
regs = { 'tilt_eq_a12','260'; 'tilt_eq_a3en','264' };
L = ['% --- tilt-eq mappings (receiver in-band tilt corrector, 0x260/0x264) ---' newline];
L = [L 'if ~isempty(find_system(''' sys '/TxRxComposite'',''SearchDepth'',1,''BlockType'',''Inport'',''Name'',''tilt_eq_a12''))' newline];
for i = 1:size(regs,1)
    p = [sys '/TxRxComposite/' regs{i,1}];
    L = [L 'hdlset_param(''' p ''', ''IOInterface'', ''AXI4-Lite'');' newline]; %#ok<AGROW>
    L = [L 'hdlset_param(''' p ''', ''IOInterfaceMapping'', ''x"' regs{i,2} '"'');' newline]; %#ok<AGROW>
end
L = [L 'end' newline '% --- end tilt-eq mappings ---' newline];
anchor = '% --- end loop-gain tuning mappings ---';
idx = strfind(txt, anchor); assert(~isempty(idx), 'patch_hdlworkflow_tilteq: loop-gain anchor not found in %s', wfFile);
at = idx(1) + numel(anchor); if at <= numel(txt) && txt(at) == newline, at = at + 1; end
txt = [txt(1:at-1) L txt(at:end)];
fid = fopen(wfFile,'w'); fwrite(fid, txt); fclose(fid);
fprintf('patch_hdlworkflow_tilteq: added 0x260/0x264 to %s\n', wfFile);
end
```

- [ ] **Step 5: Hook into assemble and build_hdl**

In `assemble_jupiter_240k5_byte.m`, directly after the `loop_gain_axi_overlay(sys, loop)` call block:

```matlab
% --- receiver in-band tilt corrector (0x260/0x264), LEAN-only, default ON; QPSK_TILT_EQ_OVERLAY=0 skips ---
if LEAN && ~strcmp(getenv('QPSK_TILT_EQ_OVERLAY'), '0')
    fprintf('=== applying tilt-eq overlay (0x260/0x264) ===\n');
    tilt_eq_overlay(sys, loop);
else
    fprintf('=== tilt-eq overlay SKIPPED ===\n');
end
```

and in the gate list near `gate(i): C3 loop-gain regs`:

```matlab
if LEAN && ~strcmp(getenv('QPSK_TILT_EQ_OVERLAY'), '0')
    assert(~isempty(find_system([loop '/Receiver/QPSK Rx'],'SearchDepth',1,'Name','TiltEq')), 'gate(j): TiltEq block missing');
    assert(~isempty(find_system(loop,'SearchDepth',1,'BlockType','Inport','Name','tilt_eq_a3en')), 'gate(j): tilt_eq_a3en inport missing');
    fprintf('gate(j): TILTEQ regs 0x260/0x264 present + mapped\n');
end
```

In `modem/build_hdl.sh`, where `patch_hdlworkflow_loopgain` is invoked, add the same invocation of `patch_hdlworkflow_tilteq` (same working directory and MATLAB call form; grep the file for `patch_hdlworkflow_loopgain` and mirror the line).

- [ ] **Step 6: MATLAB smoke test on the dev model (no regen)**

Run via the MATLAB MCP (`run_matlab_file` on a scratch script) after a one-line health probe:

```matlab
cd(getenv('KIT')); kitpath; setenv('QPSK_LEAN','1'); load_system('commhdlQPSKTxRx');
loop_gain_axi_overlay(); tilt_eq_overlay();
set_param('commhdlQPSKTxRx','SimulationCommand','update');   % type/complexity propagation must succeed
disp(get_param('commhdlQPSKTxRx/Receiver/QPSK Rx/TiltEq','Position'));
```

Expected: no error, `tilt_eq_overlay: DONE` printed; then `git checkout -- <the .slx>` (the smoke must not leave the dev model modified in the repo; the regen does the real apply).

- [ ] **Step 7: Run the static tests and commit**

Run: `python3 -m pytest -q ops/tests/test_tilt_eq_overlay.py ops/tests/test_carrier_lock_overlay.py modem/tests/test_assemble_phases.py`
Expected: pass

```bash
git add modem/dev/simulink/tilt_eq_overlay.m modem/dev/hdlcoder/patch_hdlworkflow_tilteq.m modem/dev/simulink/assemble_jupiter_240k5_byte.m modem/build_hdl.sh ops/tests/test_tilt_eq_overlay.py && tools/check_paths.sh
git commit -s -m "tilt_eq_overlay.m: 3-stage complex one-pole tilt corrector before the AGC, AXI 0x260/0x264, exact bypass; hdlworkflow mapping; assemble hook (LEAN, QPSK_TILT_EQ_OVERLAY)"
```

### Task 4: Sim harness: drive the two words, `PERT_EQ_*` knobs, tilt-budget verdict, legs

**Files:**
- Modify: `modem/rtl_sim/wrap_byte_sro4b_ss_model.v` (two new `input wire [31:0] tilt_eq_a12, tilt_eq_a3en` wired to the DUT; default 0 when the DUT lacks the ports is NOT possible in Verilog, so the wrapper is built against the regenerated tree only -- guard with `` `ifdef HAVE_TILT_EQ ``)
- Modify: `modem/rtl_sim/sim_sro_perturb.cpp` (env `PERT_EQ_A1/A2/A3` floats, or `PERT_EQ_AUTO=1` = the inverse of `PERT_TILT_DB` via the same bisection and sign; `PERT_EQ_MISSET=0.2` scales every a_k by (1+0.2); sets the ports under `HAVE_TILT_EQ`; header line `# eq a1 a2 a3 w260 w264`)
- Modify: `modem/rtl_sim/perturb_score.py` (`--tilt-budget`: PASS iff syncs(from frame 8) == all, |median cfc| < 30, median |Δcfc| < 200)
- Create: `modem/gates/tilt_eq.legs`
- Test: `ops/tests/test_perturb_score.py` (+ budget cases), `ops/tests/test_tilt_eq_legs.py`

**Interfaces:**
- Consumes: Task 1's bisection (re-implemented in C++ in the driver, identical constants).
- Produces: driver header `# eq a1=%.5f a2=%.5f a3=%.5f w260=0x%08X w264=0x%08X`; `perturb_score.py --tilt-budget <pert.txt>...` prints `PASS <name> bias=.. noise=.. syncs=a/b` or `FAIL ...`.

- [ ] **Step 1: Tests first**

```python
# ops/tests/test_tilt_eq_legs.py
import os
L = os.path.join(os.path.dirname(__file__), '..', '..', 'modem', 'gates', 'tilt_eq.legs')
def test_rows():
    rows = [l.rstrip() for l in open(L) if l.strip() and not l.startswith('#')]
    names = [r.split('|', 2)[0] for r in rows]
    assert names[0] == 'te_build' and len(set(names)) == len(names)
    assert {'te_identity', 'te_tilt_m8', 'te_tilt_m12', 'te_tilt_m16', 'te_tilt_p10', 'te_misset_m12', 'te_budget', 'te_replay_46', 'te_replay_2p4'} <= set(names)
    txt = "\n".join(rows)
    assert 'PERT_EQ_AUTO=1' in txt and 'PERT_EQ_MISSET=0.2' in txt and '--tilt-budget' in txt
    assert 'fwddiag_20261002_1604/gate3/cell1_A_2100020000/pair.iq' in txt
```

Add to `ops/tests/test_perturb_score.py`:

```python
def test_tilt_budget_verdict(tmp_path):
    import subprocess, sys, os
    p = tmp_path / "x_pert.txt"
    hdr = "frame,a,b,dp,c,biterr,d,e,rstcs,cfc," + ",".join(f"c{i}" for i in range(10, 40)) + "\n"
    rows = [hdr] + [",".join([str(f), "0", "0", "1", "0", "0", "0", "0", "0", str(-12 + (f % 3))] + ["0"] * 30) + "\n" for f in range(120)]
    p.write_text("".join(rows))
    out = subprocess.run([sys.executable, os.path.join(ROOT, "modem/rtl_sim/perturb_score.py"), "--tilt-budget", str(p)], capture_output=True, text=True).stdout
    assert out.startswith("PASS"), out
```

(`ROOT` already exists in that test file; if not, define it as the repo root.)

- [ ] **Step 2: Run to verify failure**

Run: `python3 -m pytest -q ops/tests/test_tilt_eq_legs.py ops/tests/test_perturb_score.py`
Expected: FAIL (legs missing; `--tilt-budget` unknown)

- [ ] **Step 3: Driver and wrapper changes**

Wrapper: after `output wire ... ssV);` add under the port list `` `ifdef HAVE_TILT_EQ input wire [31:0] tilt_eq_a12, tilt_eq_a3en, `endif `` and in the DUT instantiation `` `ifdef HAVE_TILT_EQ .tilt_eq_a12(tilt_eq_a12), .tilt_eq_a3en(tilt_eq_a3en), `endif ``.

Driver (after the `tilt_norm` line):

```cpp
    // PERT_EQ_* (2026-10-03): the fabric's TiltEq corrector words. PERT_EQ_AUTO=1 sets the exact inverse of
    // PERT_TILT_DB (same stage count and bisection, channel sign), PERT_EQ_A1/A2/A3 set a_k directly,
    // PERT_EQ_MISSET=m scales every a_k by (1+m). Encoded sfix16_En15, en = any a_k != 0.
    double eqa[3] = { envd("PERT_EQ_A1",0.0), envd("PERT_EQ_A2",0.0), envd("PERT_EQ_A3",0.0) };
    if (envl("PERT_EQ_AUTO",0) && tilt_db != 0.0) for (int k = 0; k < tilt_k; k++) eqa[k] = tilt_a;
    { const double m = envd("PERT_EQ_MISSET",0.0); for (int k = 0; k < 3; k++) eqa[k] *= (1.0 + m); }
    auto enc = [](double a){ long q = lround(a * 32768.0); if (q > 32767) q = 32767; if (q < -32768) q = -32768; return (unsigned)(q & 0xFFFF); };
    const unsigned w260 = (enc(eqa[1]) << 16) | enc(eqa[0]);
    const unsigned w264 = ((eqa[0]!=0||eqa[1]!=0||eqa[2]!=0) ? 0x80000000u : 0u) | enc(eqa[2]);
    fprintf(fo, "# eq a1=%.5f a2=%.5f a3=%.5f w260=0x%08X w264=0x%08X\n", eqa[0], eqa[1], eqa[2], w260, w264);
```

and after `t->tgen_sel=0; ...`:

```cpp
#ifdef HAVE_TILT_EQ
    t->tilt_eq_a12 = w260; t->tilt_eq_a3en = w264;
#endif
```

`perturb_score.py` -- add:

```python
def tilt_budget(path, max_bias=30, max_noise=200):
    rows = [l.split(",") for l in open(path) if not l.startswith("#")]
    fr = np.array([int(r[0]) for r in rows]); dp = np.array([int(r[3]) for r in rows]); cfc = np.array([int(r[9]) for r in rows]); sel = fr >= 8
    syncs, n = int((dp[sel] >= 1).sum()), int(sel.sum())
    bias = float(np.median(cfc[sel])); noise = float(np.median(np.abs(np.diff(cfc[sel]))))
    ok = syncs == n and abs(bias) < max_bias and noise < max_noise
    return ok, f"{'PASS' if ok else 'FAIL'} {os.path.basename(path)} syncs={syncs}/{n} bias={bias:+.0f} noise={noise:.0f}"
```

with a `--tilt-budget` CLI branch that prints one line per file and exits 1 if any FAIL.

- [ ] **Step 4: The legs file**

```
# tilt_eq.legs -- the receiver tilt corrector (spec docs/superpowers/specs/2026-10-03-rx-tilt-equaliser-design.md).
# Tree: $RTL/s1_rtl_model from the sp3tilteq regen; bank: the f1536 bank (run with run_gates.sh --rung r3).
# te_identity: corrector OFF -> decode bit-identical to the sp3clamp004 banked baseline (first 10 columns).
# te_tilt_*: channel tilt with the exact inverse set (PERT_EQ_AUTO=1) -> syncs all, |bias| < 30, noise < 200.
# te_misset: inverse off by +20 % at -12 dB must still meet the budget.  te_replay_*: the recorded 46 % and
# 2.4 % days replayed with a from tilt_score.py on those files (ops/tilt_eq_solve.py).
te_build|env TREE=s1_rtl_model OBJ=obj_tilt_eq_model CFLAGS_EXTRA=-DHAVE_TILT_EQ $RTL/build_carrier_lock.sh|grep -q '^BUILD_CARRIER_LOCK_DONE ' te_build.log
te_baseline|env PERT_LOOP=1 $RTL/obj_tilt_eq_model/Vwrap_byte_sro_model rx $SRO/n_p000.iq 5919840 8400 te_baseline 2 0|test -s te_baseline_pert.txt
te_identity|-|: depends te_baseline && cmp -s <(grep -v '^#' te_baseline_pert.txt | cut -d, -f1-10) ${CL_BANK:-/mnt/onetb/scratch/qpsk-build-trees/carrier_lock_bank}/tilt_eq_c004_baseline_f1536_cols1_10.txt
te_tilt_m8|env PERT_LOOP=1 PERT_TILT_DB=-8 PERT_EQ_AUTO=1 $RTL/obj_tilt_eq_model/Vwrap_byte_sro_model rx $SRO/n_p000.iq 5919840 8400 te_tilt_m8 2 0|test -s te_tilt_m8_pert.txt
te_tilt_m12|env PERT_LOOP=1 PERT_TILT_DB=-12 PERT_EQ_AUTO=1 $RTL/obj_tilt_eq_model/Vwrap_byte_sro_model rx $SRO/n_p000.iq 5919840 8400 te_tilt_m12 2 0|test -s te_tilt_m12_pert.txt
te_tilt_m16|env PERT_LOOP=1 PERT_TILT_DB=-16 PERT_EQ_AUTO=1 $RTL/obj_tilt_eq_model/Vwrap_byte_sro_model rx $SRO/n_p000.iq 5919840 8400 te_tilt_m16 2 0|test -s te_tilt_m16_pert.txt
te_tilt_p10|env PERT_LOOP=1 PERT_TILT_DB=10 PERT_EQ_AUTO=1 $RTL/obj_tilt_eq_model/Vwrap_byte_sro_model rx $SRO/n_p000.iq 5919840 8400 te_tilt_p10 2 0|test -s te_tilt_p10_pert.txt
te_misset_m12|env PERT_LOOP=1 PERT_TILT_DB=-12 PERT_EQ_AUTO=1 PERT_EQ_MISSET=0.2 $RTL/obj_tilt_eq_model/Vwrap_byte_sro_model rx $SRO/n_p000.iq 5919840 8400 te_misset_m12 2 0|test -s te_misset_m12_pert.txt
te_budget|python3 $RTL/perturb_score.py --tilt-budget te_tilt_m8_pert.txt te_tilt_m12_pert.txt te_tilt_m16_pert.txt te_tilt_p10_pert.txt te_misset_m12_pert.txt|test "$(grep -c '^PASS ' te_budget.log)" = 5
te_replay_46|env PERT_LOOP=0 $(python3 $ROOT/ops/tilt_eq_solve.py --env $(python3 $ROOT/ops/tilt_score.py --json $ROOT/ops/r3cap/fwddiag_20261002_1604/gate3/cell1_A_2100020000/pair.iq | python3 -c 'import sys,json;print(json.load(sys.stdin)["tilt_db"])')) $RTL/obj_tilt_eq_model/Vwrap_byte_sro_model rx $ROOT/ops/r3cap/fwddiag_20261002_1604/gate3/cell1_A_2100020000/pair.iq 4000000 8400 te_replay_46 2 0|python3 $RTL/perturb_score.py --tilt-budget --min-syncs 0.95 te_replay_46_pert.txt | grep -q '^PASS '
te_replay_2p4|env PERT_LOOP=0 $(python3 $ROOT/ops/tilt_eq_solve.py --env $(python3 $ROOT/ops/tilt_score.py --json $ROOT/ops/r3cap/fwd2100_20261001_1110/gate3/cell1_A_2000020000/pair.iq | python3 -c 'import sys,json;print(json.load(sys.stdin)["tilt_db"])')) $RTL/obj_tilt_eq_model/Vwrap_byte_sro_model rx $ROOT/ops/r3cap/fwd2100_20261001_1110/gate3/cell1_A_2000020000/pair.iq 4000000 8400 te_replay_2p4 2 0|python3 $RTL/perturb_score.py --tilt-budget --min-syncs 0.95 te_replay_2p4_pert.txt | grep -q '^PASS '
```

`tilt_eq_solve.py --env <tilt_db>` prints `PERT_EQ_A1=.. PERT_EQ_A2=.. PERT_EQ_A3=..` (add this flag in Task 1's file; one more test line: `assert "PERT_EQ_A1=" in run("--env -8")`). `--min-syncs` on the budget relaxes the sync criterion for the noisy live replays (bias/noise criteria unchanged). Confirm `$ROOT` is exported by `run_gates.sh` (it exports `$RTL`, `$SRO`; add `ROOT` if absent) and that `build_carrier_lock.sh` passes `CFLAGS_EXTRA` into the Verilator `-CFLAGS` (add if absent). The identity reference `tilt_eq_c004_baseline_f1536_cols1_10.txt` is produced once from the sp3clamp004 f1536 object with the same `te_baseline` command (`cut -d, -f1-10`) and placed in `carrier_lock_bank/` (outside the listing-hashed banks).

- [ ] **Step 5: Run the tests, commit**

Run: `python3 -m pytest -q ops/tests/test_tilt_eq_legs.py ops/tests/test_perturb_score.py ops/tests/test_tilt_eq_solve.py`
Expected: pass. Then build the current (clamp004, no TiltEq) object WITHOUT `-DHAVE_TILT_EQ` to confirm the driver still compiles and `PERT_EQ_*` is inert (`te_baseline` row manually, compare to `cl_baseline` cols 1-10 → identical).

```bash
git add modem/rtl_sim/wrap_byte_sro4b_ss_model.v modem/rtl_sim/sim_sro_perturb.cpp modem/rtl_sim/perturb_score.py modem/gates/tilt_eq.legs modem/gates/run_gates.sh modem/rtl_sim/build_carrier_lock.sh ops/tilt_eq_solve.py ops/tests/ && tools/check_paths.sh
git commit -s -m "sim: TiltEq words on the wrapper (HAVE_TILT_EQ), PERT_EQ_AUTO/A1-3/MISSET, perturb_score --tilt-budget, tilt_eq.legs (identity, tilt rows, mis-set, live replays)"
```

### Task 5: Host rail `ops/tilt_eq.sh` + bring-up hook

**Files:**
- Create: `ops/tilt_eq.sh`
- Modify: `ops/bringup_r2r3.sh` (after the `sro_sign.sh --check` hook: `if [ "${QPSK_TILT_EQ:-0}" = 1 ]; then bash "$D/tilt_eq.sh" $ip --bringup || echo "TILT_EQ_HOOK_FAILED $ip"; fi` for the RX board of each leg; default OFF until Gate 3)
- Test: `ops/tests/test_tilt_eq_sh.py` (DRY and parse checks; pattern of `test_carrier_probe.py`)

**Interfaces:**
- `tilt_eq.sh <ip> [--bringup] [--off] [--dry]`: capture 262144 Tap-A samples (`iio_readdev -u local: -b 32768 -s 262144 axi-adrv9002-rx-lpc voltage0_i voltage0_q`) to `/dev/shm/tilteq.iq`, pull, `tilt_score.py --json`, `tilt_eq_solve.py <tilt>` → words, write via `direct_reg_access` (`echo 0x260 0x<w> > $DRA`), read back both words, re-capture and re-score, print one line `TILT_EQ <ip> t_before=<dB> a1=.. a2=.. a3=.. w260=0x.. w264=0x.. readback=OK|MISMATCH t_after=<dB>`; `--off` writes zeros; `--dry` prints the plan and touches no board. Uses `anyssh.sh` (so it refuses under a foreign RIG_LOCK), takes no lock itself (callers hold it).

- [ ] **Step 1: Test**

```python
# ops/tests/test_tilt_eq_sh.py
import os, subprocess
S = os.path.join(os.path.dirname(__file__), '..', 'tilt_eq.sh')
def test_dry_touches_no_board():
    out = subprocess.run(["bash", S, "10.0.0.148", "--dry"], capture_output=True, text=True).stdout
    assert "TILT_EQ_DRY" in out and "0x260" in out and "iio_readdev" in out
def test_script_uses_anyssh_and_dra_and_solver():
    s = open(S).read()
    assert "anyssh.sh" in s and "direct_reg_access" in s and "tilt_eq_solve.py" in s and "tilt_score.py --json" in s
    assert "echo 0x260 " in s and "echo 0x264 " in s and "--off" in s
```

- [ ] **Step 2: Fail, implement, pass** (script per the interface above; `set -u`; DRY first; readback via `echo 0x260 > $DRA; cat $DRA`), then:

Run: `python3 -m pytest -q ops/tests/test_tilt_eq_sh.py ops/tests/test_bringup_lo_plan.py ops/tests/test_bringup_settle.py`

- [ ] **Step 3: Commit**

```bash
git add ops/tilt_eq.sh ops/bringup_r2r3.sh ops/tests/test_tilt_eq_sh.py && tools/check_paths.sh
git commit -s -m "tilt_eq.sh: measure the in-band tilt on the receiving board, solve, write 0x260/0x264, verify; bring-up hook behind QPSK_TILT_EQ=1"
```

### Task 6: Regen + Gate 1 + Gate 2 (image sp3tilteq)

**Files:**
- Run: `modem/build_image.sh --tag sp3tilteq --remote-base <hdl-dev-2 scratch>` under `ops/launch_rig_unit.sh` (not a rig unit, but the same frozen-copy/systemd rail), from the main tree on master after Tasks 1-5 are merged.
- Then `modem/gates/run_gates.sh --rung r3 --legs modem/gates/tilt_eq.legs` on the regen tree (set `RTL` to the kit's `rtl_sim`, bank default f1536).

- [ ] **Step 1: Launch** exactly as the sp3clamp004 build was launched (see `ops/r3cap/carrier_lock_20260929_NOTES.md` 06:21 and the `hw_chain_clamp004.sh` scratch script), tag `sp3tilteq`, MATLAB regen on nemo, Vivado on hdl-dev-2. Wait with a background `until` loop on the unit.
- [ ] **Step 2: Gate 1** -- `model_matrix_f1536.legs` via `--rung r3` must match the sp3clamp004 run row for row (identity), then `tilt_eq.legs` must pass every row (`te_identity`, `te_budget` 5/5, both replays).
- [ ] **Step 3: Gate 2** -- `modem/gates/modem_wns.py --min 0.005` on the routed report; record WNS and the utilisation delta (DSP/LUT/FF) in the evidence doc.
- [ ] **Step 4: Bank** the image (`images/` + MD5SUMS row, no symlink), do NOT touch `images/CURRENT.txt`.
- [ ] **Step 5: Commit** the evidence stub `docs/evidence/link/TILT_EQ_2026-10-03.md` §1-3 (design pointer, Gate 1 table, Gate 2 numbers) with the local gates; PR; merge.

### Task 7: Gate 3 pair + evidence

- [ ] **Step 1:** Preconditions: antennas re-placed by the operator (forward self-interference and the weak reverse path are bench facts, not this image's); pair arms on the default gate.
- [ ] **Step 2:** `ops/gate3_pair.sh` with `GATE3_TAG=sp3tilteq GATE3_RUNG=r3`, the standard cells, then two extra forward cells with `QPSK_TILT_EQ=1` (corrector written from the live tilt) vs OFF, interleaved, 180 s each. Lost frames in the denominator; the corrector must not degrade a flat day (ON within the CP95 of OFF).
- [ ] **Step 3:** If the day is flat (|tilt| < 6), the tilt benefit is cited from `te_replay_46`/`te_replay_2p4` (desk replay of live IQ); if a tilted day occurs, cite the live ON/OFF pair. Say which.
- [ ] **Step 4:** Evidence doc §4-5, memory file `rx-tilt-corrector-shipped.md`, update `docs/bringup.rst` (the `QPSK_TILT_EQ` knob and `tilt_eq.sh`), commit, PR, merge. `images/CURRENT.txt` is the operator's edit on a PASS.
