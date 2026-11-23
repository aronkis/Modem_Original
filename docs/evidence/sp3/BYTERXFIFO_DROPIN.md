# `ByteRxFifo` is a tracked DESIGN SOURCE, not HDL Coder output

Cleanup sub-project 3, Task 7 precondition. Recorded 2026-09-11.

## The divergence

`modem/byte_rxfifo_overlay.m` puts a MATLAB Function block `ByteRxFifo` at the
composite level, and HDL Coder emits a **64-deep register FIFO**
(`reg [63:0] mem [0:63];`). That is *not* what any deployed image runs. Every
build tree in this lineage has the generated module overwritten, by name, with
the hand-authored **v5 BRAM drop-in** `modem/rxfifo_bram/ByteRxFifo.v`:

* 4096 words deep, `(* ram_style = "block" *)` simple dual-port synchronous-read
  RAM with a registered read address and a separate registered write-through
  bypass (v3/v4 history in the file header: v3 put the mux inside the read and
  Vivado fell back to LUTRAM);
* **drop-oldest** on full (`drop = push && (wr_p1 == rd_after_pop)`), counted in
  a saturating `ovfCnt`;
* a v5 DEBUG change: AXI word **0x1B0 carries the handshake STATE**, not the
  overflow count — `{rdyRun[31:24], ready_1, valid_i, ready, stateControl_2,
  enb, nonempty, byp_sel, (ovfCnt != 0), wr[7:0], rd[7:0]}`.

Why it exists: at f1536 (191 words/frame × 1245 fps) 64 words cover ~0.25 ms,
and the `axi_dmac` S2MM inter-transfer backpressure (0.25–2 ms, tail to ~16 ms)
overflows it and truncates one frame per transfer — the forward "boundary comb",
84 % of forward loss (2026-08-27 sim-repro campaign E9).

Evidence that the bank is the drop-in and a regen was not: the banked base tree's
`TxRxCompo_ip_src_ByteRxFifo.v` greps `BRAM drop-in` = 1, and the pre-Task-7
regen's `base_rtl_diff.txt` classified both copies (`hdlsrc/` and
`ipcore/.../hdl/`) as `LOGIC`.

## The ruling

The drop-in is **tracked design source**. It is NOT rebuilt in Simulink as part
of sub-project 3, and `modem/rxfifo_inject.sh` does NOT die with the netlist
injectors: it becomes stage **`[4a/5] rxfifo`** of
`modem/fixes/build_base_tree.sh`, run right after the MATLAB stage and before
`txcap`/`ddrcap`/`ddrcap2` (it replaces a whole file, so it must not land on top
of their edits). It records `RXFIFO_INJECT_OK` or
`BASE_REGEN_INJECT_FAILED stage=rxfifo` exactly like the three instruments, and
`modem/tests/test_assemble_phases.py` pins the stage textually.

**Follow-up (not this sub-project):** re-express the v5 behaviour in
`modem/byte_rxfifo_overlay.m` as an MLFB + `Simple Dual Port RAM` pair so HDL
Coder emits the `RAMB36` mapping itself. Acceptance for that follow-up:
`grep -c "Simple Dual Port RAM\|SimpleDualPortRAM" <regen>/…ByteRxFifo*.v >= 1`
*and* the `build_sro_bs.legs` identity rows still hold. Until then the drop-in is
the only thing in the generated tree that the model does not generate.

## Consequence for the BS byte-seam census (Task 7)

The netlist injector `modem/fixes/rxfix_inject.py` taps the drop-in's **internal
wires** — `assign bsPush = push; assign bsPop = pop; assign bsDrop = drop;` — by
patching `ByteRxFifo.v` itself. A MODEL overlay cannot do that: HDL Coder
generates the *instantiation*, the drop-in replaces the *module*, so the model
can only see the module's **PORTS**, and adding ports would mean editing a
shipped design source to match a model edit.

Verified port list of the drop-in:

```
clk reset enb word tog wLast wFirst ready outWord valid outLast outFirst ovf
```

`push`, `pop` and `drop` are internal wires; **`ovf` is NOT a drop pulse** (the
Task 7 controller notes guessed it might be) — it is the v5 `dbg` word above, in
which the only drop information is the sticky bit 16, `ovfCnt != 0`.

So `modem/rxfix/rxfix_bs_overlay.m` DERIVES the three seam events from the ports,
using the drop-in's own rules:

| census event | drop-in's rule (internal) | model overlay's derivation (ports only) |
|---|---|---|
| `push` | `tog != prev`, registered under `enb_gated` | XOR edge of `tog` at the base rate — the same rule, one beat of `stateControl_2` startup earlier |
| `pop`  | `valid_i && ready_1`, `ready_1 = delayMatch_reg[3]` | `valid && ready_1`, where `ready_1` is **HDL Coder's own balanced copy of the raw `byte_rx_ready` MLFB input**, not an overlay-built `Delay` block — see "the balancer rule" below |
| `drop` | `push && (wr_p1 == rd_after_pop)` | an occupancy SHADOW: `occ_next = occ + push - pop - drop`, `drop = push && ((occ - pop) == 4095)` — algebraically the drop-in's own test with `DEPTH = 4096` |

**The balancer rule (round 2, replacing a round-1 defect).** Round 1 built
`readyD4` as an explicit 4-deep `Delay` block *outside* the census MLFB, on the
`rxfix_steer_overlay.m` "keep the long path outside the block" reasoning, and
fed `pop = valid && readyD4` in. HDL Coder then balanced the block's OTHER raw
inputs (e.g. `fixctl`) to match that path's latency by inserting **its own**
4-deep `delayMatch1_reg` chain — but it does not recognise a hand-built design
`Delay` as pipeline to match against, so the already-delayed `readyD4` input got
balanced too, landing an extra 4 beats on top of the deliberate 4 and computing
`valid(k) && ready(k-8)` where the FIFO pops on `valid(k) && ready(k-4)`. **HDL
Coder's delay balancing counts only pipeline IT inserts, never a design
`Delay`.** The fix removes the overlay's `Delay` block entirely and feeds
`byte_rx_ready` into the MLFB RAW; the balancer then supplies the missing 4
beats itself, generating `reg [3:0] delayMatch_reg; delayMatch_reg[0] <= ready
(if enb); assign ready_1 = delayMatch_reg[3];` — width-for-width and enable-for-
enable the same chain the drop-in's own `ByteRxFifo.v` carries
(`reg [3:0] delayMatch_reg; <= {delayMatch_reg[2:0], ready}` under `enb`;
`wire ready_1 = delayMatch_reg[3];`). To reproduce a generated module's own
`delayMatch` chain: feed the signal in raw and let the balancer supply it — do
not build the chain by hand.

**Startup-skew window: up to 4 `enb` beats.** `delayMatch_reg` (and, on the
model tree, the sibling `delayMatch1_reg` the balancer inserts on `fixctl`) is
4 deep, so for the first 4 `enb` beats after reset `ready_1` is still draining
the register's reset value rather than a real historical `byte_rx_ready`
sample — the census's derived `pop` can disagree with the drop-in's actual pop
for that window. Quiescent legs never exercise it (pops track pushes one-for-
one once the pipe is full); it is a startup transient, not a steady-state
error, and it is the same transient the drop-in itself has on its own
`ready_1`.

The shadow is exact **given** exact `push`/`pop`, and it is a model of the FIFO
rather than a tap of it. That is stated plainly here because it changes what
`bs_drop == 0` proves: on its own it is a shadow agreeing with itself. The gate
therefore also taps the drop-in's real `drop`/`ovfCnt` hierarchically from the
Verilator wrapper, where the module source IS in the tree, so the zero is
witnessed rather than assumed. On silicon the independent witness is 0x1B0 bit 16.
