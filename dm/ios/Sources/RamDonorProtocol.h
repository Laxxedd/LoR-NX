/*
 * Credits: this file is based on code from the MeloNX iOS sideloading project
 * (https://starforgejo.dev/projects/MeloNX), modified and adapted by the
 * ZSingularity project (RamBypass), and ported from there to this host.
 */

#ifndef RamDonorProtocol_h
#define RamDonorProtocol_h

@import Foundation;
#import <mach/mach.h>
#import <xpc/xpc.h>

#define RD_DONOR_CHUNK_SIZE (256ull * 1024ull * 1024ull)

#define RDDonorKeyOp        "op"
#define RDDonorKeySize      "size"
#define RDDonorKeyShmem     "shmem"
#define RDDonorKeyError     "error"
#define RDDonorKeyAvailable "available"

#define RDDonorOpCreate     "create"
#define RDDonorOpRelease    "release"
#define RDDonorOpAvailable  "available"

NS_ASSUME_NONNULL_BEGIN

@interface NSXPCListenerEndpoint (RDPrivate)
@property (nonatomic, setter=_setEndpoint:) xpc_object_t _endpoint;
@end

static inline NSXPCListenerEndpoint *RDWrapEndpoint(xpc_endpoint_t endpoint)
{
    NSXPCListenerEndpoint *wrapper = [NSXPCListenerEndpoint new];
    wrapper._endpoint = endpoint;

    return wrapper;
}

static inline xpc_endpoint_t _Nullable RDUnwrapEndpoint(NSXPCListenerEndpoint *_Nullable wrapper)
{
    xpc_object_t inner = wrapper._endpoint;

    if (!inner || xpc_get_type(inner) != XPC_TYPE_ENDPOINT)
    {
        return nil;
    }

    return (xpc_endpoint_t)inner;
}

NS_ASSUME_NONNULL_END

#endif
