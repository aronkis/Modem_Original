// geometry.h -- the ONE place the live simulation benches take the air-frame geometry from.
// sp4 rung (2 sps, f3072): contract/PACKET_F3072.txt, frame_config_k5.m 'f3072'.
// The sps-4 / f1536 values are in the comments for the studies that were written against them.
#ifndef QPSK_GEOMETRY_H
#define QPSK_GEOMETRY_H
#define GEOM_SPS            2       /* samples per symbol at the rail            (f1536: 4)      */
#define GEOM_SLOTS          24634   /* symbol slots per air frame (Peak_Search.timing_Reference modulus) (f1536: 12333) */
#define GEOM_DATA_SYMS      24608   /* payload symbols per frame                 (f1536: 12320)  */
#define GEOM_PREAMBLE_SYMS  26      /* Barker-13 twice                           (f1536: 13)     */
#define GEOM_FRSAMP         49268L  /* rail samples per air frame = SLOTS*SPS    (f1536: 49332)  */
#define GEOM_PAYLOAD_BITS   49216   /* Data Bits FIFO pops per frame             (f1536: 24640)  */
#define GEOM_WPP            382     /* delivered 64-bit words per frame          (f1536: 191)    */
#define GEOM_PKT_BYTES      3056    /* host frame bytes = WPP*8                  (f1536: 1528)   */
#define GEOM_MAX_FILL       3044    /* payload bytes after the 12-byte header    (f1536: 1516)   */
#define GEOM_STROBE_INTERVAL 2      /* Rate_Handle validIn beats between symbol pushes = SPS (f1536: 4) */
#define GEOM_S1B_FRAME_CLKS 197072L /* S1B bench clocks per frame = SLOTS*2*SPS*2 (f1536: 197328) */
#define GEOM_DDRCAP2_WIDE   1       /* DDRCAP-v2 15-bit record layout (ddrcap2_inject.py header) (f1536: 0) */
#define GEOM_STEER_LEAD     24534   /* steering window opens SLOTS-100 nominal pops after pcEnd (f1536: 0) */
#define GEOM_STEER_TREF_OFF 226     /* skip position before the tref epoch boundary at sps 2 (f1536: 0) */
#endif
