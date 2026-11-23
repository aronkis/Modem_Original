% packet_f3072.m -- F3072 doubled-frame bit contract for the 2-sps rung (sp4).
%
% Same K=5 [35 23] rate-1/2 FEC and the SAME legacy interleave/ROM/CAP_OUT
% CONVENTIONS as packet_k5.m / packet_f1536.m -- only the FRAME GEOMETRY doubles
% for the 3072-byte-class host frame carried at 2 samples per symbol (the frame
% rate stays ~1,247 f/s at 30.72 Msym/s; spec docs/superpowers/specs/2026-09-13-2sps-rung-design.md):
%
%   info/tail/coded = 24580 / 4 / 49168     (f1536: 12292 / 4 / 24592)
%   interleave      = ROWS=3073 COLS=16 (=49168, fully gridded)
%   filler          = 48-bit PN9 (x^9+x^5+1, seed ones) -> payload 49216 bits
%   payload         = 49216 bits = 769 uint64 words = 1538 uint32 ROM words
%   air             = 24608 data symbols + 26 preamble symbols (Barker-13 twice) = 24634 slots
%
% INFO FIELD LAYOUT (24580 bits):
%   [ 'ADI Hello World' 120 msg bits (MSB-first/char) ;
%     24456 PN pad bits (rng(30720,'twister'), randi([0 1],24456,1)) ;
%     4 always-zero pad bits ]                       = 24576 usable + 4 pad
%   The 24576 usable bits = 384 * 64; the byte-RX serializer delivers
%   WordsPerPacketRx = 382 of them per frame (delivery bound below); the 4 zero pad bits are
%   dropped by the serializer start-reset, and the K-1=4 encoder tail is
%   appended AFTER the info field for the 'term' contract).
%
% CONVENTIONS reused verbatim from packet_k5.m (proven K=5 contract):
%   * message bits : dec2bin('ADI Hello World',8) row-reshape, MSB-first/char
%   * interleave   : read perm = r*COLS + c, r=mod(beat,ROWS), c=floor(beat/ROWS)
%   * deinterleave : perm = c*ROWS + r (exact inverse; fully gridded)
%   * ROM packing  : word w = bits[32w..32w+31], MSB-first; one-line uint32([...])
%   * CAP_OUT      : LSB-first 32-bit pack of the first 32 decoded info bits
%
% NO legacy K=7 gate (that lineage is k5-specific). A K=5 round-trip self-check
% (encode -> interleave -> deinterleave -> vitdec recovers 'ADI Hello World'
% and the full 24580-bit info field) runs before any output is emitted.
%
% Outputs are written to the REPO contract/ dir (fileparts(mfilename)) so the
% overlays consume them via fileparts(fileparts(mfilename('fullpath'))).

out = fileparts(mfilename('fullpath'));

% ============================================================================
% F3072 PACKET (K=5 [35 23], geometry doubled for the 3072-byte-class host frame)
% ============================================================================
trellis = poly2trellis(5,[35 23]); TB = 25;
COLS = 16; ROWS = 3073;
NINFO_WORDS = 384;                               % usable info = 384 x 64 bits
INFO = NINFO_WORDS*64 + 4; TAIL = 4; CODED = 2*(INFO+TAIL);   % 24580 / 49168
NFILL = 48; PAYLOAD = CODED + NFILL;             % 49216
WPP = 382;                                       % delivered words/frame (delivery contract)
PRE_SYMS = 26; DATA_SYMS = PAYLOAD/2; SLOTS = PRE_SYMS + DATA_SYMS;   % 24608 / 24634
assert(CODED == ROWS*COLS, 'CODED ~= ROWS*COLS');
assert(PAYLOAD == 769*64,  'PAYLOAD ~= 769*64');
assert(WPP*64 <= INFO - TAIL - 41, 'delivery bound (RxPipelineSkipBits=41)');

% ---- message bits: 'ADI Hello World', 8 bits/char, MSB-first (packet_k5 order) ----
msg = 'ADI Hello World';
msgBits = reshape(de2bi(uint8(msg),8,'left-msb').',[],1);   % 120x1
assert(numel(msgBits)==120);

% ---- PN pad + 4 zero tail-pad -> 24580-bit info field ----
NPAD = NINFO_WORDS*64 - 120;                     % 24456 PN pad bits
rng(30720,'twister'); pad = randi([0 1],NPAD,1); % deterministic PN pad (seed 30720 = ksym of the rung)
info = [msgBits; pad; zeros(4,1)];               % 24576 usable + 4 zero pad = 24580
assert(numel(info)==INFO);
assert(all(info(INFO-3:INFO)==0), 'the 4 tail-pad info bits must be zero');

% ---- K=5 encode: [info; K-1 zero tail] -> convenc -> 49168 coded bits ----
encIn = [info; zeros(TAIL,1)];                   % 24584
coded = convenc(encIn, trellis);  assert(numel(coded)==CODED);

% ---- 3073x16 block interleave (legacy read perm r*COLS+c) ----
il = legacy_interleave(coded, ROWS, COLS, CODED);           % 49168x1

% ---- 48-bit PN9 filler (x^9+x^5+1, seed all-ones; no DC dwell) ----
% Same generator logic as packet_k5.m's 64-bit filler, truncated to 48 bits
% (the 48-bit prefix of the identical PN9 sequence).
lfsr = ones(9,1); filler = zeros(NFILL,1);
for fk = 1:NFILL
    fb = xor(lfsr(9), lfsr(5));
    filler(fk) = lfsr(9);
    lfsr = [fb; lfsr(1:8)];
end
assert(max(diff(find([1; diff(filler)~=0; 1]))) <= 9);   % no long constant runs (no DC dwell)

payload = [il; filler];  assert(numel(payload)==PAYLOAD);
words = legacy_packwords(payload);  assert(numel(words)==1538);

% ---- round-trip self-check (host Viterbi) ----
rx = payload(1:CODED);
deil = legacy_deinterleave(rx, ROWS, COLS, CODED);
assert(isequal(deil(:), coded(:)), 'F3072 deinterleave does not invert interleave');
dec = vitdec(deil, trellis, TB, 'term', 'hard');
assert(isequal(dec(1:120), msgBits), 'round-trip FAILED on message');
assert(isequal(dec(1:INFO), info), 'round-trip FAILED on full info field');
capOut = legacy_pack32_lsb(dec(1:32));

% ---- emit outputs (repo contract/) ----
parts = arrayfun(@(x) sprintf('%u', x), words(:).', 'UniformOutput', false);
romLiteral = ['uint32([' strjoin(parts, ' ') '])'];
fidw = fopen(fullfile(out,'rom_words_1538_f3072.txt'),'w');
fprintf(fidw, '%s\n', romLiteral); fclose(fidw);

save(fullfile(out,'golden_f3072.mat'), ...
     'words','payload','coded','info','msgBits','capOut','trellis','TB','ROWS','COLS', ...
     'WPP','PRE_SYMS','DATA_SYMS','SLOTS');

% ---- air-symbol references (QPSK gray, pi/4; the dump_ref.m convention) ----
% preamble: Barker-13 on I and Q, sent TWICE at this rung (26 symbols, same
% correlator length in samples at 2 sps as 13 symbols at 4 sps)
barker = [1 1 1 1 1 -1 -1 1 1 -1 1 -1 1] > 0;
preSym = pskmod(double(barker)*2 + double(barker), 4, pi/4, 'gray');
preSym = [preSym(:); preSym(:)];  assert(numel(preSym) == PRE_SYMS);
pI = payload(1:2:end); pQ = payload(2:2:end);
paySym = pskmod(pI*2 + pQ, 4, pi/4, 'gray');  assert(numel(paySym) == DATA_SYMS);
writematrix([real(preSym) imag(preSym)], fullfile(out,'ref_presym_f3072.txt'));
writematrix([real(paySym(:)) imag(paySym(:))], fullfile(out,'ref_paysym_f3072.txt'));

fidt = fopen(fullfile(out,'PACKET_F3072.txt'),'w');
fprintf(fidt, '================================================================\n');
fprintf(fidt, ' PACKET_F3072 -- K=5 doubled frame (2-sps rung, sp4) bit contract\n');
fprintf(fidt, '================================================================\n');
fprintf(fidt, ' trellis        = poly2trellis(5,[35 23])   TB=%d  (term, hard)\n', TB);
fprintf(fidt, ' message        = ''ADI Hello World'' (120 bits, MSB-first per char)\n');
fprintf(fidt, ' PN pad         = %d bits, rng(30720,''twister''), randi([0 1],%d,1)\n', NPAD, NPAD);
fprintf(fidt, ' info field     = 24576 usable (384*64) + 4 always-zero pad = %d\n', INFO);
fprintf(fidt, ' info/tail/coded= %d / %d / %d\n', INFO, TAIL, CODED);
fprintf(fidt, ' interleave     = ROWS=%d COLS=%d, read perm = r*COLS+c (legacy)\n', ROWS, COLS);
fprintf(fidt, ' deinterleave   = perm = c*ROWS+r (exact inverse; grid %dx%d=%d,\n', ROWS, COLS, CODED);
fprintf(fidt, '                  fully gridded -- no ungridded tail)\n');
fprintf(fidt, ' filler         = %d-bit PN9 (x^9+x^5+1, seed ones; no DC dwell) -> payload %d bits = 1538 uint32 words\n', NFILL, PAYLOAD);
fprintf(fidt, ' word alignment = %d bits = 769 uint64 = 1538 uint32 (exact)\n', PAYLOAD);
fprintf(fidt, ' air frame      = %d preamble symbols (Barker-13 x2) + %d data symbols = %d slots; 2 sps -> %d samples\n', PRE_SYMS, DATA_SYMS, SLOTS, 2*SLOTS);
fprintf(fidt, ' ROM packing    = word w = bits[32w..32w+31], MSB-first (bit 32w ->\n');
fprintf(fidt, '                  word bit 31); one-line uint32([...]) literal\n');
fprintf(fidt, ' CAP_OUT pack   = LSB-first 32-bit pack of first 32 decoded info bits\n');
fprintf(fidt, ' CAP_OUT_GOLDEN=0x%08X\n', capOut);
fprintf(fidt, '----------------------------------------------------------------\n');
fprintf(fidt, ' DELIVERY CONTRACT (byte-RX, controller option b -- DELIVERY-SIDE ONLY;\n');
fprintf(fidt, '   the payload/coded/interleave/filler/ROM/golden ABOVE are UNCHANGED):\n');
fprintf(fidt, '   WordsPerPacketRx = %d  ->  %d x 64 = %d info bits delivered/frame.\n', WPP, WPP, WPP*64);
fprintf(fidt, '   Bound: RxAlign emits at most InfoBits-TailBits-RxPipelineSkip(41)=%d\n', INFO-TAIL-41);
fprintf(fidt, '   info bits/frame before the frame boundary resets it; WPP*64=%d fits\n', WPP*64);
fprintf(fidt, '   with a %d-bit margin (WPP=384 -> 24576 would truncate every frame).\n', INFO-TAIL-41-WPP*64);
fprintf(fidt, '   Discarded/frame: %d usable + 4 zero-pad = %d info bits (%.2f%%).\n', INFO-4-WPP*64, INFO-WPP*64, 100*(INFO-WPP*64)/INFO);
fprintf(fidt, '   Host frame %d B -> MTU %d; TX air transfer %d B (769 words).\n', WPP*8, WPP*8-12, PAYLOAD/8);
fclose(fidt);

fprintf('PACKET_F3072 OK CAP_OUT=0x%08X word0=%u (0x%08X)\n', capOut, words(1), words(1));

% ===================== local functions (verbatim legacy expressions) ========
function txair = legacy_interleave(coded, ROWS, COLS, CODED)
  txair = zeros(CODED,1);
  for beat = 0:CODED-1
    r = mod(beat,ROWS); c = floor(beat/ROWS); perm = r*COLS+c;
    if perm < CODED, txair(beat+1) = coded(perm+1); end
  end
end

function deint = legacy_deinterleave(rxbits, ROWS, COLS, CODED)
  deint = zeros(CODED,1);
  for rc = 0:CODED-1
    c = mod(rc,COLS); r = floor(rc/COLS); perm = c*ROWS+r;
    if perm < CODED, deint(rc+1) = rxbits(perm+1); end
  end
end

function words = legacy_packwords(bits)
  W = numel(bits)/32;
  words = zeros(1, W, 'uint32');
  for w = 0:W-1
    v = uint32(0);
    for j = 0:31
      v = bitor(v, bitshift(uint32(bits(w*32+j+1)), 31-j));
    end
    words(w+1) = v;
  end
end

function r = legacy_pack32_lsb(bits)
  r = uint32(0);
  for i = 0:31
    if bits(i+1) ~= 0, r = bitor(r, bitshift(uint32(1), i)); end
  end
end
