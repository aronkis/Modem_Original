% sim_oneway_pair_gate.m -- model-level gate for the ONE-WAY images: the
% TX-only composite (Receiver stubbed) transmits, the RX-only composite
% (Transmitter stubbed) receives, in one harness wired the way the boards are:
%
%     TX.tx_dataOutI/Q --Delay--> RX.adc_dataInI/Q      (external path, rx_input_select=1)
%     adc_validIn (both) = 1-in-2 toggle at the 30.72 MHz bus rate (TX pacing + ADC cadence)
%     TX source = ROM BIST frames (tx_data_source=0), byte plane idle
%
% PASS = RX BIST reaches the golden capture word (cfg.CapGolden), packets keep
% counting, no late bit errors, AND the stubs are inert (TX copy's packets_out
% stays 0, RX copy's tx_dataOutI/Q stay 0).  Replaces the internal-loopback
% Gate 1 matrix, which cannot run on a half image.
%
% Inputs: two kits made by assemble_oneway.sh (env ONEWAY_TX_KIT / ONEWAY_RX_KIT
% override the defaults).  Writes SIM_ONEWAY_PAIR_GATE.txt next to the TX kit.
% Sim-only tweaks on the RX copy mirror sim_byte_gate_k5.m: BIST print branch
% stubbed, RxAlign latency 41 -> 25 (behavioural Viterbi lead) unless the model
% already carries the rxAlignLat parameter (prod-derived), in which case it is set.
txKit = getenv('ONEWAY_TX_KIT'); if isempty(txKit), txKit = '/mnt/onetb/scratch/qpsk-build-trees/oneway/jupiter_byte_onewaytx_build'; end
rxKit = getenv('ONEWAY_RX_KIT'); if isempty(rxKit), rxKit = '/mnt/onetb/scratch/qpsk-build-trees/oneway/jupiter_byte_onewayrx_build'; end
assert(isfile(fullfile(txKit,'commhdlQPSKTxRxLoopback.slx')), 'TX kit model missing: %s', txKit);
assert(isfile(fullfile(rxKit,'commhdlQPSKTxRxLoopback.slx')), 'RX kit model missing: %s', rxKit);
run('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/setup.m');
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox');
cd(txKit); kitpath(txKit);
% frame_config_k5 reads QPSK_FRAME / QPSK_SPS from the environment and the model
% InitFcn derives every rate from them: an unset environment silently compiles
% the f1536/sps4 kit at the k5/sps8 rates (the DAC mux then reads 61.44 MHz
% against a 30.72 MHz REP output). Take the geometry from the TX kit's
% Description stamp when the environment does not say, and refuse a mismatch.
dTx = get_param_desc(fullfile(txKit,'commhdlQPSKTxRxLoopback.slx'));
fTok = regexp(dTx, 'frame=(\w+)', 'tokens', 'once'); sTok = regexp(dTx, 'sps(\d+)/', 'tokens', 'once');
assert(~isempty(fTok) && ~isempty(sTok), 'TX kit Description carries no frame=/sps tokens: %s', dTx);
if isempty(getenv('QPSK_FRAME')), setenv('QPSK_FRAME', fTok{1}); end
if isempty(getenv('QPSK_SPS')),   setenv('QPSK_SPS',   sTok{1}); end
assert(strcmp(getenv('QPSK_FRAME'), fTok{1}) && strcmp(getenv('QPSK_SPS'), sTok{1}), ...
    'environment QPSK_FRAME=%s QPSK_SPS=%s does not match the TX kit (frame=%s sps=%s)', getenv('QPSK_FRAME'), getenv('QPSK_SPS'), fTok{1}, sTok{1});
fprintf('geometry: QPSK_FRAME=%s QPSK_SPS=%s\n', getenv('QPSK_FRAME'), getenv('QPSK_SPS'));
cfg = frame_config_k5();
logf = fullfile(txKit,'sim_oneway_pair_gate.log'); if exist(logf,'file'), delete(logf); end
diary(logf);
fprintf('=== sim_oneway_pair_gate %s\n  tx kit %s\n  rx kit %s\n', char(datetime('now')), txKit, rxKit);

% ---- load both halves under distinct names ----------------------------------
txSys = 'commhdlQPSKTxRxLoopback';
if bdIsLoaded(txSys), close_system(txSys, 0); end
load_system(fullfile(txKit,[txSys '.slx']));
assert(contains(get_param(txSys,'Description'),'oneway=tx'), 'TX kit model is not a QPSK_ONEWAY=tx assemble');
tmpDir = tempname; mkdir(tmpDir); addpath(tmpDir);
rxSys = 'oneway_rx_model';
copyfile(fullfile(rxKit,[txSys '.slx']), fullfile(tmpDir,[rxSys '.slx']));
load_system(fullfile(tmpDir,[rxSys '.slx']));
assert(contains(get_param(rxSys,'Description'),'oneway=rx'), 'RX kit model is not a QPSK_ONEWAY=rx assemble');
set_param(0,'CurrentSystem',txSys);
evalin('base', get_param(txSys,'InitFcn'));      % Rsym/dataBits etc. for the masks
assert(contains(get_param([txSys '/TxRxComposite/Receiver'],'Description'),'ONEWAY_STUB'), 'TX kit: Receiver is not the stub');
assert(contains(get_param([rxSys '/TxRxComposite/Transmitter'],'Description'),'ONEWAY_STUB'), 'RX kit: Transmitter is not the stub');

% ---- harness -----------------------------------------------------------------
h = 'oneway_pair_k5';
if bdIsLoaded(h), close_system(h,0); end
new_system(h);
add_block([txSys '/TxRxComposite'], [h '/TX'], 'Position',[500 80 800 980]);
add_block([rxSys '/TxRxComposite'], [h '/RX'], 'Position',[1200 80 1500 980]);
% sim-only tweaks on the RX copy (as sim_byte_gate_k5.m does on its DUT copy)
cdb = [h '/RX/Receiver/Capture Data Bits/MATLAB Function'];
ch = sfroot().find('-isa','Stateflow.EMChart','Path',cdb); assert(~isempty(ch), 'Capture Data Bits chart not found');
scr = ch(1).Script;
scr = regexprep(scr,'msgarray_dec = char\([^\n]*\n',''); scr = regexprep(scr,'N = length\(msgarray_dec\)[^\n]*\n','');
scr = regexprep(scr,'strAscii_dec = reshape\(msgarray_dec[^\n]*\n',''); scr = regexprep(scr,'msg = char\(bin2dec[^\n]*\n','');
scr = regexprep(scr,'\s*disp\(msg\);',''); ch(1).Script = scr;
ra = [h '/RX/Receiver/QPSK Rx/FEC Decoder Wrapper/RxAlign'];
ch2 = sfroot().find('-isa','Stateflow.EMChart','Path',ra); assert(~isempty(ch2), 'RxAlign chart not found');
if contains(ch2(1).Script,'uint16(41)')
    ch2(1).Script = strrep(ch2(1).Script,'uint16(41)','uint16(25)'); fprintf('harness: RxAlign 41 -> 25 (sim-only)\n');
else
    assignin('base','rxAlignLat',uint16(25)); fprintf('harness: rxAlignLat = 25 (parameterised model)\n');
end

% port maps by NAME (numbers differ between builds)
im = @(blk) portmap(h, blk, 'Inport'); om = @(blk) portmap(h, blk, 'Outport');
imT = im('TX'); omT = om('TX'); imR = im('RX'); omR = om('RX');
busT = '1/30.72e6'; railT = '1/15.36e6';   % same drive rates as sim_byte_gate_k5.m
mkc = @(nm,dt,val,st,y) add_block('built-in/Constant',[h '/' nm],'Value',val,'OutDataTypeStr',dt,'SampleTime',st,'Position',[60 y 120 y+20]);
% adc_validIn: 1-in-2 toggle at the bus rate (TX pacing on the TX copy, ADC cadence on the RX copy)
add_block('built-in/Constant',[h '/Tick'],'Value','true','OutDataTypeStr','boolean','SampleTime',busT,'Position',[60 40 100 60]);
add_block('simulink/User-Defined Functions/MATLAB Function',[h '/VGen'],'Position',[150 30 220 70]);
vg = sfroot().find('-isa','Stateflow.EMChart','Path',[h '/VGen']);
vg.Script = sprintf('function v = vgen(tick)\npersistent p\nif isempty(p), p=false; end\np = ~p;\nv = p && logical(tick);\n');
add_line(h,'Tick/1','VGen/1');
conn(h, 'VGen/1', 'TX', imT, 'adc_validIn'); conn(h, 'VGen/1', 'RX', imR, 'adc_validIn');
% external loopback: TX DAC -> one Delay -> RX ADC
for iq = 'IQ'
    d = ['LoopDly' iq]; add_block('built-in/Delay',[h '/' d],'DelayLength','1','Position',[900 400+40*(iq=='Q') 940 420+40*(iq=='Q')]);
    add_line(h, sprintf('TX/%d', omT(['tx_dataOut' iq])), [d '/1'], 'autorouting','on');
    add_line(h, [d '/1'], sprintf('RX/%d', imR(['adc_dataIn' iq])), 'autorouting','on');
end
% TX copy statics (its ADC inputs are unused: Receiver is the stub)
y = 100;
mkc('cT_adcI','int16','0',busT,y);   conn(h,'cT_adcI/1','TX',imT,'adc_dataInI'); y=y+40;
mkc('cT_adcQ','int16','0',busT,y);   conn(h,'cT_adcQ/1','TX',imT,'adc_dataInQ'); y=y+40;
for pair = {{'rstCS','boolean','false',railT},{'iq_debug_mux','uint32','0',railT},{'rx_input_select','boolean','false',railT}, ...
            {'host_txI','int16','0',busT},{'host_txQ','int16','0',busT},{'host_txValid','boolean','true',busT}, ...
            {'tx_source_select','uint32','0',railT},{'skip_count','uint32','0',railT},{'tx_data_source','uint32','0',railT}, ...
            {'byte_rx_ready','boolean','true',busT},{'byte_valid','boolean','false',busT},{'byte_first','boolean','false',busT}}
    p = pair{1}; nm = ['cT_' p{1}]; mkc(nm,p{2},p{3},p{4},y); conn(h,[nm '/1'],'TX',imT,p{1}); y=y+40;
end
mkc('cT_byte_data','uint64','0',busT,y); conn(h,'cT_byte_data/1','TX',imT,'byte_data'); y=y+40;
% RX copy statics: EXTERNAL path selected
y = 100; x = 1000;
mkcR = @(nm,dt,val,st,yy) add_block('built-in/Constant',[h '/' nm],'Value',val,'OutDataTypeStr',dt,'SampleTime',st,'Position',[x yy x+60 yy+20]);
for pair = {{'rstCS','boolean','false',railT},{'iq_debug_mux','uint32','0',railT},{'rx_input_select','boolean','true',railT}, ...
            {'host_txI','int16','0',busT},{'host_txQ','int16','0',busT},{'host_txValid','boolean','true',busT}, ...
            {'tx_source_select','uint32','0',railT},{'skip_count','uint32','0',railT},{'tx_data_source','uint32','0',railT}, ...
            {'byte_rx_ready','boolean','true',busT},{'byte_valid','boolean','false',busT},{'byte_first','boolean','false',busT}}
    p = pair{1}; nm = ['cR_' p{1}]; mkcR(nm,p{2},p{3},p{4},y); conn(h,[nm '/1'],'RX',imR,p{1}); y=y+40;
end
mkcR('cR_byte_data','uint64','0',busT,y); conn(h,'cR_byte_data/1','RX',imR,'byte_data');
% terminate every other output; log the oracles
for blk = {'TX','RX'}
    ph = get_param([h '/' blk{1}],'PortHandles');
    for k = 1:numel(ph.Outport)
        if get_param(ph.Outport(k),'Line') > 0, continue; end
        t = sprintf('%s/T_%s_%d', h, blk{1}, k);
        add_block('built-in/Terminator', t, 'Position',[1600 40+24*k 1620 60+24*k]);
        add_line(h, sprintf('%s/%d', blk{1}, k), sprintf('T_%s_%d/1', blk{1}, k), 'autorouting','on');
    end
end
for nm = {'packets_out','bit_errors_out','cap_out','cap_in','cap_deint','byte_rx_valid','tx_dataOutI'}
    p = get_param([h '/RX'],'PortHandles'); set_param(p.Outport(omR(nm{1})),'DataLogging','on','DataLoggingNameMode','Custom','DataLoggingName',['rx_' nm{1}]);
end
for nm = {'packets_out','tx_validOut'}
    p = get_param([h '/TX'],'PortHandles'); set_param(p.Outport(omT(nm{1})),'DataLogging','on','DataLoggingNameMode','Custom','DataLoggingName',['tx_' nm{1}]);
end
set_param(h,'SolverType','Fixed-step','Solver','FixedStepDiscrete','SignalLogging','on','SignalLoggingName','logsout','SaveFormat','Dataset');

% ---- run ---------------------------------------------------------------------
framePeriod = (13 + cfg.PayloadBits/2) * cfg.Sps / 15.36e6;
% 0.03 s (~9 air frames) counted only 3 packets on the RX copy: the external
% path adds acquisition + the RX-only pipeline before the first packet lands.
% 0.04 s (~12 frames) leaves the >= 4 packet criterion real margin.
T = 0.080 * cfg.Sps / 8; if ~strcmp(cfg.Frame,'f1536'), T = 60 * framePeriod; end
ovT = getenv('BYTEGATE_T'); if ~isempty(ovT), T = str2double(ovT); end
set_param(h,'StopTime', num2str(T));
fprintf('--- RUN pair (ROM source, external path, T=%gs ~%.0f frames) ---\n', T, T/framePeriod);
so = sim(h); L = so.logsout;
get = @(nm) L.getElement(nm).Values;
pk  = double(get('rx_packets_out').Data); err = double(get('rx_bit_errors_out').Data);
cap = uint32(get('rx_cap_out').Data(end)); capIn = uint32(get('rx_cap_in').Data(end)); capD = uint32(get('rx_cap_deint').Data(end));
txPk = double(get('tx_packets_out').Data); rxDac = double(get('rx_tx_dataOutI').Data);
rxv = logical(get('rx_byte_rx_valid').Data);
iTail = find(pk >= 2, 1);
if isempty(iTail), errLate = NaN; else, errLate = err(end) - err(iTail); end
res = struct('pk', pk(end), 'err', err(end), 'errLate', errLate, 'cap', cap, 'capIn', capIn, 'capDeint', capD, ...
             'txStubPk', max(txPk), 'rxStubDacMax', max(abs(rxDac)), 'rxWords', sum(rxv));
fprintf('pair: packets=%d errors=%d errLate=%g cap_in=0x%08X cap_deint=0x%08X cap_out=0x%08X | TX-copy packets_out(max)=%d RX-copy tx_dataOutI(max|.|)=%g byte_rx words=%d\n', ...
    res.pk, res.err, res.errLate, res.capIn, res.capDeint, res.cap, res.txStubPk, res.rxStubDacMax, res.rxWords);
okLink  = res.pk >= 4 && res.cap == cfg.CapGolden && res.errLate == 0;
okStubs = res.txStubPk == 0 && res.rxStubDacMax == 0;
pass = okLink && okStubs;
fid = fopen(fullfile(txKit,'SIM_ONEWAY_PAIR_GATE.txt'),'w');
fprintf(fid, '============ modem ONE-WAY PAIR GATE (TX-only -> RX-only) ============\ndate: %s\nresult: %s\n', char(datetime('now')), ternary(pass,'PASS','FAIL'));
fprintf(fid, 'tx kit: %s\nrx kit: %s\nT=%g s (~%.0f f1536 frames), ROM source (tx_data_source=0), external path (rx_input_select=1), adc_validIn 1-in-2\n', txKit, rxKit, T, T/framePeriod);
fprintf(fid, 'link : packets=%d errors=%d errLate=%g cap_out=0x%08X (golden 0x%08X) cap_in=0x%08X cap_deint=0x%08X byte_rx_words=%d -> %s\n', ...
    res.pk, res.err, res.errLate, res.cap, cfg.CapGolden, res.capIn, res.capDeint, res.rxWords, ternary(okLink,'PASS','FAIL'));
fprintf(fid, 'stubs: TX-copy packets_out max=%d (Receiver stub inert), RX-copy tx_dataOutI max|.|=%g (Transmitter stub inert) -> %s\n', res.txStubPk, res.rxStubDacMax, ternary(okStubs,'PASS','FAIL'));
fclose(fid);
fprintf('WROTE SIM_ONEWAY_PAIR_GATE.txt (%s)\n', ternary(pass,'PASS','FAIL'));
diary off;
try, rmpath(tmpDir); rmdir(tmpDir,'s'); catch, end
if ~pass, error('SIM_ONEWAY_PAIR_GATE FAIL'); end
fprintf('SIM_ONEWAY_PAIR_GATE_DONE PASS\n');

% ---------------------------------------------------------------------------
function m = portmap(h, blk, typ)
m = containers.Map;
for b = reshape(find_system([h '/' blk],'SearchDepth',1,'BlockType',typ),1,[])
    m(get_param(b{1},'Name')) = str2double(get_param(b{1},'Port'));
end
end
function conn(h, srcSpec, blk, im, name)
assert(im.isKey(name), '%s inport %s missing', blk, name);
add_line(h, srcSpec, sprintf('%s/%d', blk, im(name)), 'autorouting','on');
end
function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end

function d = get_param_desc(slx)
% Description of a not-yet-loaded model (loaded here, left loaded for the caller)
[~, nm] = fileparts(slx);
if ~bdIsLoaded(nm), load_system(slx); end
d = get_param(nm, 'Description');
end
