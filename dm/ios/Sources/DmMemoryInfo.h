// Memory facts the launcher shows (DmMemoryInfo.m); the Swift launcher reads them through the bridging header.
#import <stdbool.h>

bool dm_has_increased_memory_entitlement(void);   // the process carries com.apple.developer.kernel.increased-memory-limit, as the kernel sees it
bool dm_ram_donor_embedded(void);                 // the app carries the LoRRamDonor extension that Extend Memory Usage needs
