/* Carmageddon II GOG 2.1.0.28: animation-owned passive pedestrian roots.
 * Retail PHIL resets the actor matrix on interpolation-only frames, discarding
 * animation distance while independent limb matrices retain their AI pose.
 * Preserve the exact AI root after physics ONLY while identity, passive mode,
 * HP/action, velocity, omega, collision flag and every attached bone remain
 * unchanged. Retail matrix scheme is VERIFIED 0 (not the native-port helper's2).
 * This intentionally corrects the CANONICAL actor position; no clock, velocity,
 * collision-structure or cached-physics-transform fields are written.
 * Walking/running/panicking only; physical, dead, morphing and detached states
 * stay original. Each render then uses the existing40ms visual translation
 * filter against this CONSISTENT root, with all visual matrices restored.
 * Two byte-verified guest stubs preserve original register ABI and yield points.
 */
#include <emscripten/heap.h>
#include <math.h>
#define NV_MAX_PEDS 2048
#define NV_MAX_BONES 32
static int nv_enabled, nv_requested, nv_available, nv_trace, nv_safety_disabled, nv_safety_reason;
static uint32_t nv_stats[7]; /* frames, eligible, shifted, restores, resets, restoreErrors, bones */
typedef struct { uint32_t character; float visual[3]; double time; int valid; } NVState;
typedef struct { uint32_t position, actor, character, slot, bone; float original[3]; } NVBackup;
static NVState nv_states[NV_MAX_PEDS];
static NVBackup nv_backups[NV_MAX_PEDS * NV_MAX_BONES];
static int nv_backup_count;
static int nv_good(uint32_t p, size_t size) { return p >= 65536 && p <= emscripten_get_heap_size() && size <= emscripten_get_heap_size()-p; }
static uint32_t nv_u(uint32_t p) { return nv_good(p,4) ? *(uint32_t*)G2H(p) : 0; }
static unsigned nv_u16(uint32_t p) { return nv_good(p,2) ? *(uint16_t*)G2H(p) : 0xffff; }
static int nv_s8(uint32_t p) { return nv_good(p,1) ? *(int8_t*)G2H(p) : -1; }
static int nv_ownership, nv_physics_ready;
static void nv_set_physics_ready(int ready){nv_physics_ready=!!ready;if(!nv_physics_ready)nv_requested=0;}
typedef struct{uint32_t p,c,actor,phys,form,actors;int slot,phys_slot,move,action,hp,bones;unsigned actor_type;unsigned collision;float root[12],velocity[3],omega[3],bone_mats[NV_MAX_BONES][12];uint32_t bone_actors[NV_MAX_BONES];} NVPhysicalRoot;
static NVPhysicalRoot nv_roots[NV_MAX_PEDS];static int nv_root_count;static unsigned char nv_ownership_applied[NV_MAX_PEDS];
static uint32_t nv_ownership_restores,nv_ownership_skips;
static void nv_physics_capture(void){
 nv_root_count=0;memset(nv_ownership_applied,0,sizeof(nv_ownership_applied));if(!nv_requested||!nv_ownership||nv_u(0x676914))return;
 uint32_t base=nv_u(0x744808),count=nv_u(0x7447d4);if(count>NV_MAX_PEDS||!nv_good(base,count*0x54))return;
 for(uint32_t i=0;i<count;i++){uint32_t p=base+i*0x54,c=nv_u(p),flags=nv_u(c+0x14),action=nv_u(p+0x10);
 if(!nv_good(c,240)||nv_s8(p+4)<=0||action>2||flags!=1||nv_u(c+0xc)||nv_u(c+0xbc)||nv_u(c+0xe8)||nv_s8(c+4)<0||nv_s8(c+5)<0||nv_s8(c+7)<0)continue;
 uint32_t form=nv_u(nv_u(c)+0x28),actors=nv_u(nv_u(form+0x30)+nv_s8(c+4)*8+4),a=nv_u(actors),phys=nv_u(nv_u(form+0x38)+nv_s8(c+5)*8+4);
 if(!nv_good(phys,0x4d8)||nv_u(phys+0xf0)!=0||nv_s8(phys+0x238)!=2||nv_u(phys+0x23c)!=c||nv_u(phys)!=a||nv_u(nv_u(phys+0x240)+8)!=1||nv_u16(a+0x28)>1||!nv_good(a+0x2c,48))continue;
 NVPhysicalRoot* x=&nv_roots[nv_root_count];x->p=p;x->c=c;x->actor=a;x->actor_type=nv_u16(a+0x28);x->phys=phys;x->form=form;x->actors=actors;x->slot=nv_s8(c+4);x->phys_slot=nv_s8(c+5);x->move=nv_s8(c+7);x->action=action;x->hp=nv_s8(p+4);x->collision=nv_s8(phys+0x1dd);memcpy(x->root,G2H(a+0x2c),48);memcpy(x->velocity,G2H(phys+0x68),12);memcpy(x->omega,G2H(phys+0x74),12);
 x->bones=nv_good(form+0x29,1)?*(uint8_t*)G2H(form+0x29):0;int valid=x->bones>0&&x->bones<=NV_MAX_BONES&&nv_good(actors,x->bones*4);
 for(int k=0;k<12;k++)if(!isfinite(x->root[k]))valid=0;
 for(int b=0;b<x->bones&&b<NV_MAX_BONES;b++){uint32_t ba=nv_u(actors+b*4);x->bone_actors[b]=ba;if(!nv_good(ba,0x64)||nv_u16(ba+0x28)>1){valid=0;break;}memcpy(x->bone_mats[b],G2H(ba+0x2c),48);for(int k=0;k<12;k++)if(!isfinite(x->bone_mats[b][k]))valid=0;}
 if(valid)nv_root_count++;
 }
}
static uint32_t nv_after_physics(X86Cpu* cpu,uint32_t* args){
 (void)args;
 if(nv_requested&&nv_ownership&&!nv_u(0x676914))for(int i=0;i<nv_root_count;i++){NVPhysicalRoot* x=&nv_roots[i];uint32_t c=x->c,form=nv_u(nv_u(c)+0x28),actors=nv_u(nv_u(form+0x30)+x->slot*8+4);
 if(nv_u(x->p)!=c||form!=x->form||actors!=x->actors||nv_s8(c+5)!=x->phys_slot||nv_u(c+0xe8)!=0||nv_u(nv_u(form+0x38)+x->phys_slot*8+4)!=x->phys||nv_s8(c+4)!=x->slot||nv_s8(c+7)!=x->move||nv_u(x->p+0x10)!=(uint32_t)x->action||nv_s8(x->p+4)!=x->hp||nv_u(c+0x14)!=1||nv_u(c+0xc)||nv_u(c+0xbc)||nv_u(actors)!=x->actor||!nv_good(x->phys,0x4d8)||nv_u(x->phys+0xf0)!=0||nv_s8(x->phys+0x238)!=2||nv_u(x->phys+0x23c)!=c||nv_u(x->phys)!=x->actor||!nv_good(x->actor,0x64)||nv_u16(x->actor+0x28)!=x->actor_type||nv_u(nv_u(x->phys+0x240)+8)!=1){nv_ownership_skips++;continue;}
 if(memcmp(G2H(x->phys+0x68),x->velocity,12)){nv_ownership_skips++;continue;}
 if(memcmp(G2H(x->phys+0x74),x->omega,12)){nv_ownership_skips++;continue;}
 if(nv_s8(x->phys+0x1dd)!=(int)x->collision){nv_ownership_skips++;continue;}
 int consistent=1;for(int b=1;b<x->bones;b++)if(nv_u(actors+b*4)!=x->bone_actors[b]||memcmp(G2H(x->bone_actors[b]+0x2c),x->bone_mats[b],48)){consistent=0;break;}if(!consistent){nv_ownership_skips++;continue;}
 float* p=G2H(x->actor+0x2c);float dist=0;for(int k=9;k<12;k++)dist+=(p[k]-x->root[k])*(p[k]-x->root[k]);if(!isfinite(dist)||dist>1){nv_ownership_skips++;continue;}
 memcpy(p,x->root,48);uint32_t ped_index=(x->p-nv_u(0x744808))/0x54;if(ped_index<NV_MAX_PEDS)nv_ownership_applied[ped_index]=1;nv_ownership_restores++;
 }return cpu->reg[X86_EAX];
}
EMSCRIPTEN_KEEPALIVE void pedestrian_smoothing_set(int enabled) { nv_requested=nv_available&&nv_physics_ready&&!!enabled;if(nv_requested){nv_safety_disabled=0;nv_safety_reason=0;} }
EMSCRIPTEN_KEEPALIVE int pedestrian_smoothing_enabled(void) { return nv_requested; }
EMSCRIPTEN_KEEPALIVE int pedestrian_smoothing_available(void) { return nv_available&&nv_physics_ready; }
EMSCRIPTEN_KEEPALIVE int pedestrian_smoothing_pending(void) { return nv_backup_count>0; }
EMSCRIPTEN_KEEPALIVE uint32_t* pedestrian_smoothing_stats_ptr(void) { return nv_stats; }
EMSCRIPTEN_KEEPALIVE int pedestrian_smoothing_active(void){return nv_requested&&nv_enabled&&nv_physics_ready&&!nv_safety_disabled;}
EMSCRIPTEN_KEEPALIVE int pedestrian_smoothing_safety_disabled(void){return nv_safety_disabled;}
EMSCRIPTEN_KEEPALIVE int pedestrian_smoothing_safety_reason(void){return nv_safety_reason;}
EMSCRIPTEN_KEEPALIVE uint32_t pedestrian_ownership_restores(void){return nv_ownership_restores;}
EMSCRIPTEN_KEEPALIVE uint32_t pedestrian_ownership_skips(void){return nv_ownership_skips;}

EM_JS(void,nv_log_start,(int count,int enabled),{
 if (!Module.__npcRender) Module.__npcRender={rows:[],restores:0,restoreErrors:0};
 var v=Module.__npcRender;v.current={frame:Module.__glide?.frames||0,time:performance.now(),enabled:!!enabled,peds:[]};
});
EM_JS(void,nv_log_ped,(int index,int character,int mode,float x,float y,float z,float vx,float vy,float vz,float dx,float dy,float dz),{
 Module.__npcRender.current.peds.push({i:index,character,mode,canonical:[x,y,z],rendered:[vx,vy,vz],offset:[dx,dy,dz]});
});
EM_JS(void,nv_log_finish,(int errors,int backups),{
 var v=Module.__npcRender;if(!v)return;v.restores++;v.restoreErrors+=errors;
 if(v.current){v.current.restored=errors===0;v.current.backups=backups;if(v.rows.length<1200)v.rows.push(v.current);v.current=null;}
});
static uint32_t nv_before(X86Cpu* cpu,uint32_t* args) {
 (void)args;traffic_before_render();nv_backup_count=0;
 if(nv_enabled!=nv_requested){nv_enabled=nv_requested;memset(nv_states,0,sizeof(nv_states));}
 nv_stats[0]++;nv_stats[1]=nv_stats[2]=nv_stats[6]=0;
 if(!nv_enabled&&!nv_trace)return cpu->reg[X86_EAX];
 if(nv_u(0x676914)){memset(nv_states,0,sizeof(nv_states));return cpu->reg[X86_EAX];}
 uint32_t base=nv_u(0x744808),count=nv_u(0x7447d4);
 if(nv_trace)nv_log_start(count,nv_enabled);
 if(count>NV_MAX_PEDS||!nv_good(base,count*0x54))return cpu->reg[X86_EAX];
 double now=emu_now_ms();
 for(uint32_t i=0;i<count;i++){
  uint32_t ped=base+i*0x54,c=nv_u(ped),action=nv_u(ped+0x10),flags=nv_u(c+0x14);
  if(!nv_good(c,0xec)||nv_s8(ped+4)<=0||action>2||!(flags&1)||(flags&4)||nv_u(c+0xbc)!=0||nv_s8(c+4)<0||nv_s8(c+5)<0||nv_s8(c+7)<0||nv_u(c+0xe8)!=0){nv_states[i].valid=0;continue;}
  uint32_t form=nv_u(nv_u(c)+0x28),sets=nv_u(form+0x30),actors=nv_u(sets+nv_s8(c+4)*8+4);
  uint32_t root=nv_u(actors),phys=nv_u(nv_u(form+0x38)+nv_s8(c+5)*8+4),mode=nv_u(nv_u(phys+0x240)+8);
  int bones=nv_good(form+0x29,1)?*(uint8_t*)G2H(form+0x29):0;
  if(mode!=1||root!=nv_u(phys)||nv_u16(root+0x28)>1||!nv_good(root+0x50,12)||bones<1||bones>NV_MAX_BONES||!nv_good(actors,bones*4)){nv_states[i].valid=0;continue;}
  int hierarchy_ok=1;
  for(int b=0;b<bones;b++){uint32_t a=nv_u(actors+b*4);if(!nv_good(a,0x64)||nv_u16(a+0x28)>1){hierarchy_ok=0;break;}uint32_t parent=nv_u(a+0xc);for(int k=0;k<bones;k++)if(parent==nv_u(actors+k*4)){hierarchy_ok=0;break;}}
  if(!hierarchy_ok||(nv_ownership&&!nv_ownership_applied[i])){nv_states[i].valid=0;continue;}
  float* p=G2H(root+0x50);float delta[3]={0,0,0};NVState* st=&nv_states[i];double dt=now-st->time;
  if(!isfinite(p[0])||!isfinite(p[1])||!isfinite(p[2])||(nv_u(c+0xc)&1)){st->valid=0;continue;}
  nv_stats[1]++;
  float distance2=0;for(int k=0;k<3;k++)distance2+=(p[k]-st->visual[k])*(p[k]-st->visual[k]);
  if(!st->valid||st->character!=c||dt<=0||dt>250||distance2>.25f){memcpy(st->visual,p,12);st->valid=1;st->character=c;nv_stats[4]++;}
  else {float a=1.f-expf(-(float)dt/40.f);for(int k=0;k<3;k++)st->visual[k]+=(p[k]-st->visual[k])*a;}
  st->time=now;
  if(nv_enabled)for(int k=0;k<3;k++)delta[k]=st->visual[k]-p[k];
  if(nv_trace)nv_log_ped(i,c,mode,p[0],p[1],p[2],p[0]+delta[0],p[1]+delta[1],p[2]+delta[2],delta[0],delta[1],delta[2]);
  uint32_t detached=nv_u(c+0xc);if(nv_enabled)nv_stats[2]++;
  if(nv_enabled)for(int b=0;b<bones;b++){
   if(detached&(1u<<b))continue;uint32_t actor=nv_u(actors+b*4),pos=actor+0x50;
   if(!nv_good(pos,12)||nv_backup_count>=NV_MAX_PEDS*NV_MAX_BONES)continue;
   NVBackup* back=&nv_backups[nv_backup_count++];back->position=pos;back->actor=actor;back->character=c;back->slot=nv_s8(c+4);back->bone=b;memcpy(back->original,G2H(pos),12);
   float* v=G2H(pos);for(int k=0;k<3;k++)v[k]+=delta[k];
  }
 }
 nv_stats[6]=nv_backup_count;
 
 return cpu->reg[X86_EAX];
}
static uint32_t nv_after(X86Cpu* cpu,uint32_t* args) {
 (void)args;int errors=0;
 for(int i=0;i<nv_backup_count;i++){
  NVBackup* b=&nv_backups[i];uint32_t c=b->character,form=nv_u(nv_u(c)+0x28),actors=nv_u(nv_u(form+0x30)+b->slot*8+4);
  if(nv_s8(c+4)!=(int)b->slot||nv_u(actors+b->bone*4)!=b->actor||!nv_good(b->position,12)){errors++;nv_requested=0;nv_safety_disabled=1;nv_safety_reason=1;continue;}
  memcpy(G2H(b->position),b->original,12);
  if(memcmp(G2H(b->position),b->original,12))errors++;
 }
 traffic_after_render();
 nv_stats[3]++;nv_stats[5]+=errors;nv_stats[6]=nv_backup_count;
 
 if(nv_trace)nv_log_finish(errors,nv_backup_count);nv_backup_count=0;return cpu->reg[X86_EAX];
}
static void nv_call(uint8_t* code,uint32_t target){uint32_t displacement=target-(H2G(code)+5);code[0]=0xe8;memcpy(code+1,&displacement,4);}
EM_JS(void,nv_install_apis,(void),{
 Module.getPedestrianSmoothing=function(){var p=Module._pedestrian_smoothing_stats_ptr()>>>2,s=HEAPU32;return {enabled:!!Module._pedestrian_smoothing_enabled(),requested:!!Module._pedestrian_smoothing_enabled(),active:!!Module._pedestrian_smoothing_active(),safetyDisabled:!!Module._pedestrian_smoothing_safety_disabled(),safetyReason:Module._pedestrian_smoothing_safety_reason()===1?"actor_identity_changed":null,available:!!Module._pedestrian_smoothing_available(),pendingRestore:!!Module._pedestrian_smoothing_pending(),stats:{frames:s[p],eligiblePeds:s[p+1],smoothedPeds:s[p+2],restores:s[p+3],resets:s[p+4],restoreErrors:s[p+5],bones:s[p+6],ownershipRestores:Module._pedestrian_ownership_restores(),ownershipSkips:Module._pedestrian_ownership_skips()}};};
 Module.setPedestrianSmoothing=function(value){Module._pedestrian_smoothing_set(value?1:0);return Module.getPedestrianSmoothing();};
 });
static void nv_install(void){
 nv_install_apis();
 nv_ownership=1;
 int requested=EM_ASM_INT({return new URLSearchParams(location.search).has('npcvisual')?1:0;});
 nv_trace=EM_ASM_INT({return new URLSearchParams(location.search).has('npclog')?1:0;});

 const uint8_t expected[]={0xe8,0x51,0x13,0x05,0x00};
 const uint8_t reset[]={0x57,0x8b,0xf9,0x85,0xff,0x74,0x5f};
 const uint8_t physics_call[]={0xe8,0x7b,0x34,0xf8,0xff},physics_entry[]={0x83,0xec,0x0c,0xa1,0xa0,0x93,0x67,0x00};
 if(memcmp(G2H(0x493aea),expected,sizeof(expected))||memcmp(G2H(0x4c2600),reset,sizeof(reset))||memcmp(G2H(0x492ec0),physics_call,sizeof(physics_call))||memcmp(G2H(0x416340),physics_entry,sizeof(physics_entry))){emu_log("Pedestrian smoothing: unsupported executable; unchanged");return;}
 uint32_t before=emu_trap("LocalRender","PedestrianRenderBefore",nv_before,0),after=emu_trap("LocalRender","PedestrianRenderAfter",nv_after,0);
 uint8_t* stub=gcalloc(16);nv_call(stub,before);nv_call(stub+5,0x4e4e40);nv_call(stub+10,after);stub[15]=0xc3;
 nv_call(G2H(0x493aea),H2G(stub));nv_available=1;nv_requested=requested;

 emu_log("Pedestrian smoothing installed, enabled=%d trace=%d",nv_requested,nv_trace);
}
