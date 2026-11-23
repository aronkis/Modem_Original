function tilt_eq_overlay(sys, base)
% tilt_eq_overlay -- receiver IN-BAND TILT CORRECTOR
% (spec docs/superpowers/specs/2026-10-03-rx-tilt-equaliser-design.md,
%  plan docs/superpowers/plans/2026-10-03-rx-tilt-equaliser.md Task 3).
%
% A frequency-selective fade on the forward air path puts a SLOPE across the
% 15.36 Msym/s band; the power-4 coarse estimator assumes a symmetric spectrum
% and is biased/noised by it (FORWARD_LINK_2026-10-01.md sec. 9/11: -14.6 dB
% across 16 MHz = 46 % loss, estimator bias -11.3k units). The channel is
% modelled (and reproduced in sim, PERT_TILT_DB) as cascaded one-tap stages
% y = x + a*j*x[n-1]; this block applies the exact inverse, THREE cascaded
% complex one-pole stages
%     y[n] = x[n] - a_k * j * y[n-1]      (yI = xI + a*yQp,  yQ = xQ - a*yIp)
% between the QPSK Rx input and the Automatic Gain Control (the AGC absorbs the
% <= 2.6 dB/stage gain change; the RRC and everything after are untouched).
%
% Coefficients come from two uint32 AXI4-Lite WRITE words threaded down exactly
% like the loop-gain registers (loop_gain_axi_overlay.m):
%     0x260 tilt_eq_a12   {a2[31:16] a1[15:0]}      sfix16_En15 each
%     0x264 tilt_eq_a3en  {en[31] 15'b0 a3[15:0]}
% |a| is clamped to 0.95 in the decode (one-pole stability margin). en = 0 or
% a_k = 0 is an EXACT pass-through: the block emits x unchanged (same type), so
% the clean-channel decode is bit-identical to the shipped tree (hard gate
% te_identity in modem/gates/tilt_eq.legs). The host writes the words with
% ops/tilt_eq.sh (measure -> ops/tilt_eq_solve.py -> write -> verify).
%
% LEAN-only (AXI inport threading, like loop_gain_axi_overlay). Idempotent.
% Apply AFTER loop_gain_axi_overlay in assemble_jupiter_240k5_byte.m.
if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end
loop = base;
if isempty(getenv('QPSK_LEAN'))
    error('tilt_eq_overlay: LEAN-only (AXI inport threading) -- assemble with QPSK_LEAN=1');
end
rcv = [loop '/Receiver'];
qrx = [rcv '/QPSK Rx'];
agc = [qrx '/Automatic Gain Control'];
% block presence by PATH (getSimulinkBlockHandle), not find_system by Name: the AGC is a library-linked
% block and a depth-1 Name search does not see it (first regen attempt, 2026-10-03 08:57).
assert(getSimulinkBlockHandle(agc) ~= -1, 'tilt_eq_overlay: Automatic Gain Control not found at %s', agc);
if getSimulinkBlockHandle([qrx '/TiltEq']) ~= -1
    fprintf('tilt_eq_overlay: TiltEq already present -- skip\n');
    return;
end
% rate carriers (mirror loop_gain_axi_overlay / debugMuxCtrl)
dm = [qrx '/debugMuxCtrl'];
assert(~isempty(find_system(qrx,'SearchDepth',1,'LookUnderMasks','all', ...
    'BlockType','Inport','Name','debugMuxCtrl')), 'tilt_eq_overlay: debugMuxCtrl not found (rate ref)');
dmDT = get_param(dm,'OutDataTypeStr');   % uint32
dmST = get_param(dm,'SampleTime');
busST = '1/15.36e6';
% ---- 1. thread the two AXI words down to QPSK Rx
srcA12 = thread_axi_down(loop, rcv, qrx, 'tilt_eq_a12',  qrx, dmDT, dmST, busST);
srcA3  = thread_axi_down(loop, rcv, qrx, 'tilt_eq_a3en', qrx, dmDT, dmST, busST);
% ---- 2. the AGC's data (port 1) and valid (port 2) sources
aph = get_param(agc,'PortHandles');
assert(numel(aph.Inport) >= 2, 'tilt_eq_overlay: AGC inports unexpected (%d)', numel(aph.Inport));
dL = get_param(aph.Inport(1),'Line'); assert(dL ~= -1, 'tilt_eq_overlay: AGC data input unconnected');
dSrc = get_param(get_param(dL,'SrcBlockHandle'),'Name'); dPort = get_param(get_param(dL,'SrcPortHandle'),'PortNumber');
vL = get_param(aph.Inport(2),'Line'); assert(vL ~= -1, 'tilt_eq_overlay: AGC valid input unconnected');
vSrc = get_param(get_param(vL,'SrcBlockHandle'),'Name'); vPort = get_param(get_param(vL,'SrcPortHandle'),'PortNumber');
agcName = get_param(agc,'Name');
% ---- 3. the MATLAB Function block (fixed-point, HDL-codable)
mlfb = [qrx '/TiltEq'];
add_block('simulink/User-Defined Functions/MATLAB Function', mlfb, 'Position',[120 300 220 380]);
set_fcn_script(mlfb, tilteq_src());
% ---- 4. rewire: x -> TiltEq/1, v -> TiltEq/2, words -> 3/4, TiltEq/1 -> AGC/1
delete_line(dL);
add_line(qrx, sprintf('%s/%d', dSrc, dPort), 'TiltEq/1', 'autorouting','on');
add_line(qrx, sprintf('%s/%d', vSrc, vPort), 'TiltEq/2', 'autorouting','on');
add_line(qrx, srcA12, 'TiltEq/3', 'autorouting','on');
add_line(qrx, srcA3,  'TiltEq/4', 'autorouting','on');
add_line(qrx, 'TiltEq/1', sprintf('%s/1', agcName), 'autorouting','on');
assert(~isempty(find_system(loop,'SearchDepth',1,'BlockType','Inport','Name','tilt_eq_a3en')), ...
    'tilt_eq_overlay: composite inport tilt_eq_a3en missing after apply');
fprintf(['tilt_eq_overlay: DONE -- TiltEq (3 x complex one-pole, coeff fixdt(1,16,15) |a|<=0.95, ' ...
         'state fixdt(1,18,14)) before the AGC; AXI 0x260 tilt_eq_a12 / 0x264 tilt_eq_a3en\n']);
end

% ===================================================================
% the block body. Types: x/y fixdt(1,16,14) complex (the AGC input type),
% coefficients fixdt(1,16,15), state fixdt(1,18,14) (2 guard bits), output
% saturated back to fixdt(1,16,14). en=0 clears the state so a later enable
% starts clean; a_k = 0 leaves y == x exactly (the multiply adds zero).
function src = tilteq_src()
% ONE fimath (F) on every fi() in the function: HDL Coder's parser rejects an output assigned from two
% branches whose fimaths differ ("Properties of fimath object must match ... RoundMode" -- regen attempt 2,
% 2026-10-03 09:05). Floor/Saturate everywhere, full-precision products/sums.
% COEFFICIENTS ARE REGISTERED (persistent c1..c3, decoded+clamped from the PREVIOUS cycle's words): the first
% image (sp3tilteq e79f436ae88a) put word-decode + clamp + multiply + add + saturate in ONE cycle and the gate
% clock's WNS fell from 1.187 to 0.109 ns on exactly that path (a12 reg -> y state / AGC input). A one-cycle
% lag on a coefficient change is irrelevant (the host writes them once per bring-up).
src = sprintf([ ...
'function y = TiltEq3(x, v, a12, a3en)\n' ...
'%%#codegen\n' ...
'%% receiver in-band tilt corrector: 3 cascaded complex one-pole stages\n' ...
'%% y[n] = x[n] - a_k*j*y[n-1]; a_k sfix16_En15 from the AXI words, |a| <= 0.95;\n' ...
'%% EXACT pass-through when en = 0 (y == x). tilt_eq_overlay.m\n' ...
'F = fimath(''RoundingMethod'',''Floor'',''OverflowAction'',''Saturate'', ...\n' ...
'           ''ProductMode'',''FullPrecision'',''SumMode'',''FullPrecision'');\n' ...
'sT = numerictype(1,18,14); cT = numerictype(1,16,15); oT = numerictype(1,16,14);\n' ...
'persistent s1 s2 s3 c1 c2 c3 cen\n' ...
'if isempty(s1)\n' ...
'  s1 = fi(complex(0,0), sT, F); s2 = s1; s3 = s1;\n' ...
'  c1 = fi(0, cT, F); c2 = c1; c3 = c1; cen = false;\n' ...
'end\n' ...
'%% ---- this cycle uses LAST cycle''s registered coefficients\n' ...
'a1 = c1; a2 = c2; a3 = c3; en = cen;\n' ...
'y = fi(x, oT, F);\n' ...
'if en\n' ...
'  if v\n' ...
'    xi = fi(x, sT, F);\n' ...
'    y1 = fi(complex(real(xi) + a1*imag(s1), imag(xi) - a1*real(s1)), sT, F); s1 = y1;\n' ...
'    y2 = fi(complex(real(y1) + a2*imag(s2), imag(y1) - a2*real(s2)), sT, F); s2 = y2;\n' ...
'    y3 = fi(complex(real(y2) + a3*imag(s3), imag(y2) - a3*real(s3)), sT, F); s3 = y3;\n' ...
'    y = fi(y3, oT, F);\n' ...
'  end\n' ...
'else\n' ...
'  s1 = fi(complex(0,0), sT, F); s2 = s1; s3 = s1;\n' ...
'end\n' ...
'%% ---- decode + clamp the words for NEXT cycle (registered)\n' ...
'lim = fi(0.95, cT, F);\n' ...
'n1 = reinterpretcast(fi(bitand(a12,  uint32(65535)), 0,16,0, F), cT);\n' ...
'n2 = reinterpretcast(fi(bitshift(a12, -16),           0,16,0, F), cT);\n' ...
'n3 = reinterpretcast(fi(bitand(a3en, uint32(65535)), 0,16,0, F), cT);\n' ...
'c1 = fi(min(max(n1,-lim),lim), cT, F); c2 = fi(min(max(n2,-lim),lim), cT, F); c3 = fi(min(max(n3,-lim),lim), cT, F);\n' ...
'cen = bitget(a3en, 32) ~= 0;\n' ...
'end\n']);
end

% ===================================================================
% COPIED VERBATIM from loop_gain_axi_overlay.m (local functions are file-private
% in MATLAB): thread a uint32 AXI inport composite -> Receiver (rate crossing)
% -> QPSK Rx -> ... -> target container; returns the line source inside it.
function coeffSrc = thread_axi_down(loop, rcv, qrx, name, container, dmDT, dmST, busST) %#ok<INUSL>
chain = {};                 % full paths, outermost (rcv) .. target
p = container;
while ~strcmp(p, loop)
    chain{end+1} = p; %#ok<AGROW>
    if strcmp(p, rcv), break; end
    p = fileparts(p);
end
chain = fliplr(chain);      % rcv, qrx, ..., container
nTop = numel(find_system(loop,'SearchDepth',1,'BlockType','Inport'));
add_block('built-in/Inport',[loop '/' name],'Port',num2str(nTop+1), ...
    'Position',[40 40+22*(nTop+1) 70 56+22*(nTop+1)]);
set_param([loop '/' name],'OutDataTypeStr',dmDT,'SampleTime',busST);
prevSrc = [name '/1'];
parent = loop;
for k = 1:numel(chain)
    c = chain{k};
    childName = get_param(c,'Name');
    nIn = numel(find_system(c,'SearchDepth',1,'LookUnderMasks','all','BlockType','Inport'));
    port = nIn+1;
    add_block('built-in/Inport',[c '/' name],'Port',num2str(port), ...
        'Position',[25 25+22*port 55 41*1+22*port]);
    if k==1
        set_param([c '/' name],'OutDataTypeStr',dmDT,'SampleTime',busST);
    else
        set_param([c '/' name],'OutDataTypeStr',dmDT,'SampleTime',dmST);
    end
    add_line(parent, prevSrc, sprintf('%s/%d', childName, port), 'autorouting','on');
    if k==1
        add_block('built-in/Delay',[c '/RegHold_' name],'DelayLength','1', ...
            'Position',[120 25+22*port 150 41+22*port]);
        add_block('dspsigops/Downsample',[c '/RegDS_' name],'N','1', ...
            'InputProcessing','Elements as channels (sample based)', ...
            'RateOptions','Allow multirate processing', ...
            'Position',[170 25+22*port 200 41+22*port]);
        add_line(c, [name '/1'], ['RegHold_' name '/1'], 'autorouting','on');
        add_line(c, ['RegHold_' name '/1'], ['RegDS_' name '/1'], 'autorouting','on');
        prevSrc = ['RegDS_' name '/1'];
    else
        prevSrc = [name '/1'];
    end
    parent = c;
end
coeffSrc = [name '/1'];
end

function set_fcn_script(blk, src)
rt = sfroot;
chart = rt.find('-isa','Stateflow.EMChart','Path',blk);
chart.Script = src;
end
