function patch_hdlworkflow_rxfix(wfFile)
% patch_hdlworkflow_rxfix -- AXI mappings for the RXFIX model overlays
% (modem/rxfix/, cleanup sub-project 3).  Env-gated like the overlays: with
% QPSK_RXFIX unset this is a NO-OP, so the workflow file stays byte-identical
% (the ports do not exist).  Pattern-clone of patch_hdlworkflow_beatfix.m with
% patch_hdlworkflow_loopgain.m's emitted block-existence guard; idempotent.
%
% W1 (task 4) -- eight READ words, exactly docs/evidence/rxfix/W1_REGMAP.md §1:
%   w1_wita x"214"  {16'b0, occ[5:0], pushPtr[4:0], popPtr[4:0]}
%   w1_witb x"218"  {push_on_full[15:0], pop_on_empty[15:0]}
%   w1_ss   x"21C"  Symbol_Synchronizer strobe count   (census stage a)
%   w1_rh   x"220"  Rate_Handle validOut count         (stage b)
%   w1_cfc  x"224"  Coarse_Frequency_Compensator       (stage c)
%   w1_cs   x"228"  Carrier_Synchronizer               (stage d)
%   w1_pd   x"22C"  Preamble_Detector                  (stage e)
%   w1_pc   x"230"  Packet_Controller                  (stage f)
%
% STEER (task 5) -- three READ words, the runtime-selected R4B/R4D steering:
%   r4_wit    x"234"  {locked[31], skips[30:15], opens[14:0]}   (R4B's layout,
%                     and the address rxfix_inject.py's R4D hunk already used)
%   r4_extras x"238"  {16'b0, extras[15:0]}  -- the FULL-edge pops actually taken
%   sro_mode  x"25C"  {30'b0, extraArmed[1], sroSign[0]}  -- reads back which
%                     branch the image is running, i.e. fixctl bit 5 as the
%                     fabric saw it plus whether the extra branch is armed.
% BS (task 7) -- eight READ words, the byte-seam census, layout of record in
% modem/fixes/fixes.toml [fixes.BS] and bit-truth in rxfix_inject.py's
% bs_seam_census.  They occupy the eight FREE words 0x8F..0x96 = bytes
% 0x23C..0x258, i.e. they BRACKET the steering pair 0x234/0x238 and stop one word
% short of STEER's 0x25C:
%   bs_words  x"23C"  ByteSerializer words emitted (fillers included, post-PAD)
%   bs_starts x"240"  RxAlign start pulses = frame boundaries
%   bs_push   x"244"  ByteRxFifo pushes
%   bs_pop    x"248"  ByteRxFifo pops
%   bs_drop   x"24C"  ByteRxFifo drop-oldest events
%   bs_marks  x"250"  {bs_lasts[31:16], bs_markpush[15:0]}
%   bs_evt    x"254"  {trunc_last, trunc_min, trunc_max, dropmax}  (SATURATE)
%   bs_cnt    x"258"  {bs_trunc[31:16], bs_q24[15:8], 8'b0}
% Their freeze is fixctl bit 4, the SAME level W1 shadows behind, so a host sweep
% of 0x214-0x258 is one coherent snapshot.
%
% The arm itself is fixctl bit 5, a bit of the EXISTING write register 0x208, so
% nothing to map for it.  0x234/0x238 are the injector's own R4D addresses
% (W1_REGMAP.md sec 6-R4D); 0x25C is the next free word after beatila's 0x258.
% All eleven are free today (the occupied map ends at beatfix's 0x210; the
% injector's own note records 0x214-0x230 hitting `default: const_0`).  Freeze is
% fixctl bit 4 -- a bit of the EXISTING write register 0x208, so nothing to map.
%
% WHY THE GUARD IS EMITTED, NOT EVALUATED HERE.  assemble_jupiter_240k5_byte.m
% runs the phase-0 workflow patches BEFORE the model is loaded and overlaid, so a
% find_system for w1_wita at patch time always misses.  The guard therefore goes
% INTO the workflow text and runs when the workflow does, by which time the
% overlay has added the ports (patch_hdlworkflow_loopgain.m:25 does the same).

if isempty(getenv('QPSK_RXFIX'))
    fprintf('patch_hdlworkflow_rxfix: QPSK_RXFIX unset -- no-op\n');
    return;
end
if nargin < 1, wfFile = 'hdlworkflow_loopback.m'; end
sys = 'commhdlQPSKTxRxLoopback';
txt = fileread(wfFile);
if contains(txt, 'rxfix mapping')
    fprintf('patch_hdlworkflow_rxfix: already patched -- skipping\n');
    return;
end
regs = { 'w1_wita','214'; 'w1_witb','218'; 'w1_ss','21C'; 'w1_rh','220'; ...
         'w1_cfc','224';  'w1_cs','228';   'w1_pd','22C'; 'w1_pc','230'; ...
         'r4_wit','234';  'r4_extras','238'; 'sro_mode','25C'; ...
         'bs_words','23C'; 'bs_starts','240'; 'bs_push','244'; 'bs_pop','248'; ...
         'bs_drop','24C';  'bs_marks','250'; 'bs_evt','254';  'bs_cnt','258' };
L = ['% --- rxfix mapping (W1 ring witness + per-stage valid census, 0x214-0x230,' newline ...
     '%     shadowed behind fixctl bit 4; steering witnesses 0x234/0x238/0x25C,' newline ...
     '%     the R4B/R4D pop steering armed by fixctl bit 5. All read-only =>' newline ...
     '%     AXI4-Lite READ registers. Block-existence guard self-syncs with' newline ...
     '%     rxfix_w1_overlay / rxfix_steer_overlay -- both overlays run in the' newline ...
     '%     same phase 2.21 block, so one guard covers both port sets). ---' newline];
L = [L 'if ~isempty(find_system(''' sys '/TxRxComposite'',''SearchDepth'',1,''BlockType'',''Outport'',''Name'',''w1_wita''))' newline];
for i = 1:size(regs,1)
    p = [sys '/TxRxComposite/' regs{i,1}];
    L = [L 'hdlset_param(''' p ''', ''IOInterface'', ''AXI4-Lite'');' newline]; %#ok<AGROW>
    L = [L 'hdlset_param(''' p ''', ''IOInterfaceMapping'', ''x"' regs{i,2} '"'');' newline]; %#ok<AGROW>
end
L = [L 'end' newline '% --- end rxfix mapping ---' newline];

% anchored AFTER the beatfix mapping block: W1's freeze is a bit of beatfix's own
% fixctl register, so beatfix is a hard prerequisite -- if its block is absent the
% overlay could not have run either, and failing here is the loud way to say so.
anchor = '% --- end beatfix mapping ---';
idx = strfind(txt, anchor);
assert(~isempty(idx), ['patch_hdlworkflow_rxfix: beatfix mapping anchor not found in %s ' ...
                       '(QPSK_RXFIX needs QPSK_BEATFIX: fixctl 0x208 carries W1 freeze)'], wfFile);
at = idx(1) + numel(anchor);
if at <= numel(txt) && txt(at) == newline, at = at + 1; end
txt = [txt(1:at-1) newline L txt(at:end)];
fid = fopen(wfFile, 'w');
fwrite(fid, txt); fclose(fid);
fprintf(['patch_hdlworkflow_rxfix: added W1 AXI read mappings 0x214-0x230 and ' ...
         'steering 0x234/0x238/0x25C and byte-seam census 0x23C-0x258 to %s\n'], wfFile);
end
