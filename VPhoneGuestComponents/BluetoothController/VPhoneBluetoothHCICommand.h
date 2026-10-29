#ifndef VPhoneBluetoothHCICommand_h
#define VPhoneBluetoothHCICommand_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint16_t connectionHandle;
    uint16_t packetBoundaryFlag;
    const uint8_t *payload;
    uint16_t payloadLength;
} VPBTACLPacketView;

bool VPBTParseACLPacket(const void *packet, size_t length, VPBTACLPacketView *view);
bool VPBTDisconnectHandle(uint16_t opcode, const void *parameters, uint16_t length, uint16_t *handle);

#endif
