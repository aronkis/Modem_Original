// wrap_byte.v -- Verilator wrapper for the modem TxRxComposite
// netlist gate (S1B): internal loopback, byte pins driven, modulator symbol
// taps for the air-bit oracle. Pattern: jupiter_240k5/rtl_sim/rx_wrap_jup.v.
`timescale 1 ns / 1 ns
module wrap_byte
  (input  wire clk, input wire reset,
   input  wire adc_validIn,
   input  wire signed [15:0] adc_dataInI, input wire signed [15:0] adc_dataInQ,
   input  wire reg_rstCS, input wire reg_rx_input_select,
   input  wire [31:0] reg_skip_count,
   input  wire [31:0] reg_tx_data_source,
   input  wire [63:0] byte_data, input wire byte_valid, input wire byte_first,
   input  wire byte_rx_ready,
   output wire byte_ready,
   output wire [63:0] byte_rx_data,
   output wire byte_rx_valid, output wire byte_rx_last, output wire byte_rx_user,
   output wire [31:0] reg_count_out, reg_packets_out, reg_bit_errors_out,
   output wire [31:0] reg_cnt_frame_start, reg_cap_out, reg_rstcs_count, reg_cfc_est,
   output wire modValid,
   output wire signed [15:0] modI, output wire signed [15:0] modQ,
   output wire railEnb);
  wire [31:0] nc0,nc1,nc2,nc3,nc4,nc5,nc6,nc7;
  wire signed [15:0] ncI,ncQ,ncI1,ncQ1,ncTI,ncTQ; wire ncV,ncTV;
  TxRxComposite dut(
    .clk(clk), .reset(reset), .clk_enable(1'b1),
    .adc_validIn(adc_validIn), .adc_dataInI(adc_dataInI), .adc_dataInQ(adc_dataInQ),
    .reg_rstCS(reg_rstCS), .reg_iq_debug_mux(32'd0), .reg_rx_input_select(reg_rx_input_select),
    .host_txI(16'sd0), .host_txQ(16'sd0), .host_txValid(1'b0),
    .reg_tx_source_select(32'd0), .reg_skip_count(reg_skip_count),
    .byte_data(byte_data), .byte_valid(byte_valid),
    .reg_tx_data_source(reg_tx_data_source), .byte_first(byte_first),
    .byte_rx_ready(byte_rx_ready),
    .reg_count_out(reg_count_out), .reg_packets_out(reg_packets_out), .reg_bit_errors_out(reg_bit_errors_out),
    .debugI(ncI), .debugQ(ncQ), .debugValid(ncV), .debugI1(ncI1), .debugQ1(ncQ1),
    .tx_dataOutI(ncTI), .tx_dataOutQ(ncTQ), .tx_validOut(ncTV),
    .reg_cnt_descr_in(nc0), .reg_cnt_frame_start(reg_cnt_frame_start),
    .reg_cnt_vit_reset(nc1), .reg_cnt_deint_valid(nc2),
    .reg_cnt_dec_bits(nc3), .reg_cnt_bist_start(nc4), .reg_dbg_sentinel(nc5),
    .reg_cap_in(nc6), .reg_cap_deint(nc7), .reg_cap_out(reg_cap_out), .reg_cap_cad(),
    .reg_rstcs_count(reg_rstcs_count), .reg_cfc_est(reg_cfc_est),
    .byte_ready(byte_ready),
    .byte_rx_data(byte_rx_data), .byte_rx_valid(byte_rx_valid),
    .byte_rx_last(byte_rx_last), .byte_rx_user(byte_rx_user));
  // air-bit oracle taps: the true QPSK constellation symbol stream inside
  // QPSK Tx (same signals the donor tb_tx_240k5.v used on the Transmitter)
  assign modValid = dut.u_Transmitter.u_QPSK_Tx.QPSKConstellationValid;
  assign modI     = dut.u_Transmitter.u_QPSK_Tx.QPSKConstellationPoints_re;
  assign modQ     = dut.u_Transmitter.u_QPSK_Tx.QPSKConstellationPoints_im;
  // T8 rate fix: the Transmitter rail = 15.36e6 model = enb_1_2_0 (was enb_1_4_0)
  assign railEnb  = dut.u_TxRxComposite_tc.enb_1_2_0;
endmodule
