/*
 * Credits: this file is based on code from the MeloNX iOS sideloading project
 * (https://starforgejo.dev/projects/MeloNX), modified and adapted by the
 * ZSingularity project (RamBypass), and ported from there to this host.
 */

#ifndef RamDonor_h
#define RamDonor_h

@import Foundation;

NS_ASSUME_NONNULL_BEGIN

#define RDLog(...) do { NSString *rd_msg_ = [NSString stringWithFormat:__VA_ARGS__]; flockfile(stderr); fprintf(stderr, "[dm] ramdonor: %s\n", rd_msg_.UTF8String); funlockfile(stderr); } while (0)

@interface LoRRamDonor : NSObject

@property (class, readonly) LoRRamDonor *shared;
@property (class, readonly, nullable) NSString *donorBundleIdentifier;
@property (class, readonly) NSArray<NSString *> *donorBundleIdentifiers;
@property (readonly) NSUInteger liveDonorCount;
@property (nonatomic) NSUInteger maxDonors;
@property (nonatomic) BOOL killDonorsAfterMapping;
@property (nonatomic, readonly, copy, nullable) NSString *lastError;

- (nullable void *)acquireUpTo:(uint64_t)size
                       minimum:(uint64_t)minimum
                        actual:(uint64_t *_Nullable)actual;
- (nullable void *)acquireInto:(void *)base
                          size:(uint64_t)size
                       minimum:(uint64_t)minimum
                        actual:(uint64_t *_Nullable)actual;
- (void)releaseRegionAt:(void *)base;
- (uint64_t)donatedBytes;
- (void)killDonorProcesses;
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END

#endif
