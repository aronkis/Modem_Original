function rxfix_pad_overlay(sys, base)
% rxfix_pad_overlay -- F4: the ByteSerializer PADS a truncated frame to 191
% words, as a MODEL overlay (cleanup sub-project 3, task 7).  Formerly the
% netlist injector modem/fixes/rxfix_inject.py's RXFIX_PAD variant (banked twin
% modem/fixes/pad_patch.py).  Env-gated: QPSK_RXFIX.  UNCONDITIONAL -- no fixctl
% bit, exactly like the injector.
%
% WHY (ledger docs/evidence/comb/FWD_CRC_REGRESSION_0907.md sec 47.5-47.6).  A
% `start` arriving with 1..190 words accumulated used to abandon the partial
% frame at `wordCnt` words.  Downstream the stream is consumed in fixed 191-word
% frames by axi_dmac transfers with SYNC_TRANSFER_START, and ONE short frame
% misaligns every later transfer boundary: the DMAC holds ready low waiting for a
% tuser beat the FIFO head cannot present, the FIFO fills, and drop-oldest walks
% the head to the next mark -- three host frames lost per event.  Padding the
% truncated frame to exactly 191 words with all-zero fillers costs exactly ONE
% frame (no magic -> the host CRC fails) instead of three, and `wordLast` rides
% the last filler so `wordFirst` lands on the new frame's word 0 exactly as at a
% clean boundary.
%
% HOW IT IS DONE HERE.  The model's ByteSerializer is a MATLAB Function block
% wrapping the unit-tested core `qpskByteSerializer`; the injector's edit is to
% the GENERATED always block, and its exact model equivalent is a script edit to
% that wrapper, inserted between the core call and the `if wv` block that drives
% `tog`/`heldWord`.  That position is the whole semantic: the arbiter rewrites
% w/wv/wl IN PLACE, so the toggle, the held word, `wordFirst` and the RXFIX_BS
% taps all see the EMITTED word (fillers included), which is what makes
% bs_words count fillers -- the gate row words191_k1536 (79,760 words for 418
% frames) is unreachable otherwise.
%
% Three things are deliberate:
%
% (1) IT REQUIRES rxfix_bs_overlay.m TO HAVE RUN, and asserts it by anchor.  The
%     arming test needs the PRE-step word count, which BS surfaces as the local
%     `bsWcnt` (the injector's `state_wordCnt_1`); and the arbiter must land
%     ABOVE BS's tap lines, so BS's marker comment is the anchor.  The injector
%     has the same precondition ("RXFIX_PAD expects the RXFIX_BS-tapped
%     ByteSerializer").
% (2) THE PERSISTENTS JOIN THE EXISTING DECLARATION AND THE EXISTING INIT BLOCK,
%     rather than being declared mid-function.  The injector puts its resets in
%     the serializer's own reset branch; this is that, in model form, and it
%     keeps one reset for the whole block.
% (3) THE QUEUE IS THREE SCALARS, NOT AN ARRAY.  pq0/pq1/pq2 + pl0/pl1/pl2 + pqn
%     is the injector's shape (a 2-bit occupancy and three 64-bit regs); an array
%     persistent would invite HDL Coder to map it to RAM.  Three real words is the
%     bound: one word completes per 64 bits, against at most 190 filler beats.
%
% G0: the whole body early-returns when QPSK_RXFIX is unset.  It surfaces NOTHING
% -- no outport at any level, no AXI register -- so unlike the other RX overlays
% it needs no keep_last and can never cause a BASE_REGEN_INJECT_FAILED.
% Gate: modem/gates/build_sro_pad.legs.

if isempty(getenv('QPSK_RXFIX')), return; end
if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end
fprintf('=== rxfix_pad_overlay: ByteSerializer frame padding (F4) ===\n');

ser = [base '/ByteSerializer'];
if isempty(find_system(base,'SearchDepth',1,'LookUnderMasks','all','Name','ByteSerializer'))
  error('rxfix_pad: anchor missing: %s', ser);
end
S  = sfroot;
ch = S.find('Path', ser, '-isa', 'Stateflow.EMChart');
if isempty(ch), error('rxfix_pad: no Stateflow.EMChart at %s', ser); end
ch = ch(1);
sc = ch.Script;

% ---- idempotency ------------------------------------------------------------
if contains(sc, 'padCount')
  fprintf('rxfix_pad: already applied\n');
  return;
end

% ---- anchors ----------------------------------------------------------------
aPer = 'persistent state tog heldWord heldLast heldFirst firstNext';
aIni = '    heldFirst = true; firstNext = true;';
aBs  = '% BS byte-seam taps on the EMITTED word';
if ~contains(sc, aPer)
  error('rxfix_pad: ByteSerializer persistent declaration anchor missing');
end
if ~contains(sc, aIni)
  error('rxfix_pad: ByteSerializer persistent init anchor missing');
end
if ~contains(sc, aBs)
  error(['rxfix_pad: the BS byte-seam tap marker is not in the ByteSerializer script -- ' ...
         'rxfix_bs_overlay.m must run FIRST (phase 2.21 order), and PAD needs its ' ...
         'bsWcnt (the pre-step word count) to arm']);
end
if ~contains(sc, 'bsWcnt = state.wordCnt;')
  error('rxfix_pad: bsWcnt (pre-step word count) missing from the ByteSerializer script');
end

% ---- geometry: the delivered word count per frame (f1536 191, f3072 382) -----
cfg = frame_config_k5();
WPP = cfg.WordsPerPacketRx; WPPs = num2str(WPP); WPPm1 = num2str(WPP-1);

% ---- (1) persistents ---------------------------------------------------------
sc = strrep(sc, aPer, [aPer ' padCount pq0 pq1 pq2 pl0 pl1 pl2 pqn']);

% ---- (2) their reset ---------------------------------------------------------
sc = strrep(sc, aIni, [aIni newline ...
  '    padCount = uint16(0); pqn = uint8(0);' newline ...
  '    pq0 = uint64(0); pq1 = uint64(0); pq2 = uint64(0);' newline ...
  '    pl0 = false; pl1 = false; pl2 = false;']);

% ---- (3) the arbiter, ABOVE the BS byte-seam taps ----------------------------
% The inserted comment deliberately avoids the literal `RXFIX_PAD`: HDL Coder
% copies MATLAB comments into the generated ByteSerializer.v and
% modem/rtl_sim/tree_marker.sh greps that file for exactly that token to decide
% "injected tree" -- which made it report a MODEL tree as `PAD injector`.
% Statement order is the injector's: arm from the PRE-start word count first,
% then save the real word, then choose what is emitted.  A start that lands while
% fillers are still in flight does NOT re-arm (`padCount == 0` guard), which is
% the injector's `(pad_1 == 8'd0) &&` term.
arb = [ ...
'% PAD (F4) -- frame-length padding for TRUNCATED frames (ledger' newline ...
'% FWD_CRC_REGRESSION_0907 sec 47.5).  A start with 1..WPP-1 words accumulated' newline ...
'% schedules WPP - wordCnt all-zero fillers so the stream stays WPP-word' newline ...
'% aligned; real words completing meanwhile are queued (at most 3) and' newline ...
'% released in order afterwards.' newline ...
'if logical(start) && (padCount == uint16(0)) && ...' newline ...
'   (bsWcnt >= uint16(1)) && (bsWcnt <= uint16(' WPPm1 '))' newline ...
'    padCount = uint16(' WPPs ') - bsWcnt;' newline ...
'end' newline ...
'wR = w; wvR = wv; wlR = logical(wl);' newline ...
'w = uint64(0); wv = false; wl = false;' newline ...
'if padCount ~= uint16(0)' newline ...
'    w = uint64(0); wv = true; wl = (padCount == uint16(1));' newline ...
'    padCount = padCount - uint16(1);' newline ...
'    if wvR' newline ...
'        if pqn == uint8(0)' newline ...
'            pq0 = wR; pl0 = wlR; pqn = uint8(1);' newline ...
'        elseif pqn == uint8(1)' newline ...
'            pq1 = wR; pl1 = wlR; pqn = uint8(2);' newline ...
'        elseif pqn == uint8(2)' newline ...
'            pq2 = wR; pl2 = wlR; pqn = uint8(3);' newline ...
'        end' newline ...
'    end' newline ...
'elseif pqn ~= uint8(0)' newline ...
'    w = pq0; wl = pl0; wv = true;' newline ...
'    pq0 = pq1; pl0 = pl1; pq1 = pq2; pl1 = pl2; pqn = pqn - uint8(1);' newline ...
'    if wvR' newline ...
'        if pqn == uint8(0)' newline ...
'            pq0 = wR; pl0 = wlR; pqn = uint8(1);' newline ...
'        elseif pqn == uint8(1)' newline ...
'            pq1 = wR; pl1 = wlR; pqn = uint8(2);' newline ...
'        elseif pqn == uint8(2)' newline ...
'            pq2 = wR; pl2 = wlR; pqn = uint8(3);' newline ...
'        end' newline ...
'    end' newline ...
'else' newline ...
'    w = wR; wv = wvR; wl = wlR;' newline ...
'end' newline];
sc = strrep(sc, aBs, [arb aBs]);

ch.Script = sc;
if ~contains(ch.Script, 'padCount')
  error('rxfix_pad: the script edit did not take');
end
fprintf(['RXFIX_PAD_OVERLAY_OK: ByteSerializer pads a truncated frame to %d words ' ...
         '(pad = %d - wordCnt, 3-deep real-word queue); unconditional\n'], WPP, WPP);
end
