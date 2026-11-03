/*
 * Credits: this file is based on code from the MeloNX iOS sideloading project
 * (https://starforgejo.dev/projects/MeloNX), modified and adapted by the
 * ZSingularity project (RamBypass), and ported from there to this host.
 */

#ifndef DonatedHeap_h
#define DonatedHeap_h

#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stddef.h>

typedef struct {
    BOOL active;
    uint64_t poolBytes;
    uint64_t usedBytes;
    uint64_t servedAllocations;
    uint64_t fallbackAllocations;
} RamBypassStats;

typedef struct {
    uint64_t appBytes;
    uint64_t donatedBytes;
    uint64_t donatedUsedBytes;
    uint64_t totalBytes;
} RamHudSnapshot;

BOOL rd_ram_bypass_enabled(void);
BOOL rd_ram_bypass_available(void);
void rd_ram_hud_get_snapshot(RamHudSnapshot *outSnapshot);
void rd_ram_bypass_get_stats(RamBypassStats *outStats);
void rd_ram_bypass_trim(void);
void rd_ram_bypass_memlog(void);

void rd_ram_register_guest_hook(void);
size_t rd_ram_extend_guest(uint8_t *heap, size_t heapSize, uint8_t *alias, size_t aliasSize);

#endif
