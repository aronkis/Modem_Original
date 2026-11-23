function n = resize_ports_like(model, inRef, outRef, opts)
% resize_ports_like -- give every Inport and Outport block in a Simulink model
% the same on-canvas dimensions (width x height) as a reference port block.
%
%   n = resize_ports_like(model)
%   n = resize_ports_like(model, inRef, outRef)
%   n = resize_ports_like(model, inRef, outRef, 'Save', true, 'Anchor', 'center')
%
% model   model name (loaded if needed) or a path to a .slx
% inRef   name of the reference Inport block  (default 'ss_prop_gain')
% outRef  name of the reference Outport block (default 'cnt_descr_in')
% opts    'Anchor'  'center' (default) keeps each port's centre where it is,
%                   'topleft' keeps its top-left corner
%         'Save'    false (default): change in memory only, you save yourself
%         'DryRun'  false (default): true prints what would change, touches nothing
%
% The reference block is located by name anywhere under the model (first match,
% searching under masks, not following library links); its Position gives the
% target size. Every Inport / Outport block that is not inside a library-linked
% subsystem is then resized. Blocks already at the target size are left alone.
% Returns the number of blocks resized. Nothing is saved unless 'Save' is true.
arguments
    model  (1,:) char
    inRef  (1,:) char = 'ss_prop_gain'
    outRef (1,:) char = 'cnt_descr_in'
    opts.Anchor (1,:) char {mustBeMember(opts.Anchor, {'center','topleft'})} = 'center'
    opts.Save   (1,1) logical = false
    opts.DryRun (1,1) logical = false
end

% ---- load ------------------------------------------------------------------
[~, name, ext] = fileparts(model);
if ~isempty(ext), assert(exist(model,'file')==2, 'model file not found: %s', model); end
if ~bdIsLoaded(name), load_system(model); end
sys = name;

% ---- reference sizes -------------------------------------------------------
sizeIn  = refSize(sys, inRef,  'Inport');
sizeOut = refSize(sys, outRef, 'Outport');
fprintf('reference Inport  "%s": %d x %d\n', inRef,  sizeIn(1),  sizeIn(2));
fprintf('reference Outport "%s": %d x %d\n', outRef, sizeOut(1), sizeOut(2));

% ---- every port block, excluding library-linked internals -------------------
ports = [find_system(sys,'LookUnderMasks','all','FollowLinks','off','BlockType','Inport'); ...
         find_system(sys,'LookUnderMasks','all','FollowLinks','off','BlockType','Outport')];
n = 0; skipped = 0;
for k = 1:numel(ports)
    b = ports{k};
    if insideLibraryLink(b), skipped = skipped + 1; continue; end
    isIn = strcmp(get_param(b,'BlockType'),'Inport');
    if isIn, wh = sizeIn; else, wh = sizeOut; end
    p = get_param(b,'Position');            % [left top right bottom]
    cur = [p(3)-p(1), p(4)-p(2)];
    if isequal(cur, wh), continue; end
    switch opts.Anchor
        case 'center'
            cx = (p(1)+p(3))/2; cy = (p(2)+p(4))/2;
            q = round([cx-wh(1)/2, cy-wh(2)/2, cx+wh(1)/2, cy+wh(2)/2]);
        case 'topleft'
            q = [p(1), p(2), p(1)+wh(1), p(2)+wh(2)];
    end
    if opts.DryRun
        fprintf('would resize %-7s %3dx%-3d -> %3dx%-3d  %s\n', ...
            get_param(b,'BlockType'), cur(1), cur(2), wh(1), wh(2), b);
    else
        set_param(b, 'Position', q);
    end
    n = n + 1;
end
fprintf('%s %d port blocks (%d inside library links left alone)\n', ...
    ternary(opts.DryRun, 'would resize', 'resized'), n, skipped);

if opts.Save && ~opts.DryRun
    save_system(sys, [], 'OverwriteIfChangedOnDisk', true);
    fprintf('saved %s\n', get_param(sys,'FileName'));
end
end

% ---------------------------------------------------------------------------
function wh = refSize(sys, nm, type)
hits = find_system(sys,'LookUnderMasks','all','FollowLinks','off','BlockType',type,'Name',nm);
assert(~isempty(hits), 'reference %s block "%s" not found under %s', type, nm, sys);
if numel(hits) > 1
    fprintf('note: %d %s blocks named "%s"; using %s\n', numel(hits), type, nm, hits{1});
end
p = get_param(hits{1},'Position');
wh = [p(3)-p(1), p(4)-p(2)];
end

function tf = insideLibraryLink(b)
% true if any ancestor subsystem of block b is a resolved/active library link
tf = false;
parent = get_param(b,'Parent');
while ~isempty(parent) && any(parent == '/')
    try
        ls = get_param(parent,'LinkStatus');
    catch
        ls = 'none';
    end
    if ~any(strcmp(ls, {'none','inactive'})), tf = true; return; end
    parent = get_param(parent,'Parent');
end
end

function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end
