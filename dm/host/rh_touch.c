#include "rh_touch.h"
#include <stdatomic.h>
#include <string.h>

enum { K_A=1, K_B=2, K_LEFT=4, K_UP=8, K_RIGHT=16, K_DOWN=32, K_MANY=64, K_SPELL=128 };
enum { L_DPAD=0, L_ONE=1, L_TWO=2, L_MENU=3 };
enum { SHOW_DPAD=1, SHOW_X=2, SHOW_Y=4 };
typedef struct { const char *name; unsigned keys; } scene_keys;
static const scene_keys scenes[] = {
    {"birds",K_A},{"block",K_A},{"cooking",K_A},{"flydisc",K_A},{"fugu",K_A},{"grasp",K_A},{"guardian",K_A},
    {"hammer",K_A},{"hungry",K_A},{"insect",K_A},{"kaeru",K_A},{"kukan",K_A},{"moon",K_A},{"pumpup",K_A},
    {"putilabo",K_A},{"rabbit",K_A},{"ring",K_A},{"rock",K_A},{"rocket",K_A},{"rope",K_A},{"samurai",K_A},
    {"shinkai",K_A},{"shooting",K_A},{"snack",K_A},{"spinning",K_A},{"teatime",K_A},{"tennis",K_A},
    {"the_a",K_A},{"thunder",K_A},{"virus",K_A},{"volley",K_A},
    {"bacteria",K_A|K_DOWN},{"blanco",K_A|K_DOWN},{"cars",K_A|K_DOWN},{"hurdle",K_A|K_DOWN},
    {"owl",K_A|K_DOWN},{"parasol",K_A|K_DOWN},{"skater",K_A|K_DOWN},{"softcatch",K_A|K_DOWN},
    {"brush",K_A|K_LEFT},{"clap",K_A|K_LEFT},{"commander",K_A|K_LEFT},{"crab",K_A|K_LEFT},
    {"onion",K_A|K_LEFT},{"soccer",K_A|K_LEFT},{"talk",K_A|K_LEFT},{"tono2",K_A|K_LEFT},
    {"trolley",K_A|K_LEFT},{"wiper",K_A|K_LEFT},{"rolling",K_A|K_RIGHT},
    {"dancer",K_A|K_LEFT|K_RIGHT},{"master",K_A|K_LEFT|K_RIGHT},
    {"foot_race",K_A|K_B},{"quiz",K_A|K_B},
    {"audio_tile",K_MANY},{"drummer",K_MANY},{"konkon",K_MANY},{"nervous",K_MANY},
    {"doc_comic",K_MANY},{"doc_text",K_MANY},{"remix",0},
};
static int active; static unsigned keys; static _Atomic uint64_t packed = L_MENU;

static unsigned keys_of(const char *s, size_t n) {
    for (size_t i=0;i<sizeof scenes/sizeof *scenes;i++) if (strlen(scenes[i].name)==n && !memcmp(scenes[i].name,s,n)) return scenes[i].keys;
    return 0;
}
static uint64_t hint(void) {
    if (!active) return L_MENU;
    if (keys & K_SPELL) return L_ONE | (1ull<<8) | (uint64_t)(SHOW_DPAD|SHOW_X|SHOW_Y)<<24;
    if (keys & K_MANY) return L_DPAD | (uint64_t)15<<8;
    unsigned d = keys & (K_LEFT|K_UP|K_RIGHT|K_DOWN);
    uint64_t r = L_DPAD | (uint64_t)((d&K_LEFT?1:0)|(d&K_UP?2:0)|(d&K_RIGHT?4:0)|(d&K_DOWN?8:0))<<8;
    if (d && (d&(d-1))) return r;
    int b[5], n=0;
    if (keys&K_LEFT) b[n++]=12; else if (keys&K_B) b[n++]=1; else if (keys&K_DOWN) b[n++]=15;
    else if (keys&K_UP) b[n++]=13; else if (keys&K_RIGHT) b[n++]=14;
    if (!n) return (keys&K_A) ? (L_ONE|(0ull<<8)) : r;
    if (n==1) return L_ONE | (uint64_t)b[0]<<8;
    return L_TWO | (uint64_t)b[0]<<8 | (uint64_t)b[1]<<16;
}
uint64_t dm_rhythm_touch_get(void) { return atomic_load(&packed); }
int dm_rhythm_touch_menu(void) { return atomic_load(&packed) == L_MENU; }
int dm_rhythm_touch_spell(void) { uint64_t p = atomic_load(&packed); return (p & 0xff) == L_ONE && (p >> 24) == (SHOW_DPAD | SHOW_X | SHOW_Y); }
void dm_rhythm_touch_note_path(const char *path) {
    const char *g = path ? strstr(path, ":/graph/") : NULL; if (!g) return;
    const char *top=g+8,*slash=strchr(top,'/'); if(!slash) return;
    size_t tl=(size_t)(slash-top); const char *name=slash+1,*end=strchr(name,'/'); size_t nl=end?(size_t)(end-name):0;
#define TOP(x) (tl==sizeof x-1 && !memcmp(top,x,tl))
#define NAME(x) (nl==sizeof x-1 && !memcmp(name,x,nl))
    unsigned old=active?keys:0; uint64_t before=packed;
    if (TOP("menu")||TOP("result")||TOP("epilogue")||TOP("boot")) { active=0; keys=0; }
    else if (TOP("beatspell")) { active=1; keys=K_SPELL; }
    else if (TOP("prologue") && nl && !NAME("common")) { active=1; keys=keys_of(name,nl); }
    else if (TOP("scene") && nl && !NAME("common") && !NAME("multi_common")) { if(!active){active=1;keys=0;} keys|=keys_of(name,nl); }
    else return;
    (void)old; uint64_t now=hint(); if(now!=before) atomic_store(&packed,now);
#undef TOP
#undef NAME
}
