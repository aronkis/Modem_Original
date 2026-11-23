function flat_root_harness(kit, opts)
% flat_root_harness -- wire the model ROOT around TxRxComposite so the flat
% model runs with the Play button: sources on every input, a DAC->ADC loopback,
% a byte-plane source with the ready handshake, displays on the BIST counters,
% terminators on everything else, and signal logging on the oracle outputs.
%
%   flat_root_harness(kit)                    dry run: report what would be built
%   flat_root_harness(kit, 'Apply', true)     build, set the stop time, save
%   ... 'StopTime', 0.03                      seconds (default; ~37 f1536 frames)
%   ... 'RemoveLegacy', false                 also delete the stock example's own
%                                             root harness (Transmitter/Channel/
%                                             Receiver copies, scopes, displays)
%
% The drives mirror the proven byte gate harness (sim_byte_gate_k5.m):
%   adc_validIn       1-in-2 toggle at the 30.72 MHz bus rate (TX pacing)
%   adc_dataInI/Q     external loopback: tx_dataOutI/Q through one Delay
%   reg_rx_input_select  'rx_sel' constant: false = INTERNAL loopback inside the
%                     composite (the gate-proven path), true = the external wire
%   reg_tx_data_source   'txds' constant: 0 = ROM BIST frames, 1 = byte plane
%   host_tx*          idle (0, 0, valid)
%   byte plane        handshake-reactive source (counting words, 191 per frame),
%                     ready fed back through the codegen skid lag (f1536)
%   every other reg_* input    Ground (inherits type and rate, as the gate's
%                              undriven inputs do)
%   count/packets/bit_errors   Display blocks, cap_out as hex
% Existing root lines into or out of TxRxComposite are removed first; the
% harness blocks are tagged FLAT_HARNESS so a re-run replaces them.
%
% Model-level simulation needs flat_simfix applied to the DUT once (print branch
% removed, RxAlign latency parameterised) and rxAlignLat = 25 in the base
% workspace before Play. Without them:
%   * Capture Data Bits' message decoder calls disp(char(...)) on decoded
%     bytes; on garbage frames that can throw in codegen. If it does, comment
%     that disp line in the chart.
%   * RxAlign's latency constant is the NETLIST value (41 beats). In model
%     simulation the behavioural Viterbi leads by 16 beats, so cap_out reads
%     16 bits early and bit_errors_out counts. The gate uses 25 in its copy.
%     Expect the link to run and packets to count; expect the BIST word to
%     differ from the golden 0x04922282 until that constant is parameterised.
arguments
    kit (1,:) char = pwd
    opts.Apply (1,1) logical = false
    opts.StopTime (1,1) double = 0.03
    opts.RemoveLegacy (1,1) logical = false
end
sys = 'commhdlQPSKTxRxLoopback';
if ~bdIsLoaded(sys), load_system(fullfile(kit,[sys '.slx'])); end
comp = [sys '/TxRxComposite'];
TAG = 'FLAT_HARNESS';
busT = '1/30.72e6'; railT = '1/15.36e6';

% ---- inventory of the composite's ports ------------------------------------
inp = portTable(comp, 'Inport'); outp = portTable(comp, 'Outport');
legacy = setdiff(find_system(sys,'SearchDepth',1,'Type','Block'), {sys, comp});
legacy = legacy(cellfun(@(b) isempty(get_param(b,'Tag')) || ~strcmp(get_param(b,'Tag'),TAG), legacy));
fprintf('%s: composite has %d inports / %d outports; %d other root blocks%s\n', ...
    ternary(opts.Apply,'APPLY','DRY RUN'), height(inp), height(outp), numel(legacy), ...
    ternary(opts.RemoveLegacy,' (will be removed)',' (left in place)'));
if ~opts.Apply, return; end

% ---- clear previous harness / composite root wiring --------------------------
for b = reshape(find_system(sys,'SearchDepth',1,'Type','Block','Tag',TAG),1,[]), delete_block(b{1}); end
% the harness area and note are annotations, not blocks: sweep those too, plus any
% earlier untagged copies of them (matched by their text)
for a = reshape(find_system(sys,'SearchDepth',1,'FindAll','on','Type','Annotation'),1,[])
    try
        tg = get_param(a,'Tag'); nm = get_param(a,'Name'); tx = get_param(a,'Text');
        if strcmp(tg,TAG) || strcmp(nm,'SIMULATION HARNESS') || startsWith(tx,'SIMULATION HARNESS'), delete(a); end
    catch, end
end
ph = get_param(comp,'PortHandles');
for h = [ph.Inport, ph.Outport]
    l = get_param(h,'Line'); if l > 0, delete_line(l); end
end
if opts.RemoveLegacy
    for b = reshape(legacy,1,[]), try, delete_block(b{1}); catch, end, end
end
% deleting blocks leaves their lines dangling; sweep them so re-added blocks
% cannot inherit a stale connection
for pass = 1:3
    ls = find_system(sys,'SearchDepth',1,'FindAll','on','Type','Line');
    for l = reshape(ls,1,[])
        try
            if get_param(l,'LineParent') ~= -1, continue; end
            d = get_param(l,'DstPortHandle'); d = d(d > 0);
            if get_param(l,'SrcPortHandle') <= 0 || isempty(d), delete_line(l); end
        catch, end
    end
end

% ---- geometry: composite tall enough for its pins, harness columns ----------
nPins = max(height(inp), height(outp));
pitch = 30;
root = find_system(sys,'SearchDepth',1,'Type','Block'); root = setdiff(root, {sys});
% the harness column starts to the RIGHT of everything else at the root (blocks
% and annotations), so it can never overlap the stock example's material even
% if that comes back from an unsaved desktop session
xRight = 0;
for b = reshape(legacy,1,[]), p = get_param(b{1},'Position'); xRight = max(xRight, p(3)); end
for a = reshape(find_system(sys,'SearchDepth',1,'FindAll','on','Type','Annotation'),1,[])
    try, p = get_param(a,'Position'); xRight = max(xRight, p(min(3,numel(p)))); catch, end
end
xRight = max(xRight, 1300);
cx = xRight + 700; cw = 320; ch = nPins * pitch + 40; yTop = 60;
set_param(comp, 'Position', [cx yTop cx+cw yTop+ch], 'Orientation', 'right');
ph = get_param(comp,'PortHandles');

% ---- sources -------------------------------------------------------------------
xSrc = cx - 260; made = {};
mk = @(name, kind, pos, varargin) addTagged(sys, name, kind, pos, TAG, varargin{:});
for k = 1:height(inp)
    nm = inp.name{k}; pinY = get_param(ph.Inport(inp.port(k)),'Position'); pinY = pinY(2);
    y = pinY - 10;
    dt = inp.dtype{k}; if contains(dt,'Inherit'), dt = 'uint32'; end
    st = inp.st{k}; if strcmp(strtrim(st),'-1'), st = railT; end
    src = '';
    switch nm
        case 'adc_validIn'
            mk('Tick', 'built-in/Constant', [xSrc-140 y xSrc-100 y+20], 'Value','true','OutDataTypeStr','boolean','SampleTime',busT);
            mk('VGen', 'simulink/User-Defined Functions/MATLAB Function', [xSrc-60 y-10 xSrc+20 y+30]);
            vg = sfroot().find('-isa','Stateflow.EMChart','Path',[sys '/VGen']);
            vg.Script = sprintf('function v = vgen(tick)\npersistent p\nif isempty(p), p=false; end\np = ~p;\nv = p && logical(tick);\n');
            add_line(sys, 'Tick/1', 'VGen/1'); src = 'VGen/1';
        case {'adc_dataInI','adc_dataInQ'}
            d = ['LoopDly' nm(end)];
            mk(d, 'built-in/Delay', [xSrc y xSrc+40 y+20], 'DelayLength','1');
            src = [d '/1'];                                  % fed from tx_dataOut* below
        case {'host_txI','host_txQ'}
            c = ['c_' nm]; mk(c, 'built-in/Constant', [xSrc y xSrc+60 y+20], 'Value','0','OutDataTypeStr','int16','SampleTime',busT); src = [c '/1'];
        case 'host_txValid'
            mk('c_host_txValid', 'built-in/Constant', [xSrc y xSrc+60 y+20], 'Value','true','OutDataTypeStr','boolean','SampleTime',busT); src = 'c_host_txValid/1';
        case 'byte_rx_ready'
            mk('c_byte_rx_ready', 'built-in/Constant', [xSrc y xSrc+60 y+20], 'Value','true','OutDataTypeStr','boolean','SampleTime',busT); src = 'c_byte_rx_ready/1';
        case {'byte_data','byte_valid','byte_first'}
            if isempty(find_system(sys,'SearchDepth',1,'Name','ByteSrc'))
                mk('ByteSrc', 'simulink/User-Defined Functions/MATLAB Function', [xSrc-40 y xSrc+50 y+70]);
                bs = sfroot().find('-isa','Stateflow.EMChart','Path',[sys '/ByteSrc']);
                bs.Script = sprintf(['function [data, valid, first] = src(ready, nWords)\n' ...
                    'persistent idx\nif isempty(idx), idx = uint32(1); end\n' ...
                    'data = uint64(idx);\nvalid = true;\nfirst = (idx == uint32(1));\n' ...
                    'if ready\n    idx = idx + 1;\n    if idx > uint32(nWords), idx = uint32(1); end\nend\n']);
                mk('WordsPerFrame', 'built-in/Constant', [xSrc-160 y+40 xSrc-100 y+60], 'Value','191','OutDataTypeStr','uint32','SampleTime',busT);
                add_line(sys, 'WordsPerFrame/1', 'ByteSrc/2');
            end
            o = find(strcmp(nm, {'byte_data','byte_valid','byte_first'}));
            src = sprintf('ByteSrc/%d', o);
        case 'reg_rx_input_select'
            mk('rx_sel (false=internal loopback)', 'built-in/Constant', [xSrc-40 y xSrc+60 y+20], 'Value','false','OutDataTypeStr',dt,'SampleTime',st); src = 'rx_sel (false=internal loopback)/1';
        case 'reg_tx_data_source'
            mk('txds (0=ROM BIST, 1=bytes)', 'built-in/Constant', [xSrc-40 y xSrc+60 y+20], 'Value','0','OutDataTypeStr',dt,'SampleTime',st); src = 'txds (0=ROM BIST, 1=bytes)/1';
        otherwise
            % the gate leaves these registers undriven (auto-grounded); a Ground
            % inherits type and rate, a typed Constant can trip the rate checker
            c = ['g_' nm]; mk(c, 'built-in/Ground', [xSrc+20 y xSrc+50 y+20]); src = [c '/1'];
    end
    add_line(sys, src, sprintf('TxRxComposite/%d', inp.port(k)), 'autorouting','smart');
    made{end+1} = nm; %#ok<AGROW>
end

% ---- sinks ---------------------------------------------------------------------
xSink = cx + cw + 120;
oracle = {'reg_count_out','reg_packets_out','reg_bit_errors_out','reg_cap_out'};
logNames = [oracle, {'reg_cap_in','reg_cap_deint','byte_rx_data','byte_rx_valid','byte_rx_last','byte_rx_user'}];
for k = 1:height(outp)
    nm = outp.name{k}; h = ph.Outport(outp.port(k)); pinY = get_param(h,'Position'); pinY = pinY(2); y = pinY - 10;
    switch nm
        case {'tx_dataOutI','tx_dataOutQ'}
            % external loopback wire back to the ADC delay, plus a display
            add_line(sys, sprintf('TxRxComposite/%d', outp.port(k)), ['LoopDly' nm(end) '/1'], 'autorouting','smart');
        case oracle
            d = ['disp_' nm];
            mk(d, 'built-in/Display', [xSink y xSink+110 y+20]);
            if strcmp(nm,'reg_cap_out'), set_param([sys '/' d], 'Format', 'hex (Stored Integer)'); end
            add_line(sys, sprintf('TxRxComposite/%d', outp.port(k)), [d '/1'], 'autorouting','smart');
        case 'byte_ready'
            % handshake back to the byte source through the codegen skid lag
            lag = '0'; try, lag = num2str(qpskByteSkidLag()); catch, end
            mk('SkidLagDly', 'built-in/Delay', [xSink y xSink+40 y+20], 'DelayLength', lag);
            add_line(sys, sprintf('TxRxComposite/%d', outp.port(k)), 'SkidLagDly/1', 'autorouting','smart');
            add_line(sys, 'SkidLagDly/1', 'ByteSrc/1', 'autorouting','smart');
        otherwise
            t = ['T_' nm]; mk(t, 'built-in/Terminator', [xSink y xSink+20 y+20]);
            add_line(sys, sprintf('TxRxComposite/%d', outp.port(k)), [t '/1'], 'autorouting','smart');
    end
    if any(strcmp(nm, logNames))
        set_param(h, 'DataLogging','on', 'DataLoggingNameMode','Custom', 'DataLoggingName', nm);
    end
end

% ---- model settings + label -------------------------------------------------------
set_param(sys, 'StopTime', num2str(opts.StopTime), 'SolverType','Fixed-step', 'Solver','FixedStepDiscrete', ...
    'SignalLogging','on', 'SignalLoggingName','logsout', 'SaveFormat','Dataset');
try
    a = add_block('built-in/Area', [sys '/SIMULATION HARNESS'], 'Position', [xSrc-200 yTop-40 xSink+160 yTop+ch+40]);
    set_param(a, 'Tag', TAG);
catch, end
note = Simulink.Annotation(sys, sprintf(['SIMULATION HARNESS (flat_root_harness.m)\n' ...
    'Play runs TxRxComposite in loopback. rx_sel: false = internal loopback inside the composite, true = the DAC->ADC wire.\n' ...
    'txds: 0 = ROM BIST frames, 1 = byte-plane source (counting words). Displays: count / packets / bit errors / cap_out (hex).\n' ...
    'Logged to logsout: %s.\n' ...
    'BEFORE PLAY run   rxAlignLat = uint16(25)   in the base workspace (model sim; the InitFcn defaults it to 41, the netlist value used for HDL).'], strjoin(logNames, ', ')));
note.Position = [xSrc-200 yTop-140]; note.FontSize = 10; note.Tag = TAG;
% the one thing a cold Play needs, in letters nobody can miss
big = Simulink.Annotation(sys, sprintf(['BEFORE PLAY:   rxAlignLat = uint16(25)\n' ...
    '(model-simulation decoder latency; the InitFcn defaults it to 41, the netlist value used for HDL,\n' ...
    'and only sets it when the variable does not exist yet -- so set it yourself once per session)']));
big.Position = [xSrc-200 yTop-330]; big.FontSize = 22; big.FontWeight = 'bold';
big.BackgroundColor = '[1.00, 0.85, 0.40]'; big.Tag = TAG;
flat_reroute(kit, 'Subsystem', '/', 'Save', false);
save_system(sys, [], 'OverwriteIfChangedOnDisk', true);
fprintf('FLAT_ROOT_HARNESS_DONE inputs=%d outputs=%d stopTime=%g saved=%s\n', height(inp), height(outp), opts.StopTime, get_param(sys,'FileName'));
end

% ---------------------------------------------------------------------------
function T = portTable(comp, typ)
b = find_system(comp,'SearchDepth',1,'BlockType',typ);
name = cellfun(@(x) get_param(x,'Name'), b, 'uni', 0);
port = cellfun(@(x) str2double(get_param(x,'Port')), b);
dtype = cellfun(@(x) get_param(x,'OutDataTypeStr'), b, 'uni', 0);
st = cellfun(@(x) get_param(x,'SampleTime'), b, 'uni', 0);
T = sortrows(table(name, port, dtype, st), 'port');
end

function h = addTagged(sys, name, kind, pos, tag, varargin)
h = add_block(kind, [sys '/' name], 'Position', pos, varargin{:});
set_param(h, 'Tag', tag);
end

function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end
