#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Blocking call. Run on a dedicated thread; only one call per app process.
int32_t NTStartEmbeddedNode(const char *scriptPath, const char *dataRoot, const char *launchID);

#ifdef __cplusplus
}
#endif
