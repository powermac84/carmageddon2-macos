/* GOG 2.1.0.28 traffic presentation repair. Controlled car drones calculate
 * a complete actor matrix every game frame; PHIL restores their passive actor
 * to the last 40 ms physics snapshot. Capture the AI result before physics,
 * use it only for rendering, then restore the entire original 48-byte matrix.
 * Never touches racer cars, clocks, velocities, path state or collision data. */
#include <emscripten/heap.h>
#include <math.h>
#define TC_MAX_DRONES 200
static int tc_requested,tc_available,tc_trace,tc_count,tc_backup_count;
static int tc_safety_reason; /* 0 healthy, 1 actor identity, 2 restore verification */
static uint32_t tc_tick;
static uint32_t tc_stats[7]; /* renders, eligible, displayed, captures, restores, errors, skips */
typedef struct {uint32_t drone,actor,form,info,index;uint16_t type;float ai[12],original[12];int applied;} TCSnapshot;
static TCSnapshot tc_snapshots[TC_MAX_DRONES];
static int tc_good(uint32_t p,size_t n){size_t end=emscripten_get_heap_size();return p>=65536&&p<=end&&n<=end-p;}
static uint32_t tc_u(uint32_t p){return tc_good(p,4)?*(uint32_t*)G2H(p):0;}
static unsigned tc_u16(uint32_t p){return tc_good(p,2)?*(uint16_t*)G2H(p):65535;}
static unsigned tc_u8(uint32_t p){return tc_good(p,1)?*(uint8_t*)G2H(p):0;}
static int tc_identity(const TCSnapshot* s){return tc_good(s->drone,0x5d8)&&tc_good(s->form,0x88)&&tc_good(s->info,12)&&tc_good(s->actor,0x64)&&tc_u(s->drone+0xec)==s->actor&&tc_u(s->drone+4)==s->form&&tc_u(s->drone+0x338)==s->info&&tc_u(s->drone+0xf8)==s->actor&&tc_good(s->actor+0x2c,48)&&tc_u16(s->actor+0x28)==s->type;}
static int tc_eligible(const TCSnapshot* s){
 if(!tc_identity(s)||tc_u(s->form+0x10)!=0||tc_u(s->drone+0x38)!=2||!tc_u8(s->drone+0x44)||!tc_u8(s->drone+0x45)||tc_u8(s->actor+0x20)!=4||tc_u(s->info+8)!=1||tc_u(s->drone+0x334)!=s->drone)return 0;
 float speed=*(float*)G2H(s->drone+0x48);return isfinite(speed)&&speed>0.0001f;
}
EMSCRIPTEN_KEEPALIVE void traffic_smoothing_set(int enabled){tc_safety_reason=0;tc_requested=tc_available&&!!enabled;}
EMSCRIPTEN_KEEPALIVE int traffic_smoothing_enabled(void){return tc_requested;}
EMSCRIPTEN_KEEPALIVE int traffic_smoothing_available(void){return tc_available;}
EMSCRIPTEN_KEEPALIVE int traffic_smoothing_pending(void){return tc_backup_count>0;}
EMSCRIPTEN_KEEPALIVE int traffic_smoothing_safety(void){return tc_safety_reason;}
EMSCRIPTEN_KEEPALIVE uint32_t* traffic_smoothing_stats_ptr(void){return tc_stats;}
EM_JS(void,tc_log,(int index,int ai,int original,int rendered),{
 var q=Module.__trafficRender||(Module.__trafficRender={rows:[],restoreErrors:0});
 if(q.rows.length<2400){var read=p=>Array.from(HEAPF32.subarray(p>>>2,(p>>>2)+12));q.rows.push({frame:Module.__glide?.frames||0,i:index,ai:read(ai),canonical:read(original),rendered:read(rendered)});}
});
EM_JS(void,tc_log_restore,(int errors),{if(Module.__trafficRender)Module.__trafficRender.restoreErrors+=errors;});
static uint32_t tc_capture(X86Cpu* cpu,uint32_t* args){
 (void)args;nv_physics_capture();tc_count=0;tc_stats[3]=0;tc_tick=tc_u(0x68c820);
 if(!tc_requested||tc_u(0x676914))return cpu->reg[X86_EAX];
 float dt=*(float*)G2H(0x79efc0);if(!(dt>0&&dt<=.1f))return cpu->reg[X86_EAX];
 uint32_t base=tc_u(0x684504),count=tc_u(0x6820d0);if(count>TC_MAX_DRONES||!tc_good(base,count*0x5d8))return cpu->reg[X86_EAX];
 for(uint32_t i=0;i<count;i++){
  uint32_t d=base+i*0x5d8;TCSnapshot s={0};s.drone=d;s.actor=tc_u(d+0xec);s.form=tc_u(d+4);s.info=tc_u(d+0x338);s.type=tc_u16(s.actor+0x28);s.index=i;
  if(s.type>1||!tc_eligible(&s))continue;
  memcpy(s.ai,G2H(s.actor+0x2c),48);int finite=1;for(int k=0;k<12;k++)if(!isfinite(s.ai[k]))finite=0;if(!finite)continue;
  tc_snapshots[tc_count++]=s;
 }
 tc_stats[3]=tc_count;return cpu->reg[X86_EAX];
}
static void traffic_before_render(void){
 tc_stats[0]++;tc_stats[1]=tc_stats[2]=0;tc_backup_count=0;
 if(!tc_requested||tc_u(0x676914)||tc_tick!=tc_u(0x68c820))return;
 for(int i=0;i<tc_count;i++){
  TCSnapshot* s=&tc_snapshots[i];s->applied=0;if(!tc_eligible(s)){tc_stats[6]++;continue;}tc_stats[1]++;
  float* current=G2H(s->actor+0x2c);float dist=0;for(int k=9;k<12;k++)dist+=(current[k]-s->ai[k])*(current[k]-s->ai[k]);
  if(!isfinite(dist)||dist>1.f){tc_stats[6]++;continue;}
  memcpy(s->original,current,48);memcpy(current,s->ai,48);s->applied=1;tc_backup_count++;tc_stats[2]++;
  if(tc_trace)tc_log(s->index,H2G(s->ai),H2G(s->original),H2G(current));
 }
}
static void traffic_after_render(void){
 int errors=0;
 for(int i=0;i<tc_count;i++){
  TCSnapshot* s=&tc_snapshots[i];if(!s->applied)continue;s->applied=0;
  if(!tc_identity(s)){errors++;tc_requested=0;tc_safety_reason=1;continue;}
  memcpy(G2H(s->actor+0x2c),s->original,48);if(memcmp(G2H(s->actor+0x2c),s->original,48)){errors++;tc_requested=0;tc_safety_reason=2;}tc_stats[4]++;
 }
 tc_stats[5]+=errors;tc_backup_count=0;if(tc_trace)tc_log_restore(errors);
}
EM_JS(void,tc_install_apis,(void),{
 Module.getTrafficSmoothing=function(){var p=Module._traffic_smoothing_stats_ptr()>>>2,s=HEAPU32,requested=!!Module._traffic_smoothing_enabled(),available=!!Module._traffic_smoothing_available(),safety=Module._traffic_smoothing_safety();return {enabled:requested,requested:requested,active:requested&&available&&!safety,available:available,safetyDisabled:!!safety,safetyReason:safety===1?"actor_identity_changed":safety===2?"restore_verification_failed":null,pendingRestore:!!Module._traffic_smoothing_pending(),stats:{frames:s[p],eligibleDrones:s[p+1],smoothedDrones:s[p+2],capturedDrones:s[p+3],restores:s[p+4],restoreErrors:s[p+5],skipped:s[p+6]}};};
 Module.setTrafficSmoothing=function(value){Module._traffic_smoothing_set(value?1:0);return Module.getTrafficSmoothing();};
});
static void tc_branch(uint8_t* code,uint8_t op,uint32_t target){uint32_t displacement=target-(H2G(code)+5);code[0]=op;memcpy(code+1,&displacement,4);}
static void traffic_install(int render_available){
 tc_install_apis();tc_trace=EM_ASM_INT({return new URLSearchParams(location.search).has('trafficlog')?1:0;});
 const uint8_t call[]={0xe8,0x7b,0x34,0xf8,0xff},entry[]={0x83,0xec,0x0c,0xa1,0xa0,0x93,0x67,0x00};
 if(!render_available||memcmp(G2H(0x492ec0),call,5)||memcmp(G2H(0x416340),entry,8)){emu_log("Traffic smoothing: unsupported executable; unchanged");return;}
 uint32_t capture=emu_trap("LocalRender","TrafficCaptureBeforePhysics",tc_capture,0);uint32_t after=emu_trap("LocalRender","PedestrianAfterPhysics",nv_after_physics,0);uint8_t* stub=gcalloc(16);
 tc_branch(stub,0xe8,capture);tc_branch(stub+5,0xe8,0x416340);tc_branch(stub+10,0xe8,after);stub[15]=0xc3;tc_branch(G2H(0x492ec0),0xe8,H2G(stub));tc_available=1;
 tc_requested=EM_ASM_INT({return new URLSearchParams(location.search).has('trafficvisual')?1:0;});
 emu_log("Traffic smoothing installed, enabled=%d",tc_requested);
}
