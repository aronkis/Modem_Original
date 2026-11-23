function test_f3072_ref_bits()
%TEST_F3072_REF_BITS  f3072_ref_bits() must match packet_f3072.m's golden output,
% and the derived geometry must satisfy the contract rules (sp4 plan Task 1).
R = f3072_ref_bits();
assert(R.INFO == 384*64 + 4);           assert(R.TAIL == 4);
assert(R.CODED == 2*(R.INFO + R.TAIL)); assert(R.CODED == R.ROWS*R.COLS && R.COLS == 16);
assert(R.PAYLOAD == R.CODED + R.NFILL && mod(R.PAYLOAD,64) == 0 && R.PAYLOAD == 64*R.WORDS64);
assert(R.WORDS32 == 2*R.WORDS64);
assert(R.WPP*64 <= R.INFO - R.TAIL - 41, 'delivery bound (RxPipelineSkipBits=41)');
assert(R.DATA_SYMS == R.PAYLOAD/2 && R.SLOTS == R.PREAMBLE_SYMS + R.DATA_SYMS);
assert(R.SLOTS == 24634 && R.SAMPLES_PER_FRAME == 49268 && R.WPP == 382 && R.WORDS32 == 1538);
here = fileparts(mfilename('fullpath'));
G = load(fullfile(here,'golden_f3072.mat'));
assert(numel(G.words) == R.WORDS32 && G.capOut == uint32(hex2dec('04922282')), 'golden words/capOut');
assert(isequal(R.info(:),G.info(:)) && isequal(R.coded(:),G.coded(:)) && isequal(R.payload(:),G.payload(:)), ...
    'f3072_ref_bits drifted from packet_f3072.m''s golden');
pre = readmatrix(fullfile(here,'ref_presym_f3072.txt'));  pay = readmatrix(fullfile(here,'ref_paysym_f3072.txt'));
assert(size(pre,1) == R.PREAMBLE_SYMS && size(pay,1) == R.DATA_SYMS, 'air-symbol references');
rom = strtrim(fileread(fullfile(here,'rom_words_1538_f3072.txt')));
assert(isequal(eval(rom), G.words), 'ROM literal != golden words');
fprintf('test_f3072_ref_bits: OK\n');
end
