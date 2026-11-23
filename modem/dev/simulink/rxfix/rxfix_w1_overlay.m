function rxfix_w1_overlay(sys, base)
% rxfix_w1_overlay -- W1 RX ring witness + per-stage valid census, as a MODEL
% overlay (cleanup sub-project 3, task 4).  Formerly the netlist injector
% modem/fixes/rxfix_inject.py's RXFIX_W1 variant (module `rh_w1_census`).
% Env-gated: QPSK_RXFIX.  Registers 0x214-0x230, freeze = fixctl bit 4 (a LEVEL).
% Semantics: docs/evidence/rxfix/W1_REGMAP.md; the injector is the bit-layout truth.
%
%   witA = {16'b0, occ[5:0], pushPtr[4:0], popPtr[4:0]}          -> 0x214
%   witB = {push_on_full[15:0], pop_on_empty[15:0]}              -> 0x218
%   cSS cRH cCFC cCS cPD cPC  six 32-bit WRAPPING valid counters -> 0x21C..0x230
%
% READ-ONLY INSTRUMENT.  Every signal is a tap; no existing line is re-driven, so
% the delivered byte-plane stream is unchanged by construction -- which is what
% the Verilator gate's Gate A asserts (modem/gates/build_sro_w1.legs).
%
% WHERE IT LIVES, AND WHY NOT IN Rate Handle (deviation from the task brief,
% recorded).  The census is added to `Frequency and Time Synchronizer`, which is
% exactly where rxfix_inject.py instantiates `rh_w1_census`
% (patch_freq_time_sync_w1).  Four of the six census stages -- Coarse Frequency
% Compensator, Carrier Synchronizer, Preamble Detector and Packet Controller --
% are CHILDREN OF FTS (resolved from the generated RTL's `Source Path` headers
% and confirmed by find_system on the model; the brief's claim that Packet
% Controller sits in `QPSK Rx` is not what the model says).  Putting the census
% in Rate Handle would mean driving those four valids BACKWARDS into Symbol
% Synchronizer -> Rate Handle, i.e. an RH -> CFC -> CS -> PD -> PC -> RH cycle in
% the FTS block graph.  At FTS the census is a pure sink with no feedback edge at
% all.  HDL Coder still emits RxW1Census.v (the file is named after the block),
% which is what modem/rtl_sim/tree_marker.sh checks.
%
% WIRING IS BY PORT HANDLE, not by 'Name/port' strings: several of the blocks
% this overlay taps have NEWLINES in their names (`Logical\nOperator3` drives
% `pop on empty FIFO`), which no add_line string form can express.
%
% G0: the whole body early-returns when QPSK_RXFIX is unset (framestat idiom), so
% an un-gated build is unaffected.  Every structural assumption is asserted; any
% miss is a hard error naming the path.  AXI mapping: patch_hdlworkflow_rxfix.m.

if isempty(getenv('QPSK_RXFIX')), return; end
if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end
fprintf('=== rxfix_w1_overlay: RX ring witness + valid census (0x214-0x230) ===\n');

lo  = 'LookUnderMasks';
rcv = [base '/Receiver'];
qrx = [rcv  '/QPSK Rx'];
fts = [qrx  '/Frequency and Time Synchronizer'];
ssy = [fts  '/Symbol Synchronizer'];
rh  = [ssy  '/Rate Handle'];
ff  = [rh   '/FIFO'];
vip = [ff   '/Validate Input Push Pop'];
cfc = [fts  '/Coarse Frequency Compensator'];
csy = [fts  '/Carrier Synchronizer'];
pdt = [fts  '/Preamble Detector'];
pkc = [fts  '/Packet Controller'];

% ---- helpers (beatobs_overlay.m / beatfix_overlay.m idioms) ----------------
  function n = leaf(pth)
    [~, n] = fileparts(pth);   % Simulink paths: fileparts splits on '/'
  end
  function assert_block(pth)
    if isempty(find_system(fileparts(pth),'SearchDepth',1,lo,'all','Name',leaf(pth)))
      error('rxfix_w1: anchor missing: %s', pth);
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
    if isempty(b), error('rxfix_w1: %s has no outport named %s', ss, nm); end
    idx = str2double(get_param(b{1},'Port'));
  end
  function h = signal_src(ss, nm)
    % source port handle of the NAMED signal `nm` inside ss.  The two ring edge
    % events are signal LABELS on Logical Operator outputs inside Validate Input
    % Push Pop (Verilog wires pop_on_empty_FIFO / push_on_full_FIFO; the model
    % spells them with spaces), not Outports -- find_system by block Name cannot
    % see them.  Both spellings are accepted; the label is asserted.
    alt = strrep(nm, '_', ' ');
    L = find_system(ss,'FindAll','on',lo,'all','type','line','Name',nm);
    if isempty(L)
      L = find_system(ss,'FindAll','on',lo,'all','type','line','Name',alt);
    end
    if isempty(L)
      error('rxfix_w1: %s has no signal named %s (or %s)', ss, nm, alt);
    end
    h = get_param(L(1),'SrcPortHandle');   % branches share one source
  end
  function keep_last(ss, names)
    % move the named Outports back to the END of ss's port list, in order.  See
    % section (5) for why this is load-bearing.  Simulink ROTATES rather than
    % swaps: setting a block's Port to N moves it there and shifts everything
    % between its old and new index toward the old one (measured on R2025b:
    % o1..o4, set o1 -> 4, gives o1=4 o2=1 o3=2 o4=3).  So each name is sent to
    % the LAST index in turn -- after k of them, name k sits at n-(numel-k).
    n = numel(find_system(ss,'SearchDepth',1,lo,'all','BlockType','Outport'));
    for j = 1:numel(names)
      b = find_system(ss,'SearchDepth',1,lo,'all','BlockType','Outport','Name',names{j});
      if isempty(b), error('rxfix_w1: %s has no outport named %s', ss, names{j}); end
      set_param(b{1}, 'Port', num2str(n));
    end
    for j = 1:numel(names)
      if outport_by_name(ss, names{j}) ~= n - numel(names) + j
        error('rxfix_w1: %s: %s did not land last (got %d of %d)', ss, names{j}, ...
              outport_by_name(ss, names{j}), n);
      end
    end
  end
  function h = surface(ss, srch, nm)
    % add Outport `nm` to subsystem ss driven by srch, and return the port handle
    % by which the PARENT graph reaches it.
    p = next_outport(ss);
    add_block('built-in/Outport', [ss '/' nm], 'Port', num2str(p));
    add_line(ss, srch, ih([ss '/' nm], 1), 'autorouting','on');
    h = oh(ss, p);
  end

% ---- idempotency (probe by block name, framestat idiom) --------------------
if ~isempty(find_system(fts,'SearchDepth',1,lo,'all','Name','RxW1Census'))
  fprintf('rxfix_w1: already applied\n');
  return;
end

% ---- anchors: every block this overlay touches -----------------------------
need = {rcv, qrx, fts, ssy, rh, ff, vip, [vip '/Delay'], ...
        [ff '/Push Counter'], [ff '/Pop Counter'], [rh '/strobe'], ...
        cfc, csy, pdt, pkc, [qrx '/FixCtlDec']};
for i = 1:numel(need), assert_block(need{i}); end

% ---- (1) ring witnesses, surfaced UP to the FTS graph ----------------------
% occ is the TRUE registered occupancy (Validate Input Push Pop's `Delay`, the
% ufix6 `Delay_out1` the gate's reference taps as occTrue).  It is NOT the
% pointer delta W1_REGMAP.md section 1 warns about: a delta cannot tell occupancy
% 0 from 32, which is half the reason W1 exists.  (`Validate Input Push Pop` does
% carry an unconnected `numEntries` Outport -- deliberately NOT reused: nothing in
% the generated RTL says whether it is fed by the registered Delay or by the
% pre-delay `count`, and a one-beat error there fails Gate B on every row.)
sOcc = surface(vip, oh([vip '/Delay'], 1),            'w1Occ');
sPoe = surface(vip, signal_src(vip,'pop_on_empty_FIFO'), 'w1PopEmpty');
sPuf = surface(vip, signal_src(vip,'push_on_full_FIFO'), 'w1PushFull');
sOcc = surface(ff, sOcc, 'w1Occ');
sPoe = surface(ff, sPoe, 'w1PopEmpty');
sPuf = surface(ff, sPuf, 'w1PushFull');
sPsh = surface(ff, oh([ff '/Push Counter'], 1), 'w1PushPtr');
sPop = surface(ff, oh([ff '/Pop Counter'],  1), 'w1PopPtr');
% census stage (a): the ring PUSH REQUEST = Rate Handle's `strobe` input
% (Symbol_Synchronizer's Delay2_out1; the gate's reference taps
% u_Rate_Handle.strobe -- the same net).
sStr = surface(rh, oh([rh '/strobe'], 1), 'w1Strobe');
for lvl = {rh, ssy}
  sOcc = surface(lvl{1}, sOcc, 'w1Occ');
  sPoe = surface(lvl{1}, sPoe, 'w1PopEmpty');
  sPuf = surface(lvl{1}, sPuf, 'w1PushFull');
  sPsh = surface(lvl{1}, sPsh, 'w1PushPtr');
  sPop = surface(lvl{1}, sPop, 'w1PopPtr');
  if ~strcmp(lvl{1}, rh)
    sStr = surface(lvl{1}, sStr, 'w1Strobe');
  end
end

% BEATOBS'S SYMBOL SYNCHRONIZER PORTS MUST STAY LAST, for the same reason the
% beatfix ones must at section (5): modem/instruments/ddrcap2/ddrcap2_inject.py:214
% anchors its FTS patch on `.beatobsPop(Symbol_Synchronizer_beatobsPop)  // ufix5`
% being the LAST pin of the u_Symbol_Synchronizer instantiation (measured:
% BASE_REGEN_INJECT_FAILED stage=ddrcap2 naming exactly that anchor).  The six
% handles above are captured before the renumber, so they are re-resolved by name.
bo = {'beatobsRhCtr','beatobsPush','beatobsPop'};
if ~isempty(find_system(ssy,'SearchDepth',1,lo,'all','BlockType','Outport','Name','beatobsPop'))
  keep_last(ssy, bo);
end
sOcc = oh(ssy, outport_by_name(ssy,'w1Occ'));
sPoe = oh(ssy, outport_by_name(ssy,'w1PopEmpty'));
sPuf = oh(ssy, outport_by_name(ssy,'w1PushFull'));
sPsh = oh(ssy, outport_by_name(ssy,'w1PushPtr'));
sPop = oh(ssy, outport_by_name(ssy,'w1PopPtr'));
sStr = oh(ssy, outport_by_name(ssy,'w1Strobe'));

% ---- (2) the six per-stage valids, all local to the FTS graph ---------------
% (b) is Symbol Synchronizer's validOut, which IS Rate_Handle_validOut verbatim
% (Symbol_Synchronizer.v: `assign validOut = Rate_Handle_validOut;`).
vRH  = oh(ssy, outport_by_name(ssy, 'validOut'));
vCFC = oh(cfc, outport_by_name(cfc, 'validOut'));
vCS  = oh(csy, outport_by_name(csy, 'validOut'));
vPD  = oh(pdt, outport_by_name(pdt, 'validOut'));
vPC  = oh(pkc, outport_by_name(pkc, 'validOut'));

% ---- (3) freeze: FixCtlDec's w1Freeze (fixctl bit 4), plumbed DOWN one level
% beatfix_overlay.m emits the w1Freeze/sroSign outputs and parks them on
% Terminators ONLY when QPSK_RXFIX is set (G0: an un-gated build must stay
% byte-identical HDL).  QPSK_RXFIX is read by beatfix_overlay.m at phase 2.20,
% BEFORE this overlay runs at 2.21, so the variable has to be set for the whole
% assemble -- which is what modem/fixes/build_base_tree.sh does.  If it was set
% late, the Terminator is absent and the assert below says exactly that.
tb = [qrx '/FixCtlDecW1FreezeTerm'];
if isempty(find_system(qrx,'SearchDepth',1,lo,'all','Name','FixCtlDecW1FreezeTerm'))
    error(['rxfix_w1: FixCtlDec has no w1Freeze output (%s missing). ' ...
           'QPSK_RXFIX must be set when beatfix_overlay.m runs (phase 2.20), ' ...
           'not only at phase 2.21 -- see modem/fixes/build_base_tree.sh.'], tb);
end
lh = get_param(ih(tb, 1), 'Line');
if lh ~= -1, delete_line(lh); end
delete_block(tb);
pFtsI = next_inport(fts);
add_block('built-in/Inport', [fts '/w1Freeze'], 'Port', num2str(pFtsI), ...
          'OutDataTypeStr','boolean');
add_line(qrx, oh([qrx '/FixCtlDec'], 4), ih(fts, pFtsI), 'autorouting','on');

% ---- (4) the census MLFB ----------------------------------------------------
% A cycle-accurate transcription of rh_w1_census (rxfix_inject.py:1367-1452).
% THE ORDER MATTERS and is not the obvious one -- the gate driver (sim_w1.cpp)
% compares the registers against an independent reference on EVERY enb beat:
%   * `assign witA = sA` means the value visible during beat k is the shadow
%     CAPTURED at edge k-1 -> emit the outputs FIRST, from the persistent shadow.
%   * `wB = {pofCnt, poeCnt}` is a wire off the PRE-edge registers, and
%     `sSS <= lSS` is nonblocking -> the shadow takes the PRE-increment live
%     counter.  So capture the shadow BEFORE incrementing anything.
%   * every counter WRAPS (W1_REGMAP.md section 1: "read as deltas, never as
%     absolutes") -- MATLAB integer arithmetic SATURATES, so each increment is
%     written as an explicit wrap.
% freeze is a level: the shadows hold while the live counters keep running.
add_block('simulink/User-Defined Functions/MATLAB Function', [fts '/RxW1Census'], ...
          'Position', [900 500 1040 700]);
S = sfroot; ch = S.find('Path', [fts '/RxW1Census'], '-isa', 'Stateflow.EMChart');
ch.Script = sprintf([ ...
'function [witA, witB, cSS, cRH, cCFC, cCS, cPD, cPC] = fcn(occ, pushPtr, popPtr, popEmpty, pushFull, vSS, vRH, vCFC, vCS, vPD, vPC, freeze)\n' ...
'%%#codegen\n' ...
'persistent poe pof lSS lRH lCFC lCS lPD lPC sA sB sSS sRH sCFC sCS sPD sPC\n' ...
'if isempty(poe)\n' ...
'  poe = uint16(0); pof = uint16(0);\n' ...
'  lSS = uint32(0); lRH = uint32(0); lCFC = uint32(0); lCS = uint32(0); lPD = uint32(0); lPC = uint32(0);\n' ...
'  sA = uint32(0); sB = uint32(0);\n' ...
'  sSS = uint32(0); sRH = uint32(0); sCFC = uint32(0); sCS = uint32(0); sPD = uint32(0); sPC = uint32(0);\n' ...
'end\n' ...
'%% outputs = the shadow registered on the PREVIOUS enb beat (assign witA = sA)\n' ...
'witA = sA; witB = sB;\n' ...
'cSS = sSS; cRH = sRH; cCFC = sCFC; cCS = sCS; cPD = sPD; cPC = sPC;\n' ...
'%% wA/wB: wires off THIS beat inputs and the PRE-edge edge counters\n' ...
'wA = bitor(bitor(bitshift(bitand(uint32(occ), uint32(63)), 10), bitshift(bitand(uint32(pushPtr), uint32(31)), 5)), bitand(uint32(popPtr), uint32(31)));\n' ...
'wB = bitor(bitshift(uint32(pof), 16), uint32(poe));\n' ...
'%% freeze is a LEVEL: hold every shadow while the live counters keep running\n' ...
'if ~freeze\n' ...
'  sA = wA; sB = wB;\n' ...
'  sSS = lSS; sRH = lRH; sCFC = lCFC; sCS = lCS; sPD = lPD; sPC = lPC;\n' ...
'end\n' ...
'%% live counters, incremented AFTER the capture; all of them WRAP\n' ...
'if popEmpty\n' ...
'  if poe == uint16(65535), poe = uint16(0); else, poe = poe + uint16(1); end\n' ...
'end\n' ...
'if pushFull\n' ...
'  if pof == uint16(65535), pof = uint16(0); else, pof = pof + uint16(1); end\n' ...
'end\n' ...
'if vSS\n' ...
'  if lSS == uint32(4294967295), lSS = uint32(0); else, lSS = lSS + uint32(1); end\n' ...
'end\n' ...
'if vRH\n' ...
'  if lRH == uint32(4294967295), lRH = uint32(0); else, lRH = lRH + uint32(1); end\n' ...
'end\n' ...
'if vCFC\n' ...
'  if lCFC == uint32(4294967295), lCFC = uint32(0); else, lCFC = lCFC + uint32(1); end\n' ...
'end\n' ...
'if vCS\n' ...
'  if lCS == uint32(4294967295), lCS = uint32(0); else, lCS = lCS + uint32(1); end\n' ...
'end\n' ...
'if vPD\n' ...
'  if lPD == uint32(4294967295), lPD = uint32(0); else, lPD = lPD + uint32(1); end\n' ...
'end\n' ...
'if vPC\n' ...
'  if lPC == uint32(4294967295), lPC = uint32(0); else, lPC = lPC + uint32(1); end\n' ...
'end\n']);

% inputs, in the MLFB's argument order.  The three ring quantities go through
% Data Type Conversion (Stored Integer) blocks so the fixed-point ufix6/ufix5
% nets arrive as plain unsigned integers -- beatobs_overlay.m's "DTC-SI isolate
% every MLFB input" rule; the booleans need no conversion.
cen = [fts '/RxW1Census'];
dtc  = {'RxW1DtcOcc','RxW1DtcPush','RxW1DtcPop'};
dsrc = {sOcc, sPsh, sPop};
dh   = cell(1,3);
for k = 1:3
  add_block('simulink/Signal Attributes/Data Type Conversion', [fts '/' dtc{k}], ...
            'OutDataTypeStr','uint8', 'ConvertRealWorld','Stored Integer (SI)');
  add_line(fts, dsrc{k}, ih([fts '/' dtc{k}], 1), 'autorouting','on');
  dh{k} = oh([fts '/' dtc{k}], 1);
end
ins = [dh, {sPoe, sPuf, sStr, vRH, vCFC, vCS, vPD, vPC, oh([fts '/w1Freeze'], 1)}];
if numel(ins) ~= 12, error('rxfix_w1: census input count %d ~= 12', numel(ins)); end
for k = 1:12
  add_line(fts, ins{k}, ih(cen, k), 'autorouting','on');
end

% ---- (5) the eight words, surfaced FTS -> QPSK Rx -> Receiver -> composite --
% Port names on TxRxComposite are the AXI register names patch_hdlworkflow_rxfix.m
% maps (0x214..0x230) and the names modem/rtl_sim/wrap_byte_w1_model.v taps.
wnm = {'w1_wita','w1_witb','w1_ss','w1_rh','w1_cfc','w1_cs','w1_pd','w1_pc'};
spec = cell(1,8);
for k = 1:8
  spec{k} = surface(fts, oh(cen, k), wnm{k});
end
% THE BEATFIX PORTS MUST STAY LAST.  modem/instruments/ddrcap/ddrcap_inject.py --
% the netlist instrument that runs on this model's generated HDL afterwards
% (build_base_tree.sh stage 4) -- anchors its QPSK_Rx (:309) and Receiver (:378,
% :395) patches on the literal `beatfix_viol_count,\n beatfix_viol_latch);` port
% tail and on that same pair being the last two pins of the u_QPSK_Rx /
% u_Receiver instantiations, and patch_composite (:602) does the same for
% u_Receiver.  Simply appending the eight W1 words breaks all of them: measured,
% BASE_REGEN_INJECT_FAILED stage=ddrcap "Receiver u_QPSK_Rx instantiation not
% patched" plus the ddrcap2 follow-on.  So at every level that has them the two
% beatfix ports are moved back to the end and the W1 handles re-resolved by name.
bfx = {'beatfix_viol_count','beatfix_viol_latch'};
for lvl = {qrx, rcv, base}
  for k = 1:8
    surface(lvl{1}, spec{k}, wnm{k});
  end
  keep_last(lvl{1}, bfx);
  for k = 1:8
    spec{k} = oh(lvl{1}, outport_by_name(lvl{1}, wnm{k}));
  end
end

fprintf(['RXFIX_W1_OVERLAY_OK: RxW1Census in FTS; witA/witB + six wrapping valid ' ...
         'counters on %s (0x214-0x230), freeze = fixctl bit 4\n'], strjoin(wnm, ' '));
end
