function n = flat_reroute(kit, opts)
% flat_reroute -- rebuild every line in a subsystem with the smart autorouter,
% so wires take fresh short routes after blocks and ports have been moved.
%
%   n = flat_reroute(kit)                      TxRxComposite only, save
%   n = flat_reroute(kit, 'Scope', 'all')      every non-library subsystem under it
%   n = flat_reroute(kit, 'Subsystem', 'TxRxComposite/Receiver')   one level
%   n = flat_reroute(kit, 'Subsystem', '/')                        the model root
%
% Simulink.BlockDiagram.routeLine leaves existing bend points in place, which
% is why moved ports keep their old long paths. This function records each
% root line's source pin, every destination pin and its signal name, deletes
% it, and re-adds one line per destination with 'autorouting','smart'.
% Connectivity is preserved exactly (verify with flat_gate.sh diff: the
% CONNECTIONS section must show 0 removed / 0 added). Returns lines rebuilt.
arguments
    kit (1,:) char = pwd
    opts.Scope (1,:) char {mustBeMember(opts.Scope, {'composite','all'})} = 'composite'
    opts.Subsystem (1,:) char = ''
    opts.Save (1,1) logical = true
end
sys = 'commhdlQPSKTxRxLoopback';
if ~bdIsLoaded(sys), load_system(fullfile(kit,[sys '.slx'])); end
loop = [sys '/TxRxComposite'];
if strcmp(opts.Subsystem, '/')
    subs = {sys};                                   % the model root
elseif ~isempty(opts.Subsystem)
    subs = {[sys '/' opts.Subsystem]};
elseif strcmp(opts.Scope, 'all')
    subs = [{loop}; find_system(loop,'LookUnderMasks','all','FollowLinks','off','BlockType','SubSystem')];
    keep = true(numel(subs),1);
    for k = 1:numel(subs)
        try, ls = get_param(subs{k},'LinkStatus'); catch, ls = 'none'; end
        keep(k) = any(strcmp(ls, {'none','inactive'}));
    end
    subs = subs(keep);
else
    subs = {loop};
end
n0 = numel(find_system(sys,'LookUnderMasks','all','FollowLinks','off','Type','Block'));
n = 0;
for s = 1:numel(subs)
    sub = subs{s};
    ls = find_system(sub,'SearchDepth',1,'FindAll','on','Type','Line');
    roots = ls(arrayfun(@(l) get_param(l,'LineParent') == -1, ls));
    rec = struct('src', {}, 'dst', {}, 'name', {});
    for l = reshape(roots,1,[])
        src = get_param(l,'SrcPortHandle');
        dst = get_param(l,'DstPortHandle'); dst = dst(dst > 0);
        if src <= 0 || isempty(dst), continue; end        % dangling: leave as is
        rec(end+1) = struct('src', src, 'dst', dst, 'name', get_param(l,'Name')); %#ok<AGROW>
    end
    for k = 1:numel(rec)
        % delete the whole tree from the source port
        l = get_param(rec(k).src,'Line');
        if l > 0, delete_line(l); end
        h = [];
        for d = reshape(rec(k).dst,1,[])
            h = add_line(sub, rec(k).src, d, 'autorouting', 'smart');
        end
        if ~isempty(rec(k).name) && ~isempty(h)
            try, set_param(get_param(rec(k).src,'Line'), 'Name', rec(k).name); catch, end
        end
        n = n + 1;
    end
    fprintf('  %-70s %4d lines rebuilt\n', strrep(sub, [sys '/'], ''), numel(rec));
end
n1 = numel(find_system(sys,'LookUnderMasks','all','FollowLinks','off','Type','Block'));
assert(n1 == n0, 'block count changed %d -> %d; NOT saving', n0, n1);
if opts.Save
    save_system(sys, [], 'OverwriteIfChangedOnDisk', true);
end
fprintf('FLAT_REROUTE_DONE lines=%d subsystems=%d saved=%d\n', n, numel(subs), opts.Save);
end
