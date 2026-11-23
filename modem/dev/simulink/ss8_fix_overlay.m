function ss8_fix_overlay()
% ss8_fix_overlay -- set the Symbol Synchronizer sample-per-symbol configuration
% on this kit's SOURCE model commhdlQPSKTxRx.slx to match QPSK_SPS.
%
% sps=8 (default): the 240-ksym design point. THREE Symbol Synchronizer items
% must be moved from the MathWorks stock sps=4 configuration to sps=8:
%   (1) Interpolation Control (MATLAB Function): counter decrement fi(1/sps)
%       and mu scaling bitshift(x, log2(sps)). At sps=4 (stock): fi(0.25),
%       bitshift(,2). At sps=8: fi(0.125), bitshift(,3).
%   (2) Gardner TED/GTED: fixed tap delays. At sps=4 (stock) the far tap is
%       z-4 (Delay2/3/6/7 = 1) and the mid tap z-4 (Delay8/11 = 2), giving
%       e = x[n-4]*(x[n-6]-x[n-2]) -- a 4-sps Gardner. At sps=8 the taps span
%       8 with midpoint 4: Delay2/3/6/7 = 3 (far z-8), Delay8/11 = 4 (mid z-6);
%       e = x[n-6]*(x[n-10]-x[n-2]). Late tap stays n-2, so Gardner TED/Delay10
%       (strobe alignment) = 4 in BOTH configurations.
% (ROOT CAUSE for the sps=8 fix proven by Verilator RTL replay, contract/RXROOT.txt.)
%
% sps=4 (Task A3 rate rung): CONVERGENT REVERT. The committed source model is
% carried in its sps=8-overlaid state (the .slx is a tracked build artifact --
% no pristine stock donor exists), so "reverting the sps-8 surgery" means
% actively undoing (1) and (2) back to the documented MathWorks stock sps=4
% values. Each revert site FIRST asserts the sps=8 from-state (so a drifted
% model fails loudly rather than being reverted from an unexpected baseline),
% then rewrites to stock sps=4. sps is ORTHOGONAL to frame geometry.
%
% Model->tap mapping (verified against generated RTL):
%   re: In1 -> Delay(1) -> Delay1(1) -> Delay2 -> Delay3   (far tap)
%                      \-> Delay8                           (mid tap)
%   im: Delay4,Delay5,Delay6,Delay7 / Delay11 identically.
%
% sps=2 (sp4 rung, 2026-09-18): the Gardner span must be 2 samples. The far chain
% is In1 -> Delay(1) -> Delay1(1) -> Delay2 -> Delay3 -> Add1, so with the two
% shared unit delays already summing to sps the far-tap blocks Delay2/Delay3
% (Delay6/Delay7 on im) are REMOVED and Delay1 -> Add1 (Delay5 -> Add2) wired
% directly; the mid tap Delay8/Delay11 = 1 (mid = n-3 against the difference
% delayed by the untouched Delay9/Delay12 = 2: e = x[n-3]*(x[n-2]-x[n-4]));
% Interpolation Control decrement fi(0.5), mu bitshift(,1). Reverting from sps=2
% re-adds the four far-tap blocks at the target value.
%
% Idempotent (all directions). Apply AFTER rate_240k_overlay, BEFORE
% timing_hardening_overlay / build_composite_local.

cfg = frame_config_k5();
sps = cfg.Sps;
assert(sps==8 || sps==4 || sps==2, 'ss8_fix_overlay: unsupported sps=%d (8, 4 or 2)', sps);

sys = 'commhdlQPSKTxRx';
load_system(sys);
ss = [sys '/Receiver/QPSK Rx/Frequency and Time Synchronizer/Symbol Synchronizer'];

% target / from-state literals keyed on sps (target = this build; from = the
% OTHER config, asserted before any rewrite so an unexpected baseline fails)
% decrement fi(1/sps), mu bitshift log2(sps); far-tap blocks sps/2-1 (0 = removed at
% sps 2), mid tap sps/2. The from-state is whichever OTHER rung the model carries.
decOf = @(s) sprintf('fi(%g,1,11,10)', 1/s);
shOf  = @(s) sprintf('bitshift(bitand(mask,countReg),%d)', log2(s));
others = setdiff([8 4 2], sps);
decT = decOf(sps); shT = shOf(sps);
farT = num2str(sps/2 - 1); midT = num2str(sps/2);
farF = arrayfun(@(s) num2str(s/2 - 1), others, 'UniformOutput', false);   % accepted from-states
midF = arrayfun(@(s) num2str(s/2),     others, 'UniformOutput', false);

% ---- (1) Interpolation Control MATLAB Function ----
ic  = [ss '/Interpolation Control'];
cfgIC = get_param(ic, 'MATLABFunctionConfiguration');
code  = cfgIC.FunctionScript;
if contains(code, decT) && contains(code, shT)
    fprintf('ss8_fix_overlay: Interpolation Control already sps=%d (%s) -- skip\n', sps, decT);
else
    fromS = others(arrayfun(@(s) contains(code, decOf(s)) && contains(code, shOf(s)), others));
    assert(isscalar(fromS), 'Interpolation Control: no single from-state among sps %s found', mat2str(others));
    decF = decOf(fromS); shF = shOf(fromS);
    code = strrep(code, decF, decT);
    code = strrep(code, shF,  shT);
    cfgIC.FunctionScript = code;
    fprintf('ss8_fix_overlay: Interpolation Control decrement %s->%s, mu %s->%s (sps=%d)\n', ...
        decF, decT, shF, shT, sps);
end

% ---- (2) GTED tap delays ----
g = [ss '/Gardner TED/GTED'];
farBlks = {'Delay2','Delay3','Delay6','Delay7'};
% the far chain: re Delay1 -> Delay2 -> Delay3 -> Add1(in 2); im Delay5 -> Delay6 -> Delay7 -> Add2(in 2)
farChain = {{'Delay1','Delay2','Delay3','Add1'}, {'Delay5','Delay6','Delay7','Add2'}};
farPresent = ~isempty(find_system(g,'SearchDepth',1,'Name','Delay2'));
if sps == 2
    if ~farPresent
        fprintf('ss8_fix_overlay: GTED far-tap blocks already removed (sps=2) -- skip\n');
    else
        for c = 1:2
            ch = farChain{c};
            for k = 2:3
                dl = strtrim(get_param([g '/' ch{k}], 'DelayLength'));
                assert(any(strcmp(dl, farF)), 'GTED/%s unexpected from-state DelayLength %s (expected one of %s)', ch{k}, dl, strjoin(farF, '/'));
            end
            % which Add input did Delay3/Delay7 feed?
            ph = get_param([g '/' ch{3}], 'PortHandles'); ln = get_param(ph.Outport(1), 'Line');
            dstP = get_param(ln, 'DstPortHandle'); dstIdx = get_param(dstP, 'PortNumber');
            delete_line(g, [ch{3} '/1'], sprintf('%s/%d', ch{4}, dstIdx));
            delete_line(g, [ch{1} '/1'], [ch{2} '/1']);
            delete_line(g, [ch{2} '/1'], [ch{3} '/1']);
            delete_block([g '/' ch{2}]); delete_block([g '/' ch{3}]);
            add_line(g, [ch{1} '/1'], sprintf('%s/%d', ch{4}, dstIdx), 'autorouting', 'on');
            fprintf('ss8_fix_overlay: GTED/%s,%s removed; %s -> %s/%d (far chain = 2 = sps)\n', ch{2}, ch{3}, ch{1}, ch{4}, dstIdx);
        end
    end
else
    if ~farPresent
        % revert from sps 2: re-insert the four far-tap blocks at the target value
        for c = 1:2
            ch = farChain{c};
            ph = get_param([g '/' ch{1}], 'PortHandles'); ln = get_param(ph.Outport(1), 'Line');
            dstP = get_param(ln, 'DstPortHandle'); dstB = get_param(dstP, 'Parent'); dstIdx = get_param(dstP, 'PortNumber');
            % the line Delay1 -> Add1 may be a branch (Delay1 also feeds Delay8): find the Add leg
            dsts = get_param(ln, 'DstPortHandle');
            for d = reshape(dsts,1,[])
                if strcmp(get_param(get_param(d,'Parent'),'Name'), ch{4})
                    dstIdx = get_param(d, 'PortNumber'); delete_line(ln); break
                end
            end
            add_block('simulink/Discrete/Delay', [g '/' ch{2}], 'DelayLength', farT);
            add_block('simulink/Discrete/Delay', [g '/' ch{3}], 'DelayLength', farT);
            add_line(g, [ch{1} '/1'], [ch{2} '/1'], 'autorouting','on');
            add_line(g, [ch{2} '/1'], [ch{3} '/1'], 'autorouting','on');
            add_line(g, [ch{3} '/1'], sprintf('%s/%d', ch{4}, dstIdx), 'autorouting','on');
            % Delay1 -> Delay8 (mid) must survive: re-add if the branch delete took it
            if isempty(find_system(g,'SearchDepth',1,'FindAll','on','Type','line','SrcBlockHandle',get_param([g '/' ch{1}],'Handle')))
                error('ss8_fix_overlay: %s lost its fan-out while re-inserting the far taps', ch{1});
            end
            fprintf('ss8_fix_overlay: GTED/%s,%s re-inserted at %s (sps=%d)\n', ch{2}, ch{3}, farT, sps);
        end
    end
    for k = 1:numel(farBlks)
        b = [g '/' farBlks{k}];
        dl = strtrim(get_param(b, 'DelayLength'));
        if strcmp(dl, farT)
            fprintf('ss8_fix_overlay: GTED/%s already %s -- skip\n', farBlks{k}, farT);
        else
            assert(any(strcmp(dl, farF)), 'GTED/%s unexpected from-state DelayLength %s (expected one of %s)', farBlks{k}, dl, strjoin(farF, '/'));
            set_param(b, 'DelayLength', farT);
            fprintf('ss8_fix_overlay: GTED/%s DelayLength %s -> %s (far tap, sps=%d)\n', farBlks{k}, dl, farT, sps);
        end
    end
end
midBlks = {'Delay8','Delay11'};
for k = 1:numel(midBlks)
    b = [g '/' midBlks{k}];
    dl = strtrim(get_param(b, 'DelayLength'));
    if strcmp(dl, midT)
        fprintf('ss8_fix_overlay: GTED/%s already %s -- skip\n', midBlks{k}, midT);
    else
        assert(any(strcmp(dl, midF)), 'GTED/%s unexpected from-state DelayLength %s (expected one of %s)', midBlks{k}, dl, strjoin(midF, '/'));
        set_param(b, 'DelayLength', midT);
        fprintf('ss8_fix_overlay: GTED/%s DelayLength %s -> %s (mid tap, sps=%d)\n', midBlks{k}, dl, midT, sps);
    end
end

% strobe alignment (late tap) is z-2 in BOTH configs -> Delay10 = 4 unchanged
d10 = strtrim(get_param([ss '/Gardner TED/Delay10'], 'DelayLength'));
assert(strcmp(d10, '4'), 'Gardner TED/Delay10 expected 4, got %s', d10);

save_system(sys);
fprintf('ss8_fix_overlay: saved %s (sps=%d)\n', which(sys), sps);
end
