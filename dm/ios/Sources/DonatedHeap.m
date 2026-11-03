/*
 * Credits: this file is based on code from the MeloNX iOS sideloading project
 * (https://starforgejo.dev/projects/MeloNX), modified and adapted by the
 * ZSingularity project (RamBypass), and ported from there to this host.
 */

#import "DonatedHeap.h"
#import "RamDonor.h"

#import <dlfcn.h>
#import <limits.h>
#import <malloc/malloc.h>
#import <errno.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>
#import <time.h>
#if __has_include(<ptrauth.h>)
#import <ptrauth.h>
#endif

#define RD_MALLOC_ALLOCATION_MAGIC 0x5A534D414C4C4F43ull
#define RD_MALLOC_SLAB_MAGIC 0x5A53534C41424D47ull
#define RD_MALLOC_SMALL_CLASS_COUNT 4096
#define RD_MALLOC_MAX_CLASS_BLOCK_SIZE ((RD_MALLOC_SMALL_CLASS_COUNT - 1u) * 16u)
#define RD_MALLOC_KIND_LARGE 1u
#define RD_MALLOC_KIND_SMALL 2u

typedef struct __attribute__((aligned(16))) {
    uint64_t magic;
    uint32_t requestedSize;
    uint32_t capacity;
    uint32_t allocationSize;
    uint32_t ownerOffset;
    uint32_t kind;
    uint32_t classIndex;
} RDMallocAllocationHeader;

typedef struct __attribute__((aligned(16))) RDMallocSlab {
    uint64_t magic;
    uint32_t classIndex;
    uint32_t blockSize;
    uint32_t totalBlocks;
    uint32_t freeBlocks;
    uint32_t spanSize;
    uint32_t linked;
    uintptr_t freeList;
    struct RDMallocSlab *next;
    struct RDMallocSlab *prev;
} RDMallocSlab;

#ifndef VM_FLAGS_OVERWRITE
#define VM_FLAGS_OVERWRITE 0x4000
#endif

#ifndef MADV_ZERO
#define MADV_ZERO 11
#endif

static const uint64_t kRDDonatedTargetBytes = 3ull * 1024ull * 1024ull * 1024ull;
static const uint64_t kRDDonatedDecommitMinBytes = 1ull * 1024ull * 1024ull;
static const uint64_t kRDTrimMinIntervalNs = 10ull * NSEC_PER_SEC;

#define RD_TRIM_BATCH 32
static const uint64_t kRDDonatedMinimumBytes = 256ull * 1024ull * 1024ull;
static const uint64_t kRDRedirectDefaultMinimum = 256ull * 1024ull;
static const uint64_t kRDDonatedLogStride = 256ull * 1024ull * 1024ull;

#define RD_BIN_COUNT 128
#define RD_EXACT_BINS 63
#define RD_RUN_NONE UINT32_MAX
#define RD_FREE_ANY 1u
#define RD_FREE_HEAD 2u
#define RD_FREE_TAIL 4u
#define RD_BIN_SCAN_LIMIT 32
#define RD_STAT_SHARDS 16

typedef struct {
    uint32_t next;
    uint32_t prev;
    uint32_t len;
    uint32_t reserved;
} RDRun;

static struct {
    os_unfair_lock lock;
    uintptr_t base;
    uint64_t size;
    uint64_t pageSize;
    uint32_t pageCount;
    uint32_t cleanPage;
    uint64_t used;
    uint64_t loggedStride;
    RDRun *runs;
    uint8_t *freeMap;
    uint8_t *zeroMap;
    uint32_t bins[RD_BIN_COUNT];
    uint64_t binMap[2];
} g_pool;

typedef struct {
    os_unfair_lock lock;
    uint32_t emptySlabs;
    RDMallocSlab *slabs;
    RDMallocSlab *tail;
} __attribute__((aligned(64))) RDClassBin;

typedef struct {
    _Atomic(int64_t) blocks;
    _Atomic(int64_t) bytes;
} __attribute__((aligned(64))) RDStatShard;

static _Atomic(uint8_t) g_poolReady;
static _Atomic(uint8_t) g_mallocAllocationEnabled;
static _Atomic(uint8_t) g_mallocZoneRegistered;
static _Atomic(uint64_t) g_redirectMinimum = 256ull * 1024ull;
static RDClassBin g_classBins[RD_MALLOC_SMALL_CLASS_COUNT];
static RDStatShard g_statShards[RD_STAT_SHARDS];
static malloc_zone_t g_mallocZone;
static malloc_introspection_t g_mallocIntrospection;
static _Atomic(uint64_t) g_mallocPeakBytesInUse;
static _Atomic(uint64_t) g_mallocBytesAllocated;
static _Atomic(uint64_t) g_servedCount;
static _Atomic(uint64_t) g_fallbackCount;
static _Atomic(uint64_t) g_mmapCalls;
static _Atomic(uint64_t) g_largeCalls;
static _Atomic(uint64_t) g_rejectedCalls;
static _Atomic(uint32_t) g_rejectLogged;
static _Atomic(uint64_t) g_vmLargeCalls;
static _Atomic(uint64_t) g_reserveCalls;
static _Atomic(uint64_t) g_zeroedBytes;
static _Atomic(uint64_t) g_zeroSkippedBytes;
static _Atomic(uint64_t) g_decommittedBytes;
static _Atomic(uint64_t) g_decommitFailures;
static _Atomic(uint64_t) g_zeroPages;
static _Atomic(uint64_t) g_trimmedBytes;
static _Atomic(uint64_t) g_lastTrimAt;
static _Atomic(uint8_t) g_trimRunning;

static void *(*g_origMmap)(void *, size_t, int, int, int, off_t);
static int (*g_origMunmap)(void *, size_t);
static void *(*g_origMalloc)(size_t);
static void *(*g_origCalloc)(size_t, size_t);
static void *(*g_origRealloc)(void *, size_t);
static void (*g_origFree)(void *);
static size_t (*g_origMallocSize)(const void *);
static void *(*g_origValloc)(size_t);
static int (*g_origPosixMemalign)(void **, size_t, size_t);
static void *(*g_origAlignedAlloc)(size_t, size_t);
static void *(*g_origMemalign)(size_t, size_t);
static void *(*g_origMallocTypeMalloc)(size_t, uintptr_t);
static void *(*g_origMallocTypeCalloc)(size_t, size_t, uintptr_t);
static void *(*g_origMallocTypeRealloc)(void *, size_t, uintptr_t);
static void *(*g_origMallocTypeMemalign)(size_t, size_t, uintptr_t);
static kern_return_t (*g_origVmAllocate)(vm_map_t, vm_address_t *, vm_size_t, int);
static kern_return_t (*g_origMachVmAllocate)(vm_map_t, mach_vm_address_t *, mach_vm_size_t, int);
static kern_return_t (*g_origVmDeallocate)(vm_map_t, vm_address_t, vm_size_t);
static kern_return_t (*g_origMachVmDeallocate)(vm_map_t, mach_vm_address_t, mach_vm_size_t);

static char g_bundlePrefix[PATH_MAX];
static size_t g_bundlePrefixLength;

static void rd_malloc_zone_register(void);

BOOL rd_ram_bypass_enabled(void)
{
    const char *value = getenv("DM_RAM_EXTEND");

    return value && atoi(value) != 0;
}

BOOL rd_ram_bypass_available(void)
{
    return LoRRamDonor.donorBundleIdentifier.length > 0;
}

static uint64_t rd_redirect_minimum_from_env(void)
{
    const char *value = getenv("DM_RAM_REALLOC_MIN");

    if (!value || !*value)
    {
        return kRDRedirectDefaultMinimum;
    }

    const unsigned long long bytes = strtoull(value, NULL, 10);

    switch (bytes)
    {
        case 0ull:
        case 16ull * 1024ull:
        case 64ull * 1024ull:
        case 256ull * 1024ull:
            return bytes;
        default:
            return kRDRedirectDefaultMinimum;
    }
}

static uint64_t rd_donated_min_allocation(void)
{
    return atomic_load_explicit(&g_redirectMinimum, memory_order_acquire);
}

void rd_ram_bypass_get_stats(RamBypassStats *outStats)
{
    if (!outStats)
    {
        return;
    }

    memset(outStats, 0, sizeof(*outStats));

    if (!atomic_load_explicit(&g_poolReady, memory_order_acquire))
    {
        outStats->fallbackAllocations = atomic_load(&g_fallbackCount);
        return;
    }

    os_unfair_lock_lock(&g_pool.lock);
    outStats->active = YES;
    outStats->poolBytes = g_pool.size;
    outStats->usedBytes = g_pool.used;
    os_unfair_lock_unlock(&g_pool.lock);

    outStats->servedAllocations = atomic_load(&g_servedCount);
    outStats->fallbackAllocations = atomic_load(&g_fallbackCount);
}

static uint64_t rd_pool_resident_estimate(void)
{
    if (!atomic_load_explicit(&g_poolReady, memory_order_acquire))
    {
        return 0;
    }

    os_unfair_lock_lock(&g_pool.lock);
    const uint64_t committed = (uint64_t)g_pool.cleanPage * g_pool.pageSize;
    os_unfair_lock_unlock(&g_pool.lock);

    const uint64_t zeroed = atomic_load_explicit(&g_zeroPages, memory_order_relaxed) * g_pool.pageSize;

    return committed > zeroed ? committed - zeroed : 0;
}

void rd_ram_hud_get_snapshot(RamHudSnapshot *outSnapshot)
{
    if (!outSnapshot)
    {
        return;
    }

    memset(outSnapshot, 0, sizeof(*outSnapshot));

    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;

    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS)
    {
        outSnapshot->appBytes = info.phys_footprint;
    }

    RamBypassStats stats;
    rd_ram_bypass_get_stats(&stats);

    outSnapshot->donatedBytes = stats.active ? stats.poolBytes : 0;
    outSnapshot->donatedUsedBytes = stats.active ? rd_pool_resident_estimate() : 0;
    outSnapshot->totalBytes = outSnapshot->appBytes + outSnapshot->donatedUsedBytes;
}

static inline uint64_t rd_round_page(uint64_t value)
{
    const uint64_t mask = (uint64_t)vm_page_size - 1;

    return (value + mask) & ~mask;
}

static inline BOOL rd_pool_contains(const void *address, uint64_t length)
{
    if (!atomic_load_explicit(&g_poolReady, memory_order_acquire))
    {
        return NO;
    }

    const uintptr_t start = (uintptr_t)address;

    return start >= g_pool.base && start + length <= g_pool.base + g_pool.size && start + length >= start;
}

static void rd_pool_log_async(uint64_t used)
{
    const uint64_t served = atomic_load(&g_servedCount);
    const uint64_t fallback = atomic_load(&g_fallbackCount);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        RDLog(@"%llu MB of %llu MB in use, %llu allocations served, %llu large allocations fell through, zeroed %llu MB, skipped %llu MB, decommitted %llu MB (%llu failed), trimmed %llu MB, resident scan %llu MB (estimate %llu MB), thermal %ld",
             used / (1024 * 1024), g_pool.size / (1024 * 1024), served, fallback,
             atomic_load(&g_zeroedBytes) / (1024 * 1024), atomic_load(&g_zeroSkippedBytes) / (1024 * 1024),
             atomic_load(&g_decommittedBytes) / (1024 * 1024), atomic_load(&g_decommitFailures),
             atomic_load(&g_trimmedBytes) / (1024 * 1024),
             [LoRRamDonor.shared donatedBytes] / (1024 * 1024), rd_pool_resident_estimate() / (1024 * 1024),
             (long)NSProcessInfo.processInfo.thermalState);
    });
}

static inline uint32_t rd_bin_of(uint32_t len)
{
    if (len <= RD_EXACT_BINS)
    {
        return len - 1;
    }

    const uint32_t lg = 31u - (uint32_t)__builtin_clz(len);
    const uint32_t second = (len >> (lg - 1)) & 1u;
    const uint32_t bin = RD_EXACT_BINS + (lg - 6u) * 2u + second;

    return bin < RD_BIN_COUNT ? bin : RD_BIN_COUNT - 1;
}

static inline int rd_next_bin(uint32_t from)
{
    if (from >= RD_BIN_COUNT)
    {
        return -1;
    }

    uint32_t word = from >> 6;
    uint64_t bits = g_pool.binMap[word] & (~0ull << (from & 63));

    while (!bits)
    {
        if (++word >= 2)
        {
            return -1;
        }

        bits = g_pool.binMap[word];
    }

    return (int)(word * 64u + (uint32_t)__builtin_ctzll(bits));
}

static void rd_run_push(uint32_t start, uint32_t len)
{
    const uint32_t bin = rd_bin_of(len);
    const uint32_t head = g_pool.bins[bin];

    g_pool.runs[start].len = len;
    g_pool.runs[start].prev = RD_RUN_NONE;
    g_pool.runs[start].next = head;

    if (head != RD_RUN_NONE)
    {
        g_pool.runs[head].prev = start;
    }

    g_pool.bins[bin] = start;
    g_pool.binMap[bin >> 6] |= 1ull << (bin & 63);
    g_pool.runs[start + len - 1].len = len;
    g_pool.freeMap[start] |= RD_FREE_HEAD;
    g_pool.freeMap[start + len - 1] |= RD_FREE_TAIL;
}

static uint32_t rd_run_remove(uint32_t start)
{
    const uint32_t len = g_pool.runs[start].len;
    const uint32_t bin = rd_bin_of(len);
    const uint32_t next = g_pool.runs[start].next;
    const uint32_t prev = g_pool.runs[start].prev;

    if (prev != RD_RUN_NONE)
    {
        g_pool.runs[prev].next = next;
    }
    else
    {
        g_pool.bins[bin] = next;
    }

    if (next != RD_RUN_NONE)
    {
        g_pool.runs[next].prev = prev;
    }

    if (g_pool.bins[bin] == RD_RUN_NONE)
    {
        g_pool.binMap[bin >> 6] &= ~(1ull << (bin & 63));
    }

    g_pool.freeMap[start] &= (uint8_t)~RD_FREE_HEAD;
    g_pool.freeMap[start + len - 1] &= (uint8_t)~RD_FREE_TAIL;

    return len;
}

static uint32_t rd_run_find(uint32_t pages)
{
    const uint32_t bin = rd_bin_of(pages);

    if (pages <= RD_EXACT_BINS)
    {
        if (g_pool.bins[bin] != RD_RUN_NONE)
        {
            return g_pool.bins[bin];
        }
    }
    else
    {
        uint32_t cursor = g_pool.bins[bin];

        for (int scanned = 0; cursor != RD_RUN_NONE && scanned < RD_BIN_SCAN_LIMIT; scanned++)
        {
            if (g_pool.runs[cursor].len >= pages)
            {
                return cursor;
            }

            cursor = g_pool.runs[cursor].next;
        }

        const int higherBin = rd_next_bin(bin + 1);

        if (higherBin >= 0)
        {
            return g_pool.bins[higherBin];
        }

        for (; cursor != RD_RUN_NONE; cursor = g_pool.runs[cursor].next)
        {
            if (g_pool.runs[cursor].len >= pages)
            {
                return cursor;
            }
        }

        return RD_RUN_NONE;
    }

    const int higher = rd_next_bin(bin + 1);

    return higher >= 0 ? g_pool.bins[higher] : RD_RUN_NONE;
}

static inline BOOL rd_bytes_all_zero(const uint8_t *cursor, size_t count)
{
    while (count && ((uintptr_t)cursor & 7))
    {
        if (*cursor)
        {
            return NO;
        }

        cursor++;
        count--;
    }

    const uint64_t *words = (const uint64_t *)cursor;

    while (count >= 8)
    {
        if (*words)
        {
            return NO;
        }

        words++;
        count -= 8;
    }

    cursor = (const uint8_t *)words;

    while (count)
    {
        if (*cursor)
        {
            return NO;
        }

        cursor++;
        count--;
    }

    return YES;
}

static void rd_pool_prepare(void *base, uint64_t bytes, BOOL zero)
{
    const uint64_t pageSize = g_pool.pageSize;
    const uint64_t first = ((uintptr_t)base - g_pool.base) / pageSize;
    const uint64_t count = bytes / pageSize;
    uint8_t *map = g_pool.zeroMap + first;
    uint64_t dirtyPages = 0;
    uint64_t index = 0;

    while (index < count)
    {
        if (map[index])
        {
            index++;
            continue;
        }

        uint64_t end = index;

        while (end < count && !map[end])
        {
            end++;
        }

        if (zero)
        {
            memset((uint8_t *)base + index * pageSize, 0, (size_t)((end - index) * pageSize));
        }

        dirtyPages += end - index;
        index = end;
    }

    memset(map, 0, (size_t)count);

    if (count > dirtyPages)
    {
        atomic_fetch_sub_explicit(&g_zeroPages, count - dirtyPages, memory_order_relaxed);
    }

    if (zero)
    {
        atomic_fetch_add_explicit(&g_zeroedBytes, dirtyPages * pageSize, memory_order_relaxed);
        atomic_fetch_add_explicit(&g_zeroSkippedBytes, (count - dirtyPages) * pageSize, memory_order_relaxed);
    }
}

static void *rd_pool_take(uint64_t length, BOOL zero)
{
    const uint64_t needBytes = rd_round_page(length);
    const uint64_t pageSize = g_pool.pageSize;
    void *result = NULL;
    BOOL dirty = NO;
    BOOL crossedStride = NO;
    uint64_t usedAfter = 0;

    if (needBytes == 0 || needBytes / pageSize > g_pool.pageCount)
    {
        return NULL;
    }

    const uint32_t pages = (uint32_t)(needBytes / pageSize);

    os_unfair_lock_lock(&g_pool.lock);

    const uint32_t run = rd_run_find(pages);

    if (run != RD_RUN_NONE)
    {
        const uint32_t len = rd_run_remove(run);

        memset(g_pool.freeMap + run, 0, pages);

        if (len > pages)
        {
            rd_run_push(run + pages, len - pages);
        }

        result = (void *)(g_pool.base + (uint64_t)run * pageSize);
        dirty = YES;
    }
    else if (g_pool.pageCount - g_pool.cleanPage >= pages)
    {
        result = (void *)(g_pool.base + (uint64_t)g_pool.cleanPage * pageSize);
        g_pool.cleanPage += pages;
    }

    if (result)
    {
        g_pool.used += needBytes;
        usedAfter = g_pool.used;

        const uint64_t stride = usedAfter / kRDDonatedLogStride;

        crossedStride = stride > g_pool.loggedStride;

        if (crossedStride)
        {
            g_pool.loggedStride = stride;
        }
    }

    os_unfair_lock_unlock(&g_pool.lock);

    if (!result)
    {
        return NULL;
    }

    if (dirty)
    {
        rd_pool_prepare(result, needBytes, zero);
    }

    atomic_fetch_add_explicit(&g_servedCount, 1, memory_order_relaxed);

    if (crossedStride)
    {
        rd_pool_log_async(usedAfter);
    }

    return result;
}

static BOOL rd_pool_extend(uintptr_t ownerAddress, uint64_t currentBytes, uint64_t extraBytes)
{
    const uint64_t pageSize = g_pool.pageSize;

    if (extraBytes == 0 || ownerAddress < g_pool.base || (ownerAddress - g_pool.base) % pageSize != 0 ||
        currentBytes % pageSize != 0 || extraBytes % pageSize != 0)
    {
        return NO;
    }

    const uint64_t startPage = (ownerAddress - g_pool.base) / pageSize;
    const uint64_t endPage = startPage + currentBytes / pageSize;
    const uint64_t extraPages = extraBytes / pageSize;
    BOOL extended = NO;

    if (endPage + extraPages > g_pool.pageCount)
    {
        return NO;
    }

    os_unfair_lock_lock(&g_pool.lock);

    if (endPage == g_pool.cleanPage)
    {
        g_pool.cleanPage += (uint32_t)extraPages;
        g_pool.used += extraBytes;
        extended = YES;
    }
    else if (endPage < g_pool.cleanPage && (g_pool.freeMap[endPage] & RD_FREE_HEAD) &&
             g_pool.runs[endPage].len >= extraPages)
    {
        const uint32_t len = rd_run_remove((uint32_t)endPage);

        memset(g_pool.freeMap + endPage, 0, extraPages);

        if (len > extraPages)
        {
            rd_run_push((uint32_t)(endPage + extraPages), len - (uint32_t)extraPages);
        }

        g_pool.used += extraBytes;
        extended = YES;
    }

    os_unfair_lock_unlock(&g_pool.lock);

    if (extended)
    {
        uint64_t cleared = 0;

        for (uint64_t i = 0; i < extraPages; i++)
        {
            cleared += g_pool.zeroMap[endPage + i] ? 1 : 0;
        }

        memset(g_pool.zeroMap + endPage, 0, (size_t)extraPages);

        if (cleared)
        {
            atomic_fetch_sub_explicit(&g_zeroPages, cleared, memory_order_relaxed);
        }
    }

    return extended;
}

static void rd_pool_give_internal(void *address, uint64_t length, BOOL decommit)
{
    const uint64_t pageSize = g_pool.pageSize;
    const uint64_t bytes = rd_round_page(length);
    const uint64_t offset = (uintptr_t)address - g_pool.base;

    if (bytes == 0 || offset % pageSize != 0)
    {
        return;
    }

    const uint64_t first = offset / pageSize;
    const uint64_t count = bytes / pageSize;

    if (decommit && bytes >= kRDDonatedDecommitMinBytes)
    {
        os_unfair_lock_lock(&g_pool.lock);
        const BOOL valid = first + count <= g_pool.cleanPage && rd_bytes_all_zero(g_pool.freeMap + first, count);
        os_unfair_lock_unlock(&g_pool.lock);

        if (!valid)
        {
            return;
        }

        if (madvise(address, (size_t)bytes, MADV_ZERO) == 0)
        {
            memset(g_pool.zeroMap + first, 1, (size_t)count);
            atomic_fetch_add_explicit(&g_zeroPages, count, memory_order_relaxed);
            atomic_fetch_add_explicit(&g_decommittedBytes, bytes, memory_order_relaxed);
        }
        else
        {
            atomic_fetch_add_explicit(&g_decommitFailures, 1, memory_order_relaxed);
        }
    }

    os_unfair_lock_lock(&g_pool.lock);

    if (first + count > g_pool.cleanPage || !rd_bytes_all_zero(g_pool.freeMap + first, count))
    {
        os_unfair_lock_unlock(&g_pool.lock);
        return;
    }

    uint32_t start = (uint32_t)first;
    uint32_t len = (uint32_t)count;

    if (start > 0 && (g_pool.freeMap[start - 1] & RD_FREE_TAIL))
    {
        const uint32_t previousLen = g_pool.runs[start - 1].len;
        const uint32_t previousStart = start - previousLen;

        rd_run_remove(previousStart);
        start = previousStart;
        len += previousLen;
    }

    const uint32_t nextPage = (uint32_t)(first + count);

    if (nextPage < g_pool.cleanPage && (g_pool.freeMap[nextPage] & RD_FREE_HEAD))
    {
        len += rd_run_remove(nextPage);
    }

    memset(g_pool.freeMap + first, RD_FREE_ANY, count);
    rd_run_push(start, len);

    g_pool.used -= MIN(g_pool.used, bytes);

    os_unfair_lock_unlock(&g_pool.lock);
}

static void rd_pool_give(void *address, uint64_t length)
{
    rd_pool_give_internal(address, length, YES);
}

static uint64_t rd_pool_trim(uint64_t goal)
{
    const uint64_t pageSize = g_pool.pageSize;
    uint64_t released = 0;

    for (;;)
    {
        uint32_t starts[RD_TRIM_BATCH];
        uint32_t lengths[RD_TRIM_BATCH];
        int taken = 0;

        os_unfair_lock_lock(&g_pool.lock);

        for (uint32_t bin = 0; bin < RD_BIN_COUNT && taken < RD_TRIM_BATCH; bin++)
        {
            for (uint32_t cursor = g_pool.bins[bin]; cursor != RD_RUN_NONE && taken < RD_TRIM_BATCH;
                 cursor = g_pool.runs[cursor].next)
            {
                const uint32_t length = g_pool.runs[cursor].len;
                BOOL clean = YES;

                for (uint32_t i = 0; i < length; i++)
                {
                    if (!g_pool.zeroMap[cursor + i])
                    {
                        clean = NO;
                        break;
                    }
                }

                if (!clean)
                {
                    starts[taken] = cursor;
                    lengths[taken] = length;
                    taken++;
                }
            }
        }

        for (int i = 0; i < taken; i++)
        {
            rd_run_remove(starts[i]);
            memset(g_pool.freeMap + starts[i], 0, lengths[i]);
            g_pool.used += (uint64_t)lengths[i] * pageSize;
        }

        os_unfair_lock_unlock(&g_pool.lock);

        if (taken == 0)
        {
            break;
        }

        BOOL failed = NO;

        for (int i = 0; i < taken; i++)
        {
            void *base = (void *)(g_pool.base + (uint64_t)starts[i] * pageSize);
            const uint64_t bytes = (uint64_t)lengths[i] * pageSize;
            uint64_t dirtyPages = 0;

            for (uint32_t j = 0; j < lengths[i]; j++)
            {
                dirtyPages += g_pool.zeroMap[starts[i] + j] ? 0 : 1;
            }

            if (madvise(base, (size_t)bytes, MADV_ZERO) == 0)
            {
                memset(g_pool.zeroMap + starts[i], 1, lengths[i]);
                atomic_fetch_add_explicit(&g_zeroPages, dirtyPages, memory_order_relaxed);
                atomic_fetch_add_explicit(&g_decommittedBytes, dirtyPages * pageSize, memory_order_relaxed);
                released += dirtyPages * pageSize;
            }
            else
            {
                failed = YES;
                atomic_fetch_add_explicit(&g_decommitFailures, 1, memory_order_relaxed);
            }

            rd_pool_give_internal(base, bytes, NO);
        }

        if (failed || (goal && released >= goal))
        {
            break;
        }
    }

    return released;
}

static uint64_t rd_pool_trim_guarded(uint64_t goal, BOOL throttled)
{
    if (!atomic_load_explicit(&g_poolReady, memory_order_acquire))
    {
        return 0;
    }

    const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);

    if (throttled && now - atomic_load_explicit(&g_lastTrimAt, memory_order_relaxed) < kRDTrimMinIntervalNs)
    {
        return 0;
    }

    if (atomic_exchange_explicit(&g_trimRunning, 1, memory_order_acq_rel))
    {
        return 0;
    }

    atomic_store_explicit(&g_lastTrimAt, now, memory_order_relaxed);

    const uint64_t released = rd_pool_trim(goal);

    atomic_fetch_add_explicit(&g_trimmedBytes, released, memory_order_relaxed);
    atomic_store_explicit(&g_trimRunning, 0, memory_order_release);

    if (released)
    {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            RDLog(@"trim released %llu MB, resident scan %llu MB (estimate %llu MB)",
                 released / (1024 * 1024), [LoRRamDonor.shared donatedBytes] / (1024 * 1024),
                 rd_pool_resident_estimate() / (1024 * 1024));
        });
    }

    return released;
}

void rd_ram_bypass_trim(void)
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        rd_pool_trim_guarded(0, NO);
    });
}

static void rd_pool_install_pressure_handler(void)
{
    static dispatch_source_t source;

    if (source)
    {
        return;
    }

    source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
                                    DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
                                    dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));

    dispatch_source_set_event_handler(source, ^{
        rd_pool_trim_guarded(0, YES);
    });

    dispatch_resume(source);
}

static BOOL rd_pool_install(void *base, uint64_t size)
{
    const uint64_t pageSize = vm_page_size;
    const uint64_t pages = size / pageSize;

    if (!g_origMmap || pages == 0 || pages >= RD_RUN_NONE)
    {
        return NO;
    }

    void *runs = g_origMmap(NULL, (size_t)rd_round_page(pages * sizeof(RDRun)),
                            PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    void *map = g_origMmap(NULL, (size_t)rd_round_page(pages),
                           PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    void *zeroMap = g_origMmap(NULL, (size_t)rd_round_page(pages),
                               PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);

    if (runs == MAP_FAILED || map == MAP_FAILED || zeroMap == MAP_FAILED)
    {
        if (runs != MAP_FAILED)
        {
            g_origMunmap(runs, (size_t)rd_round_page(pages * sizeof(RDRun)));
        }

        if (map != MAP_FAILED)
        {
            g_origMunmap(map, (size_t)rd_round_page(pages));
        }

        if (zeroMap != MAP_FAILED)
        {
            g_origMunmap(zeroMap, (size_t)rd_round_page(pages));
        }

        return NO;
    }

    g_pool.base = (uintptr_t)base;
    g_pool.size = pages * pageSize;
    g_pool.pageSize = pageSize;
    g_pool.pageCount = (uint32_t)pages;
    g_pool.cleanPage = 0;
    g_pool.used = 0;
    g_pool.loggedStride = 0;
    g_pool.runs = runs;
    g_pool.freeMap = map;
    g_pool.zeroMap = zeroMap;
    g_pool.binMap[0] = 0;
    g_pool.binMap[1] = 0;

    for (uint32_t i = 0; i < RD_BIN_COUNT; i++)
    {
        g_pool.bins[i] = RD_RUN_NONE;
    }

    atomic_store_explicit(&g_poolReady, 1, memory_order_release);

    if (atomic_load_explicit(&g_mallocAllocationEnabled, memory_order_acquire))
    {
        rd_malloc_zone_register();
    }

    rd_pool_install_pressure_handler();

    RDLog(@"pool ready: %llu MB at %p, serving anonymous mappings of %llu KB or more",
         g_pool.size / (1024 * 1024), base, rd_donated_min_allocation() / 1024);

    return YES;
}

static void rd_log_rejected_mmap(size_t length, void *address, int prot, int flags, int fd)
{
    if (atomic_fetch_add(&g_rejectLogged, 1) >= 8)
    {
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        RDLog(@"large mmap of %zu KB not eligible: addr=%p prot=0x%x flags=0x%x fd=%d",
             length / 1024, address, prot, flags, fd);
    });
}

#define RD_PROFILE_SLOTS 2048
#define RD_PROFILE_PROBE 16
#define RD_PROFILE_FRAMES 4
#define RD_PROFILE_KEYED_FRAMES 3
#define RD_PROFILE_TOP 12

typedef enum {
    RDProfileMalloc,
    RDProfileCalloc,
    RDProfileValloc,
    RDProfileMemalign,
    RDProfileMmap,
    RDProfileMmapReserve,
    RDProfileMmapFile,
    RDProfileMmapOther,
    RDProfileVmAllocate,
    RDProfileApiCount
} RDProfileApi;

static const char *const kRDProfileApiNames[RDProfileApiCount] = {
    "malloc", "calloc", "valloc", "memalign", "mmap", "mmap-reserve", "mmap-file", "mmap-other", "vm_allocate"
};

typedef struct {
    _Atomic(uint64_t) key;
    _Atomic(uint32_t) ready;
    uint32_t api;
    uintptr_t frames[RD_PROFILE_FRAMES];
    _Atomic(uint64_t) calls;
    _Atomic(uint64_t) bytes;
    _Atomic(uint64_t) minSize;
    _Atomic(uint64_t) maxSize;
} RDProfileSlot;

typedef struct {
    uint32_t api;
    uintptr_t frames[RD_PROFILE_FRAMES];
    uint64_t calls;
    uint64_t bytes;
    uint64_t minSize;
    uint64_t maxSize;
} RDProfileRow;

static RDProfileSlot g_profileSlots[RD_PROFILE_SLOTS];
static _Atomic(uint64_t) g_profileDropped;
static uint64_t g_profileStartNs;
static _Atomic(uint8_t) g_profileActive;

static inline uintptr_t rd_profile_strip(uintptr_t address)
{
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)address, ptrauth_key_return_address);
#else
    return address;
#endif
}

static __attribute__((noinline)) void rd_profile_record(uint32_t api, uint64_t size, void *frame)
{
    if (!atomic_load_explicit(&g_profileActive, memory_order_relaxed))
    {
        return;
    }

    uintptr_t frames[RD_PROFILE_FRAMES] = {0};
    void **cursor = (void **)frame;

    for (int i = 0; i < RD_PROFILE_FRAMES && cursor; i++)
    {
        if ((uintptr_t)cursor & 15)
        {
            break;
        }

        frames[i] = rd_profile_strip((uintptr_t)cursor[1]);

        void **next = (void **)cursor[0];

        if ((uintptr_t)next <= (uintptr_t)cursor || (uintptr_t)next - (uintptr_t)cursor > (1u << 20))
        {
            break;
        }

        cursor = next;
    }

    uint64_t key = 1469598103934665603ull ^ api;

    for (int i = 0; i < RD_PROFILE_KEYED_FRAMES; i++)
    {
        key = (key ^ (uint64_t)frames[i]) * 1099511628211ull;
    }

    key |= 1;

    RDProfileSlot *slot = NULL;

    for (uint32_t probe = 0; probe < RD_PROFILE_PROBE && !slot; probe++)
    {
        RDProfileSlot *candidate = &g_profileSlots[(key + probe) % RD_PROFILE_SLOTS];
        uint64_t current = atomic_load_explicit(&candidate->key, memory_order_acquire);

        if (current == 0 && atomic_compare_exchange_strong_explicit(&candidate->key, &current, key,
                                                                    memory_order_acq_rel, memory_order_acquire))
        {
            candidate->api = api;
            memcpy(candidate->frames, frames, sizeof(frames));
            atomic_store_explicit(&candidate->ready, 1, memory_order_release);
            slot = candidate;
        }
        else if (current == key)
        {
            slot = candidate;
        }
    }

    if (!slot)
    {
        atomic_fetch_add_explicit(&g_profileDropped, 1, memory_order_relaxed);
        return;
    }

    atomic_fetch_add_explicit(&slot->calls, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&slot->bytes, size, memory_order_relaxed);

    uint64_t low = atomic_load_explicit(&slot->minSize, memory_order_relaxed);

    while ((low == 0 || size < low) &&
           !atomic_compare_exchange_weak_explicit(&slot->minSize, &low, size, memory_order_relaxed, memory_order_relaxed))
    {
    }

    uint64_t high = atomic_load_explicit(&slot->maxSize, memory_order_relaxed);

    while (size > high &&
           !atomic_compare_exchange_weak_explicit(&slot->maxSize, &high, size, memory_order_relaxed, memory_order_relaxed))
    {
    }
}

#define RD_PROFILE(api, size) rd_profile_record((api), (size), __builtin_frame_address(0))
#define RD_PROFILE_LARGE(api, size) \
    do { if ((size) >= rd_donated_min_allocation()) RD_PROFILE((api), (size)); } while (0)

static NSString *rd_profile_format_bytes(uint64_t bytes)
{
    if (bytes >= 1024ull * 1024ull * 1024ull)
    {
        return [NSString stringWithFormat:@"%.2f GB", (double)bytes / (1024.0 * 1024.0 * 1024.0)];
    }

    if (bytes >= 1024ull * 1024ull)
    {
        return [NSString stringWithFormat:@"%.1f MB", (double)bytes / (1024.0 * 1024.0)];
    }

    return [NSString stringWithFormat:@"%.1f KB", (double)bytes / 1024.0];
}

static NSString *rd_profile_describe(uintptr_t returnAddress)
{
    if (!returnAddress)
    {
        return @"?";
    }

    const uintptr_t address = returnAddress - 4;
    Dl_info info;

    if (!dladdr((void *)address, &info) || !info.dli_fname || !info.dli_fbase)
    {
        return [NSString stringWithFormat:@"0x%lx", (unsigned long)address];
    }

    const char *name = strrchr(info.dli_fname, '/');
    name = name ? name + 1 : info.dli_fname;

    NSString *text = [NSString stringWithFormat:@"%s+0x%lx", name, (unsigned long)(address - (uintptr_t)info.dli_fbase)];

    if (info.dli_sname)
    {
        text = [text stringByAppendingFormat:@"(%s)", info.dli_sname];
    }

    return text;
}

static int rd_profile_compare_calls(const void *left, const void *right)
{
    const uint64_t a = ((const RDProfileRow *)left)->calls;
    const uint64_t b = ((const RDProfileRow *)right)->calls;

    return a < b ? 1 : (a > b ? -1 : 0);
}

static int rd_profile_compare_bytes(const void *left, const void *right)
{
    const uint64_t a = ((const RDProfileRow *)left)->bytes;
    const uint64_t b = ((const RDProfileRow *)right)->bytes;

    return a < b ? 1 : (a > b ? -1 : 0);
}

static void rd_profile_log_rows(const char *title, RDProfileRow *rows, size_t count, double seconds)
{
    const size_t limit = MIN(count, (size_t)RD_PROFILE_TOP);

    for (size_t i = 0; i < limit; i++)
    {
        const RDProfileRow *row = &rows[i];
        NSMutableArray<NSString *> *chain = [NSMutableArray array];

        for (int f = 0; f < RD_PROFILE_FRAMES && row->frames[f]; f++)
        {
            [chain addObject:rd_profile_describe(row->frames[f])];
        }

        RDLog(@"hot by %s #%zu %s x%llu (%.2f/s) total %@ avg %@ min %@ max %@ | %@",
             title, i + 1, kRDProfileApiNames[row->api], row->calls, seconds > 0 ? (double)row->calls / seconds : 0.0,
             rd_profile_format_bytes(row->bytes), rd_profile_format_bytes(row->calls ? row->bytes / row->calls : 0),
             rd_profile_format_bytes(row->minSize), rd_profile_format_bytes(row->maxSize),
             [chain componentsJoinedByString:@" <- "]);
    }
}

static void rd_profile_dump(void)
{
    RDProfileRow *rows = calloc(RD_PROFILE_SLOTS, sizeof(RDProfileRow));

    if (!rows)
    {
        return;
    }

    size_t count = 0;

    for (uint32_t i = 0; i < RD_PROFILE_SLOTS; i++)
    {
        RDProfileSlot *slot = &g_profileSlots[i];

        if (!atomic_load_explicit(&slot->ready, memory_order_acquire))
        {
            continue;
        }

        RDProfileRow *row = &rows[count];
        row->calls = atomic_load_explicit(&slot->calls, memory_order_relaxed);

        if (!row->calls)
        {
            continue;
        }

        row->api = slot->api;
        memcpy(row->frames, slot->frames, sizeof(row->frames));
        row->bytes = atomic_load_explicit(&slot->bytes, memory_order_relaxed);
        row->minSize = atomic_load_explicit(&slot->minSize, memory_order_relaxed);
        row->maxSize = atomic_load_explicit(&slot->maxSize, memory_order_relaxed);
        count++;
    }

    const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    const double seconds = g_profileStartNs && now > g_profileStartNs ? (double)(now - g_profileStartNs) / 1e9 : 0.0;

    uint64_t apiCalls[RDProfileApiCount] = {0};
    uint64_t apiBytes[RDProfileApiCount] = {0};

    for (size_t i = 0; i < count; i++)
    {
        apiCalls[rows[i].api] += rows[i].calls;
        apiBytes[rows[i].api] += rows[i].bytes;
    }

    NSMutableArray<NSString *> *totals = [NSMutableArray array];

    for (uint32_t api = 0; api < RDProfileApiCount; api++)
    {
        if (apiCalls[api])
        {
            [totals addObject:[NSString stringWithFormat:@"%s %llu calls %@", kRDProfileApiNames[api],
                                                         apiCalls[api], rd_profile_format_bytes(apiBytes[api])]];
        }
    }

    RDLog(@"profile after %.0fs: %zu call sites, %llu dropped | %@",
         seconds, count, atomic_load(&g_profileDropped), [totals componentsJoinedByString:@", "]);

    qsort(rows, count, sizeof(RDProfileRow), rd_profile_compare_calls);
    rd_profile_log_rows("calls", rows, count, seconds);

    qsort(rows, count, sizeof(RDProfileRow), rd_profile_compare_bytes);
    rd_profile_log_rows("bytes", rows, count, seconds);

    free(rows);
}

static void rd_memlog_report(NSString *label)
{
    RDLog(@"%@: hook saw %llu mmap calls (%llu large, %llu not eligible, %llu of those PROT_NONE reservations) and %llu large vm_allocate calls, %llu served, %llu fell through, pool %@",
         label,
         atomic_load(&g_mmapCalls), atomic_load(&g_largeCalls), atomic_load(&g_rejectedCalls),
         atomic_load(&g_reserveCalls), atomic_load(&g_vmLargeCalls),
         atomic_load(&g_servedCount), atomic_load(&g_fallbackCount),
         atomic_load(&g_poolReady) ? @"ready" : @"not ready");

    rd_profile_dump();
}

void rd_ram_bypass_memlog(void)
{
    if (atomic_exchange_explicit(&g_profileActive, 1, memory_order_acq_rel))
    {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            rd_memlog_report(@"memlog snapshot");
        });
        return;
    }

    g_profileStartNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    RDLog(@"memlog started, reports follow at 20s, 60s, 120s, 300s and 900s, run /memlog again for an immediate snapshot");

    for (NSNumber *delay in @[@20, @60, @120, @300, @900])
    {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            rd_memlog_report([NSString stringWithFormat:@"after %@s", delay]);
        });
    }
}

static void *rd_hook_mmap(void *address, size_t length, int prot, int flags, int fd, off_t offset)
{
    const BOOL anonymous = (flags & MAP_ANON) != 0 && (fd == -1 || ((uint32_t)fd & 0xff000000u) != 0);

    const BOOL large = length >= rd_donated_min_allocation();
    const BOOL eligible = large && anonymous &&
        (flags & MAP_PRIVATE) != 0 && (flags & (MAP_FIXED | MAP_JIT | MAP_SHARED)) == 0 &&
        prot == (PROT_READ | PROT_WRITE);

    atomic_fetch_add(&g_mmapCalls, 1);

    if (large)
    {
        atomic_fetch_add(&g_largeCalls, 1);

        uint32_t category = RDProfileMmapOther;

        if (eligible)
        {
            category = RDProfileMmap;
        }
        else if (!anonymous)
        {
            category = RDProfileMmapFile;
        }
        else if (prot == PROT_NONE)
        {
            category = RDProfileMmapReserve;
        }

        RD_PROFILE(category, length);
    }

    if (large && !eligible)
    {
        atomic_fetch_add(&g_rejectedCalls, 1);

        if (anonymous && prot == PROT_NONE)
        {
            atomic_fetch_add(&g_reserveCalls, 1);
        }
        else if (anonymous)
        {
            rd_log_rejected_mmap(length, address, prot, flags, fd);
        }
    }

    if (eligible)
    {
        if (atomic_load_explicit(&g_poolReady, memory_order_acquire))
        {
            void *served = rd_pool_take(length, YES);

            if (served)
            {
                return served;
            }
        }

        atomic_fetch_add(&g_fallbackCount, 1);
    }

    return g_origMmap(address, length, prot, flags, fd, offset);
}

static int rd_hook_munmap(void *address, size_t length)
{
    if (length != 0 && rd_pool_contains(address, length))
    {
        rd_pool_give(address, length);
        return 0;
    }

    return g_origMunmap(address, length);
}

static void rd_log_rejected_vm(const char *api, uint64_t length, int flags)
{
    if (atomic_fetch_add(&g_rejectLogged, 1) >= 8)
    {
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        RDLog(@"large %s of %llu KB not eligible: flags=0x%x", api, length / 1024, flags);
    });
}

static BOOL rd_vm_allocate_common(const char *api, vm_map_t target, uint64_t *address, uint64_t size, int flags, void *callerFrame)
{
    if (!address || target != mach_task_self() || size < rd_donated_min_allocation())
    {
        return NO;
    }

    atomic_fetch_add(&g_vmLargeCalls, 1);
    rd_profile_record(RDProfileVmAllocate, size, callerFrame);

    if ((flags & VM_FLAGS_ANYWHERE) == 0 || (flags & (VM_FLAGS_OVERWRITE | VM_FLAGS_PURGABLE)) != 0)
    {
        rd_log_rejected_vm(api, size, flags);
        return NO;
    }

    if (!atomic_load_explicit(&g_poolReady, memory_order_acquire))
    {
        return NO;
    }

    void *served = rd_pool_take(size, YES);

    if (!served)
    {
        atomic_fetch_add(&g_fallbackCount, 1);
        return NO;
    }

    *address = (uint64_t)(uintptr_t)served;

    return YES;
}

static kern_return_t rd_hook_vm_allocate(vm_map_t target, vm_address_t *address, vm_size_t size, int flags)
{
    uint64_t served = 0;

    if (rd_vm_allocate_common("vm_allocate", target, &served, size, flags, __builtin_frame_address(0)))
    {
        *address = (vm_address_t)served;

        return KERN_SUCCESS;
    }

    return g_origVmAllocate(target, address, size, flags);
}

static kern_return_t rd_hook_mach_vm_allocate(vm_map_t target, mach_vm_address_t *address, mach_vm_size_t size, int flags)
{
    uint64_t served = 0;

    if (rd_vm_allocate_common("mach_vm_allocate", target, &served, size, flags, __builtin_frame_address(0)))
    {
        *address = (mach_vm_address_t)served;

        return KERN_SUCCESS;
    }

    return g_origMachVmAllocate(target, address, size, flags);
}

static kern_return_t rd_hook_vm_deallocate(vm_map_t target, vm_address_t address, vm_size_t size)
{
    if (target == mach_task_self() && size != 0 && rd_pool_contains((const void *)address, size))
    {
        rd_pool_give((void *)address, size);

        return KERN_SUCCESS;
    }

    return g_origVmDeallocate(target, address, size);
}

static kern_return_t rd_hook_mach_vm_deallocate(vm_map_t target, mach_vm_address_t address, mach_vm_size_t size)
{
    if (target == mach_task_self() && size != 0 && rd_pool_contains((const void *)(uintptr_t)address, size))
    {
        rd_pool_give((void *)(uintptr_t)address, size);

        return KERN_SUCCESS;
    }

    return g_origMachVmDeallocate(target, address, size);
}

static size_t rd_malloc_align_size(size_t value, size_t alignment)
{
    if (value > SIZE_MAX - (alignment - 1))
    {
        return 0;
    }

    return (value + alignment - 1) & ~(alignment - 1);
}

static RDMallocAllocationHeader *rd_malloc_header_for_pointer(const void *pointer)
{
    if (!pointer || !atomic_load_explicit(&g_poolReady, memory_order_acquire))
    {
        return NULL;
    }

    const uintptr_t value = (uintptr_t)pointer;

    if (value < sizeof(RDMallocAllocationHeader))
    {
        return NULL;
    }

    RDMallocAllocationHeader *header = (RDMallocAllocationHeader *)(value - sizeof(RDMallocAllocationHeader));

    if (!rd_pool_contains(header, sizeof(*header)) || header->magic != RD_MALLOC_ALLOCATION_MAGIC)
    {
        return NULL;
    }

    if (header->kind != RD_MALLOC_KIND_LARGE && header->kind != RD_MALLOC_KIND_SMALL)
    {
        return NULL;
    }

    if (header->ownerOffset >= g_pool.size)
    {
        return NULL;
    }

    const uintptr_t owner = g_pool.base + header->ownerOffset;
    const uintptr_t headerAddress = (uintptr_t)header;
    const uintptr_t poolEnd = g_pool.base + g_pool.size;

    if (header->requestedSize > header->capacity)
    {
        return NULL;
    }

    if (header->kind == RD_MALLOC_KIND_SMALL)
    {
        if (header->ownerOffset % vm_page_size != 0 || owner + vm_page_size > poolEnd)
        {
            return NULL;
        }

        RDMallocSlab *slab = (RDMallocSlab *)owner;
        const uintptr_t firstBlock = owner + sizeof(*slab);

        if (slab->magic != RD_MALLOC_SLAB_MAGIC || slab->blockSize < sizeof(*header) ||
            slab->spanSize < vm_page_size || slab->spanSize % vm_page_size != 0 ||
            owner + slab->spanSize > poolEnd ||
            headerAddress < firstBlock || headerAddress + sizeof(*header) > owner + slab->spanSize ||
            (headerAddress - firstBlock) % slab->blockSize != 0 ||
            (headerAddress - firstBlock) / slab->blockSize >= slab->totalBlocks ||
            header->allocationSize != slab->blockSize ||
            header->capacity != slab->blockSize - sizeof(*header) ||
            header->classIndex != slab->classIndex)
        {
            return NULL;
        }
    }
    else if (header->ownerOffset % vm_page_size != 0 || header->allocationSize == 0 ||
             header->allocationSize % vm_page_size != 0 || owner + header->allocationSize > poolEnd ||
             headerAddress < owner || headerAddress + sizeof(*header) > owner + header->allocationSize ||
             header->capacity > header->allocationSize || header->classIndex < 16 ||
             (header->classIndex & (header->classIndex - 1)) != 0)
    {
        return NULL;
    }

    return header;
}

static inline RDStatShard *rd_stat_shard(void)
{
    return &g_statShards[((uintptr_t)__builtin_frame_address(0) >> 15) & (RD_STAT_SHARDS - 1)];
}

static void rd_malloc_sum_stats(uint64_t *blocks, uint64_t *bytes)
{
    int64_t blockTotal = 0;
    int64_t byteTotal = 0;

    for (int i = 0; i < RD_STAT_SHARDS; i++)
    {
        blockTotal += atomic_load_explicit(&g_statShards[i].blocks, memory_order_relaxed);
        byteTotal += atomic_load_explicit(&g_statShards[i].bytes, memory_order_relaxed);
    }

    *blocks = blockTotal > 0 ? (uint64_t)blockTotal : 0;
    *bytes = byteTotal > 0 ? (uint64_t)byteTotal : 0;
}

static void rd_malloc_record_allocation(size_t requested)
{
    RDStatShard *shard = rd_stat_shard();
    atomic_fetch_add_explicit(&shard->blocks, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&shard->bytes, (int64_t)requested, memory_order_relaxed);
}

static void rd_malloc_record_free(size_t requested)
{
    RDStatShard *shard = rd_stat_shard();
    atomic_fetch_sub_explicit(&shard->blocks, 1, memory_order_relaxed);
    atomic_fetch_sub_explicit(&shard->bytes, (int64_t)requested, memory_order_relaxed);
}

static void rd_malloc_slab_link(RDClassBin *bin, RDMallocSlab *slab, BOOL atTail)
{
    if (slab->linked)
    {
        return;
    }

    slab->linked = 1;

    if (atTail)
    {
        slab->next = NULL;
        slab->prev = bin->tail;

        if (bin->tail)
        {
            bin->tail->next = slab;
        }
        else
        {
            bin->slabs = slab;
        }

        bin->tail = slab;
        return;
    }

    slab->prev = NULL;
    slab->next = bin->slabs;

    if (bin->slabs)
    {
        bin->slabs->prev = slab;
    }
    else
    {
        bin->tail = slab;
    }

    bin->slabs = slab;
}

static void rd_malloc_slab_unlink(RDClassBin *bin, RDMallocSlab *slab)
{
    if (!slab->linked)
    {
        return;
    }

    if (slab->prev)
    {
        slab->prev->next = slab->next;
    }
    else
    {
        bin->slabs = slab->next;
    }

    if (slab->next)
    {
        slab->next->prev = slab->prev;
    }
    else
    {
        bin->tail = slab->prev;
    }

    slab->next = NULL;
    slab->prev = NULL;
    slab->linked = 0;
}

static void *rd_malloc_zone_allocate(size_t requested, size_t alignment, BOOL zeroed)
{
    if (!atomic_load_explicit(&g_poolReady, memory_order_acquire))
    {
        return NULL;
    }

    const size_t actualSize = MAX(requested, (size_t)1);
    alignment = MAX(alignment, (size_t)16);

    if ((alignment & (alignment - 1)) != 0 || alignment > UINT32_MAX || actualSize > UINT32_MAX ||
        actualSize > SIZE_MAX - sizeof(RDMallocAllocationHeader) - (alignment - 1) - ((size_t)vm_page_size - 1))
    {
        return NULL;
    }

    if (alignment <= 16 && actualSize + sizeof(RDMallocAllocationHeader) <= RD_MALLOC_MAX_CLASS_BLOCK_SIZE)
    {
        const size_t blockSize = rd_malloc_align_size(actualSize + sizeof(RDMallocAllocationHeader), 16);
        const size_t classIndex = blockSize / 16;

        if (blockSize == 0 || classIndex >= RD_MALLOC_SMALL_CLASS_COUNT)
        {
            return NULL;
        }

        RDClassBin *bin = &g_classBins[classIndex];

        os_unfair_lock_lock(&bin->lock);

        RDMallocSlab *slab = bin->slabs;

        if (!slab)
        {
            size_t spanSize = vm_page_size;

            if (blockSize >= (size_t)vm_page_size / 2)
            {
                const size_t targetSpan = blockSize > SIZE_MAX / 8 ? SIZE_MAX : blockSize * 8;
                spanSize = MAX((size_t)vm_page_size * 4, (size_t)rd_round_page(targetSpan));
            }

            if (spanSize > UINT32_MAX)
            {
                os_unfair_lock_unlock(&bin->lock);
                return NULL;
            }

            void *span = rd_pool_take(spanSize, NO);

            if (!span)
            {
                os_unfair_lock_unlock(&bin->lock);
                return NULL;
            }

            slab = (RDMallocSlab *)span;
            memset(slab, 0, sizeof(*slab));
            slab->magic = RD_MALLOC_SLAB_MAGIC;
            slab->classIndex = (uint32_t)classIndex;
            slab->blockSize = (uint32_t)blockSize;
            slab->spanSize = (uint32_t)spanSize;
            slab->totalBlocks = (uint32_t)(((size_t)spanSize - sizeof(*slab)) / blockSize);
            slab->freeBlocks = slab->totalBlocks;

            if (slab->totalBlocks == 0)
            {
                slab->magic = 0;
                os_unfair_lock_unlock(&bin->lock);
                rd_pool_give(span, spanSize);
                return NULL;
            }

            uint8_t *firstBlock = (uint8_t *)span + sizeof(*slab);

            for (uint32_t i = 0; i < slab->totalBlocks; i++)
            {
                uintptr_t block = (uintptr_t)(firstBlock + (size_t)i * blockSize);
                *(uintptr_t *)block = slab->freeList;
                slab->freeList = block;
            }

            rd_malloc_slab_link(bin, slab, NO);

            if (spanSize == vm_page_size)
            {
                bin->emptySlabs++;
            }

            atomic_fetch_add_explicit(&g_mallocBytesAllocated, spanSize, memory_order_relaxed);
        }

        if (slab->freeBlocks == slab->totalBlocks && slab->spanSize == vm_page_size && bin->emptySlabs > 0)
        {
            bin->emptySlabs--;
        }

        uintptr_t block = slab->freeList;
        slab->freeList = *(uintptr_t *)block;
        slab->freeBlocks--;

        if (!slab->freeList)
        {
            rd_malloc_slab_unlink(bin, slab);
        }

        RDMallocAllocationHeader *header = (RDMallocAllocationHeader *)block;
        header->magic = RD_MALLOC_ALLOCATION_MAGIC;
        header->requestedSize = (uint32_t)requested;
        header->capacity = (uint32_t)(blockSize - sizeof(*header));
        header->allocationSize = (uint32_t)blockSize;
        header->ownerOffset = (uint32_t)((uintptr_t)slab - g_pool.base);
        header->kind = RD_MALLOC_KIND_SMALL;
        header->classIndex = (uint32_t)classIndex;

        void *result = (uint8_t *)header + sizeof(*header);
        os_unfair_lock_unlock(&bin->lock);

        if (zeroed && requested)
        {
            memset(result, 0, requested);
        }

        rd_malloc_record_allocation(requested);
        return result;
    }

    const size_t totalSize = actualSize + sizeof(RDMallocAllocationHeader) + alignment - 1;
    void *base = rd_pool_take(totalSize, zeroed);

    if (!base)
    {
        return NULL;
    }

    const uint64_t mappedSize = rd_round_page(totalSize);
    const uintptr_t firstUserAddress = (uintptr_t)base + sizeof(RDMallocAllocationHeader);
    const uintptr_t alignedUserAddress = (firstUserAddress + alignment - 1) & ~(uintptr_t)(alignment - 1);
    RDMallocAllocationHeader *header = (RDMallocAllocationHeader *)(alignedUserAddress - sizeof(*header));

    header->magic = RD_MALLOC_ALLOCATION_MAGIC;
    header->requestedSize = (uint32_t)requested;
    header->capacity = (uint32_t)((uintptr_t)base + mappedSize - alignedUserAddress);
    header->allocationSize = (uint32_t)mappedSize;
    header->ownerOffset = (uint32_t)((uintptr_t)base - g_pool.base);
    header->kind = RD_MALLOC_KIND_LARGE;
    header->classIndex = (uint32_t)alignment;

    void *result = (void *)alignedUserAddress;

    atomic_fetch_add_explicit(&g_mallocBytesAllocated, mappedSize, memory_order_relaxed);
    rd_malloc_record_allocation(requested);
    return result;
}

static void rd_malloc_zone_free_pointer(void *pointer)
{
    RDMallocAllocationHeader *header = rd_malloc_header_for_pointer(pointer);

    if (!header)
    {
        return;
    }

    const uint64_t requested = header->requestedSize;
    const uint64_t allocationSize = header->allocationSize;
    const uintptr_t owner = g_pool.base + header->ownerOffset;
    const uint32_t kind = header->kind;
    header->magic = 0;
    rd_malloc_record_free(requested);

    if (kind == RD_MALLOC_KIND_SMALL)
    {
        RDMallocSlab *slab = (RDMallocSlab *)owner;

        if (slab->magic != RD_MALLOC_SLAB_MAGIC)
        {
            return;
        }

        RDClassBin *bin = &g_classBins[slab->classIndex];
        const uint32_t spanSize = slab->spanSize;
        BOOL releaseSpan = NO;

        os_unfair_lock_lock(&bin->lock);
        *(uintptr_t *)header = slab->freeList;
        slab->freeList = (uintptr_t)header;
        slab->freeBlocks++;

        if (slab->freeBlocks == slab->totalBlocks)
        {
            if (spanSize != vm_page_size || bin->emptySlabs > 0)
            {
                rd_malloc_slab_unlink(bin, slab);
                slab->magic = 0;
                releaseSpan = YES;
            }
            else
            {
                if (slab->linked)
                {
                    rd_malloc_slab_unlink(bin, slab);
                }

                rd_malloc_slab_link(bin, slab, YES);
                bin->emptySlabs++;
            }
        }
        else if (!slab->linked)
        {
            rd_malloc_slab_link(bin, slab, NO);
        }

        os_unfair_lock_unlock(&bin->lock);

        if (releaseSpan)
        {
            atomic_fetch_sub_explicit(&g_mallocBytesAllocated, spanSize, memory_order_relaxed);
            rd_pool_give((void *)owner, spanSize);
        }

        return;
    }

    atomic_fetch_sub_explicit(&g_mallocBytesAllocated, allocationSize, memory_order_relaxed);
    rd_pool_give((void *)owner, allocationSize);
}

static void *rd_malloc_zone_reallocate(void *pointer, size_t requested)
{
    if (!pointer)
    {
        return rd_malloc_zone_allocate(requested, 16, NO);
    }

    RDMallocAllocationHeader *header = rd_malloc_header_for_pointer(pointer);

    if (!header)
    {
        return NULL;
    }

    if (requested == 0)
    {
        rd_malloc_zone_free_pointer(pointer);
        return NULL;
    }

    const uint64_t oldRequested = header->requestedSize;

    if (requested <= header->capacity)
    {
        header->requestedSize = (uint32_t)requested;

        atomic_fetch_add_explicit(&rd_stat_shard()->bytes, (int64_t)requested - (int64_t)oldRequested,
                                  memory_order_relaxed);

        return pointer;
    }

    if (header->kind == RD_MALLOC_KIND_LARGE && requested <= UINT32_MAX - 2 * (uint64_t)vm_page_size)
    {
        const uintptr_t owner = g_pool.base + header->ownerOffset;
        const uintptr_t userAddress = (uintptr_t)pointer;
        const uint64_t neededBytes = rd_round_page((userAddress - owner) + requested);
        const uint64_t currentBytes = header->allocationSize;

        if (neededBytes > currentBytes && rd_pool_extend(owner, currentBytes, neededBytes - currentBytes))
        {
            header->allocationSize = (uint32_t)neededBytes;
            header->capacity = (uint32_t)(owner + neededBytes - userAddress);
            header->requestedSize = (uint32_t)requested;
            atomic_fetch_add_explicit(&g_mallocBytesAllocated, neededBytes - currentBytes, memory_order_relaxed);
            atomic_fetch_add_explicit(&rd_stat_shard()->bytes, (int64_t)requested - (int64_t)oldRequested,
                                      memory_order_relaxed);

            return pointer;
        }
    }

    const size_t alignment = header->kind == RD_MALLOC_KIND_LARGE ? MAX((size_t)header->classIndex, (size_t)16) : 16;
    void *replacement = rd_malloc_zone_allocate(requested, alignment, NO);

    if (!replacement && g_origMalloc)
    {
        replacement = g_origMalloc(requested);
    }

    if (!replacement)
    {
        return NULL;
    }

    memcpy(replacement, pointer, MIN((size_t)oldRequested, requested));
    rd_malloc_zone_free_pointer(pointer);
    return replacement;
}

static size_t rd_malloc_zone_size(malloc_zone_t *zone, const void *pointer)
{
    RDMallocAllocationHeader *header = rd_malloc_header_for_pointer(pointer);
    return header ? (size_t)header->capacity : 0;
}

static void *rd_malloc_zone_malloc(malloc_zone_t *zone, size_t size)
{
    return rd_malloc_zone_allocate(size, 16, NO);
}

static void *rd_malloc_zone_calloc(malloc_zone_t *zone, size_t count, size_t size)
{
    if (count && size > SIZE_MAX / count)
    {
        errno = ENOMEM;
        return NULL;
    }

    return rd_malloc_zone_allocate(count * size, 16, YES);
}

static void *rd_malloc_zone_valloc(malloc_zone_t *zone, size_t size)
{
    return rd_malloc_zone_allocate(size, vm_page_size, NO);
}

static void rd_malloc_zone_free(malloc_zone_t *zone, void *pointer)
{
    rd_malloc_zone_free_pointer(pointer);
}

static void *rd_malloc_zone_realloc(malloc_zone_t *zone, void *pointer, size_t size)
{
    return rd_malloc_zone_reallocate(pointer, size);
}

static void rd_malloc_zone_destroy(malloc_zone_t *zone)
{
}

static unsigned rd_malloc_zone_batch_malloc(malloc_zone_t *zone, size_t size, void **results, unsigned count)
{
    unsigned allocated = 0;

    while (allocated < count)
    {
        void *pointer = rd_malloc_zone_allocate(size, 16, NO);

        if (!pointer)
        {
            break;
        }

        results[allocated++] = pointer;
    }

    return allocated;
}

static void rd_malloc_zone_batch_free(malloc_zone_t *zone, void **pointers, unsigned count)
{
    for (unsigned i = 0; i < count; i++)
    {
        rd_malloc_zone_free_pointer(pointers[i]);
    }
}

static void *rd_malloc_zone_memalign(malloc_zone_t *zone, size_t alignment, size_t size)
{
    if (alignment < sizeof(void *) || (alignment & (alignment - 1)) != 0)
    {
        return NULL;
    }

    return rd_malloc_zone_allocate(size, alignment, NO);
}

static void rd_malloc_zone_free_definite_size(malloc_zone_t *zone, void *pointer, size_t size)
{
    rd_malloc_zone_free_pointer(pointer);
}

static size_t rd_malloc_zone_pressure_relief(malloc_zone_t *zone, size_t goal)
{
    return (size_t)rd_pool_trim_guarded(goal, YES);
}

static boolean_t rd_malloc_zone_claimed_address(malloc_zone_t *zone, void *pointer)
{
    return rd_malloc_header_for_pointer(pointer) != NULL;
}

static kern_return_t rd_malloc_zone_enumerator(task_t task, void *context, unsigned typeMask,
                                                vm_address_t zoneAddress, memory_reader_t reader,
                                                vm_range_recorder_t recorder)
{
    return KERN_FAILURE;
}

static size_t rd_malloc_zone_good_size(malloc_zone_t *zone, size_t size)
{
    const size_t actualSize = MAX(size, (size_t)1);
    if (actualSize <= RD_MALLOC_MAX_CLASS_BLOCK_SIZE - sizeof(RDMallocAllocationHeader))
    {
        return rd_malloc_align_size(actualSize + sizeof(RDMallocAllocationHeader), 16) - sizeof(RDMallocAllocationHeader);
    }

    if (actualSize > SIZE_MAX - sizeof(RDMallocAllocationHeader) - ((size_t)vm_page_size - 1))
    {
        return 0;
    }

    return (size_t)rd_round_page(actualSize + sizeof(RDMallocAllocationHeader)) - sizeof(RDMallocAllocationHeader);
}

static boolean_t rd_malloc_zone_check(malloc_zone_t *zone)
{
    return atomic_load_explicit(&g_poolReady, memory_order_acquire) != 0;
}

static void rd_malloc_zone_print(malloc_zone_t *zone, boolean_t verbose)
{
}

static void rd_malloc_zone_log(malloc_zone_t *zone, void *address)
{
}

static void rd_malloc_zone_force_lock(malloc_zone_t *zone)
{
    for (int i = 0; i < RD_MALLOC_SMALL_CLASS_COUNT; i++)
    {
        os_unfair_lock_lock(&g_classBins[i].lock);
    }

    os_unfair_lock_lock(&g_pool.lock);
}

static void rd_malloc_zone_force_unlock(malloc_zone_t *zone)
{
    os_unfair_lock_unlock(&g_pool.lock);

    for (int i = RD_MALLOC_SMALL_CLASS_COUNT - 1; i >= 0; i--)
    {
        os_unfair_lock_unlock(&g_classBins[i].lock);
    }
}

static void rd_malloc_zone_statistics(malloc_zone_t *zone, malloc_statistics_t *stats)
{
    if (!stats)
    {
        return;
    }

    memset(stats, 0, sizeof(*stats));

    uint64_t blocks = 0;
    uint64_t bytes = 0;
    rd_malloc_sum_stats(&blocks, &bytes);

    uint64_t peak = atomic_load_explicit(&g_mallocPeakBytesInUse, memory_order_relaxed);

    while (bytes > peak && !atomic_compare_exchange_weak_explicit(&g_mallocPeakBytesInUse, &peak, bytes,
                                                                   memory_order_relaxed, memory_order_relaxed))
    {
    }

    stats->blocks_in_use = (unsigned)blocks;
    stats->size_in_use = bytes;
    stats->max_size_in_use = MAX(peak, bytes);
    stats->size_allocated = atomic_load_explicit(&g_mallocBytesAllocated, memory_order_relaxed);
}

static boolean_t rd_malloc_zone_locked(malloc_zone_t *zone)
{
    return false;
}

static void rd_malloc_zone_reinit_lock(malloc_zone_t *zone)
{
    for (int i = 0; i < RD_MALLOC_SMALL_CLASS_COUNT; i++)
    {
        g_classBins[i].lock = OS_UNFAIR_LOCK_INIT;
    }

    g_pool.lock = OS_UNFAIR_LOCK_INIT;
}

static void rd_malloc_zone_register(void)
{
    uint8_t expected = 0;

    if (!atomic_compare_exchange_strong_explicit(&g_mallocZoneRegistered, &expected, 1,
                                                  memory_order_acq_rel, memory_order_acquire))
    {
        return;
    }

    memset(&g_mallocZone, 0, sizeof(g_mallocZone));
    memset(&g_mallocIntrospection, 0, sizeof(g_mallocIntrospection));

    g_mallocIntrospection.enumerator = rd_malloc_zone_enumerator;
    g_mallocIntrospection.good_size = rd_malloc_zone_good_size;
    g_mallocIntrospection.check = rd_malloc_zone_check;
    g_mallocIntrospection.print = rd_malloc_zone_print;
    g_mallocIntrospection.log = rd_malloc_zone_log;
    g_mallocIntrospection.force_lock = rd_malloc_zone_force_lock;
    g_mallocIntrospection.force_unlock = rd_malloc_zone_force_unlock;
    g_mallocIntrospection.statistics = rd_malloc_zone_statistics;
    g_mallocIntrospection.zone_locked = rd_malloc_zone_locked;
    g_mallocIntrospection.reinit_lock = rd_malloc_zone_reinit_lock;

    g_mallocZone.size = rd_malloc_zone_size;
    g_mallocZone.malloc = rd_malloc_zone_malloc;
    g_mallocZone.calloc = rd_malloc_zone_calloc;
    g_mallocZone.valloc = rd_malloc_zone_valloc;
    g_mallocZone.free = rd_malloc_zone_free;
    g_mallocZone.realloc = rd_malloc_zone_realloc;
    g_mallocZone.destroy = rd_malloc_zone_destroy;
    g_mallocZone.zone_name = "Donated Malloc";
    g_mallocZone.batch_malloc = rd_malloc_zone_batch_malloc;
    g_mallocZone.batch_free = rd_malloc_zone_batch_free;
    g_mallocZone.introspect = &g_mallocIntrospection;
    g_mallocZone.version = 10;
    g_mallocZone.memalign = rd_malloc_zone_memalign;
    g_mallocZone.free_definite_size = rd_malloc_zone_free_definite_size;
    g_mallocZone.pressure_relief = rd_malloc_zone_pressure_relief;
    g_mallocZone.claimed_address = rd_malloc_zone_claimed_address;

    malloc_zone_register(&g_mallocZone);
    atomic_store_explicit(&g_mallocZoneRegistered, 2, memory_order_release);
}

static BOOL rd_malloc_redirect_enabled(void)
{
    return atomic_load_explicit(&g_mallocAllocationEnabled, memory_order_acquire) != 0 &&
           atomic_load_explicit(&g_poolReady, memory_order_acquire) != 0 &&
           atomic_load_explicit(&g_mallocZoneRegistered, memory_order_acquire) == 2;
}

static inline BOOL rd_malloc_should_redirect(size_t size)
{
    return size >= rd_donated_min_allocation() && rd_malloc_redirect_enabled();
}

static void *rd_hook_malloc(size_t size)
{
    RD_PROFILE_LARGE(RDProfileMalloc, size);

    if (rd_malloc_should_redirect(size))
    {
        void *pointer = rd_malloc_zone_allocate(size, 16, NO);

        if (pointer)
        {
            return pointer;
        }
    }

    return g_origMalloc(size);
}

static void *rd_hook_calloc(size_t count, size_t size)
{
    if (count && size > SIZE_MAX / count)
    {
        return g_origCalloc(count, size);
    }

    RD_PROFILE_LARGE(RDProfileCalloc, count * size);

    if (rd_malloc_should_redirect(count * size))
    {
        void *pointer = rd_malloc_zone_allocate(count * size, 16, YES);

        if (pointer)
        {
            return pointer;
        }
    }

    return g_origCalloc(count, size);
}

static void rd_hook_free(void *pointer)
{
    if (rd_malloc_header_for_pointer(pointer))
    {
        rd_malloc_zone_free_pointer(pointer);
        return;
    }

    g_origFree(pointer);
}

static void *rd_hook_realloc(void *pointer, size_t size)
{
    if (!pointer)
    {
        return rd_hook_malloc(size);
    }

    if (rd_malloc_header_for_pointer(pointer))
    {
        return rd_malloc_zone_reallocate(pointer, size);
    }

    return g_origRealloc(pointer, size);
}

static size_t rd_hook_malloc_size(const void *pointer)
{
    RDMallocAllocationHeader *header = rd_malloc_header_for_pointer(pointer);
    return header ? (size_t)header->capacity : g_origMallocSize(pointer);
}

static void *rd_hook_valloc(size_t size)
{
    RD_PROFILE_LARGE(RDProfileValloc, size);

    if (rd_malloc_should_redirect(size))
    {
        void *pointer = rd_malloc_zone_allocate(size, vm_page_size, NO);

        if (pointer)
        {
            return pointer;
        }
    }

    return g_origValloc(size);
}

static int rd_hook_posix_memalign(void **pointer, size_t alignment, size_t size)
{
    RD_PROFILE_LARGE(RDProfileMemalign, size);

    if (!pointer)
    {
        return EINVAL;
    }

    if (rd_malloc_should_redirect(size) && alignment >= sizeof(void *) &&
        (alignment & (alignment - 1)) == 0)
    {
        void *allocated = rd_malloc_zone_allocate(size, alignment, NO);

        if (allocated)
        {
            *pointer = allocated;
            return 0;
        }
    }

    return g_origPosixMemalign(pointer, alignment, size);
}

static void *rd_hook_aligned_alloc(size_t alignment, size_t size)
{
    RD_PROFILE_LARGE(RDProfileMemalign, size);

    if (rd_malloc_should_redirect(size) && alignment >= sizeof(void *) &&
        (alignment & (alignment - 1)) == 0 && size % alignment == 0)
    {
        void *pointer = rd_malloc_zone_allocate(size, alignment, NO);

        if (pointer)
        {
            return pointer;
        }
    }

    return g_origAlignedAlloc(alignment, size);
}

static void *rd_hook_memalign(size_t alignment, size_t size)
{
    RD_PROFILE_LARGE(RDProfileMemalign, size);

    if (rd_malloc_should_redirect(size) && alignment >= sizeof(void *) &&
        (alignment & (alignment - 1)) == 0)
    {
        void *pointer = rd_malloc_zone_allocate(size, alignment, NO);

        if (pointer)
        {
            return pointer;
        }
    }

    return g_origMemalign(alignment, size);
}

static void *rd_hook_malloc_type_malloc(size_t size, uintptr_t typeID)
{
    RD_PROFILE_LARGE(RDProfileMalloc, size);

    if (rd_malloc_should_redirect(size))
    {
        void *pointer = rd_malloc_zone_allocate(size, 16, NO);

        if (pointer)
        {
            return pointer;
        }
    }

    return g_origMallocTypeMalloc ? g_origMallocTypeMalloc(size, typeID) : g_origMalloc(size);
}

static void *rd_hook_malloc_type_calloc(size_t count, size_t size, uintptr_t typeID)
{
    if (!count || size <= SIZE_MAX / count)
    {
        RD_PROFILE_LARGE(RDProfileCalloc, count * size);

        if (rd_malloc_should_redirect(count * size))
        {
            void *pointer = rd_malloc_zone_allocate(count * size, 16, YES);

            if (pointer)
            {
                return pointer;
            }
        }
    }

    return g_origMallocTypeCalloc ? g_origMallocTypeCalloc(count, size, typeID) : g_origCalloc(count, size);
}

static void *rd_hook_malloc_type_realloc(void *pointer, size_t size, uintptr_t typeID)
{
    if (!pointer)
    {
        return rd_hook_malloc_type_malloc(size, typeID);
    }

    if (rd_malloc_header_for_pointer(pointer))
    {
        return rd_malloc_zone_reallocate(pointer, size);
    }

    return g_origMallocTypeRealloc ? g_origMallocTypeRealloc(pointer, size, typeID) : g_origRealloc(pointer, size);
}

static void *rd_hook_malloc_type_memalign(size_t alignment, size_t size, uintptr_t typeID)
{
    RD_PROFILE_LARGE(RDProfileMemalign, size);

    if (rd_malloc_should_redirect(size) && alignment >= sizeof(void *) &&
        (alignment & (alignment - 1)) == 0)
    {
        void *pointer = rd_malloc_zone_allocate(size, alignment, NO);

        if (pointer)
        {
            return pointer;
        }
    }

    return g_origMallocTypeMemalign ? g_origMallocTypeMemalign(alignment, size, typeID) : g_origMemalign(alignment, size);
}

static void rd_rebind_section(const struct section_64 *section, intptr_t slide,
                              const struct nlist_64 *symbols, const char *strings,
                              const uint32_t *indirect)
{
    const uint32_t *indices = indirect + section->reserved1;
    void **slots = (void **)(section->addr + slide);
    const size_t count = section->size / sizeof(void *);
    const BOOL isConst = strcmp(section->segname, "__DATA_CONST") == 0;

    BOOL unlocked = NO;
    const uintptr_t pageMask = (uintptr_t)vm_page_size - 1;
    const uintptr_t regionStart = (uintptr_t)slots & ~pageMask;
    const uintptr_t regionEnd = ((uintptr_t)slots + section->size + pageMask) & ~pageMask;

    for (size_t i = 0; i < count; i++)
    {
        const uint32_t index = indices[i];

        if (index == INDIRECT_SYMBOL_ABS || index == INDIRECT_SYMBOL_LOCAL ||
            index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS))
        {
            continue;
        }

        const char *name = strings + symbols[index].n_un.n_strx;

        if (name[0] != '_')
        {
            continue;
        }

        void *replacement = NULL;

        if (strcmp(name + 1, "mmap") == 0)
        {
            replacement = (void *)rd_hook_mmap;
        }
        else if (strcmp(name + 1, "munmap") == 0)
        {
            replacement = (void *)rd_hook_munmap;
        }
        else if (strcmp(name + 1, "malloc_type_malloc") == 0 && g_origMallocTypeMalloc)
        {
            replacement = (void *)rd_hook_malloc_type_malloc;
        }
        else if (strcmp(name + 1, "malloc_type_calloc") == 0 && g_origMallocTypeCalloc)
        {
            replacement = (void *)rd_hook_malloc_type_calloc;
        }
        else if (strcmp(name + 1, "malloc_type_realloc") == 0 && g_origMallocTypeRealloc)
        {
            replacement = (void *)rd_hook_malloc_type_realloc;
        }
        else if (strcmp(name + 1, "malloc_type_memalign") == 0 && g_origMallocTypeMemalign)
        {
            replacement = (void *)rd_hook_malloc_type_memalign;
        }
        else if (strcmp(name + 1, "malloc") == 0 && g_origMalloc)
        {
            replacement = (void *)rd_hook_malloc;
        }
        else if (strcmp(name + 1, "calloc") == 0 && g_origCalloc)
        {
            replacement = (void *)rd_hook_calloc;
        }
        else if (strcmp(name + 1, "free") == 0 && g_origFree)
        {
            replacement = (void *)rd_hook_free;
        }
        else if (strcmp(name + 1, "realloc") == 0 && g_origRealloc)
        {
            replacement = (void *)rd_hook_realloc;
        }
        else if (strcmp(name + 1, "malloc_size") == 0 && g_origMallocSize)
        {
            replacement = (void *)rd_hook_malloc_size;
        }
        else if (strcmp(name + 1, "valloc") == 0 && g_origValloc)
        {
            replacement = (void *)rd_hook_valloc;
        }
        else if (strcmp(name + 1, "posix_memalign") == 0 && g_origPosixMemalign)
        {
            replacement = (void *)rd_hook_posix_memalign;
        }
        else if (strcmp(name + 1, "aligned_alloc") == 0 && g_origAlignedAlloc)
        {
            replacement = (void *)rd_hook_aligned_alloc;
        }
        else if (strcmp(name + 1, "memalign") == 0 && g_origMemalign)
        {
            replacement = (void *)rd_hook_memalign;
        }
        else if (strcmp(name + 1, "vm_allocate") == 0)
        {
            replacement = (void *)rd_hook_vm_allocate;
        }
        else if (strcmp(name + 1, "mach_vm_allocate") == 0)
        {
            replacement = (void *)rd_hook_mach_vm_allocate;
        }
        else if (strcmp(name + 1, "vm_deallocate") == 0)
        {
            replacement = (void *)rd_hook_vm_deallocate;
        }
        else if (strcmp(name + 1, "mach_vm_deallocate") == 0)
        {
            replacement = (void *)rd_hook_mach_vm_deallocate;
        }
        else
        {
            continue;
        }

        if (slots[i] == replacement)
        {
            continue;
        }

        if (isConst && !unlocked)
        {
            if (vm_protect(mach_task_self(), regionStart, regionEnd - regionStart, FALSE,
                           VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS)
            {
                return;
            }

            unlocked = YES;
        }

        slots[i] = replacement;
    }

    if (unlocked)
    {
        vm_protect(mach_task_self(), regionStart, regionEnd - regionStart, FALSE, VM_PROT_READ);
    }
}

static void rd_rebind_image(const struct mach_header_64 *header, intptr_t slide)
{
    if (header->magic != MH_MAGIC_64)
    {
        return;
    }

    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    const struct segment_command_64 *segments[4];
    int segmentCount = 0;

    const uint8_t *cursor = (const uint8_t *)(header + 1);

    for (uint32_t i = 0; i < header->ncmds; i++)
    {
        const struct load_command *command = (const struct load_command *)cursor;

        if (command->cmd == LC_SEGMENT_64)
        {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;

            if (strcmp(segment->segname, SEG_LINKEDIT) == 0)
            {
                linkedit = segment;
            }
            else if ((strcmp(segment->segname, SEG_DATA) == 0 ||
                      strcmp(segment->segname, "__DATA_CONST") == 0) && segmentCount < 4)
            {
                segments[segmentCount++] = segment;
            }
        }
        else if (command->cmd == LC_SYMTAB)
        {
            symtab = (const struct symtab_command *)command;
        }
        else if (command->cmd == LC_DYSYMTAB)
        {
            dysymtab = (const struct dysymtab_command *)command;
        }

        cursor += command->cmdsize;
    }

    if (!symtab || !dysymtab || !linkedit || dysymtab->nindirectsyms == 0)
    {
        return;
    }

    const uintptr_t linkeditBase = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symbols = (const struct nlist_64 *)(linkeditBase + symtab->symoff);
    const char *strings = (const char *)(linkeditBase + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(linkeditBase + dysymtab->indirectsymoff);

    for (int s = 0; s < segmentCount; s++)
    {
        const struct section_64 *sections =
            (const struct section_64 *)((uintptr_t)segments[s] + sizeof(struct segment_command_64));

        for (uint32_t j = 0; j < segments[s]->nsects; j++)
        {
            const uint32_t type = sections[j].flags & SECTION_TYPE;

            if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS)
            {
                rd_rebind_section(&sections[j], slide, symbols, strings, indirect);
            }
        }
    }
}

static void rd_image_added(const struct mach_header *header, intptr_t slide)
{
    Dl_info info;

    if (!dladdr(header, &info) || !info.dli_fname)
    {
        return;
    }

    if (strncmp(info.dli_fname, "/System/", 8) == 0 || strncmp(info.dli_fname, "/usr/", 5) == 0)
    {
        return;
    }

    char resolved[PATH_MAX];

    if (!realpath(info.dli_fname, resolved) ||
        strncmp(resolved, g_bundlePrefix, g_bundlePrefixLength) != 0)
    {
        return;
    }

    rd_rebind_image((const struct mach_header_64 *)header, slide);
}

static BOOL rd_install_rebinds(void)
{
    static dispatch_once_t once;
    static BOOL installed;

    dispatch_once(&once, ^{
        g_origMmap = dlsym(RTLD_DEFAULT, "mmap");
        g_origMunmap = dlsym(RTLD_DEFAULT, "munmap");
        g_origMalloc = dlsym(RTLD_DEFAULT, "malloc");
        g_origCalloc = dlsym(RTLD_DEFAULT, "calloc");
        g_origRealloc = dlsym(RTLD_DEFAULT, "realloc");
        g_origFree = dlsym(RTLD_DEFAULT, "free");
        g_origMallocSize = dlsym(RTLD_DEFAULT, "malloc_size");
        g_origValloc = dlsym(RTLD_DEFAULT, "valloc");
        g_origPosixMemalign = dlsym(RTLD_DEFAULT, "posix_memalign");
        g_origAlignedAlloc = dlsym(RTLD_DEFAULT, "aligned_alloc");
        g_origMemalign = dlsym(RTLD_DEFAULT, "memalign");
        g_origMallocTypeMalloc = dlsym(RTLD_DEFAULT, "malloc_type_malloc");
        g_origMallocTypeCalloc = dlsym(RTLD_DEFAULT, "malloc_type_calloc");
        g_origMallocTypeRealloc = dlsym(RTLD_DEFAULT, "malloc_type_realloc");
        g_origMallocTypeMemalign = dlsym(RTLD_DEFAULT, "malloc_type_memalign");
        g_origVmAllocate = dlsym(RTLD_DEFAULT, "vm_allocate");
        g_origMachVmAllocate = dlsym(RTLD_DEFAULT, "mach_vm_allocate");
        g_origVmDeallocate = dlsym(RTLD_DEFAULT, "vm_deallocate");
        g_origMachVmDeallocate = dlsym(RTLD_DEFAULT, "mach_vm_deallocate");

        const char *bundlePath = NSBundle.mainBundle.bundlePath.fileSystemRepresentation;

        if (!g_origMmap || !g_origMunmap || !g_origVmAllocate || !g_origMachVmAllocate ||
            !g_origVmDeallocate || !g_origMachVmDeallocate || !bundlePath || !realpath(bundlePath, g_bundlePrefix))
        {
            RDLog(@"could not resolve libsystem symbols or the bundle path, hooks not installed");
            return;
        }

        g_bundlePrefixLength = strlen(g_bundlePrefix);
        _dyld_register_func_for_add_image(rd_image_added);
        installed = YES;
    });

    return installed;
}

static uint64_t rd_donated_target_bytes(void)
{
    return kRDDonatedTargetBytes;
}

static void rd_ram_bypass_start(void)
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!LoRRamDonor.donorBundleIdentifier)
        {
            RDLog(@"the donor extension is not embedded in this build, running without it");
            return;
        }

        LoRRamDonor *donor = LoRRamDonor.shared;
        donor.killDonorsAfterMapping = YES;

        const uint64_t target = rd_donated_target_bytes();
        const uint64_t minimum = MIN(kRDDonatedMinimumBytes, target);

        RDLog(@"device has %llu MB, requesting a %llu MB pool",
             NSProcessInfo.processInfo.physicalMemory / (1024 * 1024), target / (1024 * 1024));

        uint64_t granted = 0;
        void *mapped = [donor acquireUpTo:target
                                  minimum:minimum
                                   actual:&granted];

        if (!mapped || granted == 0)
        {
            RDLog(@"could not source donor memory: %@", donor.lastError ?: @"unknown error");
            return;
        }

        if (!rd_pool_install(mapped, granted))
        {
            RDLog(@"could not allocate pool bookkeeping, running without it");
            [donor releaseRegionAt:mapped];
        }
    });
}

static size_t rd_back_range(uint8_t *base, size_t size, const char *what)
{
    if (!base || size == 0)
    {
        return 0;
    }

    LoRRamDonor *donor = LoRRamDonor.shared;
    donor.killDonorsAfterMapping = YES;

    const uint64_t minimum = MIN(kRDDonatedMinimumBytes, (uint64_t)size);
    uint64_t granted = 0;
    void *mapped = [donor acquireInto:base size:size minimum:minimum actual:&granted];

    if (!mapped || granted == 0)
    {
        RDLog(@"could not back the guest %s with donor memory: %@", what, donor.lastError ?: @"unknown error");
        return 0;
    }

    if (mprotect(base, (size_t)granted, PROT_NONE) != 0)
    {
        RDLog(@"guest %s: the donated range could not be made inaccessible again, errno %d", what, errno);
    }

    RDLog(@"guest %s: %llu of %llu MB backed by donor memory", what, granted / (1024 * 1024), (uint64_t)size / (1024 * 1024));

    return (size_t)granted;
}

size_t rd_ram_extend_guest(uint8_t *heap, size_t heapSize, uint8_t *alias, size_t aliasSize)
{
    static dispatch_once_t once;
    __block size_t backed = 0;

    dispatch_once(&once, ^{
        if (!rd_ram_bypass_enabled())
        {
            return;
        }

        atomic_store_explicit(&g_redirectMinimum, rd_redirect_minimum_from_env(), memory_order_release);
        atomic_store_explicit(&g_mallocAllocationEnabled, 1, memory_order_release);

        if (!rd_ram_bypass_available())
        {
            RDLog(@"Extend Memory Usage is on, but the donor extension is not embedded in this build");
            return;
        }

        if (!rd_install_rebinds())
        {
            return;
        }

        backed += rd_back_range(heap, heapSize, "heap");
        backed += rd_back_range(alias, aliasSize, "alias region");

        rd_ram_bypass_start();
    });

    return backed;
}

extern void (*dm_guest_backing_hook)(uint8_t *heap, size_t heapSize, uint8_t *alias, size_t aliasSize);

static void rd_guest_backing_entry(uint8_t *heap, size_t heapSize, uint8_t *alias, size_t aliasSize)
{
    rd_ram_extend_guest(heap, heapSize, alias, aliasSize);
}

void rd_ram_register_guest_hook(void)
{
    dm_guest_backing_hook = rd_guest_backing_entry;
}
