function patch_hdlworkflow_tilteq(wfFile)
% patch_hdlworkflow_tilteq -- map the two TiltEq AXI4-Lite WRITE words
% (0x260 tilt_eq_a12, 0x264 tilt_eq_a3en; tilt_eq_overlay.m) in the HDL
% workflow script, the same mechanism as patch_hdlworkflow_loopgain. Block-
% existence guard self-syncs with the overlay gating. Idempotent.
if nargin < 1, wfFile = 'hdlworkflow_loopback.m'; end
sys = 'commhdlQPSKTxRxLoopback';
txt = fileread(wfFile);
if contains(txt, 'tilt-eq mappings')
    fprintf('patch_hdlworkflow_tilteq: already patched -- skipping\n');
    return;
end
regs = { 'tilt_eq_a12','260'; 'tilt_eq_a3en','264' };
L = ['% --- tilt-eq mappings (receiver in-band tilt corrector, 0x260/0x264;' newline ...
     '%     tilt_eq_overlay.m). Inputs => AXI4-Lite WRITE registers. ---' newline];
L = [L 'if ~isempty(find_system(''' sys '/TxRxComposite'',''SearchDepth'',1,''BlockType'',''Inport'',''Name'',''tilt_eq_a12''))' newline];
for i = 1:size(regs,1)
    p = [sys '/TxRxComposite/' regs{i,1}];
    L = [L 'hdlset_param(''' p ''', ''IOInterface'', ''AXI4-Lite'');' newline]; %#ok<AGROW>
    L = [L 'hdlset_param(''' p ''', ''IOInterfaceMapping'', ''x"' regs{i,2} '"'');' newline]; %#ok<AGROW>
end
L = [L 'end' newline '% --- end tilt-eq mappings ---' newline];
anchor = '% --- end loop-gain tuning mappings ---';
idx = strfind(txt, anchor);
assert(~isempty(idx), 'patch_hdlworkflow_tilteq: loop-gain anchor not found in %s (apply patch_hdlworkflow_loopgain first)', wfFile);
at = idx(1) + numel(anchor);
if at <= numel(txt) && txt(at) == newline, at = at + 1; end
txt = [txt(1:at-1) L txt(at:end)];
fid = fopen(wfFile, 'w'); fwrite(fid, txt); fclose(fid);
fprintf('patch_hdlworkflow_tilteq: added 0x260/0x264 tilt-eq AXI mappings to %s\n', wfFile);
end
