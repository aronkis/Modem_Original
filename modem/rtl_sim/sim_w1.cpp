// sim_w1.cpp -- [sim] RXFIX_W1 instrument gate driver (Task 9, 2026-09-04).
//
// NEW FILE.  sim_sro.cpp is Task 7's and is running live legs; nothing here
// touches it.
//
//   sim_w1 rx <iq_file> <nsamp> <rstcs_end> <out_prefix> [cadence] [vphase]
//
// Replays an int16 I/Q file into the receiver exactly as sim_sro.cpp's rx mode
// does (cadence 2 clk per sample, vphase 0, rstCS pulse window), and writes:
//
//   <p>_deliv.txt  one line per delivered byte-plane frame: sidx,nwords,hash,user
//                  -- the DATA-PATH witness.  The s = 0 bit-identity gate is a
//                  byte-for-byte diff of this file between the W1 build and a
//                  baseline build of the same wrapper.
//   <p>_w1.txt     one line per air frame: the eight W1 register words beside an
//                  INDEPENDENT reference computed in this driver from the raw
//                  hierarchical taps.  The COMPARISON, however, is made on EVERY
//                  enb_1_2_0 beat, not only on the logged rows -- a one-beat hole
//                  event would otherwise fall between rows and go unchecked.  The
//                  row file is a readable sample of a continuous test.
//   <p>_res.txt    summary + PASS/FAIL verdict lines.
//
// SAMPLING CONVENTION (this is the whole subtlety).  A Verilator tap read after
// tick k carries the POST-edge value; the RTL counter that ticked on edge k used
// the PRE-edge value.  And the W1 shadow lags its live counter by one enb beat.
// Composing the two: the shadow read at beat k equals the live counter after beat
// k-1, i.e. the sum of the taps as sampled at beats 1..k-1.  So the reference is
// advanced by the PREVIOUS beat's sampled taps (`last*`), one beat behind the
// read -- that makes shadow and reference exactly equal, with no fudge factor,
// and any residual difference is a real instrument fault.
// sp3 task 4 (model-backport): the model-tree build's top module is
// wrap_byte_w1_model (make_sro_trees.sh --from-regen generates that wrapper),
// so Verilator emits Vwrap_byte_w1_model.h and a Vwrap_byte_w1_model class.
// build_sro_w1.sh passes -DW1_MODEL on that path only; the injector-lineage
// build is byte-for-byte the same translation unit as before.
#ifdef W1_MODEL
#include "Vwrap_byte_w1_model.h"
#define Vwrap_byte_w1 Vwrap_byte_w1_model
#else
#include "Vwrap_byte_w1.h"
#endif
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "geometry.h"
static const long FRSAMP = GEOM_FRSAMP;   // samples per air frame (SLOTS * SPS; geometry.h)

// sp3 task 4 fix round 1: W1_LAG (env, default 0, 0..7).  On the MODEL-generated
// tree the census words are read SOME enb beats later than on the injector
// lineage; W1_LAG=N compares the registers against the reference as it stood N
// enb beats earlier (a ring of the last 8 references makes any depth scorable in
// one pass).  The brief specified N=1; the measurement said otherwise, so the
// knob is depth-general and the report states which depth was measured.  The
// default (0) is the historic comparison, bit-for-bit: the verdict and exit code
// at W1_LAG=0 are exactly what they were before this change.  Every run now also
// reports the OTHER lag's mismatch count and `bigdiff` -- the number of beats on
// which some field differs by MORE than one under the lag-0 comparison.  bigdiff
// is the falsifier: a uniform one-beat latency has bigdiff == 0, anything else is
// a real counting fault and no lag setting may be used to paper over it.
static long long wdiff(unsigned w, unsigned r, int bits){
    // signed difference in the field's own wrap domain
    unsigned long long m = (bits>=32) ? 0xFFFFFFFFull : ((1ull<<bits)-1);
    unsigned long long d = ((unsigned long long)w - (unsigned long long)r) & m;
    unsigned long long half = 1ull << (bits-1);
    return (d & half) ? (long long)d - (long long)(m+1) : (long long)d;
}
struct W1Ref { unsigned occ,push,pop,poe,pof,cSS,cRH,cCFC,cCS,cPD,cPC; };
static const int W1LAG_MAX = 7;   // depth of the reference ring below

int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 6 || strcmp(argv[1],"rx")){
        fprintf(stderr,"usage: sim_w1 rx <iq> <nsamp> <rstcs_end> <prefix> [cadence] [vphase] [base]\n");
        return 2; }
    const char* iqf = argv[2];
    long nsamp      = atol(argv[3]);
    long rstcs_end  = atol(argv[4]);
    const char* pfx = argv[5];
    const int cadence = (argc>6)?atoi(argv[6]):2;
    const int vphase  = (argc>7)?atoi(argv[7]):0;
    // "base" = a build of this wrapper against the UNPATCHED tree: the W1 ports
    // read 0 by construction, so the register comparison is skipped and the leg
    // exists only to produce the _deliv.txt the s = 0 bit-identity gate diffs.
    const int base    = (argc>8 && !strcmp(argv[8],"base"));

    // W1_LAG = the compare depth N: 0 scores against this beat's reference (the
    // historic comparison), N scores against the reference as it stood N enb
    // beats earlier.  The reference ring holds W1LAG_MAX+1 entries, so N is
    // bounded by it -- an out-of-range N would silently alias (N=11 -> depth 3)
    // and print a PASS at a depth nobody asked for.  Rejected here, before any
    // output file is created, so a bad value cannot leave a half-written gate
    // result behind.
    const char* lagenv = getenv("W1_LAG");
    const int w1lag = lagenv ? atoi(lagenv) : 0;
    if(w1lag < 0 || w1lag > W1LAG_MAX){
        fprintf(stderr,"W1_LAG out of range 0..%d\n", W1LAG_MAX); return 2; }

    FILE* fi=fopen(iqf,"rb"); if(!fi){ fprintf(stderr,"cannot open %s\n",iqf); return 2; }
    std::vector<short> iq(2*nsamp);
    long got = fread(iq.data(),2,2*nsamp,fi); fclose(fi);
    if(got/2 < nsamp) nsamp = got/2;

    char fn[512];
    auto openout=[&](const char* s)->FILE*{ snprintf(fn,sizeof fn,"%s_%s.txt",pfx,s);
        FILE* f=fopen(fn,"w"); if(!f){ fprintf(stderr,"cannot open %s\n",fn); exit(2);} return f; };
    FILE* fd=openout("deliv");
    FILE* fw=openout("w1");
    fprintf(fw,"# f,occ_ref,occ_w1,push_ref,push_w1,pop_ref,pop_w1,"
               "poe_ref,poe_w1,pof_ref,pof_w1,"
               "cSS_ref,cSS_w1,cRH_ref,cRH_w1,cCFC_ref,cCFC_w1,"
               "cCS_ref,cCS_w1,cPD_ref,cPD_w1,cPC_ref,cPC_w1\n");

    Vwrap_byte_w1* t=new Vwrap_byte_w1;
    long clk=0,sidx=0; int ph=0;
    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=1; t->skip_count=0; t->tx_data_source=0;
    t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;
    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick();
    t->reset=0;

    // ---- independent reference counters, on the same enb beats ----
    unsigned rSS=0,rRH=0,rCFC=0,rCS=0,rPD=0,rPC=0;
    unsigned short rPOE=0,rPOF=0;
    // the previous beat's sampled taps (see SAMPLING CONVENTION above)
    unsigned lSS=0,lRH=0,lCFC=0,lCS=0,lPD=0,lPC=0,lPOE=0,lPOF=0;
    unsigned lOcc=0,lPush=0,lPop=0;
    long ndeliv=0, nframe=0, nmis=0, nrows=0;
    long nmis0=0, nmisL=0, nbig=0;
    // ring of the last W1LAG_MAX references, so any lag depth can be scored
    W1Ref refHist[W1LAG_MAX+1]; int nHist=0;
    // Where the at-depth mismatches are.  Two rows are structurally special and
    // can disagree at a nonzero depth for reasons that are not faults: the first
    // N compared beats (no reference that old exists yet, so the compare falls
    // back to this beat's) and the final check after the loop (the registers have
    // not moved since the last enb beat while the reference advanced one more
    // step).  Recording the row indices is what makes those distinguishable from
    // an interior mismatch, which would be a real defect.
    long badrowsL[8]; int nbrL=0; long lastbadL=-1;
    // Per-field mismatch counts at depth 0 and at the selected depth.  This is
    // what shows whether the disagreement is ONE phase for the whole census (then
    // a single depth repairs every field) or a per-field alignment problem (then
    // no depth can).
    long fmis0[11]={0}, fmisL[11]={0};
    static const char* FLD[11] = {"occ","push","pop","poe","pof",
                                  "cSS","cRH","cCFC","cCS","cPD","cPC"};
    // per-frame byte-plane accumulation (the data-path witness)
    unsigned hash=2166136261u; int nw=0; int fuser=0;
    long lastF=-1;

    auto check=[&](long f, int emit_row){
        // W1 words as the AXI decoder would read them
        unsigned wA=t->w1A, wB=t->w1B;
        unsigned occ_w1=(wA>>10)&0x3F, push_w1=(wA>>5)&0x1F, pop_w1=wA&0x1F;
        unsigned poe_w1=wB&0xFFFF, pof_w1=(wB>>16)&0xFFFF;
        unsigned occ_r=lOcc, push_r=lPush, pop_r=lPop;
        W1Ref cur; cur.occ=occ_r; cur.push=push_r; cur.pop=pop_r;
        cur.poe=rPOE; cur.pof=rPOF;
        cur.cSS=rSS; cur.cRH=rRH; cur.cCFC=rCFC; cur.cCS=rCS; cur.cPD=rPD; cur.cPC=rPC;
        const W1Ref& lagRef = (w1lag>0 && nHist>=w1lag) ? refHist[(nHist-w1lag) & W1LAG_MAX] : cur;
        const unsigned wv[11] = { occ_w1,push_w1,pop_w1,poe_w1,pof_w1,
            (unsigned)t->w1cSS,(unsigned)t->w1cRH,(unsigned)t->w1cCFC,
            (unsigned)t->w1cCS,(unsigned)t->w1cPD,(unsigned)t->w1cPC };
        const unsigned r0[11] = { cur.occ,cur.push,cur.pop,cur.poe,cur.pof,
            cur.cSS,cur.cRH,cur.cCFC,cur.cCS,cur.cPD,cur.cPC };
        const unsigned rL[11] = { lagRef.occ,lagRef.push,lagRef.pop,lagRef.poe,lagRef.pof,
            lagRef.cSS,lagRef.cRH,lagRef.cCFC,lagRef.cCS,lagRef.cPD,lagRef.cPC };
        static const int W[11] = { 6,5,5,16,16,32,32,32,32,32,32 };
        int bad0=0, badL=0, big=0;
        if(!base){
            for(int i=0;i<11;i++){
                long long d0 = wdiff(wv[i], r0[i], W[i]);
                if(d0) { bad0=1; fmis0[i]++; if(d0>1 || d0< -1) big=1; }
                // same wrap-aware comparison at the selected depth
                if(wdiff(wv[i], rL[i], W[i])) { badL=1; fmisL[i]++; }
            }
        }
        if(bad0) nmis0++;
        if(badL){ nmisL++; if(nbrL<8) badrowsL[nbrL++]=nrows; lastbadL=nrows; }
        if(big)  nbig++;
        int bad = w1lag ? badL : bad0;
        if(bad) nmis++;
        nrows++;
        refHist[nHist & W1LAG_MAX] = cur; nHist++;
        if(!emit_row) return;
        fprintf(fw,"%ld,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u\n",
                f,occ_r,occ_w1,push_r,push_w1,pop_r,pop_w1,
                (unsigned)rPOE,poe_w1,(unsigned)rPOF,pof_w1,
                rSS,(unsigned)t->w1cSS, rRH,(unsigned)t->w1cRH,
                rCFC,(unsigned)t->w1cCFC, rCS,(unsigned)t->w1cCS,
                rPD,(unsigned)t->w1cPD, rPC,(unsigned)t->w1cPC);
    };

    long total = 100 + nsamp*(long)cadence + 200000;
    while(clk<total){
        if(ph==vphase){
            if(sidx<nsamp){ t->adc_dataInI=iq[2*sidx]; t->adc_dataInQ=iq[2*sidx+1]; t->adc_validIn=1; sidx++; }
            else t->adc_validIn=0;
        } else t->adc_validIn=0;
        ph=(ph+1)%cadence;
        t->rstCS = (clk>400 && clk<rstcs_end)?1:0;
        tick();

        long f = sidx/FRSAMP;
        if(t->railEnb){
            // compare BEFORE this beat's reference update: the RTL registers
            // sampled now already contain the effect of every PREVIOUS enb beat,
            // and the reference has been advanced over exactly those beats.
            // compare on EVERY enb beat; log a row once per air frame
            int newframe = (f!=lastF);
            check(f, newframe);
            if(newframe){ lastF=f; nframe++; }
            // advance the reference by the PREVIOUS beat's taps, then latch this
            // beat's taps as the next "previous"
            rSS+=lSS; rRH+=lRH; rCFC+=lCFC; rCS+=lCS; rPD+=lPD; rPC+=lPC;
            rPOE=(unsigned short)(rPOE+lPOE); rPOF=(unsigned short)(rPOF+lPOF);
            lSS=t->rhStrobe; lRH=t->rhValidOut;
            lCFC=t->cfcV; lCS=t->csV; lPD=t->pdV; lPC=t->pcV;
            lPOE=t->rhPopEmpty; lPOF=t->rhPushFull;
            lOcc=t->occTrue; lPush=t->fifoPush; lPop=t->fifoPop;
        }
        // byte-plane delivered stream (data-path witness)
        if(t->byte_rx_valid && t->byte_rx_ready){
            unsigned long long d=t->byte_rx_data;
            for(int b=0;b<8;b++){ hash^=(unsigned)((d>>(8*b))&0xFF); hash*=16777619u; }
            nw++;
            if(t->byte_rx_user) fuser=1;
            if(t->byte_rx_last){
                fprintf(fd,"%ld,%d,%08x,%d\n",sidx,nw,hash,fuser);
                ndeliv++; hash=2166136261u; nw=0; fuser=0;
            }
        }
    }
    // one final comparison at the end of the run
    check(-1, 1);

    FILE* fr=openout("res");
    fprintf(fr,"W1GATE prefix=%s iq=%s nsamp=%ld frames=%ld delivered=%ld\n",
            pfx,iqf,nsamp,nframe,ndeliv);
    fprintf(fr,"W1GATE ref cSS=%u cRH=%u cCFC=%u cCS=%u cPD=%u cPC=%u poe=%u pof=%u\n",
            rSS,rRH,rCFC,rCS,rPD,rPC,(unsigned)rPOE,(unsigned)rPOF);
    fprintf(fr,"W1GATE w1  cSS=%u cRH=%u cCFC=%u cCS=%u cPD=%u cPC=%u witA=%08x witB=%08x\n",
            (unsigned)t->w1cSS,(unsigned)t->w1cRH,(unsigned)t->w1cCFC,
            (unsigned)t->w1cCS,(unsigned)t->w1cPD,(unsigned)t->w1cPC,
            (unsigned)t->w1A,(unsigned)t->w1B);
    fprintf(fr,"W1GATE lag=%d mismatches_lag0=%ld mismatches_atlag=%ld bigdiff_lag0=%ld\n",
            w1lag, nmis0, nmisL, nbig);
    for(int i=0;i<11;i++)
        fprintf(fr,"W1GATE field %-4s lag0=%ld atlag=%ld\n", FLD[i], fmis0[i], fmisL[i]);
    fprintf(fr,"W1GATE atlag_rows total=%ld last_bad=%ld first_bad=[", nrows, lastbadL);
    for(int i=0;i<nbrL;i++) fprintf(fr,"%s%ld", i?" ":"", badrowsL[i]);
    fprintf(fr,"]\n");
    fprintf(fr,"W1GATE mode=%s compared_beats=%ld mismatches=%ld verdict=%s\n",
            base?"baseline":"w1", nrows,nmis, base?"SKIP":(nmis?"FAIL":"PASS"));
    fclose(fr); fclose(fd); fclose(fw);
    printf("W1GATE %s mode=%s frames=%ld delivered=%ld compared_beats=%ld mismatches=%ld"
           " lag=%d mismatches_lag0=%ld mismatches_atlag=%ld bigdiff_lag0=%ld %s\n",
           pfx, base?"baseline":"w1", nframe,ndeliv,nrows,nmis,
           w1lag,nmis0,nmisL,nbig,
           base?"SKIP":(nmis?"FAIL":"PASS"));
    delete t; return nmis?1:0;
}
