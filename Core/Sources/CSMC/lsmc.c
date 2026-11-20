#include "lsmc.h"
#include <string.h>
#include <mach/mach.h>

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} LSMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} LSMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} LSMCKeyInfo;

typedef struct {
    uint32_t key;
    LSMCVersion vers;
    LSMCPLimitData pLimitData;
    LSMCKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} LSMCParam;

_Static_assert(sizeof(LSMCParam) == 80, "SMC param struct must be 80 bytes");

size_t lsmc_param_size(void) { return sizeof(LSMCParam); }

kern_return_t lsmc_open(io_connect_t *out) {
    io_service_t service = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) return kIOReturnNotFound;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, out);
    IOObjectRelease(service);
    return kr;
}

void lsmc_close(io_connect_t conn) {
    if (conn) IOServiceClose(conn);
}

static kern_return_t lsmc_call(io_connect_t conn, LSMCParam *in, LSMCParam *out) {
    size_t outSize = sizeof(LSMCParam);
    memset(out, 0, sizeof(LSMCParam));
    return IOConnectCallStructMethod(conn, 2, in, sizeof(LSMCParam), out, &outSize);
}

kern_return_t lsmc_key_info(io_connect_t conn, uint32_t key, uint32_t *dataSize,
                            uint32_t *dataType, uint8_t *attributes, uint8_t *smcResult) {
    LSMCParam in, out;
    memset(&in, 0, sizeof(in));
    in.key = key;
    in.data8 = LSMC_CMD_READ_KEYINFO;
    kern_return_t kr = lsmc_call(conn, &in, &out);
    if (smcResult) *smcResult = out.result;
    if (kr != KERN_SUCCESS) return kr;
    if (dataSize) *dataSize = out.keyInfo.dataSize;
    if (dataType) *dataType = out.keyInfo.dataType;
    if (attributes) *attributes = out.keyInfo.dataAttributes;
    return kr;
}

kern_return_t lsmc_read(io_connect_t conn, uint32_t key, uint32_t dataSize,
                        uint8_t outBytes[32], uint8_t *smcResult) {
    LSMCParam in, out;
    memset(&in, 0, sizeof(in));
    in.key = key;
    in.keyInfo.dataSize = dataSize;
    in.data8 = LSMC_CMD_READ_BYTES;
    kern_return_t kr = lsmc_call(conn, &in, &out);
    if (smcResult) *smcResult = out.result;
    if (kr != KERN_SUCCESS) return kr;
    memcpy(outBytes, out.bytes, 32);
    return kr;
}

kern_return_t lsmc_write(io_connect_t conn, uint32_t key, uint32_t dataSize,
                         const uint8_t *bytes, uint8_t *smcResult) {
    if (dataSize > 32) return kIOReturnBadArgument;
    LSMCParam in, out;
    memset(&in, 0, sizeof(in));
    in.key = key;
    in.keyInfo.dataSize = dataSize;
    in.data8 = LSMC_CMD_WRITE_BYTES;
    memcpy(in.bytes, bytes, dataSize);
    kern_return_t kr = lsmc_call(conn, &in, &out);
    if (smcResult) *smcResult = out.result;
    return kr;
}

kern_return_t lsmc_key_at_index(io_connect_t conn, uint32_t index, uint32_t *key, uint8_t *smcResult) {
    LSMCParam in, out;
    memset(&in, 0, sizeof(in));
    in.data8 = LSMC_CMD_READ_INDEX;
    in.data32 = index;
    kern_return_t kr = lsmc_call(conn, &in, &out);
    if (smcResult) *smcResult = out.result;
    if (kr == KERN_SUCCESS && key) *key = out.key;
    return kr;
}
