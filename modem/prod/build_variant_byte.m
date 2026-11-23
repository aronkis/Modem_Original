% build_variant_byte.m (prod) -- Vivado build driver for the FLATTENED model.
% Same entry point name and same second half as dev/build_variant_byte.m, but
% there is no assemble: commhdlQPSKTxRxLoopback.slx in this tree IS the model
% (derived from dev by prod/derive/derive.sh and committed), so it is loaded and
% handed straight to the HDL Workflow Advisor. build_hdl.sh --tree prod copies
% this tree into the kit and runs `matlab -batch "cd(kit); build_variant_byte"`.
KITDIR=fileparts(mfilename('fullpath'));
run('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/setup.m');
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox');
cd(KITDIR); kitpath(KITDIR);   % kit LAST -> its params win
fprintf('build_variant_byte (prod: flattened model, no assemble) cwd=%s\n', pwd);

try
    hdlsetuptoolpath('ToolName','Xilinx Vivado','ToolPath','/tools/Xilinx/2025.1/Vivado/bin/vivado');
catch err
    fprintf('hdlsetuptoolpath warning: %s\n', err.message);
end

% Wipe stale projects so HDL Coder smart-build cannot skip steps.
try; rmdir(fullfile(pwd,'hdl_prj_jupiter_composite'),'s'); catch; end
try; rmdir(fullfile(pwd,'slprj'),'s'); catch; end

sys = 'commhdlQPSKTxRxLoopback';
load_system(sys);
set_param(0,'CurrentSystem',sys);
evalin('base', get_param(sys,'InitFcn'));      % rxAlignLat defaults to 41 (netlist) here
d = get_param(sys,'Description');
assert(contains(d,'FLAT REFERENCE MODEL') || contains(d,'frame='), ...
    'prod model description does not look like a derived flat model: %s', d(1:min(end,80)));
fprintf('prod model: %s\n', strtok(d, newline));

% Phase 3: byte reference-design IP-core workflow (CreateProject may fail --
% build_hdl.sh gates on the artefacts, as for dev).
run('hdlworkflow_loopback.m');
fprintf('VARIANT_BUILD_DONE: %s\n', 'prod');
