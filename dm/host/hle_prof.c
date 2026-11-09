#include "dm.h"
#include "prof.h"
#include <dlfcn.h>
#include <stdatomic.h>
#include <time.h>
#include <unistd.h>
#include <mach/mach.h>
#include <TargetConditionals.h>

extern _Atomic uint64_t dm_present_ns;

#define PE_MAX 32768
#define GRP_MAX 128
#define TH_MAX 256

typedef struct { uint64_t h; uint32_t all, late; uint8_t n; uint64_t pc[DM_PROF_DEPTH]; char grp[32]; } pe_t;
typedef struct { char name[32]; uint64_t run, wait, idle, run_late; } grp_t;

static pe_t g_pe[PE_MAX];
static grp_t g_grp[GRP_MAX];
static int g_ngrp;
static uint64_t g_overflow, g_sweeps, g_late_sweeps;
static char g_path[1100];
static int g_hz = 100, g_late_ms = 20, g_depth = 12, g_flush_s = 10;
static uint64_t g_start_ns;
static pthread_mutex_t g_dump_lock = PTHREAD_MUTEX_INITIALIZER;

static void group_name(const char *in, int host, char *out, size_t n) {
    char tmp[40]; snprintf(tmp, sizeof tmp, "%s", in && *in && strcmp(in, "?") ? in : "unnamed");
    size_t l = strlen(tmp);
    while (l > 1 && (tmp[l - 1] == ' ' || tmp[l - 1] == '_' || tmp[l - 1] == '#' || tmp[l - 1] == '-' || (tmp[l - 1] >= '0' && tmp[l - 1] <= '9'))) tmp[--l] = 0;
    for (size_t i = 0; i < l; i++) if (tmp[i] == '\t' || tmp[i] == '\n') tmp[i] = ' ';
    snprintf(out, n, "%s%s", host ? "host:" : "", tmp);
}

static grp_t *group_get(const char *name) {
    for (int i = 0; i < g_ngrp; i++) if (!strcmp(g_grp[i].name, name)) return &g_grp[i];
    if (g_ngrp == GRP_MAX) return &g_grp[GRP_MAX - 1];
    grp_t *g = &g_grp[g_ngrp++];
    snprintf(g->name, sizeof g->name, "%s", name);
    return g;
}

static uint64_t fnv(uint64_t h, const void *p, size_t n) {
    const uint8_t *b = p;
    for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ull; }
    return h;
}

static void add_stack(const char *grp, const uint64_t *pc, int n, int late) {
    uint64_t h = fnv(1469598103934665603ull, grp, strlen(grp));
    h = fnv(h, pc, (size_t)n * sizeof *pc);
    if (!h) h = 1;
    uint32_t i = (uint32_t)(h % PE_MAX);
    for (int probe = 0; probe < 64; probe++, i = (i + 1) % PE_MAX) {
        pe_t *e = &g_pe[i];
        if (!e->h) {
            e->h = h; e->n = (uint8_t)n; memcpy(e->pc, pc, (size_t)n * sizeof *pc);
            snprintf(e->grp, sizeof e->grp, "%s", grp);
        }
        if (e->h == h && e->n == n && !memcmp(e->pc, pc, (size_t)n * sizeof *pc)) { e->all++; if (late) e->late++; return; }
    }
    g_overflow++;
}

static void format_addr(uint64_t a, char *out, size_t n) {
    module_t *m = module_of((void *)a);
    if (m) { snprintf(out, n, "%s+%#llx", m->name, (unsigned long long)(a - (uint64_t)m->base)); return; }
    Dl_info di;
    if (dladdr((void *)a, &di)) {
        if (di.dli_sname) { snprintf(out, n, "host:%s+%#lx", di.dli_sname, (unsigned long)(a - (uint64_t)di.dli_saddr)); return; }
        if (di.dli_fname) {
            const char *b = strrchr(di.dli_fname, '/');
            snprintf(out, n, "host:%s@%#lx", b ? b + 1 : di.dli_fname, (unsigned long)(a - (uint64_t)di.dli_fbase));
            return;
        }
    }
    snprintf(out, n, "?%#llx", (unsigned long long)a);
}

static void dump(void) {
    pthread_mutex_lock(&g_dump_lock);
    char tmp[1200]; snprintf(tmp, sizeof tmp, "%s.tmp", g_path);
    FILE *f = fopen(tmp, "w");
    if (!f) { pthread_mutex_unlock(&g_dump_lock); return; }
    fprintf(f, "# dm-prof-cpu 1 hz=%d late_ms=%d depth=%d elapsed_s=%.1f sweeps=%llu late_sweeps=%llu overflow=%llu\n",
            g_hz, g_late_ms, g_depth, (now_ns() - g_start_ns) / 1e9, (unsigned long long)g_sweeps, (unsigned long long)g_late_sweeps, (unsigned long long)g_overflow);
    for (int i = 0; i < g_ngrp; i++)
        fprintf(f, "T\t%s\t%llu\t%llu\t%llu\t%llu\n", g_grp[i].name, (unsigned long long)g_grp[i].run, (unsigned long long)g_grp[i].wait,
                (unsigned long long)g_grp[i].idle, (unsigned long long)g_grp[i].run_late);
    for (int i = 0; i < PE_MAX; i++) {
        pe_t *e = &g_pe[i];
        if (!e->h) continue;
        fprintf(f, "S\t%u\t%u\t%s", e->all, e->late, e->grp);
        for (int k = 0; k < e->n; k++) { char a[160]; format_addr(e->pc[k], a, sizeof a); fprintf(f, "\t%s", a); }
        fputc('\n', f);
    }
    fclose(f);
    rename(tmp, g_path);
    pthread_mutex_unlock(&g_dump_lock);
}

static void sweep(int late) {
    static dm_thr_sample_t gs[TH_MAX];
    static mach_port_t gports[TH_MAX];
    int n = thr_sample(gs, TH_MAX, g_depth, gports);
    g_sweeps++; if (late) g_late_sweeps++;
    for (int i = 0; i < n; i++) {
        char grp[32]; group_name(gs[i].name, 0, grp, sizeof grp);
        grp_t *g = group_get(grp);
        if (gs[i].state == DM_SAMPLE_RUN) { g->run++; if (late) g->run_late++; add_stack(grp, gs[i].pc, gs[i].n, late); }
        else if (gs[i].state == DM_SAMPLE_WAIT) g->wait++;
        else g->idle++;
    }
    mach_port_t self = pthread_mach_thread_np(pthread_self());
    thread_act_array_t th; mach_msg_type_number_t nt = 0;
    if (task_threads(mach_task_self(), &th, &nt) != KERN_SUCCESS) return;
    for (mach_msg_type_number_t i = 0; i < nt; i++) {
        int skip = th[i] == self;
        for (int k = 0; k < n && !skip; k++) skip = gports[k] == th[i];
        if (!skip) {
            thread_extended_info_data_t ei; mach_msg_type_number_t c = THREAD_EXTENDED_INFO_COUNT;
            char grp[32] = "host:unnamed";
            int running = 0;
            if (thread_info(th[i], THREAD_EXTENDED_INFO, (thread_info_t)&ei, &c) == KERN_SUCCESS) {
                group_name(ei.pth_name, 1, grp, sizeof grp);
                running = ei.pth_run_state == TH_STATE_RUNNING;
            }
            grp_t *g = group_get(grp);
            if (running) {
                uint64_t pc[DM_PROF_DEPTH]; int guest = 0;
                int m = thr_grab_port(th[i], g_depth, pc, &guest);
                if (m) { g->run++; if (late) g->run_late++; add_stack(grp, pc, m, late); }
                else g->idle++;
            } else g->wait++;
        }
        mach_port_deallocate(mach_task_self(), th[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)th, nt * sizeof *th);
}

static void *prof_main(void *arg) {
    (void)arg;
    pthread_setname_np("dm prof cpu");
    while (!atomic_load(&dm_present_ns)) { struct timespec ts = {0, 20000000}; nanosleep(&ts, 0); }
    g_start_ns = now_ns();
    uint64_t rng = 88172645463325252ull, last_dump = g_start_ns, period = 1000000000ull / (uint64_t)g_hz;
    for (;;) {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
        uint64_t jitter = period / 5, wait = period - jitter + rng % (2 * jitter + 1);
        struct timespec ts = {(time_t)(wait / 1000000000ull), (long)(wait % 1000000000ull)};
        nanosleep(&ts, 0);
        uint64_t now = now_ns(), p = atomic_load(&dm_present_ns);
        sweep(p && now > p && now - p > (uint64_t)g_late_ms * 1000000ull);
        if (now - last_dump >= (uint64_t)g_flush_s * 1000000000ull) { dump(); last_dump = now; }
    }
    return NULL;
}

void dm_prof_init(void) {
    static _Atomic int once;
    if (atomic_exchange(&once, 1)) return;
    dm_diag_late_init();
    const char *e = getenv("DM_PROF_CPU");
    if (!e || !*e) return;
    char spec[1100]; snprintf(spec, sizeof spec, "%s", e);
    char *c = strchr(spec, ',');
    if (c) {
        *c++ = 0;
        char *save = c;
        int field = 0;
        for (char *tok = strsep(&save, ","); tok; tok = strsep(&save, ","), field++) {
            int v = atoi(tok);
            if (!v) continue;
            if (field == 0) g_hz = v < 10 ? 10 : v > 500 ? 500 : v;
            else if (field == 1) g_late_ms = v;
            else if (field == 2) g_depth = v < 2 ? 2 : v > DM_PROF_DEPTH ? DM_PROF_DEPTH : v;
            else if (field == 3) g_flush_s = v < 1 ? 1 : v;
        }
    }
    snprintf(g_path, sizeof g_path, "%s", spec);
#if TARGET_OS_IPHONE
    if (spec[0] != '/' && getenv("HOME")) snprintf(g_path, sizeof g_path, "%s/Documents/%s", getenv("HOME"), spec);
#endif
    atexit(dump);
    pthread_t th; pthread_create(&th, NULL, prof_main, NULL); pthread_detach(th);
    LOG("DM_PROF_CPU: sampling %d Hz, frames late after %d ms, stack depth %d, written to %s every %d s", g_hz, g_late_ms, g_depth, g_path, g_flush_s);
}
