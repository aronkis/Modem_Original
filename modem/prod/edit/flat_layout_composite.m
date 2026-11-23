function L = flat_layout_composite(kit, opts)
% flat_layout_composite -- TxRxComposite as TX / RX / byte DMA / debug lanes.
% Thin wrapper over flat_layout_lanes(kit, 'TxRxComposite', ...), kept for the
% flat_gate.sh 'layout' subcommand and older notes.
arguments
    kit (1,:) char = pwd
    opts.Apply (1,1) logical = false
end
L = flat_layout_lanes(kit, 'TxRxComposite', 'Apply', opts.Apply);
end
