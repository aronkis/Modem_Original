# The RX-only byte-plane pad, in simulation: the suspect is falsified, and the gate is blind

`ONEWAY_HW_VERIFY_2026-09-25.md` sec 7 named a suspect for the RX-only image's byte-plane loss
(69 % on 146, 6.6 % in legacy mode, clean on the fabric ROM source): *"The RXO image's 2-deep
byte-plane pad versus the full image's 4 is the documented suspect and is checkable in simulation
without a board."* It is now checked. **It is not the cause, and the check found something else.**

All desk work. No board was touched.

## 1. What the pad is

`build_hdl.sh` [7b]: HDL Coder's delay balancer pads the byte FIFO's `ready` by N registers, and
`rxfifo_inject.sh` mirrors the generated N into the drop-in `ByteRxFifo.v`, whose functional pop is
`valid && ready_1` with `ready_1 = delayMatch_reg[N-1]`. The full image lands on N=4. A one-way image
solves a different model -- one half is a stub -- and lands on N=2, which the gate accepts because
its contract is *census depth == drop-in depth*, not *depth == 4*.

## 2. First attempt, and why its clean result was worthless

2x2 on the shipped gate harness: pad {4, 2} x steering {R4B `FIXCTL=0`, R4D+R1 `FIXCTL=0x20`}, at
+2.5 and +10 ppm, patching only the ready pipeline of `s1_rtl_model/ByteRxFifo.v`.

Every pad-2 cell came out **byte-identical** to its pad-4 twin, and the steering numbers reproduced
the published Gate 1 values exactly (R4B 0.24 % at +2.5 ppm and 22.75 % at +10 ppm; R4D+R1 0.00 % at
both), which is a good harness check but not an answer.

**The reason is a tautology, not a result.** `sim_sro.cpp` sets `byte_rx_ready = 1` once and never
lowers it. A constant through an N-deep shift register is the same constant for every N, so the pad
depth is unobservable on that driver **by construction**. No possible pad-depth defect could have
shown up.

## 3. The consequence, which is bigger than the original question

**No Gate 1 leg can detect a wrong ready-pad depth.** All 53 legs run through this driver, the
`BS_READY_PAD` check in `build_hdl.sh` is a grep over generated RTL rather than a behavioural test,
and the drop-in's pop logic is only exercised with ready held high. The pad contract that the build
carefully computes and mirrors is, today, **unverified by simulation**.

## 4. With backpressure, the pad is load-bearing -- and the suspicion inverts

`sim_sro_bp.cpp` (a copy; the gate driver is untouched) drives `byte_rx_ready` as a deterministic
square wave, `BP_LOW` of every `BP_PERIOD` cycles low, so two builds see bit-identical stimulus and
any difference is the device's. At 3 of 16 (18.8 % backpressure), R4B at 0 ppm:

| ready-pad depth | LOSS | delivered-bytes md5 |
|---|---|---|
| 2 | **0.00 %** | 94c24025 |
| 3 | **0.00 %** | 94c24025 |
| 4 (the full-image value) | **49.76 %** | ffbab0f4 |
| 5 | **49.76 %** | ffbab0f4 |

Same picture with steering active at +10 ppm: depth 2 reproduces the no-backpressure numbers exactly
(R4B 22.75 %, R4D+R1 0.00 %) while depth 4 loses 61.34 % and 49.64 %.

So in this harness the pad is not merely observable under backpressure, it is a **cliff between 3 and
4**, and the one-way image's 2 is on the *good* side of it. The original suspicion -- that 2 is a
defect relative to 4 -- is **not supported by any of this**.

## 5. What this does NOT establish

**It does not show the product's depth of 4 is wrong.** The harness is a model wrapper, not the full
image: the balancer's correct N depends on the surrounding pipeline, which is the whole reason a
one-way build lands on a different number. The shipped full image runs depth 4 with a forward PER of
0.005 %, so on real hardware 4 is evidently the matching value there. What transfers is the
mechanism, not the number: **a ready pad that does not match its pipeline silently destroys about
half the frames, and only under backpressure.**

It also does not explain the RX-only failure. The hardware evidence is mode-sensitive (69 % in queued
16-packet capture, 6.6 % in legacy per-packet) and board-asymmetric (clean on 148, broken on 146),
and the FIFO in this tree is 8192 deep, the same order as production, so capacity is not the story.
The remaining candidate is the one the hardware evidence already pointed at and this work does not
touch: the **host-side queued capture path**, which locates frames by scanning the landing buffer.

## 6. What is worth doing with this

* The backpressure driver is the first harness here that can exercise the byte plane's handshake at
  all. A leg built on it would close the blind spot in sec 3.
* `BP_PERIOD`/`BP_LOW` make the backpressure duty a knob, so the tolerated ready latency can be
  mapped rather than guessed.
* The host-side scan is the next place to look for the RX-only defect, and it is readable without a
  board.

## 7. Margin sweep, and what it says about the HARNESS rather than the product

Varying the backpressure duty at period 16, R4B at 0 ppm:

| ready low | depth 4 | depth 2 |
|---|---|---|
| 1 of 16 | 49.05 % | 0.00 % |
| 2 of 16 | 49.05 % | 0.00 % |
| 3 of 16 | 49.76 % | 0.00 % |

**Depth 4 has NO margin at all: a single deasserted ready cycle in sixteen costs half the frames.**
That is the decisive interpretive fact, and it points at the harness, not the product. The shipped
image runs depth 4 and delivers a forward PER of 0.005 %; the host's receive DMA certainly deasserts
ready sometimes, so if the product had zero tolerance for one cycle of backpressure the link would be
catastrophically broken and it is not.

**Conclusion: this model harness's byte-plane latency differs from the shipped image's, and depth
<= 3 is what matches the HARNESS.** Three consequences, one of which corrects sec 4:

1. Sec 4's result stands as stated -- the pad is observable only under backpressure, and the one-way
   depth of 2 is not on the failing side -- but it cannot be read as "2 is right and 4 is wrong for
   the product". Which depth is correct is a property of the pipeline each model generates, and this
   harness is not that pipeline.
2. **A backpressure leg must NOT be added to the gate yet.** It would fail on the production tree for
   a harness reason and read as a product defect. The harness has to be reconciled with the shipped
   image's latency first -- that is the prerequisite for closing the sec 3 blind spot, and it is a
   piece of work in its own right.
3. The blind spot itself is unchanged and still real: no existing leg exercises the handshake at all,
   so a genuinely wrong pad depth would ship undetected.
