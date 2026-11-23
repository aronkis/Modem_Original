function r = flat_diff(kit, refFile)
% flat_diff -- what changed in the edited model versus the reference snapshot.
%
%   r = flat_diff(kit)              kit dir; compares commhdlQPSKTxRxLoopback.slx
%                                   against flat_ref.slx in the same dir
%   r = flat_diff(kit, refFile)     explicit reference .slx
%
% Reports, and writes to <kit>/FLAT_DIFF.txt:
%   * STRUCTURE EQUAL / DIFFERENT: same blocks, key parameters and connections
%     (Simulink's getChecksum is printed too but folds the model name in)
%   * blocks removed / added (full paths, model name normalised)
%   * blocks whose BlockType or key parameters changed
%   * TxRxComposite Inport/Outport list with port NUMBERS, before vs after --
%     the injectors and the AXI map key on names and order, so this is the
%     first thing to look at after deleting a debug port
%   * line counts per model
% Read-only: loads both models, changes nothing, unloads the reference.
if nargin < 1 || isempty(kit), kit = pwd; end
if nargin < 2 || isempty(refFile), refFile = fullfile(kit, 'flat_ref.slx'); end
edFile = fullfile(kit, 'commhdlQPSKTxRxLoopback.slx');
assert(isfile(edFile), 'edited model not found: %s', edFile);
assert(isfile(refFile), 'reference model not found: %s', refFile);

ed = 'commhdlQPSKTxRxLoopback';
if ~bdIsLoaded(ed), load_system(edFile); end
% the reference must be loaded under a DIFFERENT name: copy to a temp name
tmpDir = tempname; mkdir(tmpDir);
rf = 'flat_ref_cmp';
copyfile(refFile, fullfile(tmpDir, [rf '.slx']));
addpath(tmpDir);
load_system(fullfile(tmpDir, [rf '.slx']));
cleanup = onCleanup(@() cleanupRef(rf, tmpDir));

fid = fopen(fullfile(kit,'FLAT_DIFF.txt'),'w');
out = @(varargin) tee(fid, varargin{:});   % file + console
out('FLAT_DIFF %s\n  edited: %s\n  ref:    %s\n\n', char(datetime('now')), edFile, refFile);

% ---- checksum (informational: Simulink folds the MODEL NAME into it, so two
%      byte-identical files loaded under different names differ here) ---------
try
    ce = Simulink.BlockDiagram.getChecksum(ed);
    cr = Simulink.BlockDiagram.getChecksum(rf);
    out('CHECKSUM (name-dependent, informational) edited=%s ref=%s\n', sprintf('%02x',ce), sprintf('%02x',cr));
catch err
    out('CHECKSUM unavailable (%s)\n', strrep(err.message, newline, ' '));
end

% ---- block inventory -------------------------------------------------------
be = inventory(ed); br = inventory(rf);
removed = setdiff(br.keys, be.keys); added = setdiff(be.keys, br.keys);
out('\nBLOCKS ref=%d edited=%d removed=%d added=%d\n', numel(br.keys), numel(be.keys), numel(removed), numel(added));
for k = 1:numel(removed), out('  - %s  [%s]\n', removed{k}, br.type(removed{k})); end
for k = 1:numel(added),   out('  + %s  [%s]\n', added{k},   be.type(added{k}));   end
common = intersect(be.keys, br.keys); nChg = 0;
for k = 1:numel(common)
    p = common{k};
    if ~strcmp(be.sig(p), br.sig(p))
        if nChg == 0, out('\nCHANGED (type or key params):\n'); end
        out('  ~ %s\n      ref:    %s\n      edited: %s\n', p, br.sig(p), be.sig(p)); nChg = nChg + 1;
    end
end
if nChg == 0, out('CHANGED 0\n'); end

% ---- connections -----------------------------------------------------------
le = connections(ed); lr = connections(rf);
cRem = setdiff(lr, le); cAdd = setdiff(le, lr);
out('\nCONNECTIONS ref=%d edited=%d removed=%d added=%d\n', numel(lr), numel(le), numel(cRem), numel(cAdd));
for k = 1:numel(cRem), out('  - %s\n', cRem{k}); end
for k = 1:numel(cAdd), out('  + %s\n', cAdd{k}); end
same = isempty(removed) && isempty(added) && nChg == 0 && isempty(cRem) && isempty(cAdd);
out('\nSTRUCTURE %s\n', ternary(same, 'EQUAL (same blocks, parameters and connections)', 'DIFFERENT'));

% ---- composite ports -------------------------------------------------------
out('\nTxRxComposite PORTS (number:name)  -- order matters to the injectors and the AXI map\n');
for typ = {'Inport','Outport'}
    pe = portList(ed, typ{1}); pr = portList(rf, typ{1});
    out('  %s ref=%d edited=%d %s\n', typ{1}, numel(pr), numel(pe), ternary(isequal(pe,pr),'(identical)','(DIFFERENT)'));
    if ~isequal(pe, pr)
        out('    ref:    %s\n    edited: %s\n', strjoin(pr,' '), strjoin(pe,' '));
    end
end

% ---- lines -----------------------------------------------------------------
ne = numel(find_system(ed,'LookUnderMasks','all','FollowLinks','off','FindAll','on','Type','Line'));
nr = numel(find_system(rf,'LookUnderMasks','all','FollowLinks','off','FindAll','on','Type','Line'));
out('\nLINES ref=%d edited=%d\n', nr, ne);
fclose(fid);
r = struct('structureEqual', same, 'removed', {removed}, 'added', {added}, 'changed', nChg);
fprintf('FLAT_DIFF_DONE structure=%s blocks-=%d blocks+=%d changed=%d conn-=%d conn+=%d -> %s\n', ...
    ternary(same,'equal','different'), numel(removed), numel(added), nChg, numel(cRem), numel(cAdd), fullfile(kit,'FLAT_DIFF.txt'));
end

% ---------------------------------------------------------------------------
function inv = inventory(sys)
blks = find_system(sys,'LookUnderMasks','all','FollowLinks','off','Type','Block');
keys = cell(numel(blks),1); types = keys; sigs = keys;
for k = 1:numel(blks)
    b = blks{k};
    keys{k} = regexprep(b, ['^' regexptranslate('escape',sys)], '<model>');
    bt = get_param(b,'BlockType'); types{k} = bt;
    extra = '';
    for pn = {'Value','Gain','Operator','Port','OutDataTypeStr','SampleTime','Inputs','DelayLength','const'}
        try, v = get_param(b, pn{1}); if ischar(v), extra = [extra ' ' pn{1} '=' v]; end %#ok<AGROW>
        catch, end
    end
    sigs{k} = [bt extra];
end
inv.keys = keys; inv.type = containers.Map(keys, types); inv.sig = containers.Map(keys, sigs);
end

function L = portList(sys, typ)
loop = [sys '/TxRxComposite'];
b = find_system(loop,'SearchDepth',1,'BlockType',typ);
n = cellfun(@(x) str2double(get_param(x,'Port')), b);
[~, o] = sort(n); b = b(o); n = n(o);
L = arrayfun(@(k) sprintf('%d:%s', n(k), get_param(b{k},'Name')), 1:numel(b), 'uni', 0);
end

function C = connections(sys)
% one string per line segment: '<src block>:<port> -> <dst block>:<port>', model name normalised
ls = find_system(sys,'LookUnderMasks','all','FollowLinks','off','FindAll','on','Type','Line');
C = {};
for k = 1:numel(ls)
    sp = get_param(ls(k),'SrcPortHandle'); if sp <= 0, continue; end
    src = sprintf('%s:%d', getfullname(get_param(sp,'Parent')), get_param(sp,'PortNumber'));
    dps = get_param(ls(k),'DstPortHandle');
    for d = reshape(dps,1,[])
        if d <= 0, continue; end
        dst = sprintf('%s:%d', getfullname(get_param(d,'Parent')), get_param(d,'PortNumber'));
        C{end+1,1} = regexprep([src ' -> ' dst], ['(^|-> )' regexptranslate('escape',sys)], '$1<model>'); %#ok<AGROW>
    end
end
C = unique(C);
end

function cleanupRef(rf, tmpDir)
try, if bdIsLoaded(rf), close_system(rf, 0); end, catch, end
try, rmpath(tmpDir); rmdir(tmpDir,'s'); catch, end
end

function tee(fid, varargin)
fprintf(fid, varargin{:}); fprintf(1, varargin{:});
end

function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end
