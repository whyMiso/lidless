#ifndef LIDLESS_SMC_H
#define LIDLESS_SMC_H

#include <stdint.h>
#include <IOKit/IOKitLib.h>

// Raw AppleSMC user-client protocol (same layout as smcFanControl / Stats).
// Every call goes through IOConnectCallStructMethod selector 2 (kSMCHandleYPCEvent)
// with the command in `data8`.

enum {
    LSMC_CMD_READ_BYTES   = 5,
    LSMC_CMD_WRITE_BYTES  = 6,
    LSMC_CMD_READ_INDEX   = 8,
    LSMC_CMD_READ_KEYINFO = 9,
};

enum {
    LSMC_RESULT_OK           = 0x00,
    LSMC_RESULT_REJECTED     = 0x82,
    LSMC_RESULT_KEY_NOTFOUND = 0x84,
};

// Open/close a connection to the AppleSMC service.
kern_return_t lsmc_open(io_connect_t *out);
void lsmc_close(io_connect_t conn);

// Each call returns the IOKit status; the SMC firmware's own result byte is
// written to *smcResult (0 == success). Both must be checked.
kern_return_t lsmc_key_info(io_connect_t conn, uint32_t key,
                            uint32_t *dataSize, uint32_t *dataType,
                            uint8_t *attributes, uint8_t *smcResult);

kern_return_t lsmc_read(io_connect_t conn, uint32_t key, uint32_t dataSize,
                        uint8_t out[32], uint8_t *smcResult);

kern_return_t lsmc_write(io_connect_t conn, uint32_t key, uint32_t dataSize,
                         const uint8_t *bytes, uint8_t *smcResult);

kern_return_t lsmc_key_at_index(io_connect_t conn, uint32_t index,
                                uint32_t *key, uint8_t *smcResult);

// Exposed for tests: must be 80.
size_t lsmc_param_size(void);

#endif
