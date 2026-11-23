function T = flat_debug_candidates(kit)
% flat_debug_candidates -- list what in the edited model LOOKS like removable
% debug / instrumentation, so the cleanup can be planned rather than hunted.
%
%   T = flat_debug_candidates(kit)     writes <kit>/FLAT_DEBUG_CANDIDATES.txt
%
% Categories (each row: category, path, note):
%   TERMINATED      signal sunk in a Terminator (dead output of a real block)
%   COMMENTED       block already commented out
%   SIMONLY         Scope / Display / To Workspace / To File / Assertion blocks
%   UNCONNECTED     block with an unconnected input or output port
%   DEBUGNAME       block or port whose name matches the instrument vocabulary
%                   (debug, canary, shadow, beatobs, beatfix, framestat, w1, r4,
%                    forensic, taps, wit, census, dbg, sentinel, cap_, cnt_)
%   COMPOSITEPORT   TxRxComposite outport that is NOT one of the functional
%                   interfaces (ADC/DAC data, host tx, byte plane) -- i.e. a
%                   register/witness port; removing one needs an AXI map + regmap edit
% Nothing is changed. Treat the list as candidates: several "debug" items are
% load-bearing (fixctl, tx_data_source, rx_input_select, the byte plane).
if nargin < 1 || isempty(kit), kit = pwd; end
sys = 'commhdlQPSKTxRxLoopback';
if ~bdIsLoaded(sys), load_system(fullfile(kit,[sys '.slx'])); end
loop = [sys '/TxRxComposite'];
lo = 'LookUnderMasks';
rows = {};

% TERMINATED
for b = reshape(find_system(sys,lo,'all','FollowLinks','off','BlockType','Terminator'),1,[])
    ph = get_param(b{1},'PortHandles');
    ln = get_param(ph.Inport(1),'Line');
    src = '';
    if ln > 0, sh = get_param(ln,'SrcBlockHandle'); if sh > 0, src = getfullname(sh); end, end
    rows(end+1,:) = {'TERMINATED', b{1}, ternary(isempty(src),'(no source)',['source: ' src])}; %#ok<AGROW>
end
% COMMENTED
for b = reshape(find_system(sys,lo,'all','FollowLinks','off','Commented','on'),1,[])
    rows(end+1,:) = {'COMMENTED', b{1}, get_param(b{1},'BlockType')}; %#ok<AGROW>
end
% SIMONLY
for bt = {'Scope','Display','ToWorkspace','ToFile','Assertion','FromFile','FromWorkspace'}
    for b = reshape(find_system(sys,lo,'all','FollowLinks','off','BlockType',bt{1}),1,[])
        rows(end+1,:) = {'SIMONLY', b{1}, bt{1}}; %#ok<AGROW>
    end
end
% UNCONNECTED
allb = find_system(sys,lo,'all','FollowLinks','off','Type','Block');
for k = 1:numel(allb)
    b = allb{k};
    try, pc = get_param(b,'PortConnectivity'); catch, continue; end
    for j = 1:numel(pc)
        srcU = isempty(pc(j).SrcBlock) && isempty(pc(j).DstBlock);
        srcNeg = ~isempty(pc(j).SrcBlock) && any(pc(j).SrcBlock == -1);
        dstNeg = ~isempty(pc(j).DstBlock) && any(pc(j).DstBlock == -1);
        if srcU || srcNeg || dstNeg
            rows(end+1,:) = {'UNCONNECTED', b, sprintf('port %s', pc(j).Type)}; %#ok<AGROW>
            break;
        end
    end
end
% DEBUGNAME
pat = '(?i)(debug|canary|shadow|beatobs|beatfix|framestat|\bw1|\br4|forensic|taps?\b|\bwit|census|\bdbg|sentinel|cap_|cnt_|viol|movsum|telemetry)';
for k = 1:numel(allb)
    nm = get_param(allb{k},'Name');
    if ~isempty(regexp(nm, pat, 'once'))
        rows(end+1,:) = {'DEBUGNAME', allb{k}, get_param(allb{k},'BlockType')}; %#ok<AGROW>
    end
end
% COMPOSITEPORT
functional = {'adc_dataInI','adc_dataInQ','adc_validIn','tx_dataOutI','tx_dataOutQ','tx_validOut', ...
    'host_txI','host_txQ','host_txValid','byte_data','byte_valid','byte_first','byte_ready', ...
    'byte_rx_data','byte_rx_valid','byte_rx_last','byte_rx_user','byte_rx_ready', ...
    'rx_input_select','tx_source_select','tx_data_source','fixctl','rstCS'};
for typ = {'Inport','Outport'}
    for b = reshape(find_system(loop,'SearchDepth',1,'BlockType',typ{1}),1,[])
        nm = get_param(b{1},'Name');
        if ~any(strcmp(nm, functional))
            rows(end+1,:) = {'COMPOSITEPORT', b{1}, sprintf('%s %s -- AXI-mapped register; remove via hdlworkflow_loopback.m + modem/regmap/regmap.toml', typ{1}, get_param(b{1},'Port'))}; %#ok<AGROW>
        end
    end
end

T = cell2table(rows, 'VariableNames', {'category','path','note'});
T = unique(T, 'stable');
fid = fopen(fullfile(kit,'FLAT_DEBUG_CANDIDATES.txt'),'w');
fprintf(fid, 'FLAT_DEBUG_CANDIDATES %s  model=%s\n', char(datetime('now')), sys);
cats = unique(T.category, 'stable');
for c = reshape(cats,1,[])
    sub = T(strcmp(T.category, c{1}), :);
    fprintf(fid, '\n== %s (%d) ==\n', c{1}, height(sub));
    for k = 1:height(sub)
        fprintf(fid, '%s\n    %s\n', strrep(sub.path{k}, [sys '/'], ''), sub.note{k});
    end
end
fclose(fid);
for c = reshape(cats,1,[]), fprintf('%-14s %d\n', c{1}, sum(strcmp(T.category,c{1}))); end
fprintf('FLAT_DEBUG_CANDIDATES_DONE rows=%d -> %s\n', height(T), fullfile(kit,'FLAT_DEBUG_CANDIDATES.txt'));
end

function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end
