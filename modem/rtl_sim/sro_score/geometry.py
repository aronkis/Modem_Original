"""geometry.py -- the ONE place the live scorers / stimulus generator take the air-frame geometry from.
sp4 rung (2 sps, f3072): contract/PACKET_F3072.txt, frame_config_k5.m 'f3072'. Twin of ../geometry.h;
modem/tests/test_sim_geometry.py keeps the two in step. (f1536 values in the comments.)"""
SPS = 2              # (f1536: 4)
SLOTS = 24634        # symbols per air frame = Peak_Search.timing_Reference modulus (f1536: 12333)
DATA_SYMS = 24608    # (f1536: 12320)
PREAMBLE_SYMS = 26   # (f1536: 13)
FRSAMP = SLOTS * SPS # rail samples per air frame = 49268 (f1536: 49332)
PAYLOAD_BITS = 49216 # Data Bits FIFO pops per frame (f1536: 24640)
WPP = 382            # delivered 64-bit words per frame (f1536: 191)
PKT_BYTES = WPP * 8  # 3056 (f1536: 1528)
MAX_FILL = PKT_BYTES - 12  # 3044 (f1536: 1516)
# Rate Handle steering window (rxfix_steer_overlay.m): at sps 2 the 13-slot skip/extra window opens
# STEER_LEAD nominal pops after pcEnd (= 100 pops before the next pcEnd) so the dropped/held symbol
# lands in the filler+preamble of the frame entering the ring; the skips then sit STEER_TREF_OFF
# symbols before the air-frame (tref) epoch boundary (measured, Gate 1 run 3). f1536: 0 and 0.
STEER_LEAD = SLOTS - 100   # 24534 (f1536: 0)
STEER_TREF_OFF = 226       # (f1536: 0 -- skips within TREF_TOL of the boundary)
