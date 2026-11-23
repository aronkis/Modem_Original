function oneway_overlay(sys, base)
% oneway_overlay -- ONE-DIRECTIONAL test images (env-gated QPSK_ONEWAY=tx|rx).
%
%   QPSK_ONEWAY=tx   TX-only image: the Receiver subsystem is replaced by a
%                    same-interface STUB (inputs terminated, outputs constant 0)
%   QPSK_ONEWAY=rx   RX-only image: the Transmitter subsystem is stubbed the same way
%   unset            byte-identical HDL (nothing touched) -- the G0 idiom
%
% Why stub instead of delete: TxRxComposite keeps its full 24-in / 57-out
% interface (names, types, sample times), so hdlworkflow_loopback.m, the block
% design's byte-pin wiring, the DMAs, the UIO/DTB and every host tool see an
% unchanged IP core; synthesis prunes the constant-driven logic.  The TX pacing
% path (adc_validIn -> DS_TxValid -> Transmitter) is composite-level and stays,
% so a TX-only board must still enable its RX SSI for the valid cadence.
%
% Runs LAST in assemble_jupiter_240k5_byte.m (phase 2.22), after every overlay
% that touches Transmitter or Receiver internals.  The stub's port attributes are
% taken from a compile of the fully-assembled model, so they match what the
% removed half produced.  Idempotent: a second call finds the stub marker.
mode = lower(getenv('QPSK_ONEWAY'));
if isempty(mode), return; end
assert(any(strcmp(mode, {'tx','rx'})), 'QPSK_ONEWAY must be tx or rx (got "%s")', mode);
if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end
loop = base;
switch mode
    case 'tx', victim = 'Receiver';      % TX-only keeps the Transmitter
    case 'rx', victim = 'Transmitter';   % RX-only keeps the Receiver
end
vb = [loop '/' victim];
assert(~isempty(find_system(loop,'SearchDepth',1,'Name',victim)), 'oneway_overlay: %s not found under %s', victim, loop);
if contains(get_param(vb,'Description'), 'ONEWAY_STUB')
    fprintf('oneway_overlay: %s already stubbed (mode=%s)\n', victim, mode); return;
end
fprintf('=== oneway_overlay: QPSK_ONEWAY=%s -> stub %s (interface preserved) ===\n', mode, victim);

% ---- 1. compiled port attributes of the subsystem to be stubbed -------------
% (CompiledPort* are readable only while the model is in the compiled state)
feval(sys, [], [], [], 'compile');
ph  = get_param(vb, 'PortHandles');
nIn = numel(ph.Inport); nOut = numel(ph.Outport);
outs = struct('name', {}, 'port', {}, 'dt', {}, 'cplx', {}, 'dims', {}, 'st', {}, 'extConnected', {});
for k = 1:nOut
    h = ph.Outport(k);
    o.name = portBlockName(vb, 'Outport', k);
    o.port = k;
    o.dt   = get_param(h, 'CompiledPortDataType');
    o.cplx = get_param(h, 'CompiledPortComplexSignal');
    o.dims = get_param(h, 'CompiledPortDimensions');
    st     = get_param(h, 'CompiledSampleTime');
    o.st   = st(1);
    o.extConnected = get_param(h, 'Line') > 0;
    outs(end+1) = o; %#ok<AGROW>
end
ins = cell(nIn,1); inSt = zeros(nIn,1);
for k = 1:nIn
    ins{k} = portBlockName(vb, 'Inport', k);
    st = get_param(ph.Inport(k), 'CompiledSampleTime'); inSt(k) = st(1);
end
feval(sys, [], [], [], 'term');

% ---- 2. keep the port blocks (so the external lines stay attached), delete
%         everything else, then terminate inputs and drive outputs with constants.
%         RATES ARE PINNED EXPLICITLY on both sides: the removed half used to
%         anchor inherited rates around it (e.g. the DAC mux takes its 61.44 MHz
%         from the loopback path INTO the Receiver); a stub of bare Terminators
%         would let those resolve differently and change the surviving half's
%         generated clock enables.
inner = find_system(vb, 'SearchDepth', 1, 'Type', 'Block'); inner = inner(~strcmp(inner, vb));
isPort = cellfun(@(b) any(strcmp(get_param(b,'BlockType'), {'Inport','Outport'})), inner);
for l = reshape(find_system(vb, 'SearchDepth', 1, 'FindAll', 'on', 'Type', 'Line'), 1, [])
    try, if get_param(l,'LineParent') == -1, delete_line(l); end, catch, end
end
for b = reshape(inner(~isPort), 1, []), delete_block(b{1}); end
x0 = 40; y = 40;
for k = 1:nIn
    ip = [vb '/' ins{k}];
    set_param(ip, 'Position', [x0 y x0+30 y+14]);
    if isfinite(inSt(k)) && inSt(k) > 0, set_param(ip, 'SampleTime', num2str(inSt(k), 17)); end
    add_block('built-in/Terminator', [vb '/T_' ins{k}], 'Position', [x0+90 y-3 x0+110 y+17]);
    add_line(vb, [ins{k} '/1'], ['T_' ins{k} '/1']);
    y = y + 40;
end
y = 40; x1 = 400; nDropped = 0;
for k = 1:nOut
    o = outs(k);
    op = [vb '/' o.name];
    [dtStr, ok] = hdlTypeString(o.dt);
    if ~ok
        % a bus (or other unstubbable) output: allowed only if nothing outside
        % uses it -- then the port is dropped (external ports renumber, their
        % lines follow the surviving port objects)
        assert(~o.extConnected, 'oneway_overlay: %s output %s has type "%s" and IS connected outside -- cannot stub', victim, o.name, o.dt);
        delete_block(op); nDropped = nDropped + 1;
        fprintf('oneway_overlay: dropped unconnected %s output %s (type "%s")\n', victim, o.name, o.dt);
        continue;
    end
    val = zeroLiteral(o.dims, o.cplx);
    cb = [vb '/c_' o.name];
    add_block('built-in/Constant', cb, 'Value', val, 'OutDataTypeStr', dtStr, ...
        'SampleTime', num2str(o.st, 17), 'Position', [x1 y x1+60 y+22]);
    set_param(op, 'Position', [x1+120 y+4 x1+150 y+18]);
    add_line(vb, ['c_' o.name '/1'], [o.name '/1']);
    y = y + 44;
end
set_param(vb, 'Description', sprintf(['ONEWAY_STUB mode=%s: %s removed for a one-directional test image. ' ...
    'Same interface (%d in / %d out, %d unconnected bus output(s) dropped), inputs terminated, outputs constant 0. oneway_overlay.m'], mode, victim, nIn, nOut - nDropped, nDropped));

% ---- 3. the HDL workflow script names blocks INSIDE the removed half
%         (hdlset_param ResetType/… per Delay): neutralise those lines, in place,
%         kit-root contract (relative name, like the phase-0 patchers)
wf = 'hdlworkflow_loopback.m';
if isfile(wf)
    txt = fileread(wf); pfx = [loop '/' victim '/'];
    lines = regexp(txt, '[^\n]*\n?', 'match'); nOff = 0;
    for k = 1:numel(lines)
        ln = lines{k};
        if contains(ln, 'hdlset_param(') && contains(ln, pfx) && ~startsWith(strtrim(ln), '%')
            lines{k} = ['% ONEWAY_STUB(' mode ') ' ln]; nOff = nOff + 1;
        end
    end
    fid = fopen(wf, 'w'); fwrite(fid, [lines{:}]); fclose(fid);
    fprintf('oneway_overlay: %d hdlset_param line(s) on %s neutralised in %s\n', nOff, victim, wf);
end

% ---- 4. a REAL compile proves the stub is type- and rate-consistent with its
%         users (SimulationCommand update does not raise in -batch)
try
    feval(sys, [], [], [], 'compile'); feval(sys, [], [], [], 'term');
catch e
    try, feval(sys, [], [], [], 'term'); catch, end
    error('oneway_overlay: stubbed model does not compile: %s', e.message);
end
fprintf('ONEWAY_OVERLAY_OK mode=%s stubbed=%s in=%d out=%d dropped=%d\n', mode, victim, nIn, nOut - nDropped, nDropped);
end

% ---------------------------------------------------------------------------
function nm = portBlockName(sub, typ, k)
b = find_system(sub, 'SearchDepth', 1, 'BlockType', typ, 'Port', num2str(k));
assert(numel(b) == 1, 'oneway_overlay: %s %d of %s not unique', typ, k, sub);
nm = get_param(b{1}, 'Name');
end

function [s, ok] = hdlTypeString(dt)
% compiled type names -> OutDataTypeStr:  sfix16_En14 -> fixdt(1,16,14), ufix5 -> fixdt(0,5,0),
% sfix32_E3 -> fixdt(1,32,-3); builtins pass through.
t = regexp(dt, '^([su])fix(\d+)(_En?\d+)?$', 'tokens', 'once');
ok = true;
if isempty(t)
    if any(strcmp(dt, {'double','single','boolean','int8','uint8','int16','uint16','int32','uint32','int64','uint64'}))
        s = dt; return;
    end
    s = dt; ok = false; return;      % bus / enum / unknown
end
signed = double(t{1} == 's'); w = t{2};
f = '0';
if numel(t) >= 3 && ~isempty(t{3})
    e = t{3};                        % '_En14' -> 14 ; '_E3' -> -3
    if startsWith(e, '_En'), f = e(4:end); else, f = ['-' e(3:end)]; end
end
s = sprintf('fixdt(%d,%s,%s)', signed, w, f);
end

function v = zeroLiteral(dims, cplx)
% dims from CompiledPortDimensions: [ndims d1 ...]; scalar = [1 1]
if numel(dims) >= 2 && prod(dims(2:end)) > 1
    d = dims(2:end); if numel(d) == 1, d = [d 1]; end
    v = sprintf('zeros(%d,%d)', d(1), d(2));
else
    v = '0';
end
if cplx, v = ['complex(' v ',' v ')']; end
end
