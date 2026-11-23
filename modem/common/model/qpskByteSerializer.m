function [word, wordValid, wordLast, drop, state] = qpskByteSerializer(state, bitIn, bitValid, start, ready, wordsPerPacket)
% qpskByteSerializer -- recovered payload bit -> 64-bit word serializer for
% the byte-RX path (the EXACT inverse of qpskByteBitShifter: byte-0-first,
% MSB-first within each byte, so shifter(pack(bytes)) bits fed in here
% reproduce pack(bytes) words and the host unpacks them little-endian).
%
%   state = qpskByteSerializer()                            -- initial state
%   [word, wordValid, wordLast, drop, state] = ...
%       qpskByteSerializer(state, bitIn, bitValid, start, ready)
%
% Collects bitValid-gated payload bits into a 64-bit word. `start` (the Rx
% packet-boundary flag, asserted with the packet's first payload bit) resets
% the bit position AND the word counter -- a start arriving mid-word
% DISCARDS the partial word, so word/packet alignment self-heals at every
% packet boundary. When the 64th bit lands the word completes in the SAME
% step:
%   * ready true  -> wordValid asserted for this one step, with wordLast on
%     the 35th word of the packet (2240 bits = exactly 35 words);
%   * ready false -> the word is flagged via `drop` and DISCARDED -- the
%     serializer NEVER stalls the Receiver (the recovered bit stream cannot
%     be backpressured). The word-position counter still advances, so
%     wordLast keeps marking the word that completes the packet.
%
% After the packet's last word (wordCnt reaches wordsPerPacket) the serializer
% is DONE for this packet: bits that keep arriving before the next `start` are
% discarded (no accumulation, no word count). This matters when the Rx emits
% more than wordsPerPacket*64 bits per frame -- f3072 delivers up to 24535 bits
% against WPP=382 (24448): the 87 spare bits used to complete a 383rd word,
% so the next `start` found wordCnt=1 and the F4 pad logic (rxfix_pad_overlay)
% emitted a 382-word all-zero filler packet EVERY frame (Gate 1 run 1 of the
% sp4 rung, 2026-09-19). At k5 (60 spare bits) and f1536 (23 spare bits) no
% full word can complete after the last word, so this latch is a no-op there.
%
% This function is the unit-tested single source of truth for the logic
% inside the composite overlay's ByteSerializer MATLAB Function block.

if nargin >= 1 && nargin < 6
    % default = full-payload words (frame_config_k5.PayloadWords64 = 35 k5 /
    % 385 f1536). Only reached when a caller omits wordsPerPacket; the
    % model/tests pass it explicitly, so this branch is codegen-dead there.
    % wordCnt/wordsPerPacket are uint16: f1536 PayloadWords64=385 overflows
    % uint8 and WordsPerPacketRx=192 is widened for consistency.
    wordsPerPacket = uint16(frame_config_k5().PayloadWords64);
end
if nargin == 0
    word = struct('acc', uint64(0), 'bitIdx', uint8(0), 'wordCnt', uint16(0), 'done', false);
    return
end

word      = uint64(0);
wordValid = false;
wordLast  = false;
drop      = false;

if start
    % packet boundary: discard any partial word, restart word counting
    state.acc     = uint64(0);
    state.bitIdx  = uint8(0);
    state.wordCnt = uint16(0);
    state.done    = false;
end

if bitValid && ~state.done
    if bitIn
        byteIdx   = bitshift(state.bitIdx, -3);          % floor(bitIdx/8)
        bitInByte = bitand(state.bitIdx, uint8(7));      % mod(bitIdx,8)
        % global 0-based bit position: MSB-first within the byteIdx-th byte
        pos = uint32(8)*uint32(byteIdx) + (uint32(7) - uint32(bitInByte));
        state.acc = bitor(state.acc, bitshift(uint64(1), pos));
    end
    state.bitIdx = state.bitIdx + 1;
    if state.bitIdx >= 64
        % word complete this step
        state.wordCnt = state.wordCnt + 1;
        if ready
            word      = state.acc;
            wordValid = true;
            wordLast  = state.wordCnt >= uint16(wordsPerPacket);
        else
            drop = true;
        end
        if state.wordCnt >= uint16(wordsPerPacket)
            state.wordCnt = uint16(0);
            state.done    = true;   % packet complete: ignore bits until the next start
        end
        state.acc    = uint64(0);
        state.bitIdx = uint8(0);
    end
end
end
