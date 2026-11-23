function M = flat_rename_reg_ports(kit, opts)
% flat_rename_reg_ports -- prefix every REGISTER port on TxRxComposite with
% 'reg_' (or another prefix), and keep the gate consumers in the kit in step.
%
%   M = flat_rename_reg_ports(kit)                    dry run: report only
%   M = flat_rename_reg_ports(kit, 'Apply', true)     rename + rewrite + save
%   ... 'Prefix', 'reg_'                              default prefix
%
% "Register port" = an Inport or Outport on TxRxComposite that is NOT one of
% the reference-design data interfaces. The functional set is read from the
% kit's hdlworkflow_loopback.m (every port mapped to something other than
% AXI4-Lite: ADC/DAC data, host tx, debug capture, byte plane), with a
% hard-coded fallback if the file is missing. Everything else on the boundary
% is an AXI4-Lite register in the IP core, whichever overlay added it.
%
% The generated Verilog port names follow the block names, so the files that
% bind to them by name are rewritten too (word-boundary, never double-prefixed):
%   hdlworkflow_loopback.m       block paths in the IOInterface map
%   sim_byte_gate_k5.m           harness connect_in / logNames
%   rtl_sim/wrap_byte.v          Verilator wrapper pin binding (S1B gate)
%   rtl_sim/sim_byte.cpp         top->port accesses (S1B gate)
% Writes <kit>/RENAME_MAP.txt. Returns a table old -> new -> direction.
% Not touched: the repo, modem/regmap/regmap.toml, the host tools, or any
% other testbench in rtl_sim/ (they bind to older netlists by name).
arguments
    kit (1,:) char = pwd
    opts.Prefix (1,:) char = 'reg_'
    opts.Apply (1,1) logical = false
end
pfx = opts.Prefix;
sys = 'commhdlQPSKTxRxLoopback';
if ~bdIsLoaded(sys), load_system(fullfile(kit,[sys '.slx'])); end
loop = [sys '/TxRxComposite'];

% ---- functional (non-register) ports from the workflow map ----------------
wf = fullfile(kit,'hdlworkflow_loopback.m');
functional = {};
if isfile(wf)
    txt = fileread(wf);
    tok = regexp(txt, "TxRxComposite/([A-Za-z0-9_]+)'\s*,\s*'IOInterface'\s*,\s*'([^']*)'", 'tokens');
    for k = 1:numel(tok)
        if ~strcmp(tok{k}{2}, 'AXI4-Lite'), functional{end+1} = tok{k}{1}; end %#ok<AGROW>
    end
end
fallback = {'adc_dataInI','adc_dataInQ','adc_validIn','tx_dataOutI','tx_dataOutQ','tx_validOut', ...
    'host_txI','host_txQ','host_txValid','debugI','debugQ','debugI1','debugQ1','debugValid', ...
    'byte_data','byte_valid','byte_first','byte_ready','byte_rx_data','byte_rx_valid', ...
    'byte_rx_last','byte_rx_user','byte_rx_ready'};
functional = unique([functional fallback]);

% ---- the rename plan --------------------------------------------------------
rows = {};
for typ = {'Inport','Outport'}
    blks = find_system(loop,'SearchDepth',1,'BlockType',typ{1});
    for k = 1:numel(blks)
        nm = get_param(blks{k},'Name');
        if any(strcmp(nm, functional)), continue; end
        if startsWith(nm, pfx), continue; end
        rows(end+1,:) = {nm, [pfx nm], typ{1}, str2double(get_param(blks{k},'Port'))}; %#ok<AGROW>
    end
end
M = cell2table(rows, 'VariableNames', {'old','new','dir','port'});
M = sortrows(M, {'dir','port'});
fprintf('%s: %d register ports to prefix with "%s" (%d functional ports left alone)\n', ...
    ternary(opts.Apply,'APPLY','DRY RUN'), height(M), pfx, numel(functional));

% ---- consumers in the kit ---------------------------------------------------
% the kit's stage-folder layout (2026-09-17): the Simulink byte gate lives in simgate/ (it was
% silently '(missing, skipped)' at the kit root, so a derived prod gate kept the un-renamed ports)
files = {'hdlworkflow_loopback.m', fullfile('simgate','sim_byte_gate_k5.m'), fullfile('rtl_sim','wrap_byte.v'), fullfile('rtl_sim','sim_byte.cpp')};
hits = zeros(numel(files),1);
newTxt = cell(numel(files),1);
for f = 1:numel(files)
    p = fullfile(kit, files{f});
    assert(isfile(p), 'flat_rename_reg_ports: %s not found in the kit (layout drift?)', files{f});
    t = fileread(p); n = 0;
    for k = 1:height(M)
        pat = ['(?<![A-Za-z0-9_])' regexptranslate('escape', M.old{k}) '(?![A-Za-z0-9_])'];
        % never double-prefix: a preceding "<pfx>" already counts as an identifier char, so the
        % lookbehind above excludes it automatically
        [t, c] = regexprepCount(t, pat, M.new{k});
        n = n + c;
    end
    hits(f) = n; newTxt{f} = t;
    fprintf('  %-28s %4d replacements\n', files{f}, n);
end

% ---- report -----------------------------------------------------------------
fid = fopen(fullfile(kit,'RENAME_MAP.txt'),'w');
fprintf(fid, 'RENAME_MAP %s  prefix=%s  applied=%d\n', char(datetime('now')), pfx, opts.Apply);
for k = 1:height(M), fprintf(fid, '%-7s %3d  %-24s -> %s\n', M.dir{k}, M.port(k), M.old{k}, M.new{k}); end
for f = 1:numel(files), fprintf(fid, 'rewrite %-28s %d\n', files{f}, hits(f)); end
fclose(fid);

if ~opts.Apply
    fprintf('dry run: nothing changed. Plan in %s. Re-run with ''Apply'',true.\n', fullfile(kit,'RENAME_MAP.txt'));
    return;
end

% ---- apply ------------------------------------------------------------------
for k = 1:height(M)
    set_param([loop '/' M.old{k}], 'Name', M.new{k});
end
for f = 1:numel(files)
    if isempty(newTxt{f}), continue; end
    p = fullfile(kit, files{f});
    copyfile(p, [p '.pre_rename']);
    fw = fopen(p,'w'); fwrite(fw, newTxt{f}); fclose(fw);
end
save_system(sys, [], 'OverwriteIfChangedOnDisk', true);
fprintf('FLAT_RENAME_DONE renamed=%d files=%d saved=%s\n', height(M), sum(hits>0), get_param(sys,'FileName'));
end

function [t, c] = regexprepCount(t, pat, rep)
c = numel(regexp(t, pat, 'once', 'start'));
if c, c = numel(regexp(t, pat, 'start')); t = regexprep(t, pat, rep); end
end

function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end
