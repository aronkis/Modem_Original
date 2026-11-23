%commhdlQPSKTxRxParameters script generates parameters for QPSK Transmitter and Receiver required for initialization.
%   Params = commhdlQPSKTxRxParameters() returns, a structure containing 
%   constants used by the model commhdlQPSKTxRx.slx.
% 
%   Note: This function is called in mask initializations of the QPSK Tx
%   and QPSK Rx subsystems in the model commhdlQPSKTxRx.slx.
%   

%   Copyright 2020-2023 The MathWorks, Inc. 

function Params = commhdlQPSKTxRxParameters()

   cfg = frame_config_k5();   % single source of truth for frame geometry + sps
   Params.Preamble                 = generatePreamble(cfg.PreambleSyms);   % 13 (Barker) or 26 (Barker x2 at sps 2)
   Params.QPSKConstellation        = double(fi(QPSKModulate([0 0 1 0 1 1 0 1].'),1,16,15));
   Params.DataBitsPerPacket        = cfg.PayloadBits;   % 2240 (= CodedBits + FillerBits)
   % --- frame geometry mirrored from frame_config_k5 (new fields; k5 -> identical) ---
   Params.InfoBitsPerPacket        = cfg.InfoBits;
   Params.TailBitsPerPacket        = cfg.TailBits;
   Params.CodedBitsPerPacket       = cfg.CodedBits;
   Params.InterleaveRows           = cfg.InterleaveRows;
   Params.InterleaveCols           = cfg.InterleaveCols;
   Params.FillerBits               = cfg.FillerBits;
   Params.PayloadWords64           = cfg.PayloadWords64;
   Params.RomWords32               = cfg.RomWords32;
   Params.SamplesPerSymbol         = cfg.Sps; % samples per symbol from the single source (frame_config_k5):
                                        % 8 = the historical 240-ksym design point at the 1.92 MHz SSI,
                                        % 4 = the sp2/sp3 rung (15.36 Msym/s at 61.44 MSPS),
                                        % 2 = the sp4 rung (30.72 Msym/s at the SAME 61.44 MSPS).
                                        % The model rail is Rsym*sps (rate_240k_overlay.m derives every
                                        % sample time as 1/(Rsym*SamplesPerSymbol)); at sps 2 the rail
                                        % value doubles in symbols while the sample rate is unchanged.
   if cfg.Sps == 2
       % 2-sps rung: the sps-4 pulse (rolloff 0.5) would occupy 46 MHz at 30.72 Msym/s,
       % outside the 40 MHz profile. Rolloff 0.25 over 8 symbols keeps 17 taps and
       % 38.4 MHz occupied (spec section 3).
       Params.RRCFilterSpanInSymbols = 8;
       rollOffFactor                 = 0.25;
   else
       Params.RRCFilterSpanInSymbols = 4;
       rollOffFactor                 = 0.5;
   end
   Params.RRCRolloff               = rollOffFactor;
   Params.RRCCoef                  = rcosdesign(rollOffFactor,...
                                         Params.RRCFilterSpanInSymbols,...
                                         Params.SamplesPerSymbol);
   Params.preambleSymbols          = QPSKModulate(Params.Preamble);
   Params.rxPreambleMFCoeffs       = flip(conj(Params.preambleSymbols)).';
   Params.rxPreambleMFCoeffs       = Params.rxPreambleMFCoeffs/cfg.PreambleSyms;   % unit-gain correlator
   Params.txDataRAMAddrWidth       = nextpow2(Params.DataBitsPerPacket*2);
   Params.BitsPerPacket            = length(Params.Preamble) + Params.DataBitsPerPacket;
   
   % AGC Parameters
   Params.AGCReference           = 0.25;
   Params.AGCLoopGain            = 2e-3;
   
   % Carrier Synchronizer Parameters
   CSBnXTsamp             = 0.005;
   CSdoo                  = 1/sqrt(2);
   CSth                   = CSBnXTsamp/(CSdoo + 0.25/CSdoo);
   CSd                    = 1+2*CSdoo*CSth+CSth^2;
   CSKp                   = sqrt(2);
   CSK0                   = 1;
   CSLoopFilterPropGain   = 4*CSdoo*(CSth/CSd)*(1/(CSKp*CSK0));
   CSLoopFilterIntegGain  = 4*(CSth^2/CSd)*(1/(CSKp*CSK0));
   CFOChangeDetectThreshold = 0.0125;    % RXFIX RE-APPLIED (2026-07-09): widen the CFO-step-change deadband.
                                         % Stock 0.0015625 (=3277 En21, ~697 Hz on this kit) false-fired the
                                         % carrier-sync reset (internalRst) ~52/s at the flooring condition
                                         % (HW rstcs=3101/60s while the real CFO was a stable 26 Hz) -> carrier
                                         % loss-of-lock RESET STORM -> BER floor / ~40% frame yield. Confirmed:
                                         % ideal receiver decodes the same samples 0/220; pre-carrier-loop cause.
                                         % 0.0125 (=26214 En21, ~5577 Hz) clears the ~3 kHz storm-break knee and
                                         % the good-lock p99 jitter (835 Hz), still catches real CFO steps >=~3kHz.
                                         % Prior-validated on real air (jupiter_t8pn/RXFIX.txt: resets 9->1).
   
   Params.CSKp                  = CSKp;
   Params.CSK0                  = CSK0;
   Params.CSLoopFilterPropGain  = CSLoopFilterPropGain;
   Params.CSLoopFilterIntegGain = CSLoopFilterIntegGain;
   Params.CFOChangeDetectThreshold = CFOChangeDetectThreshold;
   
   % Symbol Synchronizer Parameters
   SSBnXTsamp             = 0.01;
   SSdoo                  = 1/sqrt(2);
   SSth                   = SSBnXTsamp/(SSdoo + 0.25/SSdoo);
   SSd                    = 1+2*SSdoo*SSth+SSth^2;
   if cfg.Sps == 2
       % sp4 rung: the Gardner detector gain is about half at rolloff 0.25 / 2 sps
       % (the TED's minimum rate and a quarter of the excess bandwidth), so the
       % loop constants are re-derived with the halved detector-gain estimate.
       % Measured 2026-09-18 on the noiseless loopback (sps2 diagnostic 3): with
       % 2.7 the timing loop dithered across the sample boundary and the Rate
       % Handle slipped symbols (10-15 %% bit errors per frame); with 1.35 every
       % frame decoded clean. modem/debug/sps2_sync_sweep_k5.m re-arbitrates it.
       SSKp               = 1.35;
   else
       SSKp               = 2.7;
   end
   SSK0                   = -1;
   SSLoopFilterPropGain   = 4*SSdoo*(SSth/SSd)*(1/(SSKp*SSK0));
   SSLoopFilterIntegGain  = 4*(SSth^2/SSd)*(1/(SSKp*SSK0));
   
   Params.SSKp                  = SSKp;
   Params.SSK0                  = SSK0;
   Params.SSLoopFilterPropGain  = SSLoopFilterPropGain;
   Params.SSLoopFilterIntegGain = SSLoopFilterIntegGain;
   
   % Preamble Detector Parameters
   PreambleThresholdScaldB       = -1.25;
   thresholdScalFac              = 10^(PreambleThresholdScaldB/10);
   rxPreambleMFEnergy            = sum(abs(Params.rxPreambleMFCoeffs).^2);
   assert(thresholdScalFac*rxPreambleMFEnergy < 1, 'ThresoldGainFac saturates ufix16_En16');
   Params.ThresoldGainFac        = fi(thresholdScalFac*rxPreambleMFEnergy,0,16,16);
   Params.SearchSamples          = Params.BitsPerPacket/2;   % = symbol slots per frame
   assert(Params.SearchSamples == cfg.SlotsPerFrame, 'SearchSamples ~= frame_config SlotsPerFrame');
end


function preamble = generatePreamble(nSyms)

  barkarCode13Bit = logical([1 1 1 1 1 0 0 1 1 0 1 0 1]);
  
  if nargin < 1, nSyms = 13; end
  switch nSyms
    case 13, preambleI = barkarCode13Bit;
    case 26, preambleI = [barkarCode13Bit barkarCode13Bit];   % sps-2 rung: same length in samples
    otherwise, error('generatePreamble: %d symbols not supported (13 or 26)', nSyms);
  end
  preambleQ = preambleI;
  
  preamble = [preambleI;preambleQ];
  preamble = preamble(:);

end

function QPSKMod = QPSKModulate(sdata)
 
   sdataI = sdata(1:2:end);
   sdataQ = sdata(2:2:end);
   QPSKMod = pskmod(sdataI*2+sdataQ,4,pi/4,'gray');

end