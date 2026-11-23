function L = flat_layout_lanes(kit, subsystem, opts)
% flat_layout_lanes -- lay out ONE subsystem level as labelled horizontal lanes.
%
%   L = flat_layout_lanes(kit, 'TxRxComposite')                  dry run (classification)
%   L = flat_layout_lanes(kit, 'TxRxComposite/Receiver', 'Apply', true)
%   L = flat_layout_lanes(kit, sub, 'Lanes', {...}, 'Patterns', {...}, 'Apply', true)
%
% Lanes and name patterns come from a preset (see presets() at the bottom) for
% the subsystems already worked on, or from the 'Lanes'/'Patterns' options for a
% new one. Blocks are sorted into lanes by name pattern first; any block still
% unassigned takes the lane of the majority of its wired neighbours (repeated
% until stable); leftovers go to the LAST lane and are listed. Inside a lane
% each signal chain runs left to right on one horizontal row (columns = flow
% rank, blocks centred on the row), and branches fan off into rows below.
% Blocks are turned to face left-to-right ('Orient', default true) so a mirrored
% subsystem reads with the flow; ports follow when flat_snap_ports runs after. Ports
% go beside the lane of the blocks they are wired to. Each lane gets a named
% Area. Lines are rebuilt afterwards (flat_reroute). Run flat_snap_ports on the
% same subsystem afterwards to pull each port onto its pin.
%
% Nothing structural changes; the block count is asserted before saving.
arguments
    kit (1,:) char = pwd
    subsystem (1,:) char = 'TxRxComposite'
    opts.Apply (1,1) logical = false
    opts.Lanes cell = {}
    opts.Patterns cell = {}
    opts.Orient (1,1) logical = true     % face every block left-to-right so chains read with the flow
end
sys = 'commhdlQPSKTxRxLoopback';
if ~bdIsLoaded(sys), load_system(fullfile(kit,[sys '.slx'])); end
loop = [sys '/' subsystem];
if ~isempty(opts.Lanes)
    lanes = opts.Lanes; pat = opts.Patterns;
else
    [lanes, pat] = presets(subsystem);
end
assert(numel(lanes) == numel(pat) && ~isempty(lanes), 'need one name pattern per lane');
nL = numel(lanes);

% ---- inventory ---------------------------------------------------------------
blks = find_system(loop,'SearchDepth',1,'Type','Block');
blks = blks(~strcmp(blks, loop));
isPort = cellfun(@(b) any(strcmp(get_param(b,'BlockType'),{'Inport','Outport'})), blks);
isArea = cellfun(@(b) strcmp(get_param(b,'BlockType'),'Area'), blks);
work = blks(~isPort & ~isArea);
n0 = numel(find_system(loop,'SearchDepth',1,'Type','Block'));

% neighbours via PortConnectivity (block handles)
H = cellfun(@(b) get_param(b,'Handle'), blks);
nb = containers.Map('KeyType','double','ValueType','any');
for k = 1:numel(blks)
    pc = get_param(blks{k},'PortConnectivity'); s = [];
    for j = 1:numel(pc)
        s = [s, pc(j).SrcBlock(pc(j).SrcBlock > 0), pc(j).DstBlock(pc(j).DstBlock > 0)]; %#ok<AGROW>
    end
    nb(H(k)) = unique(s(ismember(s, H)));
end

% ---- classify ----------------------------------------------------------------
lane = zeros(numel(work),1);
for k = 1:numel(work)
    nm = get_param(work{k},'Name');
    for g = 1:nL
        if ~isempty(regexp(nm, pat{g}, 'once')), lane(k) = g; break; end
    end
end
hw = cellfun(@(b) get_param(b,'Handle'), work);
laneOf = containers.Map('KeyType','double','ValueType','double');
changed = true; iter = 0;
while changed && iter < 20
    changed = false; iter = iter + 1;
    for k = 1:numel(work), if lane(k) > 0, laneOf(hw(k)) = lane(k); end, end
    for k = 1:numel(work)
        if lane(k) > 0, continue; end
        v = zeros(1,nL);
        for h = nb(hw(k)), if laneOf.isKey(h), v(laneOf(h)) = v(laneOf(h)) + 1; end, end
        if any(v), [~, lane(k)] = max(v); changed = true; end
    end
end
left = work(lane == 0); lane(lane == 0) = nL;
L = table(cellfun(@(b) get_param(b,'Name'), work, 'uni', 0), lanes(lane)', 'VariableNames', {'block','lane'});
for g = 1:nL, fprintf('%-26s %3d blocks\n', lanes{g}, sum(lane == g)); end
if ~isempty(left), fprintf('unclassified -> last lane: %s\n', strjoin(cellfun(@(b) get_param(b,'Name'), left, 'uni', 0), ', ')); end
if ~opts.Apply, fprintf('dry run: nothing moved. Re-run with ''Apply'',true.\n'); return; end

% ---- port lane assignment (majority of wired neighbours; unresolved -> DEBUG)
portLane = containers.Map('KeyType','char','ValueType','double');
for typ = {'Inport','Outport'}
    for b = reshape(find_system(loop,'SearchDepth',1,'BlockType',typ{1}),1,[])
        v = zeros(1,nL);
        for h = nb(get_param(b{1},'Handle')), if laneOf.isKey(h), v(laneOf(h)) = v(laneOf(h)) + 1; end, end
        if any(v), [~, g] = max(v); else, g = nL; end
        portLane(b{1}) = g;
    end
end

% ---- placement: one pass per lane; blocks in flow-rank columns, that lane's
%      ports stacked beside it (several columns if many), lane box around all
X0 = 420; colGap = 90; rowGap = 35; laneGap = 120; laneTop = 60; maxPerCol = 22; portPitch = 36; portColGap = 110;
laneMaxRight = X0;
areaBox = zeros(nL,4);
y = laneTop;
for g = 1:nL
    idx = find(lane == g);
    x = X0; laneBottom = y + 60;
    if ~isempty(idx)
        hh = hw(idx);
        rank = zeros(numel(idx),1);
        inLane = containers.Map('KeyType','double','ValueType','double');
        for j = 1:numel(idx), inLane(hh(j)) = j; end
        preds = cell(numel(idx),1);
        for j = 1:numel(idx)
            pc = get_param(work{idx(j)},'PortConnectivity'); p = [];
            for q = 1:numel(pc), p = [p, pc(q).SrcBlock(pc(q).SrcBlock > 0)]; end %#ok<AGROW>
            p = unique(p); p = p(arrayfun(@(h) inLane.isKey(h), p));
            preds{j} = arrayfun(@(h) inLane(h), p);
        end
        for pass = 1:numel(idx)
            moved = false;
            for j = 1:numel(idx)
                r = 0; for p = reshape(preds{j},1,[]), if p ~= j, r = max(r, rank(p) + 1); end, end
                if r > rank(j) && r < numel(idx), rank(j) = r; moved = true; end
            end
            if ~moved, break; end
        end
        % ---- rows: follow each signal chain left to right on ONE horizontal
        %      line; a branch that cannot continue its predecessor's row starts a
        %      new row below. Columns are the flow ranks; every block in a row is
        %      centred on the same y, so single-pin chains draw as straight lines.
        succs = cell(numel(idx),1);
        for j = 1:numel(idx)
            pc = get_param(work{idx(j)},'PortConnectivity'); d = [];
            for q = 1:numel(pc), d = [d, pc(q).DstBlock(pc(q).DstBlock > 0)]; end %#ok<AGROW>
            d = unique(d, 'stable'); d = d(arrayfun(@(h) inLane.isKey(h), d));
            succs{j} = zeros(1,0); for h = reshape(d,1,[]), succs{j}(end+1) = inLane(h); end
        end
        row = zeros(numel(idx),1); nRows = 0;
        % sources first (no in-lane predecessor), big subsystems before small blocks
        isSrc = cellfun(@isempty, preds) | (rank == 0);
        [~, srcOrder] = sortrows([~isSrc, ~cellfun(@(b) strcmp(get_param(b,'BlockType'),'SubSystem'), work(idx)), (1:numel(idx))']);
        stack = srcOrder(:)';
        while ~isempty(stack)
            j = stack(1); stack(1) = [];
            if row(j) > 0, continue; end
            nRows = nRows + 1; row(j) = nRows;
            % walk the chain: first unplaced successor continues the row, the rest queue
            cur = j;
            while true
                nxt = [];
                for h = reshape(succs{cur},1,[]), if row(h) == 0 && h ~= cur, nxt(end+1) = h; end, end %#ok<AGROW>
                if isempty(nxt), break; end
                % prefer the successor whose rank is exactly one more (a direct link)
                [~, o] = sort(abs(rank(nxt) - (rank(cur) + 1))); nxt = nxt(o);
                row(nxt(1)) = row(cur);
                stack = [reshape(nxt(2:end),1,[]), reshape(stack,1,[])];
                cur = nxt(1);
            end
        end
        % column x by rank (width = widest block in that rank), row y by tallest block
        colW = zeros(max(rank)+1,1);
        for j = 1:numel(idx), p = get_param(work{idx(j)},'Position'); colW(rank(j)+1) = max(colW(rank(j)+1), p(3)-p(1)); end
        colX = zeros(max(rank)+1,1); x = X0;
        for r = 1:numel(colW), colX(r) = x; x = x + colW(r) + colGap; end
        rowH = zeros(nRows,1);
        for j = 1:numel(idx), p = get_param(work{idx(j)},'Position'); rowH(row(j)) = max(rowH(row(j)), p(4)-p(2)); end
        rowC = zeros(nRows,1); yy = y;
        for r = 1:nRows, rowC(r) = yy + rowH(r)/2; yy = yy + rowH(r) + rowGap; end
        for j = 1:numel(idx)
            if opts.Orient && ~strcmp(get_param(work{idx(j)},'Orientation'),'right'), set_param(work{idx(j)},'Orientation','right'); end
            p = get_param(work{idx(j)},'Position'); w = p(3)-p(1); h = p(4)-p(2);
            bx = colX(rank(j)+1); by = round(rowC(row(j)) - h/2);
            set_param(work{idx(j)}, 'Position', [bx by bx+w by+h]);
        end
        laneBottom = max(laneBottom, yy);
    end
    laneRight = x;
    % this lane's ports
    for typ = {'Inport','Outport'}
        pb = find_system(loop,'SearchDepth',1,'BlockType',typ{1});
        pb = pb(cellfun(@(b) portLane(b) == g, pb));
        pn = cellfun(@(b) str2double(get_param(b,'Port')), pb); [~, o] = sort(pn); pb = pb(o);
        nCols = max(1, ceil(numel(pb) / maxPerCol));
        for k = 1:numel(pb)
            c = floor((k-1) / maxPerCol); rIdx = mod(k-1, maxPerCol);
            p = get_param(pb{k},'Position'); w = p(3)-p(1); h = p(4)-p(2);
            if strcmp(typ{1},'Inport'), xp = 60 + (nCols-1-c) * portColGap; else, xp = laneRight + 80 + c * portColGap; end
            yp = y + rIdx * portPitch;
            set_param(pb{k}, 'Position', [xp yp xp+w yp+h]);
            laneBottom = max(laneBottom, yp + h + rowGap);
        end
        if strcmp(typ{1},'Outport'), laneRight = laneRight + 80 + nCols * portColGap; end
    end
    laneMaxRight = max(laneMaxRight, laneRight);
    areaBox(g,:) = [X0-30, y-34, x, laneBottom];
    y = laneBottom + laneGap;
end

% ---- areas (annotations; delete any previous ones of the same names) --------
for a = reshape(find_system(loop,'SearchDepth',1,'FindAll','on','Type','Annotation'),1,[])
    try
        nm = get_param(a,'Name'); tx = get_param(a,'Text');
        if any(strcmp(nm, lanes)) || any(strcmp(tx, lanes)) || strcmp(tx, 'DEBUG / INSTRUMENTS'), delete(a); end
    catch, end
end
for g = 1:nL
    try
        add_block('built-in/Area', [loop '/' lanes{g}], 'Position', areaBox(g,:));
    catch err
        fprintf('area "%s" not created (%s); leaving a label instead\n', lanes{g}, err.message);
        an = Simulink.Annotation(loop, lanes{g}); an.Position = areaBox(g,1:2) - [0 22]; an.FontSize = 12; an.FontWeight = 'bold';
    end
end

% ---- routing: rebuild the lines so they take fresh routes ------------------
flat_reroute(kit, 'Subsystem', subsystem, 'Save', false);

nAreas = 0;
for a = reshape(find_system(loop,'SearchDepth',1,'FindAll','on','Type','Annotation'),1,[])
    try, if any(strcmp(get_param(a,'Name'), lanes)), nAreas = nAreas + 1; end, catch, end
end
n1 = numel(find_system(loop,'SearchDepth',1,'Type','Block'));
assert(n1 == n0, 'block count changed %d -> %d; NOT saving', n0, n1);
save_system(sys, [], 'OverwriteIfChangedOnDisk', true);
fprintf('FLAT_LAYOUT_DONE subsystem=%s lanes=%d areas=%d saved=%s\n', subsystem, nL, nAreas, get_param(sys,'FileName'));
end

function [lanes, pat] = presets(subsystem)
switch subsystem
    case 'TxRxComposite'
        lanes = {'TRANSMITTER PATH','RECEIVER PATH','BYTE DMA INTERFACE','DEBUG AND INSTRUMENTS'};
        pat = { '^(Transmitter|HostCap|HostRT|REP_Tx|MUX_Dac|T_repValid|DS_TxValid|SelRT|ByteSel|WordRT|PopRT|PopDly|PopEdge)'
                '^(Receiver|AdcRT|AdcStab|AdcCap|MUX_Rx|RxValidConst|IntValidConst|RT_Rx)'
                '^(ByteWordBuffer|ByteSerializer|byteRxFifo|ByteRxFifo|FirstRT|AvailRT|Ser\w*RT|BsRt|RxReadyRT|ReadyDly)'
                '^(FrameStat|frameStat|Fs[A-Z]|Bs\w*Census|DbgSentinel|FixCtl|\w*Census|\w*Canary|\w*Probe)' };
    case 'TxRxComposite/Receiver'
        % Receiver level: ADC/valid/reset conditioning (downsample to the symbol
        % rail + pipeline delays), the QPSK Rx core, the register hold/downsample
        % pairs that bring the AXI loop gains onto the rail, and the output side
        % (bus split, BIST capture, repeat-up to the DMA rail, capture taps).
        lanes = {'INPUT CONDITIONING','QPSK RX CORE','REGISTER HOLD AND DOWNSAMPLE','OUTPUTS, BIST AND CAPTURE TAPS'};
        pat = { '^(Downsample[0-4]?$|Real-Imag to Complex|Data Type Conversion2$|Delay[1-6]?$)'
                '^QPSK Rx$'
                '^(RegHold_|RegDS_|SkipHold|SkipDS)'
                '^(Bus Selector|Bus Creator|Repeat|Capture Data Bits|Delay(7|8|11)$)' };
    otherwise
        error('flat_layout_lanes: no preset for "%s" -- pass ''Lanes'' and ''Patterns''', subsystem);
end
end
