function txfix_f3_overlay(sys, base)
% txfix_f3_overlay -- the TRANSMITTER's 120.2 s stall fix (F1+F2+F3) as a MODEL
% overlay (cleanup sub-project 3, task 8).  Formerly the netlist injector
% modem/fixes/txfix_inject.py, variant `F3` (= F1 + F2 + F3; the shipped variant,
% fixes.toml [chain].txfix.variant = "F3").  The injector is the SEMANTIC TRUTH
% and every edit below is a line-by-line transcription of one of its patchers.
% Env-gated: QPSK_RXFIX (the same gate the modem/rxfix/ RX overlays ride; phase
% 2.21 of modem/assemble_jupiter_240k5_byte.m) AND QPSK_TXFIX -- BOTH must be
% set.  The second gate exists so a model-lineage UNFIXED baseline (same
% receiver, stock transmitter) can be built for the gate's four RX-capture rows;
% see the G0 note below.
%
% NO NEW PORTS, NO NEW REGISTERS.  Unlike every other overlay in this directory
% this one is a pure behaviour change inside `Bit Packetizer`: nothing is
% surfaced, so there is no `keep_last` dance and no AXI map entry.  A
% BASE_REGEN_INJECT_FAILED in a tree carrying this overlay is therefore never
% attributable to it.
%
% ---------------------------------------------------------------------------
% F1 -- the pop-enable latch may only change at a frame boundary.
%   injector: patch_data_bits_fifo, Data_Bits_FIFO.v.  The generated
%   `Unit Delay Enabled Resettable Synchronous` emits
%       if (C1) out <= 0; else if (C3) out <= C2;
%   i.e. the RESET (C1 = frameCount==0) beats the ENABLE (C3 = sampleCount==0)
%   and clears the latch MID-FRAME, aborting pops -- the 120.2 s stall.  The
%   injector moves the clear inside the C3 branch.  In the model the same thing
%   is done by ANDing the latch's RESET input with the ENABLE compare:
%       reset' = C1 & C3   ->   if (C1&C3) out <= 0; else if (C3) out <= C2;
%   Truth table vs the injector's DBF_NEW, on all four (C3,C1):
%       C3=1,C1=1 -> 0        (patched: C3 branch, C1 arm -> 0)
%       C3=1,C1=0 -> C2       (patched: C3 branch, else arm -> C2)
%       C3=0,C1=1 -> hold     (patched: no C3 branch -> hold)
%       C3=0,C1=0 -> hold     (patched: hold)
%   NOTE this equivalence is UNCONDITIONAL -- unlike the injector's comment it
%   does not lean on the identity C2 === ~C1.  The two polarity asserts below
%   are kept anyway, as structural anchors against a re-wire upstream.
%
% F2 -- saturating frameCount.  injector: patch_ram_frame_status_indicator.
% F3 -- dataReady = DataReadyPaceCmp & ~fullRAM (patch_bit_packetizer) AND a
%   saturating uint16 occupancy count (patch_matlab_function1).
%   F3b (--margin, fullRAM threshold 49279 -> 49263) is NOT applied.
%
% ---------------------------------------------------------------------------
% THE TWO SATURATING COUNTERS ARE SCRIPT EDITS OF THE EXISTING MATLAB FUNCTION
% BLOCKS, NOT NEW BLOCKS (deviation from the task brief, recorded).  The brief
% calls for "an MLFB `FrameCountSat` replacing the counter block".  There is no
% counter block: `RAM Frame Status Indicator` and `MATLAB Function1` are ALREADY
% MATLAB Function blocks (the generated RAM_Frame_Status_Indicator.v /
% MATLAB_Function1.v are MLFB output -- `frameCount_temp`/`count_temp` with a
% `_next` register, the HDL Coder MLFB shape).  Replacing them would rename the
% module and the instance, and BOTH TX gate harnesses read AND WRITE those
% instances by hierarchical path:
%     sim_txfix_force.cpp : DBF u_MATLAB_Function1__DOT__count  (read + forced,
%                           the `nearfull` sel), FSI frameCount (read + forced,
%                           the `frcwrap` sel)
%     txrate_probe.cpp    : the same two
% Those are C++ MEMBER paths (the harnesses' CAT() macro expands to
% `R->wrap_byte_ddrcap__DOT__...__DOT__u_MATLAB_Function1__DOT__count`), so a rename
% does not blind the gate silently -- it stops the harness COMPILING, and every row
% that forces those two registers (G9/G10/G11/G12) becomes unrunnable until someone
% re-derives the paths.  Loud, but it costs a rebuild of the whole gate chain for no
% behavioural gain.  Editing the scripts keeps
% `u_RAM_Frame_Status_Indicator.frameCount` and `u_MATLAB_Function1.count` exactly
% where the harnesses expect them.
%
% THE SATURATION LIMITS ARE LITERALS (3 and 65535), as in the injector (2'b11 /
% 16'hFFFF).  They are the full range of the two fi types, which are derived
% from `dataBitsPerPacket`: frameCount is fi(0,0,2,0) and count is
% fi(0,0,nextpow2(dataBitsPerPacket*2-1),0) = ufix16 at the deployed rung
% (dataBitsPerPacket = 24640 -> depth 49279 -> nextpow2 16).  `nextpow2` is NOT
% put in the always-executed body -- it is a codegen gamble that costs a 22 min
% regen -- so the guarantee comes from asserts instead: the ORIGINAL script text
% is anchored exactly (including `depth = dataBitsPerPacket*2 - 1;`), and the
% regen post-check greps the emitted widths (`reg [15:0] count`,
% `reg [1:0] frameCount`).
%
% BLOCK NAMES IN THIS SUBSYSTEM CONTAIN NEWLINES (`Compare\nTo Constant3`,
% `Logical\nOperator2`, `Unit Delay Enabled Resettable\nSynchronous`), which no
% exact-Name find_system can express -- every anchor below is resolved with
% 'regexp','on' and a whitespace-tolerant pattern, asserted to hit exactly once.
%
% G0: the whole body early-returns when QPSK_RXFIX is unset, so an un-gated
% build is byte-identical HDL.
%
% SECOND GATE, QPSK_TXFIX (sp3 task 8 fix round 2).  The four RX-capture rows of
% the TX gate (G3, G4/G5 k0+k6, G7) compare a capture from THIS tree against the
% unfixed baseline `beat_runs/g0_none_U`.  With only the QPSK_RXFIX gate there is
% no way to build a tree that carries the RX overlays but NOT this one, so the
% only available baseline came from the injected lineage (a receiver with no RX
% overlays at all) and those four rows measured the receiver, not the
% transmitter.  QPSK_TXFIX makes a model-lineage UNFIXED baseline expressible:
% both vars set (the normal regen -- modem/fixes/build_base_tree.sh exports both)
% = fix applied; QPSK_RXFIX=1 with QPSK_TXFIX empty = same receiver, stock
% transmitter.  BOTH must be set for any edit below to happen.

if isempty(getenv('QPSK_RXFIX')), return; end
if isempty(getenv('QPSK_TXFIX')), return; end
if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end
fprintf('=== txfix_f3_overlay: TX stall fix F1+F2+F3 (Bit Packetizer) ===\n');

lo  = 'LookUnderMasks';
tx  = [base '/Transmitter'];
qtx = [tx  '/QPSK Tx'];
bp  = [qtx '/Bit Packetizer'];
dbf = [bp  '/Data Bits FIFO'];

% ---- helpers ---------------------------------------------------------------
  function b = one(ss, pat)
    % the single SearchDepth-1 child of ss whose name matches `pat` with any
    % run of whitespace (newlines included) allowed where `pat` has a space.
    rx = ['^' regexprep(regexptranslate('escape', pat), '\s+', '[\\s]+') '$'];
    h = find_system(ss,'SearchDepth',1,lo,'all','regexp','on','Name',rx);
    if numel(h) ~= 1
      error('txfix_f3: %s: %d blocks match %s (want exactly 1)', ss, numel(h), pat);
    end
    b = h{1};
  end
  function h = oh(blk, k)
    p = get_param(blk,'PortHandles'); h = p.Outport(k);
  end
  function h = ih(blk, k)
    p = get_param(blk,'PortHandles'); h = p.Inport(k);
  end
  function s = src_of(porth)
    l = get_param(porth,'Line');
    if l == -1, error('txfix_f3: input port is unconnected'); end
    s = get_param(l,'SrcPortHandle');
  end
  function n = flat(blk)
    n = regexprep(get_param(blk,'Name'), '\s+', ' ');
  end
  function assert_cmp(blk, relop, konst, what)
    if ~strcmp(get_param(blk,'relop'), relop) || ~strcmp(strtrim(get_param(blk,'const')), konst)
      error('txfix_f3: %s (%s) is "%s %s", expected "%s %s"', what, flat(blk), ...
            get_param(blk,'relop'), get_param(blk,'const'), relop, konst);
    end
  end
  function ch = chart(pth)
    S = sfroot; c = S.find('Path', pth, '-isa', 'Stateflow.EMChart');
    if isempty(c), error('txfix_f3: %s is not a MATLAB Function block', pth); end
    ch = c(1);
  end
  function s = sub1(s, old, new, what)
    % replace `old` by `new`, asserting the anchor occurs EXACTLY once
    % (txfix_inject.py's _sub, transcribed).
    n = numel(strfind(s, old));
    if n ~= 1
      error('txfix_f3: anchor for %s occurs %d times (want exactly 1)', what, n);
    end
    s = strrep(s, old, new);
  end

% ---- anchors: every block this overlay touches ------------------------------
% (newline-free names only; the three that carry a newline go through one()).
  function assert_block(pth)
    parent = regexprep(pth, '/[^/]*$', '');
    nm     = regexprep(pth, '.*/', '');
    if isempty(find_system(parent,'SearchDepth',1,lo,'all','Name',nm))
      error('txfix_f3: anchor missing: %s', pth);
    end
  end

fsi   = [dbf '/RAM Frame Status Indicator'];
mf1   = [dbf '/MATLAB Function1'];
pace  = [bp  '/DataReadyPaceCmp'];
dtc   = [bp  '/Data Type Conversion'];
% NB not `p`: oh()/ih() below are NESTED functions and share this workspace, so a
% loop index named `p` would be clobbered by their `p = get_param(...)`.
for anc = {tx, qtx, bp, dbf, fsi, mf1, pace, dtc}
  assert_block(anc{1});
end
uders = one(dbf, 'Unit Delay Enabled Resettable Synchronous');
notf  = one(bp,  'Logical Operator2');

% ---- idempotency -----------------------------------------------------------
% Probed on ALL FOUR edits, not on one block name: a half-applied overlay (say,
% the F1 AND present but the F2 script not re-written) must be an error, never a
% silent "already applied".
% `TXFIX_F3` IS A PREFIX OF `TXFIX_F3B`, so the F3b marker is tested FIRST and a
% plain `contains(..., 'TXFIX_F3')` is only ever read after that -- the same
% discipline txfix_inject.py:patch_matlab_function1's docstring spells out, where an
% unordered test would make `--margin` a silent no-op. This overlay never writes F3b,
% so an F3b chart is not "already applied": it is a tree that must not be reported as
% the shipped F3 variant.
mf1Script = chart(mf1).Script;
if contains(mf1Script, 'TXFIX_F3B')
  error(['txfix_f3: %s already carries the F3b margin (TXFIX_F3B). F3 is the ' ...
         'shipped variant (fixes.toml [chain].txfix.variant = "F3"); refusing to ' ...
         're-apply F3 over it -- re-assemble from a clean slx.'], mf1);
end
haveF1 = ~isempty(find_system(dbf,'SearchDepth',1,lo,'all','Name','TxF1BoundaryGuard'));
haveF3 = ~isempty(find_system(bp, 'SearchDepth',1,lo,'all','Name','TxF3ReadyGate'));
haveF2s = contains(chart(fsi).Script, 'TXFIX_F2');
haveF3s = contains(mf1Script, 'TXFIX_F3');
st = [haveF1 haveF2s haveF3 haveF3s];
if all(st)
  fprintf('txfix_f3: already applied\n');
  return;
elseif any(st)
  error(['txfix_f3: HALF-APPLIED overlay (F1=%d F2script=%d F3gate=%d F3script=%d) -- ' ...
         'the model is in an inconsistent state; re-assemble from a clean slx'], st);
end

% ---- F1: gate the latch's RESET input with the frame-boundary ENABLE ---------
% Port order on the generated Unit Delay Enabled Resettable Synchronous is
% (1) data (2) enable (3) reset -- measured, and asserted here by the identity of
% the block driving each one rather than taken on faith.
ph = get_param(uders,'PortHandles');
if numel(ph.Inport) ~= 3
  error('txfix_f3: %s has %d inputs (want 3: data/enable/reset)', flat(uders), numel(ph.Inport));
end
hData = src_of(ph.Inport(1));  bData = get_param(hData,'Parent');
hEn   = src_of(ph.Inport(2));  bEn   = get_param(hEn,'Parent');
hRst  = src_of(ph.Inport(3));  bRst  = get_param(hRst,'Parent');
if ~strcmp(flat(bData),'Compare To Constant2') || ~strcmp(flat(bEn),'Compare To Constant3') ...
   || ~strcmp(flat(bRst),'Compare To Constant1')
  error(['txfix_f3: %s is wired data<-%s enable<-%s reset<-%s, expected ' ...
         'Compare To Constant2/3/1'], flat(uders), flat(bData), flat(bEn), flat(bRst));
end
% polarity anchors (txfix_inject.py:patch_data_bits_fifo's two asserts):
%   Compare_To_Constant1_out1 = Delay3_out1 == 2'b00   (frameCount == 0)
%   Compare_To_Constant2_out1 = Delay3_out1 != 2'b00
% plus the guard the fix moves the clear inside:
%   Compare_To_Constant3_out1 = HDL_Counter2_out1 == 0 (sampleCount == 0)
assert_cmp(bRst,  '==', '0', 'F1 reset compare (frameCount==0)');
assert_cmp(bData, '~=', '0', 'F1 data compare (frameCount~=0)');
assert_cmp(bEn,   '==', '0', 'F1 enable compare (sampleCount==0)');

pos = get_param(uders,'Position');
add_block('simulink/Logic and Bit Operations/Logical Operator', [dbf '/TxF1BoundaryGuard'], ...
          'Operator','AND', 'Inputs','2', ...
          'Position', [pos(1)-90 pos(4)+30 pos(1)-50 pos(4)+70]);
delete_line(get_param(ph.Inport(3),'Line'));
add_line(dbf, hRst, ih([dbf '/TxF1BoundaryGuard'], 1), 'autorouting','on');
add_line(dbf, hEn,  ih([dbf '/TxF1BoundaryGuard'], 2), 'autorouting','on');   % branch off C3
add_line(dbf, oh([dbf '/TxF1BoundaryGuard'], 1), ih(uders, 3), 'autorouting','on');
fprintf('txfix_f3: F1 latch reset gated by the sampleCount==0 boundary\n');

% ---- F2: saturating frameCount (script edit) --------------------------------
% txfix_inject.py FSI_BODY_OLD -> FSI_BODY_NEW, transcribed.  The fcInc/fcDec
% pair is computed BEFORE pushCount/popCount advance, exactly as in the original
% (and in the injector), and the simultaneous push-wrap + pop-wrap case stays a
% no-op -- which is what the original's unguarded (+1 then -1) netted to.
chF2 = chart(fsi);
F2_OLD = sprintf([ ...
'   if (pushCount == dataBitsPerPacket-1) && push\n' ...
'       frameCount(:) = frameCount + 1;\n' ...
'   end\n' ...
'   if (popCount == dataBitsPerPacket-1) && pop\n' ...
'       frameCount(:) = frameCount - 1;\n' ...
'   end\n']);
F2_NEW = sprintf([ ...
'   %% TXFIX_F2: saturating frameCount -- the original +1/-1 pair wrapped 3->0 on a\n' ...
'   %% push-wrap and underflowed 0->3 on a pop-wrap.  A 3->0 wrap makes the pop-enable\n' ...
'   %% latch read frameCount==0 and abort pops.  Simultaneous push-wrap and pop-wrap\n' ...
'   %% stays a no-op, exactly as the original (+1 then -1) netted to.  3 is the full\n' ...
'   %% range of frameCount''s fi(0,0,2,0) type (the injector''s 2''b11).\n' ...
'   fcInc = (pushCount == dataBitsPerPacket-1) && push;\n' ...
'   fcDec = (popCount == dataBitsPerPacket-1) && pop;\n' ...
'   if fcInc && ~fcDec && (frameCount ~= 3)\n' ...
'       frameCount(:) = frameCount + 1;\n' ...
'   elseif fcDec && ~fcInc && (frameCount ~= 0)\n' ...
'       frameCount(:) = frameCount - 1;\n' ...
'   end\n']);
s = chF2.Script;
% the persistent names the gate harnesses tap (FSI frameCount) must survive
if ~contains(s, 'persistent pushCount popCount frameCount;')
  error('txfix_f3: %s does not declare the expected persistents', fsi);
end
chF2.Script = sub1(s, F2_OLD, F2_NEW, 'F2 frameCount inc/dec pair');
fprintf('txfix_f3: F2 frameCount saturates (no 3->0 wrap, no 0->3 underflow)\n');

% ---- F3a: dataReady = DataReadyPaceCmp & ~fullRAM ---------------------------
% txfix_inject.py:patch_bit_packetizer -- `assign dataReady =
% DataReadyPaceCmp_out1 & Logical_Operator2_out1;` where Logical_Operator2_out1
% is ` ~ Data_Bits_FIFO_fullRAM`.  The AND goes BEFORE the boolean Data Type
% Conversion that already sits between the pace compare and the `dataReady`
% Outport, so both operands are boolean (a Logical Operator fed one boolean and
% one converted type is a modelling error, not a fix).
if ~strcmp(get_param(notf,'Operator'), 'NOT')
  error('txfix_f3: %s is a %s, expected the NOT of fullRAM', flat(notf), get_param(notf,'Operator'));
end
hFull = src_of(ih(notf, 1));
if ~strcmp(flat(get_param(hFull,'Parent')), 'Data Bits FIFO')
  error('txfix_f3: %s is not driven by Data Bits FIFO (got %s)', flat(notf), ...
        flat(get_param(hFull,'Parent')));
end
fullPort = get_param(hFull,'PortNumber');
fullBlk  = find_system(dbf,'SearchDepth',1,lo,'all','BlockType','Outport', ...
                       'Port', num2str(fullPort));
if isempty(fullBlk)
  error('txfix_f3: %s has no outport numbered %d', dbf, fullPort);
end
fullName = get_param(fullBlk{1}, 'Name');
if ~strcmp(fullName, 'fullRAM')
  error('txfix_f3: %s taps Data Bits FIFO port %d (%s), expected fullRAM', ...
        flat(notf), fullPort, fullName);
end
lPace = get_param(ih(dtc, 1), 'Line');
if lPace == -1, error('txfix_f3: %s input is unconnected', dtc); end
hPace = get_param(lPace,'SrcPortHandle');
if ~strcmp(flat(get_param(hPace,'Parent')), 'DataReadyPaceCmp')
  error('txfix_f3: %s is fed by %s, expected DataReadyPaceCmp', dtc, ...
        flat(get_param(hPace,'Parent')));
end
ppos = get_param(pace,'Position');
add_block('simulink/Logic and Bit Operations/Logical Operator', [bp '/TxF3ReadyGate'], ...
          'Operator','AND', 'Inputs','2', ...
          'Position', [ppos(1)+70 ppos(4)+30 ppos(1)+110 ppos(4)+70]);
delete_line(lPace);
add_line(bp, hPace, ih([bp '/TxF3ReadyGate'], 1), 'autorouting','on');
add_line(bp, oh(notf, 1), ih([bp '/TxF3ReadyGate'], 2), 'autorouting','on');  % branch off ~fullRAM
add_line(bp, oh([bp '/TxF3ReadyGate'], 1), ih(dtc, 1), 'autorouting','on');
fprintf('txfix_f3: F3 dataReady gated by ~fullRAM\n');

% ---- F3b: saturating uint16 occupancy count (script edit) -------------------
% txfix_inject.py MF1_BODY_OLD -> MF1_BODY_NEW.  The --margin threshold change
% (F3b, 49279 -> 49263) is deliberately NOT applied: the shipped variant is F3.
chF3 = chart(mf1);
% count is fi(0,0,nextpow2(depth),0) with depth = dataBitsPerPacket*2 - 1: ufix16
% (65535) at f1536, ufix17 (131071) at f3072. The saturation literal must be the
% full range of THAT type, so it is derived here from the same expression.
cfgF3 = frame_config_k5();
SATW = nextpow2(cfgF3.PayloadBits*2 - 1); SATMAX = 2^SATW - 1;
F3_OLD = sprintf([ ...
'    if wr\n' ...
'        count(:) = count + 1;\n' ...
'    end\n' ...
'    if rd\n' ...
'        count(:) = count - 1;\n' ...
'    end\n']);
F3_NEW = sprintf([ ...
'    %% TXFIX_F3: saturating occupancy count.  The original wrapped at 65536 (and\n' ...
'    %% underflowed at 0), which is how the fullRAM back-pressure runaway ends: the\n' ...
'    %% producer keeps pushing until the uint16 count wraps and full drops again.\n' ...
'    %% Simultaneous wr+rd stays a no-op, exactly as the original netted to.  %d\n' ...
'    %% is the full range of count''s fi(0,0,nextpow2(depth),0) = ufix%d type at this\n' ...
'    %% rung (f1536: 65535 / the injector''s 16''hFFFF); nextpow2 is NOT re-evaluated here.\n' ...
'    cntInc = wr;\n' ...
'    cntDec = rd;\n' ...
'    if cntInc && ~cntDec && (count ~= %d)\n' ...
'        count(:) = count + 1;\n' ...
'    elseif cntDec && ~cntInc && (count ~= 0)\n' ...
'        count(:) = count - 1;\n' ...
'    end\n'], SATMAX, SATW, SATMAX);
s = chF3.Script;
% the width anchor: `count` is ufix16 only because depth is 49279 here
if ~contains(s, 'depth = dataBitsPerPacket*2 - 1;') || ~contains(s, 'persistent count;')
  error(['txfix_f3: %s is not the stock occupancy counter (no `depth = ' ...
         'dataBitsPerPacket*2 - 1;` / `persistent count;`) -- the 65535 ' ...
         'saturation literal is only valid for the ufix16 that expression gives'], mf1);
end
% F3b's ONLY other change is the fullRAM threshold, and in the chart that is the
% `full = (count > depth);` line, not the injector's `16'b1100000001111111` ->
% `...01101111` Verilog literal (an earlier revision of this overlay grepped for that
% binary literal here -- it can never appear in a MATLAB script, so the guard was
% dead code). A margin variant would compare against `depth - 16`, so the stock
% expression is asserted verbatim.
if ~contains(s, 'full = (count > depth);')
  error(['txfix_f3: %s does not carry the stock occupancy threshold ' ...
         '`full = (count > depth);` -- a chart with an F3b-style margin ' ...
         '(depth-16, the injector''s 49279 -> 49263) must not be reported as F3'], mf1);
end
chF3.Script = sub1(s, F3_OLD, F3_NEW, 'F3 count inc/dec pair');
fprintf('txfix_f3: F3 occupancy count saturates at %d (ufix%d; no wrap, no underflow)\n', SATMAX, SATW);

fprintf(['TXFIX_F3_OVERLAY_OK: F1 boundary-guarded pop latch, F2 saturating ' ...
         'frameCount, F3 dataReady & ~fullRAM + saturating occupancy count ' ...
         '(variant F3; F3b margin NOT applied)\n']);
end
