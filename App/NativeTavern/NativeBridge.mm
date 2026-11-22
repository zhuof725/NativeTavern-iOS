#include "NativeBridge.h"
#include <TargetConditionals.h>
#include <sys/sysctl.h>
#include <array>
#include <atomic>
#include <cstring>
#include <string>
#include <vector>

extern "C" int node_start(int argc, char *argv[]);

static bool runtimeCPUIsSupported() {
#if TARGET_OS_SIMULATOR
    return true;
#else
    // The pinned NodeMobile build uses ARM LSE atomics. A device that reports
    // the feature off would crash inside V8, so it is not started. A device that
    // does not report the key at all is not evidence of absence — older
    // sysctl names are absent on some releases — so it is allowed to try.
    for (const char *key : {"hw.optional.arm.FEAT_LSE", "hw.optional.armv8_1_atomics"}) {
        int enabled = 0;
        size_t size = sizeof(enabled);
        if (sysctlbyname(key, &enabled, &size, nullptr, 0) == 0) return enabled != 0;
    }
    return true;
#endif
}

int32_t NTStartEmbeddedNode(const char *scriptPath, const char *dataRoot, const char *launchID) {
    if (!scriptPath || !dataRoot || !launchID) return -3;
    if (!runtimeCPUIsSupported()) return -4;
    static std::atomic<bool> entered{false};
    bool expected = false;
    if (!entered.compare_exchange_strong(expected, true)) return -2;

    const std::array<std::string, 4> arguments{"node", scriptPath, dataRoot, launchID};
    size_t byteCount = 0;
    for (const auto &argument : arguments) byteCount += argument.size() + 1;
    // libuv may rewrite argv: all argument strings must live in one mutable allocation.
    std::vector<char> storage(byteCount);
    std::vector<char *> argv;
    argv.reserve(arguments.size() + 1);
    size_t offset = 0;
    for (const auto &argument : arguments) {
        char *start = storage.data() + offset;
        std::memcpy(start, argument.c_str(), argument.size() + 1);
        argv.push_back(start);
        offset += argument.size() + 1;
    }
    argv.push_back(nullptr);
    return node_start(static_cast<int>(arguments.size()), argv.data());
}
