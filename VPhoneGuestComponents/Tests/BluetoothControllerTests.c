#include <assert.h>
#include <stdint.h>
#include <stdio.h>

#include "VPhoneBluetoothHCICommand.h"

int main(void) {
    const uint8_t mtuResponse[] = {
        0x01, 0x24, 0x07, 0x00,
        0x03, 0x00, 0x04, 0x00, 0x03, 0xb9, 0x00,
    };
    const uint8_t expectedPayload[] = {0x03, 0x00, 0x04, 0x00, 0x03, 0xb9, 0x00};
    VPBTACLPacketView view = {0};
    assert(VPBTParseACLPacket(mtuResponse, sizeof(mtuResponse), &view));
    assert(view.connectionHandle == 0x0401);
    assert(view.packetBoundaryFlag == 2);
    assert(view.payloadLength == sizeof(expectedPayload));
    for (size_t index = 0; index < sizeof(expectedPayload); index++) {
        assert(view.payload[index] == expectedPayload[index]);
    }

    const uint8_t incomplete[] = {0x01, 0x24, 0x07, 0x00, 0x03};
    const uint8_t zeroHandle[] = {0x00, 0x20, 0x00, 0x00};
    assert(!VPBTParseACLPacket(incomplete, sizeof(incomplete), &view));
    assert(!VPBTParseACLPacket(zeroHandle, sizeof(zeroHandle), &view));
    assert(!VPBTParseACLPacket(NULL, sizeof(mtuResponse), &view));
    assert(!VPBTParseACLPacket(mtuResponse, sizeof(mtuResponse), NULL));

    uint16_t handle = 0;
    const uint8_t disconnect[] = {0x01, 0x00, 0x13};
    assert(VPBTDisconnectHandle(0x0406, disconnect, sizeof(disconnect), &handle));
    assert(handle == 1);

    const uint8_t maximum[] = {0xff, 0x0e, 0x16};
    assert(VPBTDisconnectHandle(0x0406, maximum, sizeof(maximum), &handle));
    assert(handle == 0x0eff);

    const uint8_t zero[] = {0x00, 0x00};
    const uint8_t reserved[] = {0x00, 0x0f};
    assert(!VPBTDisconnectHandle(0x0405, disconnect, sizeof(disconnect), &handle));
    assert(!VPBTDisconnectHandle(0x0406, disconnect, 1, &handle));
    assert(!VPBTDisconnectHandle(0x0406, disconnect, 2, &handle));
    assert(!VPBTDisconnectHandle(0x0406, NULL, sizeof(disconnect), &handle));
    assert(!VPBTDisconnectHandle(0x0406, zero, sizeof(zero), &handle));
    assert(!VPBTDisconnectHandle(0x0406, reserved, sizeof(reserved), &handle));
    assert(!VPBTDisconnectHandle(0x0406, disconnect, sizeof(disconnect), NULL));

    puts("Bluetooth controller tests passed: ACL framing and HCI disconnect parsing");
    return 0;
}
