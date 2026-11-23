function flat_simfix(kit, opts)
% flat_simfix -- make the DUT simulate at model level without a private copy:
%
%  1. Capture Data Bits: delete the cosmetic decoded-message print (char /
%     reshape / disp lines). Counter and capture arithmetic untouched. This is
%     the same edit the byte gate makes on its harness copy; without it the
%     first garbage frame throws a UTF-8 -> UTF-16 conversion error.
%  2. RxAlign: the decoder-latency literal (+41, the netlist-measured value)
%     becomes a chart INPUT fed by a Constant block 'RxAlignLatency' whose value
%     is the workspace variable rxAlignLat. The model InitFcn defaults it to 41,
%     so HDL generation and the netlist gates are unchanged; a simulation sets
%     rxAlignLat = 25 first (the behavioural Viterbi leads the RTL by 16 beats).
%  3. The kit's sim_byte_gate_k5.m stops patching the literal in its copy and
%     assigns rxAlignLat = 25 instead (backup: sim_byte_gate_k5.m.pre_simfix).
%
%   flat_simfix(kit)                  dry run
%   flat_simfix(kit, 'Apply', true)   edit, save
% Idempotent: re-running detects the applied state and leaves it alone.
arguments
    kit (1,:) char = pwd
    opts.Apply (1,1) logical = false
end
sys = 'commhdlQPSKTxRxLoopback';
if ~bdIsLoaded(sys), load_system(fullfile(kit,[sys '.slx'])); end
cdb = [sys '/TxRxComposite/Receiver/Capture Data Bits/MATLAB Function'];
dec = [sys '/TxRxComposite/Receiver/QPSK Rx/FEC Decoder Wrapper'];
ra  = [dec '/RxAlign'];

% ---- 1. Capture Data Bits print branch ---------------------------------------
ch = sfroot().find('-isa','Stateflow.EMChart','Path',cdb);
assert(~isempty(ch), 'Capture Data Bits chart not found at %s', cdb);
scr = ch(1).Script;
new = regexprep(scr,'msgarray_dec = char\([^\n]*\n','');
new = regexprep(new,'N = length\(msgarray_dec\)[^\n]*\n','');
new = regexprep(new,'strAscii_dec = reshape\(msgarray_dec[^\n]*\n','');
new = regexprep(new,'msg = char\(bin2dec[^\n]*\n','');
new = regexprep(new,'\s*disp\(msg\);','');
nRemoved = numel(strsplit(scr,newline)) - numel(strsplit(new,newline));
dispLeft = ~isempty(regexp(new, 'disp\(', 'once'));
fprintf('Capture Data Bits: %d line(s) to remove%s\n', nRemoved, ternary(dispLeft,'  (WARNING: a disp( call remains)',''));

% ---- 2. RxAlign latency parameter ----------------------------------------------
ch2 = sfroot().find('-isa','Stateflow.EMChart','Path',ra);
assert(~isempty(ch2), 'RxAlign chart not found at %s', ra);
s2 = ch2(1).Script;
already = contains(s2, 'alignLat');
if ~already
    assert(contains(s2, 'uint16(41)'), 'RxAlign: +41 literal not found; chart text differs from the assembled model');
    s2 = strrep(s2, 'function [dataOut, startOut, endOut, validOut] = fecRxAlign(decBit, deintValid, frameStart, frameEnd, skipCount)', ...
                    'function [dataOut, startOut, endOut, validOut] = fecRxAlign(decBit, deintValid, frameStart, frameEnd, skipCount, alignLat)');
    assert(contains(s2, 'alignLat)'), 'RxAlign: signature line not matched');
    s2 = strrep(s2, 'sk=sc+uint16(41); end % +41 = gated-Viterbi latency in deintValid beats incl. VitGate hold reg (RXROOT E8)', ...
                    'sk=sc+uint16(alignLat); end % alignLat = gated-Viterbi latency in deintValid beats incl. VitGate hold reg (RXROOT E8): 41 on the netlist, 25 for the behavioural Viterbi in model sim (rxAlignLat)');
    assert(contains(s2, 'uint16(alignLat)'), 'RxAlign: latency line not matched');
end
fprintf('RxAlign: %s\n', ternary(already, 'already parameterised', '41 literal -> alignLat input, Constant RxAlignLatency = rxAlignLat'));

initFcn = get_param(sys, 'InitFcn');
initHas = contains(initFcn, 'rxAlignLat');
fprintf('InitFcn: %s\n', ternary(initHas, 'already defaults rxAlignLat', 'will default rxAlignLat = 41'));

if ~opts.Apply, fprintf('dry run: nothing changed.\n'); return; end

ch(1).Script = new;
if ~already
    ch2(1).Script = s2;
    % the chart grows a 6th input; feed it from a Constant next to it
    rp = get_param(ra, 'Position');
    cb = add_block('built-in/Constant', [dec '/RxAlignLatency'], 'Value', 'rxAlignLat', ...
        'OutDataTypeStr', 'uint16', 'SampleTime', 'Inf', 'Position', [rp(1)-120 rp(4)+20 rp(1)-40 rp(4)+40]);
    set_param(cb, 'Description', 'Decoder latency absorbed by RxAlign. rxAlignLat = 41 (netlist, default from InitFcn) or 25 (model simulation).');
    add_line(dec, 'RxAlignLatency/1', 'RxAlign/6', 'autorouting', 'smart');
end
if ~initHas
    set_param(sys, 'InitFcn', sprintf(['%% RxAlign decoder latency (flat_simfix): 41 = netlist value used for HDL; set\n' ...
        '%% rxAlignLat = 25 in the base workspace before a model-level simulation.\n' ...
        'if ~exist(''rxAlignLat'',''var''), rxAlignLat = uint16(41); end\n%s'], initFcn));
end
save_system(sys, [], 'OverwriteIfChangedOnDisk', true);

% ---- 3. the kit's sim gate ------------------------------------------------------
g = fullfile(kit, 'simgate', 'sim_byte_gate_k5.m');   % stage-folder layout (2026-09-17)
if isfile(g)
    t = fileread(g);
    if contains(t, 'uint16(41)')
        copyfile(g, [g '.pre_simfix']);
        t = strrep(t, "assert(contains(scr2,'uint16(41)'), 'RxAlign +41 latency constant not found');", ...
                      "assert(contains(scr2,'alignLat'), 'RxAlign latency input not found (flat_simfix not applied?)');");
        t = strrep(t, "ch2(1).Script = strrep(scr2,'uint16(41)','uint16(25)');", ...
                      "assignin('base','rxAlignLat',uint16(25));   % flat_simfix: latency is a workspace parameter now");
        fw = fopen(g, 'w'); fwrite(fw, t); fclose(fw);
        fprintf('sim_byte_gate_k5.m: patched to assign rxAlignLat = 25 (backup .pre_simfix)\n');
    else
        fprintf('sim_byte_gate_k5.m: already patched\n');
    end
end
fprintf('FLAT_SIMFIX_DONE saved=%s\n', get_param(sys,'FileName'));
end

function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end
