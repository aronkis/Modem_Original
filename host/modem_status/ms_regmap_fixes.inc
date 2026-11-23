/* generated from modem/regmap/regmap.toml sha 85c09033e68ece08; do not edit */
#ifdef MS_REGMAP_FIXES_FIXCTL_ONLY
{ 0x208, "fixctl", M, MS_F_WO, "fix control (write-only)" },
#else
{ 0x214, "w1_wita", W, MS_F_PACKED, "{occ[15:10] pushPtr[9:5] popPtr[4:0]}" }, /* W1 */
{ 0x218, "w1_witb", W, MS_F_PACKED, "{push_on_full[31:16] pop_on_empty[15:0]}" }, /* W1 */
{ 0x21C, "w1_ss", W, MS_F_WRAP32, "census (a) symbol-sync strobes" }, /* W1 */
{ 0x220, "w1_rh", W, MS_F_WRAP32, "census (b) Rate_Handle validOut" }, /* W1 */
{ 0x224, "w1_cfc", W, MS_F_WRAP32, "census (c) CFC validOut" }, /* W1 */
{ 0x228, "w1_cs", W, MS_F_WRAP32, "census (d) carrier-sync validOut" }, /* W1 */
{ 0x22C, "w1_pd", W, MS_F_WRAP32, "census (e) preamble-detector validOut" }, /* W1 */
{ 0x230, "w1_pc", W, MS_F_WRAP32, "census (f) packet-controller validOut" }, /* W1 */
{ 0x234, "r4_wit", W, MS_F_PACKED|MS_F_IMGKEY, "{locked[31] skips[30:15] opens[14:0]}" }, /* STEER */
{ 0x238, "r4_extras", W, MS_F_PACKED|MS_F_IMGKEY, "{16'b0 extras[15:0]}" }, /* STEER */
{ 0x23C, "bs_words", S, MS_F_WRAP32, "ByteSerializer words" }, /* BS */
{ 0x240, "bs_starts", S, MS_F_WRAP32, "RxAlign start pulses (frame boundaries)" }, /* BS */
{ 0x244, "bs_push", S, MS_F_WRAP32, "ByteRxFifo pushes" }, /* BS */
{ 0x248, "bs_pop", S, MS_F_WRAP32, "ByteRxFifo pops" }, /* BS */
{ 0x24C, "bs_drop", S, MS_F_WRAP32, "ByteRxFifo drop-oldest events" }, /* BS */
{ 0x250, "bs_marks", S, MS_F_PACKED, "{lasts[31:16] markpush[15:0]} wraps 52.6 s" }, /* BS */
{ 0x254, "bs_evt", S, MS_F_PACKED, "{trunc_last trunc_min trunc_max dropmax} sat; 8/8/8/8 bits at f1536, 9/9/9/5 at f3072 (WPP 382)" }, /* BS */
{ 0x258, "bs_cnt", S, MS_F_PACKED, "{trunc[31:16] q24[15:8]}" }, /* BS */
{ 0x25C, "sro_mode", W, MS_F_PACKED, "{30'b0 extra_armed[1] sro_sign[0]}" }, /* STEER */
{ 0x260, "tilt_eq_a12", W, MS_F_PACKED, "{a2[31:16] a1[15:0]} sfix16_En15 each" }, /* TILTEQ */
{ 0x264, "tilt_eq_a3en", W, MS_F_PACKED, "{en[31] 15'b0 a3[15:0]}" }, /* TILTEQ */
#endif /* MS_REGMAP_FIXES_FIXCTL_ONLY */
