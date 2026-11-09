#pragma once
#include <mach/mach_types.h>
#include <stdint.h>
#define DM_PROF_DEPTH 16
typedef struct { uint32_t handle; int state, guest, n; uint64_t pc[DM_PROF_DEPTH]; char name[40]; } dm_thr_sample_t;
enum { DM_SAMPLE_RUN, DM_SAMPLE_WAIT, DM_SAMPLE_IDLE };
int thr_sample(dm_thr_sample_t *out, int max, int depth, mach_port_t *ports);
int thr_grab_port(mach_port_t port, int depth, uint64_t *pc, int *guest);
void dm_prof_init(void) __attribute__((weak));
void dm_diag_late_init(void);
