function preamble_len_overlay()
% preamble_len_overlay -- make the SOURCE model's preamble-length literals follow
% frame_config_k5().PreambleSyms (13 = Barker-13 once, the sps 4/8 rungs; 26 =
% Barker-13 twice, the sps-2 sp4 rung, 2026-09-18).
%
% commhdlQPSKTxRxParameters() already sizes Params.Preamble, the correlator taps
% (rxPreambleMFCoeffs) and ThresoldGainFac from cfg.PreambleSyms, but the stock
% MathWorks model carries the preamble length as TWO Delay literals inside the
% preamble detector's energy normaliser:
%   Preamble Detector/Correlator/Magnitude Squared and Moving Sum/Delay    13
%   Preamble Detector/Correlator/Magnitude Squared and Moving Sum/Delay11  11  (= 13 - 2)
% -- the moving-sum window over the preamble span and its pipeline twin. With a
% 26-symbol preamble and a 13-symbol energy window the threshold compare is
% against half the energy, so the detector fires early/late and frames are lost
% (first sps-2 sweep cell: 2 frames in 12 ms, cap_out wrong). CONVERGENT in both
% directions, keyed on the from-state; idempotent; saves the slx.
% Apply AFTER ss8_fix_overlay, BEFORE build_composite_local.

cfg = frame_config_k5();
N = cfg.PreambleSyms;
assert(N == 13 || N == 26, 'preamble_len_overlay: unsupported PreambleSyms=%d', N);
sys = 'commhdlQPSKTxRx';
load_system(sys);
ms = [sys '/Receiver/QPSK Rx/Frequency and Time Synchronizer/Preamble Detector/Correlator/Magnitude Squared and Moving Sum'];
fix = { [ms '/Delay'],   N,     {13, 26}; ...       % window = preamble length
        [ms '/Delay11'], N - 2, {11, 24} };         % pipeline twin (length - 2)
for k = 1:size(fix,1)
    dl = str2double(strtrim(get_param(fix{k,1}, 'DelayLength')));
    if dl == fix{k,2}
        fprintf('preamble_len_overlay: %s already %d -- skip\n', fix{k,1}, dl);
    else
        assert(any(dl == cell2mat(fix{k,3})), 'preamble_len_overlay: %s unexpected DelayLength %g (expected one of %s)', ...
            fix{k,1}, dl, mat2str(cell2mat(fix{k,3})));
        set_param(fix{k,1}, 'DelayLength', num2str(fix{k,2}));
        fprintf('preamble_len_overlay: %s DelayLength %d -> %d (PreambleSyms=%d)\n', fix{k,1}, dl, fix{k,2}, N);
    end
end
P = commhdlQPSKTxRxParameters();
assert(numel(P.rxPreambleMFCoeffs) == N, 'correlator taps %d != PreambleSyms %d', numel(P.rxPreambleMFCoeffs), N);
save_system(sys);
fprintf('preamble_len_overlay: DONE (moving-sum window %d, twin %d; %d correlator taps)\n', N, N-2, N);
end
