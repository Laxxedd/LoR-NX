// Memory facts the launcher shows: whether the Increased Memory Limit entitlement is active for this process, and whether the memory donor extension is in the app.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import "DmMemoryInfo.h"
#import "RamDonor.h"

typedef CFTypeRef SecTaskRefOpaque;

// SecTaskCreateFromSelf / SecTaskCopyValueForEntitlement are in Security.framework on iOS but not in its public headers: looked up by name. They report the entitlements of the code signature
// the kernel holds for this process, which is what a sideloader's re-signing leaves in force (not what the build asked for)
static bool process_has_entitlement(NSString *key) {
    typedef SecTaskRefOpaque (*create_fn)(CFAllocatorRef);
    typedef CFTypeRef (*copy_fn)(SecTaskRefOpaque, CFStringRef, CFErrorRef *);
    create_fn create = (create_fn)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    copy_fn copy = (copy_fn)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!create || !copy) return false;
    SecTaskRefOpaque task = create(kCFAllocatorDefault);
    if (!task) return false;
    CFTypeRef value = copy(task, (__bridge CFStringRef)key, NULL);
    CFRelease(task);
    if (!value) return false;
    bool on = CFGetTypeID(value) == CFBooleanGetTypeID() ? CFBooleanGetValue((CFBooleanRef)value) : true;
    CFRelease(value);
    return on;
}

bool dm_has_increased_memory_entitlement(void) {
    return process_has_entitlement(@"com.apple.developer.kernel.increased-memory-limit");
}

bool dm_ram_donor_embedded(void) {
    return LoRRamDonor.donorBundleIdentifier.length > 0;
}
