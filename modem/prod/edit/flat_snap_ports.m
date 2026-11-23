function n = flat_snap_ports(kit, opts)
% flat_snap_ports -- move every Inport/Outport block next to the pin it is
% wired to, and colour-code ports by direction and class.
%
%   n = flat_snap_ports(kit)                        dry run: counts only
%   n = flat_snap_ports(kit, 'Apply', true)         move, colour, re-route, save
%   ... 'Scope', 'composite' | 'all'                TxRxComposite only (default)
%                                                   or every non-library subsystem under it
%   ... 'Subsystem', 'TxRxComposite/Receiver'       exactly one level
%
% Placement: an Inport block goes beside the pin of the block it drives; an
% Outport block beside the pin that drives it. The side is whichever side of
% the target block the pin is on, so inputs can land on the right and outputs on
% the left when that is where the wire goes. Ports that would overlap a block or
% another port are pushed outward into a second (third, ...) column. A port that
% lands on the far side of its pin is rotated to face it (Orientation 'left'),
% so the wire never has to loop round the block. Lines are
% rebuilt afterwards with the smart router (flat_reroute). Unconnected ports are left where they are.
%
% Colours (BackgroundColor), class from flat_port_class:
%             DATA              CONTROL           DEBUG
%   Inport    light blue        light amber       light grey
%   Outport   blue              amber             grey
% Returns the number of ports moved. Nothing structural changes.
arguments
    kit (1,:) char = pwd
    opts.Apply (1,1) logical = false
    opts.Scope (1,:) char {mustBeMember(opts.Scope, {'composite','all'})} = 'composite'
    opts.Subsystem (1,:) char = ''
end
sys = 'commhdlQPSKTxRxLoopback';
if ~bdIsLoaded(sys), load_system(fullfile(kit,[sys '.slx'])); end
loop = [sys '/TxRxComposite'];
if ~isempty(opts.Subsystem)
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

colours = struct('DATA',    {{'[0.80, 0.90, 1.00]', '[0.45, 0.70, 1.00]'}}, ...
                 'CONTROL', {{'[1.00, 0.93, 0.72]', '[1.00, 0.76, 0.35]'}}, ...
                 'DEBUG',   {{'[0.92, 0.92, 0.92]', '[0.72, 0.72, 0.72]'}});
gap = 40; pad = 12;
n = 0; nCol = 0; nFlip = 0;
for s = 1:numel(subs)
    sub = subs{s};
    blks = find_system(sub,'SearchDepth',1,'Type','Block'); blks = blks(~strcmp(blks, sub));
    bt = cellfun(@(b) get_param(b,'BlockType'), blks, 'uni', 0);
    isP = ismember(bt, {'Inport','Outport'});
    fixed = blks(~isP);
    fixedR = cell2mat(cellfun(@(b) get_param(b,'Position'), fixed, 'uni', 0));
    if isempty(fixedR), fixedR = zeros(0,4); end
    ports = blks(isP); pt = bt(isP);
    placed = zeros(0,4);
    % process in target order so stacking is deterministic: by target pin y
    plan = cell(numel(ports),1); tgtY = inf(numel(ports),1);
    for k = 1:numel(ports)
        [pin, side] = wiredPin(ports{k}, pt{k});
        if isempty(pin), continue; end
        plan{k} = struct('pin', pin, 'side', side); tgtY(k) = pin(2);
    end
    [~, ord] = sort(tgtY);
    for k = reshape(ord,1,[])
        b = ports{k};
        cls = flat_port_class(get_param(b,'Name'));
        isIn = strcmp(get_param(b,'BlockType'),'Inport');
        if opts.Apply
            set_param(b, 'BackgroundColor', colours.(cls){1 + ~isIn}); nCol = nCol + 1;
        end
        if isempty(plan{k}), continue; end
        p = get_param(b,'Position'); w = p(3)-p(1); h = p(4)-p(2);
        pin = plan{k}.pin; side = plan{k}.side;
        if side < 0, x = pin(1) - gap - w; else, x = pin(1) + gap; end
        y = round(pin(2) - h/2);
        r = [x y x+w y+h];
        tries = 0;
        while (overlaps(r, fixedR, pad) || overlaps(r, placed, 6)) && tries < 30
            step = max(w, 96) + 14;                                 % a column pitch wide enough for the name label
            r = r + side * [step 0 step 0]; tries = tries + 1;      % push outward, next column
        end
        placed(end+1,:) = r; %#ok<AGROW>
        if opts.Apply
            if ~isequal(round(r), p), set_param(b, 'Position', round(r)); end
            % face the pin: an Inport to the RIGHT of its pin points left, an
            % Outport to the LEFT of its pin takes its input from the right
            if (isIn && side > 0) || (~isIn && side < 0), ori = 'left'; else, ori = 'right'; end
            if ~strcmp(get_param(b,'Orientation'), ori), set_param(b, 'Orientation', ori); nFlip = nFlip + 1; end
        end
        n = n + 1;
    end
    if opts.Apply
        % routeLine keeps old bend points; rebuild the lines so they take fresh routes
        flat_reroute(kit, 'Subsystem', strrep(sub, [sys '/'], ''), 'Save', false);
    end
end
fprintf('%s: %d ports snapped to their pins, %d coloured, %d flipped to face their pin, across %d subsystem(s)\n', ...
    ternary(opts.Apply,'APPLY','DRY RUN'), n, nCol, nFlip, numel(subs));
if ~opts.Apply, return; end
n1 = numel(find_system(sys,'LookUnderMasks','all','FollowLinks','off','Type','Block'));
assert(n1 == n0, 'block count changed %d -> %d; NOT saving', n0, n1);
save_system(sys, [], 'OverwriteIfChangedOnDisk', true);
fprintf('FLAT_SNAP_DONE moved=%d saved=%s\n', n, get_param(sys,'FileName'));
end

% ---------------------------------------------------------------------------
function [pin, side] = wiredPin(portBlk, type)
% pin = [x y] of the block pin this port block is wired to; side = -1 if that
% pin is on the left half of its block (place the port to the left), +1 otherwise
pin = []; side = 0;
ph = get_param(portBlk,'PortHandles');
if strcmp(type,'Inport')
    ln = get_param(ph.Outport(1),'Line'); if ln <= 0, return; end
    dst = get_param(ln,'DstPortHandle'); dst = dst(dst > 0);
    cands = dst;
else
    ln = get_param(ph.Inport(1),'Line'); if ln <= 0, return; end
    src = get_param(ln,'SrcPortHandle'); if src <= 0, return; end
    cands = src;
end
for c = reshape(cands,1,[])
    parent = get_param(c,'Parent');
    if any(strcmp(get_param(parent,'BlockType'), {'Inport','Outport'})), continue; end
    pin = get_param(c,'Position');
    bp = get_param(parent,'Position');
    if pin(1) <= (bp(1)+bp(3))/2, side = -1; else, side = 1; end
    return;
end
end

function tf = overlaps(r, R, pad)
if isempty(R), tf = false; return; end
tf = any(r(1) < R(:,3)+pad & r(3) > R(:,1)-pad & r(2) < R(:,4)+pad & r(4) > R(:,2)-pad);
end

function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end
