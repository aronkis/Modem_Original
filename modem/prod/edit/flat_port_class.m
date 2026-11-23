function c = flat_port_class(name)
% flat_port_class -- DATA / CONTROL / DEBUG classification of a port name.
% Shared by flat_order_ports (numbering) and flat_snap_ports (colours).
% Exact lists first (composite-level names, with or without the reg_ prefix),
% then name patterns for ports deeper in the hierarchy.
base = regexprep(name, '^reg_', '');
DATA = {'adc_dataInI','adc_dataInQ','adc_validIn','host_txI','host_txQ','host_txValid', ...
        'byte_data','byte_valid','byte_first','byte_ready', ...
        'tx_dataOutI','tx_dataOutQ','tx_validOut', ...
        'byte_rx_data','byte_rx_valid','byte_rx_last','byte_rx_user','byte_rx_ready'};
CONTROL = {'rstCS','rx_input_select','tx_source_select','tx_data_source','skip_count','iq_debug_mux', ...
           'cs_prop_gain','cs_integ_gain','ss_prop_gain','ss_integ_gain','agc_loop_gain','cfo_threshold', ...
           'fixctl','count_out','packets_out','bit_errors_out','cap_out'};
if any(strcmp(base, DATA)),           c = 'DATA';
elseif any(strcmp(base, CONTROL)),    c = 'CONTROL';
elseif ~isempty(regexp(base, ['^(debug|cnt_|cap_|rstcs_count|cfc_est|adc_forensic|state_|shdw_|strobe_forensic|' ...
        'beat|path_canary|ic_div|cs_lf|cs_v|lt_|ta_|byte_fifo_ovf|p1b_|framestat|w1|r4|sro|bs_|bs[A-Z]|beatfix|dbg|' ...
        'census|wit|canary|shadow|forensic|probe|telemetry|fs_)'], 'once'))
    c = 'DEBUG';
elseif ~isempty(regexp(base, '(?i)(gain|thresh|select|sel$|^rst|reset|fixctl|En$|enable|source|skip|freeze|sign|mode$|ctl$)', 'once'))
    c = 'CONTROL';
else
    c = 'DATA';
end
end
