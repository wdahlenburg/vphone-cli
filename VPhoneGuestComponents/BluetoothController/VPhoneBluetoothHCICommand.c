#include "VPhoneBluetoothHCICommand.h"

bool VPBTParseACLPacket(const void *packet, size_t length, VPBTACLPacketView *view) {
    if (!packet || length < 4 || !view) return false;
    const uint8_t *bytes = packet;
    uint16_t header = (uint16_t)bytes[0] | (uint16_t)bytes[1] << 8;
    uint16_t payloadLength = (uint16_t)bytes[2] | (uint16_t)bytes[3] << 8;
    uint16_t handle = header & 0x0fff;
    if (handle == 0 || handle > 0x0eff || length != (size_t)payloadLength + 4) return false;
    view->connectionHandle = handle;
    view->packetBoundaryFlag = (uint16_t)((header >> 12) & 0x03);
    view->payload = bytes + 4;
    view->payloadLength = payloadLength;
    return true;
}

bool VPBTDisconnectHandle(uint16_t opcode, const void *parameters, uint16_t length, uint16_t *handle) {
    if (opcode != 0x0406 || !parameters || length != 3 || !handle) return false;
    const uint8_t *bytes = parameters;
    uint16_t value = (uint16_t)bytes[0] | (uint16_t)bytes[1] << 8;
    value &= 0x0fff;
    if (value == 0 || value > 0x0eff) return false;
    *handle = value;
    return true;
}
