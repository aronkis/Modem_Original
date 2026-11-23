function T = flat_order_ports(kit, opts)
% flat_order_ports -- renumber the TxRxComposite ports into three groups:
% DATA, then CONTROL, then DEBUG (inports and outports separately, original
% relative order kept inside each group).
%
%   T = flat_order_ports(kit)                  dry run: print + ORDER_MAP.txt
%   T = flat_order_ports(kit, 'Apply', true)   renumber and save
%
% Classification (lists live in flat_port_class.m; the ones below are documentation):
%   DATA     the modem's traffic interfaces: ADC/DAC samples and valids, host
%            TX samples, the byte plane both ways
%   CONTROL  registers that configure or report normal operation: source
%            selects, resets, loop gains, thresholds, fixctl, the BIST counters
%   DEBUG    everything else: capture DMA taps, witnesses, censuses, shadows,
%            canaries, forensic taps, framestat, per-stage counters
% Unknown names fall into DEBUG and are flagged so the lists can be extended.
%
% Only port NUMBERS change. Every consumer in the kit binds by name (the sim
% harness introspects numbers at run time, the netlist wrapper and the AXI map
% use names), so no file rewrite is needed. Ports on lower subsystems are not
% touched: the ddrcap2 injector keys on port order there, not here.
arguments
    kit (1,:) char = pwd
    opts.Apply (1,1) logical = false
end
sys = 'commhdlQPSKTxRxLoopback';
if ~bdIsLoaded(sys), load_system(fullfile(kit,[sys '.slx'])); end
loop = [sys '/TxRxComposite'];

DATA = {'adc_dataInI','adc_dataInQ','adc_validIn','host_txI','host_txQ','host_txValid', ...
        'byte_data','byte_valid','byte_first','byte_ready', ...
        'tx_dataOutI','tx_dataOutQ','tx_validOut', ...
        'byte_rx_data','byte_rx_valid','byte_rx_last','byte_rx_user','byte_rx_ready'};
CONTROL = {'rstCS','rx_input_select','tx_source_select','tx_data_source','skip_count','iq_debug_mux', ...
           'cs_prop_gain','cs_integ_gain','ss_prop_gain','ss_integ_gain','agc_loop_gain','cfo_threshold', ...
           'fixctl','count_out','packets_out','bit_errors_out','cap_out'};
% DEBUG = everything else (debugI/Q/I1/Q1/Valid capture taps, witnesses, censuses, ...)

rows = {};
for typ = {'Inport','Outport'}
    blks = find_system(loop,'SearchDepth',1,'BlockType',typ{1});
    n = cellfun(@(b) str2double(get_param(b,'Port')), blks);
    [~, o] = sort(n); blks = blks(o); n = n(o);
    grp = zeros(numel(blks),1); unk = false(numel(blks),1);
    for k = 1:numel(blks)
        nm = get_param(blks{k},'Name');
        switch flat_port_class(nm)
            case 'DATA',    grp(k) = 1;
            case 'CONTROL', grp(k) = 2;
            otherwise,      grp(k) = 3; unk(k) = ~isDebugName(regexprep(nm, '^reg_', ''));
        end
    end
    [~, o] = sortrows([grp (1:numel(blks))']);      % stable within group
    for j = 1:numel(o)
        k = o(j);
        rows(end+1,:) = {typ{1}, get_param(blks{k},'Name'), n(k), j, groupName(grp(k)), unk(k)}; %#ok<AGROW>
    end
end
T = cell2table(rows, 'VariableNames', {'dir','name','oldPort','newPort','group','unclassified'});

fid = fopen(fullfile(kit,'ORDER_MAP.txt'),'w');
fprintf(fid, 'ORDER_MAP %s applied=%d\n', char(datetime('now')), opts.Apply);
for typ = {'Inport','Outport'}
    S = T(strcmp(T.dir,typ{1}),:);
    fprintf(fid, '\n%s (%d)\n', typ{1}, height(S));
    lastG = '';
    for k = 1:height(S)
        if ~strcmp(S.group{k}, lastG), fprintf(fid, '  -- %s --\n', S.group{k}); lastG = S.group{k}; end
        fprintf(fid, '  %3d <- %3d  %s%s\n', S.newPort(k), S.oldPort(k), S.name{k}, ternary(S.unclassified(k),'   (unclassified -> DEBUG)',''));
    end
end
fclose(fid);
nMove = sum(T.oldPort ~= T.newPort);
fprintf('%s: %d of %d ports change number; %d unclassified names put in DEBUG. Map: %s\n', ...
    ternary(opts.Apply,'APPLY','DRY RUN'), nMove, height(T), sum(T.unclassified), fullfile(kit,'ORDER_MAP.txt'));
if ~opts.Apply, return; end

% ---- apply: assign target numbers in ascending order; Simulink shifts the rest
for typ = {'Inport','Outport'}
    S = sortrows(T(strcmp(T.dir,typ{1}),:), 'newPort');
    for k = 1:height(S)
        set_param([loop '/' S.name{k}], 'Port', num2str(S.newPort(k)));
    end
    % verify
    for k = 1:height(S)
        got = str2double(get_param([loop '/' S.name{k}], 'Port'));
        assert(got == S.newPort(k), 'port renumber failed: %s is %d, wanted %d', S.name{k}, got, S.newPort(k));
    end
end
save_system(sys, [], 'OverwriteIfChangedOnDisk', true);
fprintf('FLAT_ORDER_DONE moved=%d saved=%s\n', nMove, get_param(sys,'FileName'));
end

function tf = isDebugName(nm)
tf = ~isempty(regexp(nm, ['^(debug|cnt_|cap_(in|deint|cad)|rstcs_count|cfc_est|adc_forensic|state_|shdw_|strobe_|' ...
    'beat_|path_canary|ic_div|cs_lf|cs_v|lt_|ta_|byte_fifo_ovf|p1b_|framestat_|w1_|r4_|sro_mode|bs_|beatfix_|dbg_)'], 'once'));
end

function s = groupName(g)
names = {'DATA','CONTROL','DEBUG'}; s = names{g};
end

function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end
