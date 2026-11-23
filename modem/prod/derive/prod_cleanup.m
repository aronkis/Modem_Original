function prod_cleanup(kit)
% prod_cleanup -- the hand-cleanup steps of the dev -> prod derivation that are
% not covered by the generic tools, as a replayable list.
%
%   1. DELETE-LIST: blocks removed from the flattened model on purpose (debug
%      outputs of the Transmitter that only fed the stock example's scopes).
%      After deleting, every output pin left dangling is terminated so the
%      model still compiles cleanly.
%   2. The stock example's root-level harness (everything at the model root
%      that is not TxRxComposite and not part of the flat simulation harness)
%      is COMMENTED OUT, not deleted, so the example stays readable next to
%      the real harness.
%
% Add to DELETE when you remove something in prod that should stay removed on
% the next derivation. Paths are relative to the model root.
if nargin < 1 || isempty(kit), kit = pwd; end
sys = 'commhdlQPSKTxRxLoopback';
if ~bdIsLoaded(sys), load_system(fullfile(kit,[sys '.slx'])); end

DELETE = { ...
  'TxRxComposite/Transmitter/Bus Creator'
  'TxRxComposite/Transmitter/Bus Selector'
  'TxRxComposite/Transmitter/Delay10'
  'TxRxComposite/Transmitter/Delay6'
  'TxRxComposite/Transmitter/Repeat3'
  'TxRxComposite/Transmitter/Repeat4'
  'TxRxComposite/Transmitter/Repeat5'
  'TxRxComposite/Transmitter/complex'
  'TxRxComposite/Transmitter/dataOutI2'
  'TxRxComposite/Transmitter/dataOutQ2'
  'TxRxComposite/Transmitter/msg_count_out'
  'TxRxComposite/Transmitter/txDiagBus'
  'TxRxComposite/REP_TxValid'          % dead repeat of the TX valid, only fed a Terminator
  'TxRxComposite/T_repValid'
};

n0 = numel(find_system(sys,'LookUnderMasks','all','FollowLinks','off','Type','Block'));
nDel = 0; parents = {};
for k = 1:numel(DELETE)
    % block names from the stock example may carry a newline where the list has a space
    b = [sys '/' DELETE{k}];
    if getSimulinkBlockHandle(b) == -1
        leafNl = strrep(regexprep(DELETE{k},'.*/',''), ' ', newline);
        b = [sys '/' regexprep(DELETE{k},'/[^/]*$','') '/' leafNl];
    end
    if getSimulinkBlockHandle(b) == -1
        fprintf('prod_cleanup: already absent %s\n', DELETE{k}); continue;
    end
    try
        parents{end+1} = get_param(b,'Parent'); %#ok<AGROW>
        ph = get_param(b,'PortHandles');
        for h = [ph.Inport, ph.Outport]
            l = get_param(h,'Line'); if l > 0, try, delete_line(l); catch, end, end
        end
        delete_block(b); nDel = nDel + 1;
    catch err
        fprintf('prod_cleanup: could not delete %s (%s)\n', DELETE{k}, err.message);
    end
end
% terminate dangling output pins in every touched subsystem
nTerm = 0;
for p = unique(parents)
    blks = find_system(p{1},'SearchDepth',1,'Type','Block'); blks = blks(~strcmp(blks, p{1}));
    for b = reshape(blks,1,[])
        if any(strcmp(get_param(b{1},'BlockType'),{'Terminator','Outport'})), continue; end
        ph = get_param(b{1},'PortHandles');
        for j = 1:numel(ph.Outport)
            if get_param(ph.Outport(j),'Line') <= 0
                nTerm = nTerm + 1;
                t = sprintf('%s/T_cleanup%d', p{1}, nTerm);
                pos = get_param(b{1},'Position');
                add_block('built-in/Terminator', t, 'Position', [pos(3)+60, pos(2)+20*j, pos(3)+80, pos(2)+20*j+20]);
                add_line(p{1}, ph.Outport(j), get_param(t,'PortHandles').Inport(1), 'autorouting','smart');
            end
        end
    end
end
% comment out the stock example's root material
nCom = 0;
for b = reshape(find_system(sys,'SearchDepth',1,'Type','Block'),1,[])
    if strcmp(b{1}, sys) || strcmp(get_param(b{1},'Name'),'TxRxComposite'), continue; end
    if strcmp(get_param(b{1},'Tag'),'FLAT_HARNESS'), continue; end
    if ~strcmp(get_param(b{1},'Commented'),'on'), set_param(b{1},'Commented','on'); nCom = nCom + 1; end
end
n1 = numel(find_system(sys,'LookUnderMasks','all','FollowLinks','off','Type','Block'));
save_system(sys, [], 'OverwriteIfChangedOnDisk', true);
fprintf('PROD_CLEANUP_DONE deleted=%d terminated=%d commented=%d blocks %d -> %d\n', nDel, nTerm, nCom, n0, n1);
end
