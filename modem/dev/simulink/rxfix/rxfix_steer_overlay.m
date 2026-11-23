function rxfix_steer_overlay(sys, base)
% rxfix_steer_overlay -- Rate Handle POP STEERING as a MODEL overlay (cleanup
% sub-project 3, task 5).  Formerly the netlist injections
% modem/fixes/rxfix_inject.py variants RXFIX_R4B (EMPTY-edge skip) and RXFIX_R4D
% (that skip PLUS the FULL-edge extra pop), which were two DIFFERENT netlists.
% Here BOTH branches are permanently present in ONE netlist and the FULL-edge one
% is armed at runtime by `fixctl` bit 5 (`sroSign`), so the deployed image can be
% switched between the two behaviours without a rebuild:
%
%   sro_sign = 0  ->  pop = popNom & ~skipEn                      (exactly R4B)
%   sro_sign = 1  ->  pop = (popNom & ~skipEn) | doExtra          (R4D)
%
% Env-gated: QPSK_RXFIX.  Read registers 0x234 / 0x238 / 0x25C.  The injector's
% two always-blocks (RH_POP_NEW_R4B, RH_POP_NEW_R4D) are the semantic truth and
% the MLFB below is a line-by-line transcription of the R4D one; the deltas are
% listed in .superpowers/sdd/2026-09-11-model-backport-sro-select/task-5-report.md.
%
%   r4Wit    {locked[31], skips[30:15], opens[14:0]}   -> 0x234  r4_wit
%   r4Extras {16'b0,      extras[15:0]}                -> 0x238  r4_extras
%   sroMode  {30'b0, extraArmed[1], sroSign[0]}        -> 0x25C  sro_mode
%
% ---------------------------------------------------------------------------
% THE POP EXPRESSION IS BUILT FROM PRIMITIVES, NOT INSIDE THE MLFB (deviation
% from the task brief, recorded).  The brief's MLFB returns `popEn` directly.
% Measured on this tree, HDL Coder gives a stateful MATLAB Function block an
% input delay-match register on SOME inputs and not others -- BfGridPace.v has
% `en_1 <= en` while `c` is used live, and RxW1Census.v has `freeze_1 <= freeze`
% -- and it wraps every output in `assign y = stateControl_2 ? y_1 :
% y_last_value`.  A delay-match landing on `popNom` or `validIn` would put the
% FIFO pop one enb beat late, i.e. silently change the data path (G1/G4 would
% fail and the cause would cost a 26-minute regen to find).  So the MLFB emits
% only the two REGISTERED ARMING LEVELS (skipEn, extraEn) plus the witnesses, and
% the pop is rebuilt outside it from Logical Operator / Compare To Constant
% primitives -- the same shape BfGridPace -> Compare To Constant -> Logical
% Operator -> FIFO.pop already has in this model, which is known to stay
% combinational.  doSkip/doExtra are still computed INSIDE for the counters and
% the once-per-window latches; if HDL Coder does delay-match an MLFB input, the
% cost is that the skip is NOTICED one beat after it fires.  That is inside the
% budget the injector's own comment sets ("up to one enb tick of arming latency
% against a 13-slot window"): nominal pops are 4 beats apart, so `skipEn` is
% still cleared before the next one and a double skip is impossible.
%
% THE TWO LONG PATHS ARE REGISTERED WITH Delay BLOCKS, NOT INSIDE THE MLFB.  The
% injector registers pcEndIn (`r4b_pcend_d`) and the occupancy compare
% (`r4b_occ_le8`) on arrival, "so the ONLY combinational path into the pop is the
% baseline's own guard".  Transcribing those as persistents would ALSO have left
% two algebraic loops in the model graph that the RTL does not have: Packet
% Controller -> Symbol Synchronizer closes a cycle in the Frequency and Time
% Synchronizer graph, and FIFO.w1Occ -> pop closes one inside Rate Handle.  A
% MATLAB Function block is direct-feedthrough, a Delay block is not, so each of
% those registers is a Delay block placed exactly where the injector's flop is:
% one enb beat, same position, and the loop is broken by construction.  The
% occupancy compare is then combinational inside the MLFB off the DELAYED value,
% which is bit-for-bit the same thing as the injector's registered compare of the
% live value.
%
% WHY sroSign ALSO GATES `extraArm` AND NOT ONLY `doExtra`.  With bit 5 clear the
% extra branch must be inert, not merely disconnected: on n_p10 / n_m2p5 the ring
% does reach occ >= 24, so an ungated `extraArm` would latch and 0x25C's
% extraArmed bit would read 1 on an R4B-configured image.  Gating the arm keeps
% FIXCTL=0 identical to R4B in state as well as in output.
%
% G0: the whole body early-returns when QPSK_RXFIX is unset.  Prerequisites are
% phase 2.20 (BEATFIX: `fixctl`, `FixCtlDec`, `FixCtlDecSroSignTerm`) and the W1
% overlay (FIFO's `w1Occ` outport is the TRUE registered occupancy tap); both are
% asserted by name.  AXI mapping: patch_hdlworkflow_rxfix.m.

if isempty(getenv('QPSK_RXFIX')), return; end
if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end
fprintf('=== rxfix_steer_overlay: Rate Handle pop steering (0x234/0x238/0x25C) ===\n');

lo  = 'LookUnderMasks';
rcv = [base '/Receiver'];
qrx = [rcv  '/QPSK Rx'];
fts = [qrx  '/Frequency and Time Synchronizer'];
ssy = [fts  '/Symbol Synchronizer'];
rh  = [ssy  '/Rate Handle'];
ff  = [rh   '/FIFO'];
pkc = [fts  '/Packet Controller'];

% ---- helpers (rxfix_w1_overlay.m idioms; see that file for keep_last/surface) --
  function n = leaf(pth)
    [~, n] = fileparts(pth);
  end
  function assert_block(pth)
    if isempty(find_system(fileparts(pth),'SearchDepth',1,lo,'all','Name',leaf(pth)))
      error('rxfix_steer: anchor missing: %s', pth);
    end
  end
  function h = oh(blk, k)
    p = get_param(blk,'PortHandles'); h = p.Outport(k);
  end
  function h = ih(blk, k)
    p = get_param(blk,'PortHandles'); h = p.Inport(k);
  end
  function p = next_outport(ss)
    p = numel(find_system(ss,'SearchDepth',1,lo,'all','BlockType','Outport')) + 1;
  end
  function p = next_inport(ss)
    p = numel(find_system(ss,'SearchDepth',1,lo,'all','BlockType','Inport')) + 1;
  end
  function idx = outport_by_name(ss, nm)
    b = find_system(ss,'SearchDepth',1,lo,'all','BlockType','Outport','Name',nm);
    if isempty(b), error('rxfix_steer: %s has no outport named %s', ss, nm); end
    idx = str2double(get_param(b{1},'Port'));
  end
  function idx = inport_by_name(ss, nm)
    b = find_system(ss,'SearchDepth',1,lo,'all','BlockType','Inport','Name',nm);
    if isempty(b), error('rxfix_steer: %s has no inport named %s', ss, nm); end
    idx = str2double(get_param(b{1},'Port'));
  end
  function keep_last(ss, names)
    % see rxfix_w1_overlay.m section (5) / modem/rxfix/README.md: the ddrcap and
    % ddrcap2 netlist instruments anchor on these ports being LAST.
    n = numel(find_system(ss,'SearchDepth',1,lo,'all','BlockType','Outport'));
    for j = 1:numel(names)
      b = find_system(ss,'SearchDepth',1,lo,'all','BlockType','Outport','Name',names{j});
      if isempty(b), error('rxfix_steer: %s has no outport named %s', ss, names{j}); end
      set_param(b{1}, 'Port', num2str(n));
    end
    for j = 1:numel(names)
      if outport_by_name(ss, names{j}) ~= n - numel(names) + j
        error('rxfix_steer: %s: %s did not land last (got %d of %d)', ss, names{j}, ...
              outport_by_name(ss, names{j}), n);
      end
    end
  end
  function h = surface(ss, srch, nm)
    p = next_outport(ss);
    add_block('built-in/Outport', [ss '/' nm], 'Port', num2str(p));
    add_line(ss, srch, ih([ss '/' nm], 1), 'autorouting','on');
    h = oh(ss, p);
  end

% ---- idempotency (probe by block name) --------------------------------------
if ~isempty(find_system(rh,'SearchDepth',1,lo,'all','Name','RxSteer'))
  fprintf('rxfix_steer: already applied\n');
  return;
end

% ---- anchors ----------------------------------------------------------------
need = {rcv, qrx, fts, ssy, rh, ff, pkc, [rh '/validIn'], ...
        [rh '/Compare To Constant'], [qrx '/FixCtlDec']};
for i = 1:numel(need), assert_block(need{i}); end
if isempty(find_system(qrx,'SearchDepth',1,lo,'all','Name','FixCtlDecSroSignTerm'))
  error(['rxfix_steer: FixCtlDec has no sroSign output (%s/FixCtlDecSroSignTerm ' ...
         'missing). QPSK_RXFIX must be set when beatfix_overlay.m runs (phase ' ...
         '2.20), not only at phase 2.21 -- see modem/fixes/build_base_tree.sh.'], qrx);
end
if isempty(find_system(ff,'SearchDepth',1,lo,'all','BlockType','Outport','Name','w1Occ'))
  error(['rxfix_steer: %s has no w1Occ outport -- rxfix_w1_overlay.m must run ' ...
         'FIRST (assemble phase 2.21 order); w1Occ is the TRUE registered ring ' ...
         'occupancy (Validate Input Push Pop''s Delay), the only occupancy this ' ...
         'steering may use.'], ff);
end

% ---- (1) the pop net: cut it, and capture popNom ----------------------------
% The nominal pop is whatever drives FIFO's `pop` port -- on this tree the
% `Logical Operator` AND of validIn and Compare To Constant (Rate_Handle.v:
% `assign Logical_Operator_out1 = validIn & Compare_To_Constant_out1;`, the same
% line rxfix_inject.py's RH_POP_OLD_R4B/R4D anchor on).  It is resolved by
% FOLLOWING the pop line rather than by block name, and the block it lands on is
% then asserted, so a rename upstream fails loudly instead of steering nothing.
pPop = inport_by_name(ff, 'pop');
lPop = get_param(ih(ff, pPop), 'Line');
if lPop == -1, error('rxfix_steer: %s pop input is unconnected', ff); end
hPopNom = get_param(lPop, 'SrcPortHandle');
srcBlk  = get_param(hPopNom, 'Parent');
if ~strcmp(get_param(srcBlk,'BlockType'), 'Logic')
  error(['rxfix_steer: %s pop is driven by %s (BlockType %s), not the Logical ' ...
         'Operator the injector re-defines'], ff, srcBlk, get_param(srcBlk,'BlockType'));
end
delete_line(lPop);

% ---- (2) phase: the mod-4 counter phase, tapped where the nominal pop taps it
% The injector's FULL-side mirror fires at `HDL_Counter_out1 == 2'b10`.  On this
% model the counter reaches the nominal-pop comparison through BEATFIX's
% BfGridPace mux (Rate_Handle.v: `assign Compare_To_Constant_out1 = y == 8'b0`),
% so the phase is tapped from whatever feeds `Compare To Constant` -- the SAME
% net the nominal pop is derived from, in every beatfix configuration.
cmp = [rh '/Compare To Constant'];
lCmp = get_param(ih(cmp, 1), 'Line');
if lCmp == -1, error('rxfix_steer: %s input is unconnected', cmp); end
hPhase = get_param(lCmp, 'SrcPortHandle');
% the FULL-side mirror phase is the OPPOSITE half of the mod-sps counter: 2 on the
% mod-4 counter (sps 4), 1 on the mod-2 counter (sps 2) -- sps/2 from the contract
cfgSteer = frame_config_k5();
add_block('simulink/Logic and Bit Operations/Compare To Constant', [rh '/RxSteerPhase2'], ...
          'relop','==', 'const',num2str(cfgSteer.Sps/2), 'OutDataTypeStr','boolean', ...
          'Position',[520 620 560 660]);
add_line(rh, hPhase, ih([rh '/RxSteerPhase2'], 1), 'autorouting','on');

% ---- (3) the two registered long paths (Delay blocks; see the header) -------
% occupancy: FIFO's w1Occ (ufix6) -> Delay -> Data Type Conversion (Stored
% Integer) -> the MLFB, which does the <=8 / >=24 compares combinationally.
hOcc = oh(ff, outport_by_name(ff, 'w1Occ'));
add_block('simulink/Discrete/Delay', [rh '/RxSteerOccDly'], ...
          'DelayLength','1', 'Position',[420 700 460 740]);
add_line(rh, hOcc, ih([rh '/RxSteerOccDly'], 1), 'autorouting','on');
add_block('simulink/Signal Attributes/Data Type Conversion', [rh '/RxSteerDtcOcc'], ...
          'OutDataTypeStr','uint8', 'ConvertRealWorld','Stored Integer (SI)', ...
          'Position',[500 700 540 740]);
add_line(rh, oh([rh '/RxSteerOccDly'],1), ih([rh '/RxSteerDtcOcc'],1), 'autorouting','on');

% pcEnd: Packet Controller's endOut, registered AT THE SOURCE (inside Frequency
% and Time Synchronizer) and then plumbed DOWN qrx-side blocks the way beatfix
% plumbs bfGridEn.  The Delay is at the FTS level and not in Rate Handle because
% that is where the cycle it breaks lives (PC -> SS -> CFC -> CS -> PD -> PC).
hEnd = oh(pkc, outport_by_name(pkc, 'endOut'));
add_block('simulink/Discrete/Delay', [fts '/RxSteerPcEndDly'], ...
          'DelayLength','1', 'Position',[1200 760 1240 800]);
add_line(fts, hEnd, ih([fts '/RxSteerPcEndDly'], 1), 'autorouting','on');

% ---- (4) sroSign: take over FixCtlDec's bit-5 Terminator --------------------
tb = [qrx '/FixCtlDecSroSignTerm'];
lh = get_param(ih(tb, 1), 'Line');
if lh ~= -1, delete_line(lh); end
delete_block(tb);

% ---- (5) plumb pcEnd and sroSign DOWN to Rate Handle ------------------------
% order: build the Rate Handle inports first, then the Symbol Synchronizer ones
% that feed them, then the FTS one that feeds sroSign (pcEnd already has its
% source inside FTS).
pRhPc  = next_inport(rh);
add_block('built-in/Inport', [rh '/sroPcEnd'], 'Port', num2str(pRhPc), 'OutDataTypeStr','boolean');
pRhSg  = next_inport(rh);
add_block('built-in/Inport', [rh '/sroSign'],  'Port', num2str(pRhSg), 'OutDataTypeStr','boolean');
pSsPc  = next_inport(ssy);
add_block('built-in/Inport', [ssy '/sroPcEnd'], 'Port', num2str(pSsPc), 'OutDataTypeStr','boolean');
pSsSg  = next_inport(ssy);
add_block('built-in/Inport', [ssy '/sroSign'],  'Port', num2str(pSsSg), 'OutDataTypeStr','boolean');
add_line(ssy, oh([ssy '/sroPcEnd'],1), ih(rh, pRhPc), 'autorouting','on');
add_line(ssy, oh([ssy '/sroSign'],1),  ih(rh, pRhSg), 'autorouting','on');
add_line(fts, oh([fts '/RxSteerPcEndDly'],1), ih(ssy, pSsPc), 'autorouting','on');
pFtsSg = next_inport(fts);
add_block('built-in/Inport', [fts '/sroSign'], 'Port', num2str(pFtsSg), 'OutDataTypeStr','boolean');
add_line(fts, oh([fts '/sroSign'],1), ih(ssy, pSsSg), 'autorouting','on');
% FixCtlDec output 5 IS sroSign: beatfix_overlay.m:114 parks outputs 4 and 5 on
% FixCtlDecW1FreezeTerm / FixCtlDecSroSignTerm in that order, and its decode script
% appends w1Freeze (bit 4) then sroSign (bit 5) after the three beatfix outputs.
add_line(qrx, oh([qrx '/FixCtlDec'], 5), ih(fts, pFtsSg), 'autorouting','on');

% ---- (6) the steering MLFB --------------------------------------------------
% A line-by-line transcription of rxfix_inject.py's RH_POP_NEW_R4D always block.
% STATEMENT ORDER IS THE RTL'S, NOT THE NATURAL ONE: Verilog non-blocking
% assignment means every right-hand side in that block reads the PRE-EDGE value,
% so the registered decision (f) is computed FIRST here, from the pre-edge
% win/wslot/skipDone/occ compares, and applied last.  Block (e) is written after
% (c)/(d) for the same reason the injector puts it there: a window opening on the
% same tick as a skip must win and start the new window clean.
add_block('simulink/User-Defined Functions/MATLAB Function', [rh '/RxSteer'], ...
          'Position', [620 560 780 760]);
S = sfroot; ch = S.find('Path', [rh '/RxSteer'], '-isa', 'Stateflow.EMChart');
ch.Script = sprintf([ ...
'function [skipEn, extraEn, r4Wit, r4Extras, sroMode] = fcn(validIn, popNom, occ, phase2, pcEnd, sroSign)\n' ...
'%%#codegen\n' ...
'persistent win wslot skipDone extraDone skipArm extraArm frames skips opens extras pcPend\n' ...
'if isempty(win)\n' ...
'  win = false; wslot = uint8(0); skipDone = false; extraDone = false; pcPend = uint16(0);\n' ...
'  skipArm = false; extraArm = false; frames = uint8(0);\n' ...
'  skips = uint16(0); opens = uint16(0); extras = uint16(0);\n' ...
'end\n' ...
'%% wires off the PRE-edge registers (the injector''s assign lines)\n' ...
'locked  = frames == uint8(8);\n' ...
'occLe8  = occ <= uint8(8);\n' ...
'occGe24 = occ >= uint8(24);\n' ...
'skipEn  = skipArm;\n' ...
'extraEn = extraArm;\n' ...
'doSkip  = skipArm & popNom;\n' ...
'doExtra = extraArm & validIn & phase2 & sroSign;\n' ...
'r4Wit    = bitor(bitor(bitshift(uint32(locked), 31), bitshift(uint32(skips), 15)), uint32(opens));\n' ...
'r4Extras = uint32(extras);\n' ...
'sroMode  = bitor(bitshift(uint32(extraArm), 1), uint32(sroSign));\n' ...
'%% (f) THE REGISTERED DECISION -- pre-edge state only, applied at the end\n' ...
'if doSkip\n' ...
'  nSkipArm = false;\n' ...
'else\n' ...
'  nSkipArm = locked & win & occLe8 & ~skipDone & (wslot <= uint8(12));\n' ...
'end\n' ...
'if doExtra\n' ...
'  nExtraArm = false;\n' ...
'else\n' ...
'  nExtraArm = locked & win & occGe24 & ~extraDone & (wslot <= uint8(12)) & sroSign;\n' ...
'end\n' ...
'%% (b) LOCK: eight pcEnd pulses since reset\n' ...
'if pcEnd && ~locked\n' ...
'  frames = frames + uint8(1);\n' ...
'end\n' ...
'%% (c) the skip / the extra, and their witnesses (skips/extras/opens WRAP;\n' ...
'%%     frames does NOT -- it is capped by its own lock gate at 8, never 15)\n' ...
'if doSkip\n' ...
'  if skips == uint16(65535), skips = uint16(0); else, skips = skips + uint16(1); end\n' ...
'  skipDone = true;\n' ...
'end\n' ...
'if doExtra\n' ...
'  if extras == uint16(65535), extras = uint16(0); else, extras = extras + uint16(1); end\n' ...
'  extraDone = true;\n' ...
'end\n' ...
'%% (d) one window slot per NOMINAL pop opportunity, taken or not\n' ...
'if win && popNom\n' ...
'  if wslot >= uint8(13)\n' ...
'    win = false;\n' ...
'  else\n' ...
'    wslot = wslot + uint8(1);\n' ...
'  end\n' ...
'end\n' ...
'%% (e) a pcEnd OPENS the window -- last, so it wins over (c) and (d).\n' ...
'%% PCEND_LEAD_POPS > 0 (sps 2): open it PCEND_LEAD_POPS nominal pops after pcEnd instead,\n' ...
'%% i.e. SlotsPerFrame - lead before the NEXT pcEnd, so the skip/extra lands in the\n' ...
'%% filler+preamble of the frame entering the ring and not in its data (see overlay header).\n' ...
'openNow = false;\n' ...
'if pcEnd\n' ...
'  if uint16(PCEND_LEAD_POPS) == uint16(0), openNow = true; else, pcPend = uint16(PCEND_LEAD_POPS); end\n' ...
'elseif pcPend > uint16(0) && popNom\n' ...
'  pcPend = pcPend - uint16(1);\n' ...
'  if pcPend == uint16(0), openNow = true; end\n' ...
'end\n' ...
'if openNow\n' ...
'  win = true; wslot = uint8(0); skipDone = false; extraDone = false;\n' ...
'  if opens == uint16(32767), opens = uint16(0); else, opens = opens + uint16(1); end\n' ...
'end\n' ...
'skipArm = nSkipArm;\n' ...
'extraArm = nExtraArm;\n']);
% ---- window placement (sp4 rung, 2026-09-21) ---------------------------------------
% At sps 2 the ring -> Packet Controller pipeline is ~94 symbols long, so the 13-slot
% window opened right at pcEnd sits ~94 symbols INTO the data of the frame entering the
% ring; every skip/extra there desynchronises that frame (R4DR1 +10 ppm: 30 % loss, one
% frame per extra). Measured on the model tree with the window delayed by N nominal
% pops (obj_byte_sro_rxfix4dr1_model_20, n_p10, 130 frames, 14 extras):
%   N = 0 / 30 / 100 / 300 / 1000 / 3000 / 24600 / 24620  -> 20-23 frames lost
%   N = 24500 -> 3 lost, 24540 -> 0 lost, 24560 -> 19, 24580 -> 3
% i.e. the harmless zone (filler 24 + preamble 26 symbols) is SlotsPerFrame - [84..119]
% pops after pcEnd. Lead = 100 pops before the next pcEnd (zone centre). sps 4/8 keep 0
% (window at pcEnd, the shipped f1536 behaviour, bit-identical).
cfgS = frame_config_k5();
if cfgS.Sps == 2
    PCEND_LEAD_POPS = cfgS.SlotsPerFrame - 100;
else
    PCEND_LEAD_POPS = 0;
end
ch.Script = strrep(ch.Script, 'PCEND_LEAD_POPS', num2str(PCEND_LEAD_POPS));

ins = {oh([rh '/validIn'],1), hPopNom, oh([rh '/RxSteerDtcOcc'],1), ...
       oh([rh '/RxSteerPhase2'],1), oh([rh '/sroPcEnd'],1), oh([rh '/sroSign'],1)};
for k = 1:numel(ins)
  add_line(rh, ins{k}, ih([rh '/RxSteer'], k), 'autorouting','on');
end

% ---- (7) rebuild the pop from primitives -------------------------------------
%   Logical_Operator_out1 = (popNom & ~skipEn) | doExtra
add_block('simulink/Logic and Bit Operations/Logical Operator', [rh '/RxSteerNotSkip'], ...
          'Operator','NOT', 'Inputs','1', 'Position',[820 560 860 600]);
% sps-2 occupancy floor (2026-09-19): at 2 samples per symbol the nominal pop cadence
% (one per mod-2 counter cycle) equals the push cadence beat for beat, so the ring
% can settle at occupancy 0/1 -- and a pop on the empty ring returns the slot
% written 32 symbols ago (the sps-2 sweep: 36 %% of the popped symbols were
% ring-stale in the two cells whose loopback delay was an integer number of
% symbols; the R4B EMPTY-edge skip only arms after 8 frames of lock and once per
% window, far too slow). Popping only while the one-beat-old occupancy is >= 2
% raises the steady-state floor to 1-2 symbols (one extra symbol of latency, no
% data change) and makes the empty pop impossible. sps 4/8 keep the shipped
% two-input AND (their pop cadence leaves the ring at >= 1 by construction).
nPopIn = 2; if cfgSteer.Sps == 2, nPopIn = 3; end
add_block('simulink/Logic and Bit Operations/Logical Operator', [rh '/RxSteerSkipAnd'], ...
          'Operator','AND', 'Inputs',num2str(nPopIn), 'Position',[900 560 940 600]);
if cfgSteer.Sps == 2
    add_block('simulink/Logic and Bit Operations/Compare To Constant', [rh '/RxSteerOccFloor'], ...
              'relop','>=', 'const','2', 'OutDataTypeStr','boolean', 'Position',[820 700 860 740]);
    add_line(rh, oh([rh '/RxSteerDtcOcc'],1), ih([rh '/RxSteerOccFloor'],1), 'autorouting','on');
    add_line(rh, oh([rh '/RxSteerOccFloor'],1), ih([rh '/RxSteerSkipAnd'],3), 'autorouting','on');
end
add_block('simulink/Logic and Bit Operations/Logical Operator', [rh '/RxSteerExtraAnd'], ...
          'Operator','AND', 'Inputs','4', 'Position',[900 640 940 700]);
add_block('simulink/Logic and Bit Operations/Logical Operator', [rh '/RxSteerPopOr'], ...
          'Operator','OR',  'Inputs','2', 'Position',[980 600 1020 650]);
add_line(rh, oh([rh '/RxSteer'],1),        ih([rh '/RxSteerNotSkip'],1), 'autorouting','on');
add_line(rh, hPopNom,                      ih([rh '/RxSteerSkipAnd'],1), 'autorouting','on');
add_line(rh, oh([rh '/RxSteerNotSkip'],1), ih([rh '/RxSteerSkipAnd'],2), 'autorouting','on');
add_line(rh, oh([rh '/RxSteer'],2),        ih([rh '/RxSteerExtraAnd'],1), 'autorouting','on');
add_line(rh, oh([rh '/validIn'],1),        ih([rh '/RxSteerExtraAnd'],2), 'autorouting','on');
add_line(rh, oh([rh '/RxSteerPhase2'],1),  ih([rh '/RxSteerExtraAnd'],3), 'autorouting','on');
add_line(rh, oh([rh '/sroSign'],1),        ih([rh '/RxSteerExtraAnd'],4), 'autorouting','on');
add_line(rh, oh([rh '/RxSteerSkipAnd'],1), ih([rh '/RxSteerPopOr'],1), 'autorouting','on');
add_line(rh, oh([rh '/RxSteerExtraAnd'],1),ih([rh '/RxSteerPopOr'],2), 'autorouting','on');
add_line(rh, oh([rh '/RxSteerPopOr'],1),   ih(ff, pPop), 'autorouting','on');

% ---- (8) the three witness words, surfaced Rate Handle -> composite ---------
% Port names on TxRxComposite are the AXI register names patch_hdlworkflow_rxfix.m
% maps (0x234/0x238/0x25C).  The instrument port tails must stay last at every
% level (modem/rxfix/README.md): beatobs at Symbol Synchronizer, beatfix at QPSK
% Rx / Receiver / the composite -- and the handles re-resolved after each move.
wnm  = {'r4_wit','r4_extras','sro_mode'};
spec = cell(1,3);
for k = 1:3
  spec{k} = surface(rh, oh([rh '/RxSteer'], k+2), wnm{k});
end
bo = {'beatobsRhCtr','beatobsPush','beatobsPop'};
for k = 1:3
  spec{k} = surface(ssy, spec{k}, wnm{k});
end
if ~isempty(find_system(ssy,'SearchDepth',1,lo,'all','BlockType','Outport','Name','beatobsPop'))
  keep_last(ssy, bo);
end
for k = 1:3
  spec{k} = oh(ssy, outport_by_name(ssy, wnm{k}));
end
bfx = {'beatfix_viol_count','beatfix_viol_latch'};
for k = 1:3
  spec{k} = surface(fts, spec{k}, wnm{k});
end
for lvl = {qrx, rcv, base}
  for k = 1:3
    surface(lvl{1}, spec{k}, wnm{k});
  end
  keep_last(lvl{1}, bfx);
  for k = 1:3
    spec{k} = oh(lvl{1}, outport_by_name(lvl{1}, wnm{k}));
  end
end

fprintf(['RXFIX_STEER_OVERLAY_OK: RxSteer in Rate Handle; pop = (popNom & ~skipEn) ' ...
         '| doExtra, extra armed by fixctl bit 5; %s (0x234/0x238/0x25C)\n'], ...
        strjoin(wnm, ' '));
end
