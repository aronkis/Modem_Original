function rxfix_r1_overlay(sys, base)
% rxfix_r1_overlay -- the Preamble Detector realignment FIFO's pop indexed by
% OCCUPANCY instead of by enb ticks (cleanup sub-project 3, task 6).  Formerly the
% netlist injection modem/fixes/rxfix_inject.py variant RXFIX_R1, whose two lines
% are the semantic truth of this file:
%
%     - assign Delay10_out1 = Delay10_reg[49331];
%     + assign Delay10_full = FIFO_numEntries == 14'd12333;   (f1536; f3072: 15'd24634)
%     + assign Delay10_out1 = Delay8_out1 & Delay10_full;
%
% Baseline: the realignment FIFO's data delay is realised as
%     push = Delay8_out1                        (the symbol valid)
%     pop  = Delay10_out1 = Delay10_reg[49331]  (that same valid delayed 49,332
%                                                enb_1_2_0 TICKS)
% 49,332 ticks equal 12,333 valids ONLY while the valid density is exactly 1-in-4.
% Every Rate Handle EMPTY-edge event punches a permanent hole in that density, so
% for the epoch the hole is in flight the delay is 12,332 valids, not 12,333 --
% and Peak Search counts valids on the UNDELAYED chain while Timing Adjust counts
% them on the DELAYED one, so the phase between the two epoch spaces steps by one
% symbol.  Popping on `push & full` makes the delay exactly 12,333 VALIDS for
% ever, which is what every downstream epoch counter already assumes.  At exact
% 1-in-4 density the two pop streams are the SAME beats, so the s = 0 leg is
% bit-identical to baseline (gate S1).
%
% UNCONDITIONAL.  Unlike task 5's steering, R1 carries no runtime arming bit: the
% EMPTY-edge role (fixctl bit 5 clear) gets it too.  The FIXCTL=0 R4B rows are
% re-run against the reference for exactly that reason.
%
% ---------------------------------------------------------------------------
% THE 49,332-DEEP Delay BLOCK IS DELETED, NOT LEFT DANGLING.  `Delay10` is a
% 49,332-bit shift register -- real fabric if HDL Coder keeps it -- and its only
% purpose was to be the tick-indexed pop.  The injected reference kit left
% `Delay10_reg` in the netlist (dead, pruned by synthesis); in the model the
% honest form is delete_block, which is what the spec's "retires the Delay10
% shift register" asks for.  If a future HDL Coder errors on this, the fallback
% is to leave the block with its input still connected and its output
% terminated, and record the decision -- NOT to keep it driving anything.
%
% ITS OUTPUT HAS TWO LOADS, NOT ONE.  In the generated RTL `Delay10_out1` drives
% the FIFO's `.pop(...)` AND `Delay14` (`Delay14_out1 <= Delay10_out1;`), which
% is Timing Adjust's `validIn`.  The injector REDEFINES the net, so both loads
% see the new pop.  This overlay therefore re-drives EVERY destination of the
% deleted Delay's output line from `PdPopIndex/1`; rewiring only the FIFO would
% leave Timing Adjust without a valid and fail the gates as if it were a DSP bug.
%
% THE BLOCK IS FOUND BY FOLLOWING THE POP LINE, NOT BY DelayLength.  On this tree
% `Delay10`'s DelayLength is the EXPRESSION `searchSamples * 4`, so
% find_system(...,'DelayLength','49332') matches nothing.  The pop line is
% followed back the way rxfix_steer_overlay.m resolves popNom, the block it lands
% on is asserted to be a Delay, and the length is then resolved and checked
% against 49,332 as a soft confirmation (a warning, not an error, if the symbol
% cannot be resolved from this workspace -- identity is already established by
% the pop line).
%
% THE MLFB IS STATELESS ON PURPOSE.  `PdPopIndex` has no persistents, so HDL
% Coder emits a pure combinational module with no clk/reset and no input
% delay-match registers (measured on this tree: FixCtlDec.v, also stateless, is
% five `assign` lines and nothing else).  That is what makes it safe to put a
% DATA-PATH signal through a MATLAB Function block here, where task 5 deliberately
% did not -- see rxfix_steer_overlay.m's header for the stateful case.
%
% NO ALGEBRAIC LOOP.  `numEntries` leaves the FIFO subsystem from `Validate Input
% Push Pop`'s `Delay`, and neither subsystem is atomic, so Simulink traces the
% feedthrough through the register and the numEntries -> pop path is not a loop.
% That is also why the compare needs no Delay block of its own: the injector's
% compare is combinational off an already-registered occupancy, and so is this.
%
% G0: the whole body early-returns when QPSK_RXFIX is unset.  No registers, no
% AXI mapping, no surfaced ports (so no instrument port-tail ordering to keep).

if isempty(getenv('QPSK_RXFIX')), return; end
if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end
fprintf('=== rxfix_r1_overlay: Preamble Detector FIFO pop by occupancy ===\n');

lo  = 'LookUnderMasks';
rcv = [base '/Receiver'];
qrx = [rcv  '/QPSK Rx'];
fts = [qrx  '/Frequency and Time Synchronizer'];
pd  = [fts  '/Preamble Detector'];
ff  = [pd   '/FIFO'];

% ---- helpers (rxfix_steer_overlay.m / rxfix_w1_overlay.m idioms) -------------
  function n = leaf(pth)
    [~, n] = fileparts(pth);
  end
  function assert_block(pth)
    if isempty(find_system(fileparts(pth),'SearchDepth',1,lo,'all','Name',leaf(pth)))
      error('rxfix_r1: anchor missing: %s', pth);
    end
  end
  function h = oh(blk, k)
    p = get_param(blk,'PortHandles'); h = p.Outport(k);
  end
  function h = ih(blk, k)
    p = get_param(blk,'PortHandles'); h = p.Inport(k);
  end
  function idx = outport_by_name(ss, nm)
    b = find_system(ss,'SearchDepth',1,lo,'all','BlockType','Outport','Name',nm);
    if isempty(b), error('rxfix_r1: %s has no outport named %s', ss, nm); end
    idx = str2double(get_param(b{1},'Port'));
  end
  function idx = inport_by_name(ss, nm)
    b = find_system(ss,'SearchDepth',1,lo,'all','BlockType','Inport','Name',nm);
    if isempty(b), error('rxfix_r1: %s has no inport named %s', ss, nm); end
    idx = str2double(get_param(b{1},'Port'));
  end

% ---- idempotency (probe by block name) --------------------------------------
if ~isempty(find_system(pd,'SearchDepth',1,lo,'all','Name','PdPopIndex'))
  fprintf('rxfix_r1: already applied\n');
  return;
end

% ---- geometry from the single source (f1536: 12333 slots x 4 ticks = 49332;
% f3072 at sps 2: 24634 slots) -----------------------------------------------
cfg = frame_config_k5();
SLOTS = cfg.SlotsPerFrame;

% ---- anchors ----------------------------------------------------------------
need = {rcv, qrx, fts, pd, ff};
for i = 1:numel(need), assert_block(need{i}); end

% ---- (1) resolve the tick-indexed pop by following the FIFO's pop line -------
pPop = inport_by_name(ff, 'pop');
lPop = get_param(ih(ff, pPop), 'Line');
if lPop == -1, error('rxfix_r1: %s pop input is unconnected', ff); end
dly  = get_param(get_param(lPop, 'SrcPortHandle'), 'Parent');
if ~strcmp(get_param(dly,'BlockType'), 'Delay')
  error(['rxfix_r1: %s pop is driven by %s (BlockType %s), not the tick-indexed ' ...
         'Delay the injector re-defines'], ff, dly, get_param(dly,'BlockType'));
end

% soft confirmation of the length (the expression is `searchSamples * 4`)
dlExpr = get_param(dly, 'DelayLength');
dlVal  = [];
try   dlVal = slResolve(dlExpr, dly);
catch
  try   dlVal = evalin('base', dlExpr); catch, dlVal = []; end
end
if isempty(dlVal)
  fprintf(['rxfix_r1: WARNING %s DelayLength = %s could not be resolved here; ' ...
           'block identity rests on the pop line alone\n'], dly, dlExpr);
elseif dlVal ~= SLOTS*cfg.Sps && dlVal ~= SLOTS*4
  error(['rxfix_r1: %s DelayLength resolves to %g, not %d (slots x sps) or %d (slots x 4). The ' ...
         'FIFO depth and the pop constant below are tied to %d slots -- a different ' ...
         'geometry needs a new constant, not a silent pass.'], dly, dlVal, SLOTS*cfg.Sps, SLOTS*4, SLOTS);
else
  fprintf('rxfix_r1: %s DelayLength = %g ticks (%d slots)\n', dly, dlVal, SLOTS);
end

% every load of the retired Delay's output (FIFO.pop AND Timing Adjust's valid)
hDlyOut = oh(dly, 1);
lOut    = get_param(hDlyOut, 'Line');
if lOut == -1, error('rxfix_r1: %s output is unconnected', dly); end
dsts    = get_param(lOut, 'DstPortHandle');
if ~any(dsts == ih(ff, pPop))
  error('rxfix_r1: %s does not drive %s pop after all', dly, ff);
end

% the push valid feeding it (the RTL's Delay8_out1)
lIn = get_param(ih(dly, 1), 'Line');
if lIn == -1, error('rxfix_r1: %s input is unconnected', dly); end
hPush = get_param(lIn, 'SrcPortHandle');

% ---- (2) the registered occupancy, as a stored-integer uint16 ---------------
% FIFO's `numEntries` outport is fed by `Validate Input Push Pop`'s Delay -- the
% SAME register rxfix_w1_overlay.m surfaces as w1Occ, and the one the RTL calls
% FIFO_numEntries.  It is already wired (to P1cEntSi / a Terminator); this is a
% branch off it, so nothing existing is disturbed.
hEnt = oh(ff, outport_by_name(ff, 'numEntries'));
add_block('simulink/Signal Attributes/Data Type Conversion', [pd '/PdPopEntSi'], ...
          'OutDataTypeStr','uint16', 'ConvertRealWorld','Stored Integer (SI)', ...
          'Position',[1030 470 1070 510]);
add_line(pd, hEnt, ih([pd '/PdPopEntSi'], 1), 'autorouting','on');

% ---- (3) PdPopIndex: pop = push & (numEntries == SlotsPerFrame) -------------
add_block('simulink/User-Defined Functions/MATLAB Function', [pd '/PdPopIndex'], ...
          'Position', [1110 420 1230 510]);
S = sfroot; ch = S.find('Path', [pd '/PdPopIndex'], '-isa', 'Stateflow.EMChart');
ch.Script = sprintf([ ...
'function pop = fcn(delay8Out, numEntries)\n' ...
'%%#codegen\n' ...
'%% RXFIX_R1: the realignment FIFO is popped by OCCUPANCY, not by enb ticks.\n' ...
'%% numEntries is the registered occupancy and the ring guard bounds it to\n' ...
'%% 0..%d, so ==%d is exactly "full"; popping on push & full fixes the\n' ...
'%% data delay at %d VALIDS (one frame of slots) for ever.  Stateless on purpose (see the\n' ...
'%% overlay header): no persistents => no HDL Coder input delay-match register\n' ...
'%% on this DATA-PATH signal.\n' ...
'pop = delay8Out & (numEntries == uint16(%d));\n'], SLOTS, SLOTS, SLOTS, SLOTS);
add_line(pd, hPush,                       ih([pd '/PdPopIndex'], 1), 'autorouting','on');
add_line(pd, oh([pd '/PdPopEntSi'], 1),   ih([pd '/PdPopIndex'], 2), 'autorouting','on');

% ---- (4) retire the 49,332-deep shift register ------------------------------
for k = 1:numel(dsts)
  delete_line(pd, hDlyOut, dsts(k));
end
delete_line(pd, hPush, ih(dly, 1));
delete_block(dly);
for k = 1:numel(dsts)
  add_line(pd, oh([pd '/PdPopIndex'], 1), dsts(k), 'autorouting','on');
end

fprintf(['RXFIX_R1_OVERLAY_OK: PdPopIndex in Preamble Detector; pop = Delay8_out1 ' ...
         '& (FIFO_numEntries == %d); the %g-deep tick delay is deleted ' ...
         '(%d load(s) re-driven)\n'], SLOTS, dlVal, numel(dsts));
end
