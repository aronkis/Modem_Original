classdef TestByteHelpersK5 < matlab.unittest.TestCase
    %TESTBYTEHELPERSK5  L1: byte-packing contract vs the kit helper sources.
    %   Converted from modem/test_byte_helpers_k5.m, which was
    %   silently testing the retired /mnt/onetb/scratch/qpsk_variants tree via
    %   a hardcoded path. Now repo-relative (modem_paths). Pure MATLAB, no
    %   Simulink. Verifies:
    %     (1) pack_bits64(frameBits) replayed through qpskByteBitShifter
    %         reproduces the 2240-bit frame (the shifter is the on-chip
    %         consumer -- proves the packing convention);
    %     (2) the info stream through qpskByteSerializer (WPP=16) emits exactly
    %         the 16 golden info words per frame, wordLast on word 16.

    properties (Constant)
        NBITS = 2240;
        INFO  = 1084;
    end

    methods (TestClassSetup)
        function addKit(tc)
            p = modem_paths();
            tc.applyFixture(matlab.unittest.fixtures.PathFixture({p.kit, p.model}));
        end
    end

    methods (Test, TestTags = {'L1'})

        function shifterReplay(tc)
            info = tc.loadInfo();
            frameBits = [info; zeros(tc.NBITS - tc.INFO, 1)];
            w = TestByteHelpersK5.packBits64(frameBits);
            tc.verifyEqual(numel(w), 35, 'pack_bits64 should yield 35 words');

            st = qpskByteBitShifter();
            widx = 1; out = zeros(tc.NBITS, 1);
            for k = 1:tc.NBITS
                [bit, pop, st] = qpskByteBitShifter(st, true, k==1, w(widx), true, widx==1);
                out(k) = double(bit);
                if pop, widx = widx + 1; if widx > 35, widx = 1; end, end
            end
            tc.verifyEqual(out, frameBits, ...
                'shifter replay != frame bits (packing convention broken)');
        end

        function serializerWords(tc)
            info = tc.loadInfo();
            st = qpskByteSerializer();
            words = {}; lasts = [];
            for rep = 1:2   % two frames exercise start-reset partial-word discard
                for k = 1:tc.INFO
                    [wv, v, l, ~, st] = qpskByteSerializer(st, info(k)~=0, true, k==1, true, uint8(16));
                    if v, words{end+1} = wv; lasts(end+1) = l; end %#ok<AGROW>
                end
            end
            rxGold = TestByteHelpersK5.packBits64(info(1:1024));
            tc.verifyEqual(numel(words), 32, 'expected 32 words over 2 frames');
            w1 = [words{1:16}].'; w2 = [words{17:32}].';
            tc.verifyEqual(w1, rxGold, 'frame 1 serializer words != golden rx packet');
            tc.verifyEqual(w2, rxGold, 'frame 2 serializer words != golden rx packet');
            tc.verifyEqual(find(lasts), [16 32], 'wordLast not on word 16 of each frame');
        end

        function strictShifterRealignsWithLatePops(tc)
            % sps-2 race (sp4 S1B rot=17, 2026-09-21): the shifter sees the word buffer's
            % REGISTERED head (one step old) and its pop lands one step later (popToggle
            % edge crossing). Model both: view V(k) = head(k-1); a pop issued at k advances
            % the head at k+1. Discarding one word per step, the first-marked word is in
            % view exactly when the previous discard lands on it -- it is eaten every time
            % and alignment is never acquired. discardGap (one pop per two steps) makes the
            % head stable at every decision and the marked word is latched at a start.
            NW = 40; words = uint64(1:NW); first = (1:NW) == 1;
            for gap = [false true]
                st = qpskByteBitShifterStrict();
                H = 17; V = 17; pendingPop = false; alignedAt = 0;   % misaligned start
                for k = 1:4000
                    if pendingPop, H = mod(H, NW) + 1; pendingPop = false; end
                    isStart = mod(k, 1000) == 1;
                    [~, pop, st] = qpskByteBitShifterStrict(st, true, isStart, words(V), true, first(V), gap);
                    if pop, pendingPop = true; end
                    V = H;
                    if st.aligned, alignedAt = k; break; end
                end
                if gap
                    tc.verifyEqual(alignedAt, 1001, 'discardGap: shifter must latch the marked word at the first start after acquisition');
                else
                    tc.verifyEqual(alignedAt, 0, 'no gap: the late-pop race blocks alignment (documents the sps-2 defect)');
                end
            end
        end

        function serializerDiscardsBitsAfterLastWord(tc)
            % f3072 shape: 24580 info bits per frame against WPP=382 (24448 bits)
            % leaves 132 spare bits = 2 full words + 4 bits. Without the done
            % latch those words counted towards the NEXT frame (wordCnt=2 at
            % the next start) and the F4 pad logic emitted a 382-word zero
            % filler every frame (sp4 Gate 1 run 1, 2026-09-19).
            rng(3072); nInfo = 24580; WPP = uint16(382);
            info = double(rand(nInfo,1) > 0.5);
            st = qpskByteSerializer();
            nWords = 0; lastAt = []; cnts = [];
            for rep = 1:3
                for k = 1:nInfo
                    [~, v, l, ~, st] = qpskByteSerializer(st, info(k)~=0, true, k==1, true, WPP);
                    if v, nWords = nWords + 1; end
                    if l, lastAt(end+1) = nWords; end %#ok<AGROW>
                end
                cnts(end+1) = st.wordCnt; %#ok<AGROW>
            end
            tc.verifyEqual(nWords, 3*382, 'expected exactly WPP words per frame, no leftover words');
            tc.verifyEqual(lastAt, [382 764 1146], 'wordLast must land on word 382 of each frame');
            tc.verifyEqual(cnts, [0 0 0], 'wordCnt must be 0 at every frame end (no pad trigger)');
            tc.verifyTrue(st.done, 'done latch must be set after the last word');
        end

    end

    methods (Access = private)
        function info = loadInfo(tc)
            p = modem_paths();
            G = load(fullfile(p.k5, 'golden_k5.mat'));
            info = double(G.info(:));
            tc.assertEqual(numel(info), tc.INFO, 'golden_k5.mat info length');
        end
    end

    methods (Static, Access = private)
        function w = packBits64(bits)
            n = ceil(numel(bits)/64)*64;
            b = zeros(n,1); b(1:numel(bits)) = double(bits(:));
            B = reshape(b,8,[]).';
            bytes = uint64(B * (2.^(7:-1:0)).');
            nw = n/64; w = zeros(nw,1,'uint64');
            for k = 1:nw
                v = uint64(0);
                for j = 0:7, v = bitor(v, bitshift(bytes((k-1)*8+j+1), 8*j)); end
                w(k) = v;
            end
        end
    end
end
