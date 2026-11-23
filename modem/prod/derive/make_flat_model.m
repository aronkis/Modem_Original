% make_flat_model.m -- produce a READABLE reference copy of the fully-overlaid
% DUT model: run the byte-complete assemble (every overlay the production image
% gets, chosen by the QPSK_* environment the caller exported), then auto-arrange
% every subsystem under TxRxComposite and save the result under a new name.
%
% This is a reading/review artefact. The build chain does NOT consume it: images
% are still regenerated from commhdlQPSKTxRx.slx + the overlay stack by
% build_hdl.sh, so Gates 1-3 are untouched.
%
% Run from a scratch KIT COPY (make_flat_model.sh does the copy + repoint), not
% from the repo modem/ dir: the assemble edits both .slx files in place.
%
% Output: <kit>/<OUT_NAME>.slx  (default commhdlQPSKTxRxLoopback_flat.slx), plus
% <kit>/flat_model_report.txt (block counts per subsystem, arrange results) and
% best-effort PNG snapshots of the top two levels.

KITDIR = fileparts(fileparts(mfilename('fullpath')));   % the kit root; this script runs from <kit>/derive/
run('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/setup.m');
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox');
cd(KITDIR); kitpath(KITDIR);   % kit LAST -> its params win (same as build_variant_byte.m)
fprintf('make_flat_model cwd=%s\n', pwd);

outName = getenv('FLAT_OUT_NAME'); if isempty(outName), outName = 'commhdlQPSKTxRxLoopback_flat'; end
gitSha  = getenv('FLAT_GIT_SHA');  if isempty(gitSha),  gitSha  = 'unknown'; end
envTags = {'QPSK_LEAN','QPSK_FRAME','QPSK_SPS','QPSK_BEATFIX','QPSK_BEATOBS','QPSK_FRAMESTAT','QPSK_RXFIX','QPSK_TXFIX'};
envStr = '';
for k = 1:numel(envTags), envStr = [envStr sprintf('%s=%s ', envTags{k}, getenv(envTags{k}))]; end %#ok<AGROW>
fprintf('env: %s\n', envStr);

try; rmdir(fullfile(pwd,'slprj'),'s'); catch; end

% ---- 1. every overlay, exactly as the image build applies them ------------
run('assemble_jupiter_240k5_byte.m');   % saves commhdlQPSKTxRxLoopback.slx in the kit
sys  = 'commhdlQPSKTxRxLoopback';
loop = [sys '/TxRxComposite'];
assert(bdIsLoaded(sys), 'assemble did not leave %s loaded', sys);
nBlocksAssembled = numel(find_system(sys,'LookUnderMasks','all','FollowLinks','off','Type','Block'));
fprintf('assembled: %d blocks under %s\n', nBlocksAssembled, sys);

% ---- 2. save under the new name, then arrange the copy --------------------
flatFile = fullfile(KITDIR, [outName '.slx']);
if exist(flatFile,'file'), delete(flatFile); end
save_system(sys, flatFile);           % renames the loaded diagram to outName
close_system(sys, 0);                 % drop the assembled original from memory (already saved by assemble)
load_system(outName);
sys  = outName; loop = [sys '/TxRxComposite'];

% Walk every non-library subsystem under the DUT, deepest first, so parents are
% arranged after their children have their final port order.
subs = find_system(loop, 'LookUnderMasks','all', 'FollowLinks','off', 'BlockType','SubSystem');
subs = [{loop}; subs(:)];
depth = cellfun(@(s) sum(s == '/'), subs);
[~, ord] = sort(depth, 'descend');
subs = subs(ord);

rep = fopen(fullfile(KITDIR,'flat_model_report.txt'),'w');
fprintf(rep, 'flat model report  out=%s  git=%s\n%s\n', outName, gitSha, envStr);
fprintf(rep, 'assembled blocks: %d\n\n', nBlocksAssembled);
nArr = 0; nSkip = 0; nFail = 0;
for k = 1:numel(subs)
    s = subs{k};
    try
        link = get_param(s,'LinkStatus');
    catch
        link = 'none';
    end
    nb = numel(find_system(s,'SearchDepth',1,'LookUnderMasks','all','FollowLinks','off','Type','Block')) - 1;
    if ~strcmp(link,'none') && ~strcmp(link,'inactive')
        fprintf(rep, 'SKIP  link=%-9s blocks=%4d  %s\n', link, nb, s); nSkip = nSkip+1; continue;
    end
    if nb < 2
        fprintf(rep, 'SKIP  trivial      blocks=%4d  %s\n', nb, s); nSkip = nSkip+1; continue;
    end
    try
        Simulink.BlockDiagram.arrangeSystem(s, 'FullLayout', 'true');
        fprintf(rep, 'OK    arranged     blocks=%4d  %s\n', nb, s); nArr = nArr+1;
    catch err
        fprintf(rep, 'FAIL  %-12s blocks=%4d  %s  (%s)\n', '', nb, s, strrep(err.message, newline, ' ')); nFail = nFail+1;
    end
end
fprintf(rep, '\narranged=%d skipped=%d failed=%d\n', nArr, nSkip, nFail);
fclose(rep);
fprintf('arranged=%d skipped=%d failed=%d\n', nArr, nSkip, nFail);

% ---- 2b. explanatory notes (documentation only; no blocks or lines change) --
try
    annotate_flat_rate_handle(sys);
catch err
    fprintf('annotate_flat_rate_handle skipped: %s\n', err.message);
end

% ---- 3. stamp + save -------------------------------------------------------
desc = get_param(sys,'Description');
set_param(sys,'Description', sprintf(['%s\n\nFLAT REFERENCE MODEL (make_flat_model.m): every overlay applied, ' ...
    'subsystems auto-arranged. Reading/review artefact only; the image build regenerates from ' ...
    'commhdlQPSKTxRx.slx + the overlay stack. git=%s  %s  arranged=%d skipped=%d failed=%d  %s'], ...
    desc, gitSha, envStr, nArr, nSkip, nFail, char(datetime('now'))));
save_system(sys, flatFile, 'OverwriteIfChangedOnDisk', true);
nBlocksFlat = numel(find_system(sys,'LookUnderMasks','all','FollowLinks','off','Type','Block'));
assert(nBlocksFlat == nBlocksAssembled, 'block count changed by arrange: %d -> %d', nBlocksAssembled, nBlocksFlat);

% ---- 4. best-effort snapshots (batch mode may lack a renderer) -------------
snaps = {sys, loop, [loop '/Transmitter'], [loop '/Receiver']};
for k = 1:numel(snaps)
    try
        png = fullfile(KITDIR, sprintf('flat_%02d.png', k));
        print(['-s' snaps{k}], '-dpng', '-r72', png);
        fprintf('snapshot %s -> %s\n', snaps{k}, png);
    catch err
        fprintf('snapshot %s skipped: %s\n', snaps{k}, err.message);
    end
end

fprintf('FLAT_MODEL_DONE file=%s blocks=%d arranged=%d skipped=%d failed=%d\n', flatFile, nBlocksFlat, nArr, nSkip, nFail);
