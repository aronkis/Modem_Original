% derive_prod.m -- dev -> prod in ONE MATLAB session, run inside a kit copy of
% modem/dev (derive.sh makes the copy, exports the production QPSK_* env and
% puts <kit> and its stage folders on the path via kitpath).
%
%  1. make_flat_model      assemble every overlay, auto-arrange, annotate
%  2. install the flat model as the kit's commhdlQPSKTxRxLoopback.slx
%  3. flat_rename_reg_ports  reg_ prefix on the 58 register ports (+ consumers)
%  4. flat_order_ports       DATA / CONTROL / DEBUG numbering
%  5. flat_layout_lanes      TxRxComposite and Receiver lanes
%  6. flat_snap_ports        ports beside their pins, rotated, coloured
%  7. flat_simfix            BIST print branch removed, RxAlign latency -> rxAlignLat
%  8. prod_cleanup           delete-list + terminate + comment the example root
%  9. flat_root_harness      sources / sinks / loopback at the root
% Prints DERIVE_PROD_DONE on success; derive.sh copies the results into modem/prod.
KIT = fileparts(fileparts(mfilename('fullpath')));    % <kit>/derive -> <kit>
cd(KIT);
make_flat_model;                                       % script: leaves commhdlQPSKTxRxLoopback_flat loaded
flatName = 'commhdlQPSKTxRxLoopback_flat';
sys = 'commhdlQPSKTxRxLoopback';
if bdIsLoaded(flatName), close_system(flatName, 0); end
if bdIsLoaded(sys), close_system(sys, 0); end
copyfile(fullfile(KIT,[flatName '.slx']), fullfile(KIT,[sys '.slx']));
load_system(fullfile(KIT,[sys '.slx']));
% the flat copy was saved under the _flat name; loading it under the kit name
% is what every tool below expects
flat_rename_reg_ports(KIT, 'Apply', true);
flat_order_ports(KIT, 'Apply', true);
flat_layout_lanes(KIT, 'TxRxComposite', 'Apply', true);
flat_layout_lanes(KIT, 'TxRxComposite/Receiver', 'Apply', true);
flat_snap_ports(KIT, 'Subsystem', 'TxRxComposite', 'Apply', true);
flat_snap_ports(KIT, 'Subsystem', 'TxRxComposite/Receiver', 'Apply', true);
flat_simfix(KIT, 'Apply', true);
prod_cleanup(KIT);
flat_root_harness(KIT, 'Apply', true);
n = numel(find_system(sys,'LookUnderMasks','all','FollowLinks','off','Type','Block'));
fprintf('DERIVE_PROD_DONE blocks=%d file=%s\n', n, get_param(sys,'FileName'));
