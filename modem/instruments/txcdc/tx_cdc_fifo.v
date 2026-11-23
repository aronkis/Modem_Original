// tx_cdc_fifo.v (v2) -- the modem's transmit samples cross from the ADRV9001 RX-derived clock
// (axi_adrv9001_adc_1_clk, the DUT's IPCORE_CLK) into the ADI DAC core's clock
// (axi_adrv9001_dac_1_clk) through a REAL asynchronous FIFO.
//
// WHY (docs/evidence/sp3/SP3_GATE3_RETEST.md sections 7-8): the reference design carries these
// samples through sync_output/sync_fast_to_slow (ADI, RATIO=2), a ring buffer whose read/write
// addresses are compared across the two clocks unsynchronised and whose data is only bounded by
// `set_max_delay -datapath_only 8.0` (modem/common/bd/cdc_exceptions.xdc). The two clocks are the same
// 8 ns but their phase is re-established at every ADRV9001 profile load, so every arm is a
// lottery: when the phase lands inside the placement-dependent skew window of the 32-bit bus,
// bits of one sample are captured from different cycles (data-dependent, bursty TX corruption;
// ~40 % of arms on 148 with the sp3 bitstream, rare with sp2A). An async FIFO with Gray-coded
// pointers (xpm_fifo_async) removes the phase dependence entirely.
//
// Rates: the DUT emits one sample per request it receives (dac_1_valid_i0 crossed into the DUT
// through sync_input), so the long-run write and read rates are identical (61.44 MSPS on 125 MHz
// clocks). The FIFO is primed to PRIME_LEVEL entries before the first pop and thereafter pops
// one entry per DAC request; a pop on an empty FIFO (never, once primed and the rates match)
// holds the last sample and counts in `underflow`; a write into a full FIFO drops the sample
// and counts in `overflow`. Both counters are sticky witnesses for a scope/ILA or a later
// register tap; nothing in the datapath depends on them.
//
// RATE GOVERNANCE (v2, after the first silicon window drained the FIFO in 595 s and left the link in a
// permanent reset storm): the DUT is no longer paced by the DAC request crossed back through
// sync_input (a single-bit crossing that can lose pulses, which drains the FIFO by one entry per
// lost pulse). `dut_req` -- one request every second wr_clk, held off while the FIFO is above
// PROG_FULL entries -- paces the DUT from the FIFO's own occupancy, so the write rate follows the
// read rate by construction. Safety net: an empty FIFO drops `primed` and re-primes to PRIME_LEVEL
// (one 32-sample insertion instead of a sample-by-sample stutter), counted in `underflow`. Depth 64
// with 32 entries of slack: the v1 silicon window drained 8 entries in ~600 s, so a re-prime is
// expected about once per 40 min at that drift, costing one RX resync each.
//
// Reset: xpm_fifo_async's `rst` is synchronous to wr_clk and must be held for a few cycles;
// the design's rx_rstn (the DUT reset, adc domain) is used. Reads and writes are held off while
// the FIFO reports *_rst_busy.
`timescale 1ns/1ps
module tx_cdc_fifo_v2 #(
  parameter integer WIDTH = 16,
  parameter integer PRIME_LEVEL = 32,   // entries queued before the first pop (depth 64)
  parameter integer PROG_FULL   = 48    // dut_req pauses while the FIFO holds more than this
) (
  // write side: the DUT (adc_1_clk domain). X_INTERFACE_* keeps Vivado's interface inference
  // from folding the data pins into a phantom FIFO/stream bus (it did: "interface_fifo_wr") and
  // declares the clocks/resets properly so the BD cell exposes plain pins.
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 wr_clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_RESET wr_rstn" *)
  input  wire             wr_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 wr_rstn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire             wr_rstn,
  (* X_INTERFACE_IGNORE = "true" *) input  wire             wr_valid,
  (* X_INTERFACE_IGNORE = "true" *) input  wire [WIDTH-1:0] wr_i,
  (* X_INTERFACE_IGNORE = "true" *) input  wire [WIDTH-1:0] wr_q,
  (* X_INTERFACE_IGNORE = "true" *) output reg              dut_req,     // -> TxRxCompo_ip_0/dut_data_valid_in_tx
  // read side: the ADI DAC core (dac_1_clk domain)
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 rd_clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_RESET rd_rstn" *)
  input  wire             rd_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rd_rstn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire             rd_rstn,
  (* X_INTERFACE_IGNORE = "true" *) input  wire             rd_req,      // axi_adrv9001 dac_1_valid_i0: one sample requested
  (* X_INTERFACE_IGNORE = "true" *) output reg  [WIDTH-1:0] rd_i,
  (* X_INTERFACE_IGNORE = "true" *) output reg  [WIDTH-1:0] rd_q,
  (* X_INTERFACE_IGNORE = "true" *) output reg              primed,
  (* X_INTERFACE_IGNORE = "true" *) output reg  [15:0]      underflow,
  (* X_INTERFACE_IGNORE = "true" *) output reg  [15:0]      overflow
);
  wire             full, empty, wr_rst_busy, rd_rst_busy, prog_full;
  wire [2*WIDTH-1:0] dout;
  wire [6:0]       rd_count;
  wire             wr_en = wr_valid & ~full & ~wr_rst_busy;
  wire             rd_en = rd_req & primed & ~empty & ~rd_rst_busy;

  xpm_fifo_async #(
    .CDC_SYNC_STAGES     (3),
    .DOUT_RESET_VALUE    ("0"),
    .ECC_MODE            ("no_ecc"),
    .FIFO_MEMORY_TYPE    ("distributed"),
    .FIFO_READ_LATENCY   (0),
    .FIFO_WRITE_DEPTH    (64),
    .FULL_RESET_VALUE    (0),
    .PROG_EMPTY_THRESH   (5),
    .PROG_FULL_THRESH    (PROG_FULL),
    .RD_DATA_COUNT_WIDTH (7),
    .READ_DATA_WIDTH     (2*WIDTH),
    .READ_MODE           ("fwft"),
    .RELATED_CLOCKS      (0),
    .SIM_ASSERT_CHK      (0),
    .USE_ADV_FEATURES    ("0402"),     // rd_data_count + prog_full
    .WAKEUP_TIME         (0),
    .WRITE_DATA_WIDTH    (2*WIDTH),
    .WR_DATA_COUNT_WIDTH (7)
  ) u_fifo (
    .rst           (~wr_rstn),
    .wr_clk        (wr_clk),
    .wr_en         (wr_en),
    .din           ({wr_q, wr_i}),
    .full          (full),
    .wr_rst_busy   (wr_rst_busy),
    .rd_clk        (rd_clk),
    .rd_en         (rd_en),
    .dout          (dout),
    .empty         (empty),
    .rd_rst_busy   (rd_rst_busy),
    .rd_data_count (rd_count),
    .sleep         (1'b0),
    .injectsbiterr (1'b0),
    .injectdbiterr (1'b0),
    .almost_empty  (), .almost_full (), .data_valid (), .dbiterr (), .overflow (),
    .prog_empty    (), .prog_full (prog_full), .sbiterr (), .underflow (),
    .wr_ack        (), .wr_data_count ()
  );

  // priming + presented sample (dac domain). In fwft mode dout is the head entry whenever
  // !empty; the DAC core samples rd_i/rd_q on its own valid, so the head is what it gets and
  // the pop below advances to the next one for the next request.
  always @(posedge rd_clk) begin
    if (!rd_rstn) begin
      primed <= 1'b0; rd_i <= {WIDTH{1'b0}}; rd_q <= {WIDTH{1'b0}}; underflow <= 16'd0;
    end else begin
      // prime: load the first head sample in the same edge that raises `primed`, so the first
      // request after priming already sees a real sample (not the reset value)
      if (!primed && !rd_rst_busy && !empty && rd_count >= PRIME_LEVEL) begin
        primed <= 1'b1; rd_i <= dout[WIDTH-1:0]; rd_q <= dout[2*WIDTH-1:WIDTH];
      end else if (primed && !empty) begin
        rd_i <= dout[WIDTH-1:0]; rd_q <= dout[2*WIDTH-1:WIDTH];
      end else if (primed && empty && rd_req) begin
        primed <= 1'b0;                              // drained: hold the last sample, re-prime
        if (underflow != 16'hFFFF) underflow <= underflow + 16'd1;
      end
    end
  end
  reg req_tog;
  always @(posedge wr_clk) begin
    if (!wr_rstn) begin overflow <= 16'd0; req_tog <= 1'b0; dut_req <= 1'b0; end
    else begin
      req_tog <= ~req_tog;
      dut_req <= req_tog & ~prog_full & ~wr_rst_busy;   // one sample per two clocks while there is room
      if (wr_valid && full && overflow != 16'hFFFF) overflow <= overflow + 16'd1;
    end
  end
endmodule
