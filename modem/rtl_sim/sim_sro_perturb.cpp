// sim_sro_perturb.cpp -- the receiver's response to a PERTURBED air stream: signal dropouts, fades,
// AWGN, carrier-frequency offsets and steps, applied sample by sample to the banked stimulus before
// it reaches adc_dataIn. Logs, per air frame, the AXI-visible receiver state: packets_out (frame
// syncs), bit_errors_out, cnt_frame_start, rstcs_count (the CFO step-change detector's carrier-sync
// resets) and cfc_est (the coarse frequency estimate).
//
// WHY. docs/evidence/link/RESET_LEDGER_2026-09-29.md: 82-89 % of the historical "resets while
// decoding" were one event -- a 4-246 ms interruption of the peer's transmit feed -- after which the
// receiver stormed (~900 rstCS/s, CRC 0 %) and had not re-locked 5 s later. The Gate 1 driver
// (sim_sro.cpp) feeds a clean stream and cannot ask how the carrier path behaves when the signal goes
// away and comes back, or sits at exactly zero residual offset. This one can. The gate driver is not
// modified; this is a separate, lean driver built against the same verilated model.
//
//   sim_sro_perturb rx <iq> <nsamp> <rstcs_end> <prefix> [cadence=2] [vphase=0]
//
// Env (all optional; frames are FRSAMP-sample air frames counted from the first sample fed):
//   PERT_FS=61440000       rail sample rate, Hz (the CFO rotation's time base)
//   PERT_LOOP=1            wrap the stimulus at its end (the bank file is an exact whole number of
//                          frames, so the wrap lands on a frame boundary) so nsamp may exceed the file
//   PERT_CFO_HZ=f          constant carrier offset applied to the whole stream
//   PERT_STEP_HZ=f PERT_STEP_FRAME=n     add a further offset step from frame n on
//   PERT_SNR_DB=x          add AWGN at x dB below the stream's RMS (measured over the first 2 frames)
//   PERT_DROP_FRAME=n PERT_DROP_N=k PERT_DROP_MODE=zero|noise   replace frames [n, n+k) by zeros or
//                          by noise at PERT_DROP_NOISE_DB (default 0 dB = same RMS as the signal)
//   PERT_FADE_DB=x PERT_FADE_FRAME=n PERT_FADE_N=k             attenuate frames [n, n+k) by x dB
//   PERT_SEED=s            xorshift seed for the noise (deterministic by default)
//   PERT_GAIN=g            global amplitude scale on the stream (1.0)
//   PERT_TILT_DB=t         frequency-selective channel: in-band spectral slope, dB from -8 to +8 MHz (multipath fade)
//   PERT_EQ_A1/A2/A3=a     TiltEq corrector words (HAVE_TILT_EQ trees): a_k sfix16_En15; PERT_EQ_AUTO=1 = exact inverse of PERT_TILT_DB;
//   PERT_EQ_MISSET=m       scale every a_k by (1+m) (robustness row)
//   PERT_RSTCS_AT_FRAME=n  hold rstCS (the host 0x110 carrier-sync reset) for 400 clks at frame n
//   PERT_RESET_AT_FRAME=n  pulse the top-level reset (the 0x000 soft reset) for 100 clks at frame n
// Output: <prefix>_pert.txt (one row per frame) and <prefix>_pert_summary.txt. Per-frame STAGE LEVELS
// (v2): RMS at the Rate-Handle input (post AGC+RRC+symbol-sync, the earliest exposed tap so it tracks
// the AGC output), at the coarse compensator output and the carrier-sync output; the correlator's
// peak value and its threshold; the Peak_Search running max. These say WHICH stage is stuck after a
// signal gap (an AGC wound up on silence clips; a stuck correlator threshold never re-syncs).
#ifdef SRO_MODEL
#include "Vwrap_byte_sro_model.h"
#define Vwrap_byte_sro Vwrap_byte_sro_model
#else
#include "Vwrap_byte_sro.h"
#endif
#include "verilated.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <algorithm>
#define _USE_MATH_DEFINES
#include "geometry.h"
static const long FRSAMP = GEOM_FRSAMP;

static double envd(const char* k, double d){ const char* v=getenv(k); return v? atof(v): d; }
static long   envl(const char* k, long d){ const char* v=getenv(k); return v? atol(v): d; }
static const char* envs(const char* k, const char* d){ const char* v=getenv(k); return v? v: d; }

struct Rng { unsigned long long s; explicit Rng(unsigned long long seed): s(seed?seed:0x9E3779B97F4A7C15ULL) {}
  double uni(){ s^=s<<13; s^=s>>7; s^=s<<17; return (double)(s>>11)/9007199254740992.0; }
  double gauss(){ double u=uni(), v=uni(); if(u<1e-300) u=1e-300; return sqrt(-2.0*log(u))*cos(6.283185307179586*v); } };

static inline short sat16(double x){ if(x>32767) return 32767; if(x<-32768) return -32768; return (short)lrint(x); }

int main(int argc, char** argv){
    Verilated::commandArgs(argc, argv);
    if(argc < 6 || strcmp(argv[1],"rx")){ fprintf(stderr,"usage: sim_sro_perturb rx iq nsamp rstcs_end prefix [cadence] [vphase]\n"); return 2; }
    const char* iqf = argv[2]; long nsamp = atol(argv[3]); long rstcs_end = atol(argv[4]); const char* pfx = argv[5];
    const int cadence = (argc>6)?atoi(argv[6]):2; const int vphase = (argc>7)?atoi(argv[7]):0;

    FILE* fi=fopen(iqf,"rb"); if(!fi){ fprintf(stderr,"cannot open %s\n",iqf); return 2; }
    fseek(fi,0,SEEK_END); long fsamp = ftell(fi)/4; fseek(fi,0,SEEK_SET);
    std::vector<short> iq(2*fsamp); long got=fread(iq.data(),2,2*fsamp,fi); fclose(fi); fsamp=got/2;
    const int loop = (int)envl("PERT_LOOP",1);
    if(!loop && nsamp>fsamp) nsamp=fsamp;
    const long NFR = nsamp/FRSAMP + 1;

    // perturbation plan
    const double FS = envd("PERT_FS",61440000.0);
    const double cfo = envd("PERT_CFO_HZ",0.0), step_hz = envd("PERT_STEP_HZ",0.0); const long step_fr = envl("PERT_STEP_FRAME",-1);
    const double snr_db = envd("PERT_SNR_DB",1e9);
    const long drop_fr = envl("PERT_DROP_FRAME",-1), drop_n = envl("PERT_DROP_N",0); const char* drop_mode = envs("PERT_DROP_MODE","zero");
    const double drop_noise_db = envd("PERT_DROP_NOISE_DB",0.0);
    const double fade_db = envd("PERT_FADE_DB",0.0); const long fade_fr = envl("PERT_FADE_FRAME",-1), fade_n = envl("PERT_FADE_N",0);
    Rng rng((unsigned long long)envl("PERT_SEED",1));
    const double gain = envd("PERT_GAIN",1.0);
    // PERT_TILT_DB=t (2026-10-02): a frequency-selective CHANNEL -- the in-band spectral slope the forward air
    // path shows in a multipath fade (FORWARD_LINK_2026-10-01.md sec. 9: -14.6 dB across 16 MHz = 46 % loss).
    // Modelled as K cascaded one-tap filters y = x + a*j*x[n-1]: |H(f)|^2 = 1 + a^2 + 2a sin(2 pi f/FS), an
    // antisymmetric slope across the band; t is the dB difference between +8 MHz and -8 MHz (negative = upper
    // half down, the sign seen on the rig). One stage spans ~8 dB; |t| > 7 uses two stages, > 14 three.
    const double tilt_db = envd("PERT_TILT_DB",0.0);
    int tilt_k = (fabs(tilt_db) > 14.0) ? 3 : (fabs(tilt_db) > 7.0) ? 2 : 1;
    double tilt_a = 0.0;
    if(tilt_db != 0.0){
        const double s8 = sin(6.283185307179586*8.0e6/FS), want = fabs(tilt_db)/tilt_k;
        double lo=0.0, hi=0.999;
        for(int it=0; it<60; it++){ double a=0.5*(lo+hi); double v=10.0*log10((1+a*a+2*a*s8)/(1+a*a-2*a*s8)); if(v<want) lo=a; else hi=a; }
        tilt_a = (tilt_db > 0) ? 0.5*(lo+hi) : -0.5*(lo+hi);
    }
    double tprevI[3]={0,0,0}, tprevQ[3]={0,0,0};
    const double tilt_norm = (tilt_db != 0.0) ? 1.0/sqrt(1.0 + tilt_a*tilt_a) : 1.0;
    // PERT_EQ_* (2026-10-03): the fabric's TiltEq corrector words (tilt_eq_overlay.m). PERT_EQ_AUTO=1 sets the exact
    // inverse of PERT_TILT_DB (same stage count, same a, channel sign -- the fabric applies the one-pole inverse),
    // PERT_EQ_A1/A2/A3 set a_k directly, PERT_EQ_MISSET=m scales every a_k by (1+m). Encoded sfix16_En15,
    // en = any a_k != 0. Without HAVE_TILT_EQ the words are computed and logged but drive nothing.
    double eqa[3] = { envd("PERT_EQ_A1",0.0), envd("PERT_EQ_A2",0.0), envd("PERT_EQ_A3",0.0) };
    if (envl("PERT_EQ_AUTO",0) && tilt_db != 0.0) for (int k = 0; k < tilt_k; k++) eqa[k] = tilt_a;
    { const double m = envd("PERT_EQ_MISSET",0.0); for (int k = 0; k < 3; k++) eqa[k] *= (1.0 + m); }
    auto eq_enc = [](double a){ long q = lround(a * 32768.0); if (q > 32767) q = 32767; if (q < -32768) q = -32768; return (unsigned)(q & 0xFFFF); };
    const unsigned eq_w260 = (eq_enc(eqa[1]) << 16) | eq_enc(eqa[0]);
    const unsigned eq_w264 = ((eqa[0] != 0.0 || eqa[1] != 0.0 || eqa[2] != 0.0) ? 0x80000000u : 0u) | eq_enc(eqa[2]);
    const long rstcs_fr = envl("PERT_RSTCS_AT_FRAME",-1), reset_fr = envl("PERT_RESET_AT_FRAME",-1);
    // stream RMS over the first two frames, for noise scaling
    double acc=0; long nrms = std::min<long>(2*FRSAMP, fsamp);
    for(long i=0;i<nrms;i++){ acc += (double)iq[2*i]*iq[2*i] + (double)iq[2*i+1]*iq[2*i+1]; }
    const double rms = sqrt(acc/(2.0*nrms));
    const double nsig = (snr_db<1e8)? rms*pow(10.0,-snr_db/20.0) : 0.0;
    const double dnsig = rms*pow(10.0,-drop_noise_db/20.0);
    const double fade_g = pow(10.0,-fade_db/20.0);

    char fn[512]; snprintf(fn,sizeof fn,"%s_pert.txt",pfx); FILE* fo=fopen(fn,"w"); if(!fo){ fprintf(stderr,"cannot write %s\n",fn); return 2; }
    fprintf(fo,"# frame,sidx,packets,d_packets,biterr,d_biterr,frame_start,rstcs,d_rstcs,cfc_est,pert,rhin_rms,cfc_rms,cs_rms,corr_max,corr_thr_med,ps_rmax,cfcEst_tap,"
               "strobes,mu_mean,mu_sd,rh_ph0,rh_ph1,rh_ph2,rh_ph3,pop_empty,push_full,occ_min,occ_max,est_changes,est_min,est_max"
#ifdef HAVE_AGC_TAP
               ",agc_mag,agc_ang_deg,agc_rot_deg_per_frame,agc_ang_sd_deg"
#endif
#ifdef HAVE_SS_TAP
               ",ss_integ_mean,ss_integ_min,ss_integ_max,ss_v_mean,ss_v_min,ss_v_max"
#endif
               "\n");
    // v3 side file: EVERY change of the coarse estimate (window-rate), for the first EST_LOG_FRAMES frames
    snprintf(fn,sizeof fn,"%s_est.txt",pfx); FILE* fe=fopen(fn,"w"); if(fe) fprintf(fe,"# frame,sidx,cfcEst\n");
    const long est_log_frames = envl("PERT_EST_LOG_FRAMES",60);
    fprintf(fo,"# rms=%.1f fs=%.0f cfo_hz=%.1f step_hz=%.1f@%ld snr_db=%s drop=%s@%ld+%ld fade=%.1fdB@%ld+%ld loop=%d file_frames=%ld\n",
            rms,FS,cfo,step_hz,step_fr,(snr_db<1e8?std::to_string(snr_db).c_str():"none"),drop_mode,drop_fr,drop_n,fade_db,fade_fr,fade_n,loop,fsamp/FRSAMP);
    fprintf(fo,"# tilt_db=%.1f stages=%d a=%.4f\n", tilt_db, tilt_k, tilt_a);
    fprintf(fo,"# eq a1=%.5f a2=%.5f a3=%.5f w260=0x%08X w264=0x%08X\n", eqa[0], eqa[1], eqa[2], eq_w260, eq_w264);

    Vwrap_byte_sro* t=new Vwrap_byte_sro;
    long clk=0, sidx=0; int ph=0;
    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=1; t->skip_count=0; t->tx_data_source=0;
    t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;
    t->tgen_sel=0; t->tgen_ctrl=0; t->tgen_gap=0;
#ifdef HAVE_TILT_EQ
    t->tilt_eq_a12 = eq_w260; t->tilt_eq_a3en = eq_w264;
#endif
    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick();
    t->reset=0;

    double phase=0.0; long lastP=0, lastB=0, lastR=0; long curfr=-1; int pertflag=0;
    // per-frame stage accumulators, sampled on rail beats (railEnb)
    double a_rh=0,a_cfc=0,a_cs=0; long n_rh=0; long corr_max=0; std::vector<long> thr; long ps_max=0;
    // v3 symbol-sync census per frame
    long strobes=0; double mu_s=0, mu_ss=0; long mu_n=0; long rhph[4]={0,0,0,0}; long pe=0, pf=0; int occ_min=99, occ_max=-1;
    int est_prev=0; long est_changes=0; int est_min=0, est_max=0; bool est_init=false; unsigned char prev_und=0;
#ifdef HAVE_SS_TAP
    double si_s=0; long si_n=0; long si_min=0, si_max=0; double sv_s=0; int sv_min=0, sv_max=0; bool ss_init=false;
    auto sx30=[](unsigned v)->long{ long x=(long)(v & ((1u<<30)-1)); if(x & (1L<<29)) x -= (1L<<30); return x; };
    auto sx11=[](unsigned v)->int{ int x=(int)(v & 0x7FF); if(x & 0x400) x -= 0x800; return x; };
#endif
#ifdef HAVE_AGC_TAP
    double g_mag=0, g_cos=0, g_sin=0; long g_n=0; double g_ang_prev_frame=0; bool g_have_prev=false; std::vector<double> g_angs;
    auto sx34=[](unsigned long long v)->long long{ long long x=(long long)(v & ((1ULL<<34)-1)); if(x & (1LL<<33)) x -= (1LL<<34); return x; };
#endif
    long knob_rstcs_until=-1, knob_reset_until=-1; long knob_rstcs_done=-1, knob_reset_done=-1;
    unsigned long total = 100 + (unsigned long)nsamp*(unsigned long)cadence + 200000;
    for(unsigned long c=0; c<total; c++){
        if(ph==vphase){
            if(sidx<nsamp){
                long fidx = sidx / FRSAMP;
                long src = loop ? (sidx % fsamp) : sidx;
                double I = iq[2*src], Q = iq[2*src+1]; pertflag=0;
                if(fade_n>0 && fidx>=fade_fr && fidx<fade_fr+fade_n){ I*=fade_g; Q*=fade_g; pertflag|=1; }
                double f = cfo + ((step_fr>=0 && fidx>=step_fr)? step_hz : 0.0);
                if(f!=0.0){ double ci=cos(phase), si=sin(phase); double I2=I*ci-Q*si, Q2=I*si+Q*ci; I=I2; Q=Q2;
                            phase += 6.283185307179586*f/FS; if(phase>6.283185307179586) phase-=6.283185307179586; if(phase<0) phase+=6.283185307179586; }
                I*=gain; Q*=gain;
                if(tilt_db != 0.0){ for(int k=0;k<tilt_k;k++){ double yI = I - tilt_a*tprevQ[k], yQ = Q + tilt_a*tprevI[k];
                                                             tprevI[k]=I; tprevQ[k]=Q; I=yI*tilt_norm; Q=yQ*tilt_norm; } }
                if(nsig>0){ I += nsig*rng.gauss(); Q += nsig*rng.gauss(); }
                if(drop_n>0 && fidx>=drop_fr && fidx<drop_fr+drop_n){
                    if(!strcmp(drop_mode,"noise")){ I = dnsig*rng.gauss(); Q = dnsig*rng.gauss(); } else { I=0; Q=0; }
                    pertflag|=2;
                }
                t->adc_dataInI=sat16(I); t->adc_dataInQ=sat16(Q); t->adc_validIn=1; sidx++;
            } else t->adc_validIn=0;
        } else t->adc_validIn=0;
        ph=(ph+1)%cadence;
        long fnow = sidx/FRSAMP;
        if(rstcs_fr>=0 && fnow==rstcs_fr && knob_rstcs_done!=rstcs_fr){ knob_rstcs_until=clk+400; knob_rstcs_done=rstcs_fr; }
        if(reset_fr>=0 && fnow==reset_fr && knob_reset_done!=reset_fr){ knob_reset_until=clk+100; knob_reset_done=reset_fr; }
        t->rstCS = ((clk>400 && clk<rstcs_end) || clk<knob_rstcs_until)?1:0;
        t->reset = (clk<knob_reset_until)?1:0;
        tick();
        if(t->railEnb){
            double ri=(double)(short)t->rhInI, rq=(double)(short)t->rhInQ; a_rh+=ri*ri+rq*rq;
            double ci=(double)(short)t->cfcI, cq=(double)(short)t->cfcQ; a_cfc+=ci*ci+cq*cq;
            double si=(double)(short)t->csI,  sq=(double)(short)t->csQ;  a_cs+=si*si+sq*sq; n_rh++;
            long cd=(long)(int)t->corrD; if(cd>corr_max) corr_max=cd;
            thr.push_back((long)(int)t->corrT);
            long pm=(long)(int)t->psRmax; if(pm>ps_max) ps_max=pm;
            // symbol synchronizer: strobes (Interpolation_Control underflow edges), mu, Rate_Handle phase/ring
            if(t->icUnd && !prev_und) strobes++; prev_und=t->icUnd;
            { int mu=(int)t->icMu; if(mu & (1<<10)) mu -= (1<<11); mu_s+=mu; mu_ss+=(double)mu*mu; mu_n++; }
            rhph[t->rhPhase & 3]++;
            if(t->rhPopEmpty) pe++; if(t->rhPushFull) pf++;
            { int o=(int)t->occTrue; if(o<occ_min) occ_min=o; if(o>occ_max) occ_max=o; }
#ifdef HAVE_SS_TAP
            { long si=sx30(t->ssInteg); int sv=sx11(t->ssV);
              if(!ss_init){ si_min=si_max=si; sv_min=sv_max=sv; ss_init=true; }
              si_s+=si; si_n++; if(si<si_min) si_min=si; if(si>si_max) si_max=si; sv_s+=sv; if(sv<sv_min) sv_min=sv; if(sv>sv_max) sv_max=sv; }
#endif
#ifdef HAVE_AGC_TAP
            { double gr=(double)sx34(t->agcGainRe), gi=(double)sx34(t->agcGainIm); double m=hypot(gr,gi);
              g_mag+=m; if(m>0){ g_cos+=gr/m; g_sin+=gi/m; } g_n++; if(g_angs.size()<4096) g_angs.push_back(atan2(gi,gr)); }
#endif
            { int e=(int)t->cfcEst; if(e & (1<<20)) e -= (1<<21);
              if(!est_init){ est_prev=e; est_min=est_max=e; est_init=true; }
              else if(e!=est_prev){ est_changes++; est_prev=e; if(e<est_min) est_min=e; if(e>est_max) est_max=e;
                                    if(fe && curfr>=0 && curfr<est_log_frames) fprintf(fe,"%ld,%ld,%d\n",curfr,sidx,e); } }
        }
        long f = sidx/FRSAMP;
        if(f!=curfr && curfr>=0){
            long P=t->packets_out, B=t->bit_errors_out, R=t->rstcs_count; int cf=(int)t->cfc_est;
            long thr_med=0; if(!thr.empty()){ std::nth_element(thr.begin(),thr.begin()+thr.size()/2,thr.end()); thr_med=thr[thr.size()/2]; }
            int est=(int)t->cfcEst; if(est & (1<<20)) est -= (1<<21);   // sfix21 sign-extend
            double mum = mu_n? mu_s/mu_n : 0.0; double musd = mu_n? sqrt(std::max(0.0, mu_ss/mu_n - mum*mum)) : 0.0;
            fprintf(fo,"%ld,%ld,%ld,%ld,%ld,%ld,%u,%ld,%ld,%d,%d,%.0f,%.0f,%.0f,%ld,%ld,%ld,%d,%ld,%.1f,%.1f,%ld,%ld,%ld,%ld,%ld,%ld,%d,%d,%ld,%d,%d\n",
                    curfr,sidx,P,P-lastP,B,B-lastB,(unsigned)t->cnt_frame_start,R,R-lastR,cf,pertflag,
                    n_rh?sqrt(a_rh/(2.0*n_rh)):0.0, n_rh?sqrt(a_cfc/(2.0*n_rh)):0.0, n_rh?sqrt(a_cs/(2.0*n_rh)):0.0, corr_max, thr_med, ps_max, est,
                    strobes, mum, musd, rhph[0],rhph[1],rhph[2],rhph[3], pe, pf, occ_min, occ_max, est_changes, est_min, est_max);
#ifdef HAVE_AGC_TAP
            { double mag = g_n? g_mag/g_n : 0.0; double ang = atan2(g_sin, g_cos)*180.0/M_PI;
              double rot = g_have_prev ? (ang - g_ang_prev_frame) : 0.0; while(rot>180) rot-=360; while(rot<-180) rot+=360;
              double sd=0; if(g_angs.size()>1){ double c=0,sn=0; for(double a: g_angs){ c+=cos(a); sn+=sin(a);} double R=hypot(c,sn)/g_angs.size(); sd = R>0? sqrt(-2*log(std::max(R,1e-12)))*180.0/M_PI : 180.0; }
              fseek(fo,-1,SEEK_CUR); fprintf(fo,",%.0f,%.1f,%.1f,%.1f\n", mag, ang, rot, sd);
              g_ang_prev_frame=ang; g_have_prev=true; g_mag=g_cos=g_sin=0; g_n=0; g_angs.clear(); }
#endif
#ifdef HAVE_SS_TAP
            { fseek(fo,-1,SEEK_CUR); fprintf(fo,",%.0f,%ld,%ld,%.1f,%d,%d\n", si_n? si_s/si_n:0.0, si_min, si_max, si_n? sv_s/si_n:0.0, sv_min, sv_max);
              si_s=0; si_n=0; ss_init=false; sv_s=0; }
#endif
            lastP=P; lastB=B; lastR=R; a_rh=a_cfc=a_cs=0; n_rh=0; corr_max=0; thr.clear(); ps_max=0;
            strobes=0; mu_s=mu_ss=0; mu_n=0; rhph[0]=rhph[1]=rhph[2]=rhph[3]=0; pe=pf=0; occ_min=99; occ_max=-1; est_changes=0; est_min=est_max=est_prev;
        }
        curfr=f;
        if(sidx>=nsamp && c>100+(unsigned long)nsamp*cadence+150000) break;
    }
    fclose(fo); if(fe) fclose(fe);
    snprintf(fn,sizeof fn,"%s_pert_summary.txt",pfx); FILE* fs=fopen(fn,"w");
    if(fs){ fprintf(fs,"frames=%ld packets=%lu rstcs=%lu biterr=%lu\n",NFR,(unsigned long)t->packets_out,(unsigned long)t->rstcs_count,(unsigned long)t->bit_errors_out); fclose(fs); }
    printf("PERT_DONE %s frames=%ld packets=%lu rstcs=%lu\n",pfx,NFR,(unsigned long)t->packets_out,(unsigned long)t->rstcs_count);
    delete t; return 0;
}
