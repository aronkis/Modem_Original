function R = f3072_ref_bits()
%F3072_REF_BITS  The f3072 ROM reference: what the 2-sps transmitter actually sends.
%
% Bit-for-bit identical construction to packet_f3072.m -- deliberately duplicated
% rather than imported, because packet_f3072.m writes files as a side effect and
% this must be a pure function (the f1536_ref_bits.m pattern). The asserts here
% are self-consistency checks only; drift against packet_f3072.m's committed
% output is caught by test_f3072_ref_bits.m (golden_f3072.mat).
%
% Geometry (single source for every downstream number of the sp4 rung):
%   INFO 24580 = 384*64 + 4, TAIL 4, CODED 49168 = 3073 x 16, NFILL 48,
%   PAYLOAD 49216 = 769 x 64 = 1538 x 32, WPP 382 delivered words,
%   26 preamble symbols (Barker-13 twice) + 24608 data symbols = 24634 slots.

R.trellis = poly2trellis(5,[35 23]);  R.TB = 25;
R.COLS = 16;  R.ROWS = 3073;
R.INFO = 384*64 + 4;  R.TAIL = 4;  R.CODED = 2*(R.INFO + R.TAIL);   % 24580 / 49168
R.NFILL = 48;         R.PAYLOAD = R.CODED + R.NFILL;                % 49216
R.WORDS64 = R.PAYLOAD/64;  R.WORDS32 = R.PAYLOAD/32;                % 769 / 1538
R.WPP = 382;                                                        % delivered words/frame
R.PREAMBLE_SYMS = 26;  R.DATA_SYMS = R.PAYLOAD/2;                   % 24608
R.SLOTS = R.PREAMBLE_SYMS + R.DATA_SYMS;                            % 24634
R.SPS = 2;  R.SAMPLES_PER_FRAME = R.SLOTS*R.SPS;                    % 49268
assert(R.CODED == R.ROWS*R.COLS, 'CODED ~= ROWS*COLS');
assert(R.PAYLOAD == 769*64, 'PAYLOAD ~= 769*64');
assert(R.WPP*64 <= R.INFO - R.TAIL - 41, 'delivery bound (RxPipelineSkipBits=41)');

% message bits: 'ADI Hello World', 8 bits/char, MSB-first
msg = 'ADI Hello World';
msgBits = reshape(de2bi(uint8(msg),8,'left-msb').',[],1);      % 120x1
assert(numel(msgBits)==120);

% PN pad (deterministic seed 30720, a LOCAL stream -- never rng() on the global
% stream, see f1536_ref_bits.m) + 4 zero tail-pad -> 24580-bit info field
NPAD = 384*64 - 120;                                           % 24456
s = RandStream('twister','Seed',30720);
pad = randi(s,[0 1],NPAD,1);
R.info = [msgBits; pad; zeros(4,1)];
assert(numel(R.info)==R.INFO);
assert(all(R.info(R.INFO-3:R.INFO)==0), 'the 4 tail-pad info bits must be zero');

% K=5 encode with K-1 zero tail
R.coded = convenc([R.info; zeros(R.TAIL,1)], R.trellis);
assert(numel(R.coded)==R.CODED);

% 3073x16 block interleave, legacy read perm r*COLS + c
il = zeros(R.CODED,1);
for beat = 0:R.CODED-1
    r = mod(beat, R.ROWS);  c = floor(beat / R.ROWS);
    il(beat+1) = R.coded(r*R.COLS + c + 1);
end

% 48-bit PN9 filler (x^9 + x^5 + 1, seed all-ones)
lfsr = ones(9,1);  filler = zeros(R.NFILL,1);
for k = 1:R.NFILL
    fb = xor(lfsr(9), lfsr(5));
    filler(k) = lfsr(9);
    lfsr = [fb; lfsr(1:8)];
end

R.payload = [il; filler];
assert(numel(R.payload)==R.PAYLOAD);
end
