// tb_tx_cdc_fifo.sv -- xsim testbench for tx_cdc_fifo (run: modem/instruments/txcdc/run_tb.sh on the
// Vivado host). Two 8 ns clocks with a phase offset swept over the whole period; a source that
// emits one counter sample per request it sees (the request is the DAC valid crossed back through
// three flops, as sync_input does in the design); the DAC side samples rd_i/rd_q on each request.
// PASS = every sample the DAC took is the next counter value (no duplicate, no skip, no mixed
// bits) at every phase, and underflow/overflow stay 0. Prints TB_PASS or TB_FAIL.
`timescale 1ns/1ps
module tb_tx_cdc_fifo;
  localparam integer WIDTH = 16;
  localparam integer NPHASE = 32;
  localparam integer NSAMP  = 4000;

  reg wr_clk = 0, rd_clk = 0;
  real phase_ns = 0.0; real rd_half = 4.0;   // rd_half != 4.0 = deliberate frequency mismatch (drift test)
  always #4.0 wr_clk = ~wr_clk;
  initial begin #(0.001); #(phase_ns); forever begin rd_clk = 1; #(rd_half); rd_clk = 0; #(rd_half); end end

  reg  wr_rstn = 0, rd_rstn = 0;
  reg  wr_valid = 0; reg [WIDTH-1:0] wr_i = 0, wr_q = 0;
  reg  rd_req = 0;
  wire [WIDTH-1:0] rd_i, rd_q; wire primed, dut_req; wire [15:0] underflow, overflow;

  tx_cdc_fifo_v2 #(.WIDTH(WIDTH)) dut (
    .wr_clk(wr_clk), .wr_rstn(wr_rstn), .wr_valid(wr_valid), .wr_i(wr_i), .wr_q(wr_q), .dut_req(dut_req),
    .rd_clk(rd_clk), .rd_rstn(rd_rstn), .rd_req(rd_req), .rd_i(rd_i), .rd_q(rd_q),
    .primed(primed), .underflow(underflow), .overflow(overflow));

  // DAC side: one request every other rd_clk (61.44 MSPS on a 125 MHz clock)
  reg tog = 0;
  always @(posedge rd_clk) begin tog <= ~tog; rd_req <= tog; end
  // the request crosses back into the source domain through 3 flops (sync_input's role)
  reg [2:0] req_sync = 0; reg req_d = 0;
  always @(posedge wr_clk) begin req_sync <= {req_sync[1:0], rd_req}; req_d <= req_sync[2]; end
  wire req_edge = req_sync[2] & ~req_d;
  // source (the DUT): one counter sample per dut_req (v2 pacing from the FIFO occupancy)
  reg [WIDTH-1:0] cnt = 0;
  always @(posedge wr_clk) begin
    wr_valid <= 0;
    if (wr_rstn && dut_req) begin wr_valid <= 1; wr_i <= cnt; wr_q <= ~cnt; cnt <= cnt + 1; end
  end
  // checker on the DAC side
  integer taken = 0, errors = 0, slips = 0, fails = 0, ph, mode;
  reg [WIDTH-1:0] last_i; reg have_last = 0;
  always @(posedge rd_clk) if (rd_req && primed) begin
    if (rd_q !== ~rd_i) begin errors = errors + 1; if (errors <= 2) $display("  ERR t=%0t q!=~i i=%h q=%h taken=%0d", $time, rd_i, rd_q, taken); end
    if (have_last && rd_i !== last_i + 1) begin slips = slips + 1; if (slips <= 2) $display("  SLIP t=%0t seq got=%h last=%h taken=%0d", $time, rd_i, last_i, taken); end
    last_i <= rd_i; have_last <= 1; taken = taken + 1;
  end

  initial begin
    for (mode = 0; mode < 3; mode = mode + 1) begin
      // mode 0: equal clocks (must be perfect); mode 1: DAC clock 2.5 % fast (FIFO drains, re-primes);
      // mode 2: DAC clock 2.5 % slow (FIFO fills, dut_req pauses -- no loss at all)
      rd_half = (mode == 0) ? 4.0 : (mode == 1) ? 3.90 : 4.10;   // 2.5 % mismatch: ~50 samples of drift per run, 1-2 re-primes
      for (ph = 0; ph < NPHASE; ph = ph + 1) begin
        phase_ns = 8.0 * ph / NPHASE;
        wr_rstn = 0; rd_rstn = 0; cnt = 0;
        repeat (20) @(posedge wr_clk);
        have_last = 0; taken = 0; errors = 0; slips = 0;
        wr_rstn = 1; repeat (4) @(posedge rd_clk); rd_rstn = 1;
        wait (primed);
        repeat (NSAMP) @(posedge rd_clk);
        if (errors != 0 || (mode == 0 && (slips != 0 || underflow != 0)) || (mode == 1 && slips > 8) || (mode == 2 && slips != 0) || overflow != 0 || taken < NSAMP/2 - ((mode == 1) ? 120 : 20)) begin   // a re-prime (mode 1) parks 32 requests
          fails = fails + 1;
          $display("TB_PHASE m%0d %0d (%0.3f ns): FAIL taken=%0d errors=%0d slips=%0d underflow=%0d overflow=%0d", mode, ph, phase_ns, taken, errors, slips, underflow, overflow);
        end else
          $display("TB_PHASE m%0d %0d (%0.3f ns): ok taken=%0d slips=%0d underflow=%0d", mode, ph, phase_ns, taken, slips, underflow);
      end
    end
    if (fails == 0) $display("TB_PASS 3 modes x %0d phases x %0d samples", NPHASE, NSAMP); else $display("TB_FAIL %0d of %0d runs", fails, 3*NPHASE);
    $finish;
  end
endmodule
