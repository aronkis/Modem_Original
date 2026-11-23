function flat_tidy(kit, varargin)
% flat_tidy -- re-organise the edited model after a cleanup pass, then save.
%
%   flat_tidy(kit)                       arrange EVERY non-library subsystem under
%                                        TxRxComposite, re-apply the Rate Handle
%                                        notes, make all ports the same size, save
%   flat_tidy(kit, 'TxRxComposite/Receiver', ...)
%                                        arrange only the named subsystems (paths
%                                        relative to the model root)
%
% Steps:
%   1. Simulink.BlockDiagram.arrangeSystem on the selected subsystems (deepest
%      first), skipping library-linked ones.
%   2. annotate_flat_rate_handle (idempotent) if the script and the subsystem exist.
%   3. resize_ports_like with the defaults (ss_prop_gain / cnt_descr_in) if both
%      reference ports still exist; otherwise skipped with a message.
%   4. save. Block count is asserted unchanged across the whole run.
if nargin < 1 || isempty(kit), kit = pwd; end
sys = 'commhdlQPSKTxRxLoopback';
if ~bdIsLoaded(sys), load_system(fullfile(kit,[sys '.slx'])); end
loop = [sys '/TxRxComposite'];
n0 = numel(find_system(sys,'LookUnderMasks','all','FollowLinks','off','Type','Block'));

if isempty(varargin)
    subs = [{loop}; find_system(loop,'LookUnderMasks','all','FollowLinks','off','BlockType','SubSystem')];
else
    subs = cellfun(@(s) [sys '/' s], varargin, 'uni', 0)';
end
depth = cellfun(@(s) sum(s == '/'), subs);
[~, o] = sort(depth, 'descend'); subs = subs(o);
nArr = 0;
for k = 1:numel(subs)
    s = subs{k};
    try, ls = get_param(s,'LinkStatus'); catch, ls = 'none'; end
    if ~any(strcmp(ls, {'none','inactive'})), continue; end
    nb = numel(find_system(s,'SearchDepth',1,'LookUnderMasks','all','FollowLinks','off','Type','Block')) - 1;
    if nb < 2, continue; end
    try
        Simulink.BlockDiagram.arrangeSystem(s, 'FullLayout', 'true'); nArr = nArr + 1;
    catch err
        fprintf('arrange failed: %s (%s)\n', s, err.message);
    end
end
fprintf('tidy: arranged %d subsystems\n', nArr);

if exist('annotate_flat_rate_handle','file') == 2
    try, annotate_flat_rate_handle(sys); catch err, fprintf('notes skipped: %s\n', err.message); end
end

if exist('resize_ports_like','file') == 2
    % reference ports, with or without the reg_ prefix flat_rename_reg_ports adds
    inRef  = firstExisting(sys, 'Inport',  {'ss_prop_gain','reg_ss_prop_gain'});
    outRef = firstExisting(sys, 'Outport', {'cnt_descr_in','reg_cnt_descr_in'});
    if ~isempty(inRef) && ~isempty(outRef)
        resize_ports_like(sys, inRef, outRef);
    else
        fprintf('port resize skipped: reference port(s) missing (in=%s out=%s)\n', inRef, outRef);
    end
end

n1 = numel(find_system(sys,'LookUnderMasks','all','FollowLinks','off','Type','Block'));
assert(n1 == n0, 'tidy changed the block count %d -> %d; NOT saving', n0, n1);
save_system(sys, [], 'OverwriteIfChangedOnDisk', true);
fprintf('FLAT_TIDY_DONE arranged=%d blocks=%d saved=%s\n', nArr, n1, get_param(sys,'FileName'));
end

function nm = firstExisting(sys, typ, names)
nm = '';
for k = 1:numel(names)
    if ~isempty(find_system(sys,'LookUnderMasks','all','FollowLinks','off','BlockType',typ,'Name',names{k}))
        nm = names{k}; return;
    end
end
end
