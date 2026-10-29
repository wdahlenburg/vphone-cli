// libvphonebluetoothcontroller.m — plaintext HCI ACL bridge for BTVC.
//
// bluetoothd's BTVCConnectionManager receives ordinary HCI ACL packets from
// the iOS Bluetooth stack before BTVC applies its simulated link-layer state
// and encryption. This hook mirrors those packets to the persistent guest
// bridge and accepts controller-to-host ACL packets on the same connection.
// BTVC remains active for discovery, connection lifecycle, flow control and
// every packet not claimed by the physical-peripheral bridge.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <os/lock.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

#import "VPhoneBluetoothHCICommand.h"

static const uint16_t VPBTControllerPort = 55890;
static dispatch_queue_t VPBTQueue;
static int VPBTSocket = -1;
static uint64_t VPBTSocketGeneration;
static id VPBTConnectionManager;
static os_unfair_lock VPBTManagerLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSNumber *, NSDictionary *> *VPBTLinks;

typedef void (*VPBTHandleHciCommandIMP)(id, SEL, uint16_t, const void *, uint16_t);
static VPBTHandleHciCommandIMP VPBTOriginalHandleHciCommand;
typedef void (*VPBTHciEventIMP)(id, SEL, uint8_t, const void *, uint8_t);
static VPBTHciEventIMP VPBTOriginalSendLEEvent;
static VPBTHciEventIMP VPBTOriginalSendEvent;
typedef unsigned char (*VPBTSendDataToPeerIMP)(id, SEL, const void *, uint16_t);
static VPBTSendDataToPeerIMP VPBTOriginalSendDataToPeer;
typedef void (^VPBTReceiveDataPacketHandler)(uint16_t, NSData *);
static int VPBTConnect(void);

static BOOL VPBTSendAll(int fd, NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSUInteger sent = 0;
    while (sent < data.length) {
        ssize_t count = send(fd, bytes + sent, data.length - sent, MSG_NOSIGNAL);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        sent += (NSUInteger)count;
    }
    return YES;
}

static void VPBTSendMessage(NSDictionary *message) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:message options:0 error:NULL];
    if (!json) return;
    NSMutableData *line = [json mutableCopy];
    uint8_t newline = '\n';
    [line appendBytes:&newline length:1];
    dispatch_async(VPBTQueue, ^{
        int fd = VPBTConnect();
        if (fd >= 0 && !VPBTSendAll(fd, line) && VPBTSocket == fd) {
            shutdown(VPBTSocket, SHUT_RDWR);
            close(VPBTSocket);
            VPBTSocket = -1;
        }
    });
}

static NSDictionary *VPBTLink(uint16_t handle) {
    os_unfair_lock_lock(&VPBTManagerLock);
    NSDictionary *link = VPBTLinks[@(handle)];
    // BTVC tags its wire ACL handle with bit 10. Correlate against the
    // observed completion, never against an independently allocated counter.
    NSDictionary *tagged = VPBTLinks[@(handle & 0x03ff)];
    if (link && tagged && link != tagged) link = nil;
    else if (!link) link = tagged;
    os_unfair_lock_unlock(&VPBTManagerLock);
    return link;
}

static void VPBTDeliverACL(NSData *packet, NSString *identifier) {
    VPBTACLPacketView view = {0};
    if (!VPBTParseACLPacket(packet.bytes, packet.length, &view)) return;
    NSDictionary *link = VPBTLink(view.connectionHandle);
    if (![link[@"connection"] isEqual:identifier]) return;
    NSData *payload = [NSData dataWithBytes:view.payload length:view.payloadLength];

    os_unfair_lock_lock(&VPBTManagerLock);
    id connectionManager = VPBTConnectionManager;
    os_unfair_lock_unlock(&VPBTManagerLock);
    if (!connectionManager) {
        Class managerClass = objc_getClass("BTVCConnectionManager");
        SEL sharedSelector = sel_registerName("sharedConnectionManager");
        if ([managerClass respondsToSelector:sharedSelector]) {
            connectionManager = ((id (*)(id, SEL))objc_msgSend)(managerClass, sharedSelector);
        }
    }
    if (!connectionManager) {
        os_log_error(OS_LOG_DEFAULT, "VPBluetoothController missing BTVC manager for handle 0x%04x",
                     view.connectionHandle);
        return;
    }
    SEL queueSelector = sel_registerName("dispatchQueue");
    SEL handlerSelector = sel_registerName("receiveDataPacketHandler");
    if (![connectionManager respondsToSelector:queueSelector]) return;
    dispatch_queue_t queue = ((id (*)(id, SEL))objc_msgSend)(connectionManager, queueSelector);
    if (!queue) return;
    dispatch_async(queue, ^{
        if (![VPBTLink(view.connectionHandle)[@"connection"] isEqual:identifier]
            || ![connectionManager respondsToSelector:handlerSelector]) return;
        VPBTReceiveDataPacketHandler handler =
            ((id (*)(id, SEL))objc_msgSend)(connectionManager, handlerSelector);
        if (handler) {
            uint16_t aclHeader = view.connectionHandle | (view.packetBoundaryFlag << 12);
            handler(aclHeader, payload);
        }
    });
}

static void VPBTHandleLine(NSData *line) {
    NSDictionary *message = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
    if (![message isKindOfClass:NSDictionary.class]) return;
    if ([message[@"type"] isEqualToString:@"hci_response"]) {
        NSData *packet = [[NSData alloc] initWithBase64EncodedString:message[@"data"] ?: @"" options:0];
        VPBTDeliverACL(packet, message[@"connection"]);
    } else if ([message[@"type"] isEqualToString:@"link_disconnected"]) {
        uint16_t handle = [message[@"handle"] unsignedShortValue];
        NSString *identifier = message[@"connection"];
        if (![VPBTLink(handle)[@"connection"] isEqual:identifier]) return;
        os_unfair_lock_lock(&VPBTManagerLock);
        id manager = VPBTConnectionManager;
        os_unfair_lock_unlock(&VPBTManagerLock);
        if (!manager) {
            Class cls = objc_getClass("BTVCConnectionManager");
            SEL shared = sel_registerName("sharedConnectionManager");
            if ([cls respondsToSelector:shared]) manager = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
        }
        if (!manager) return;
        dispatch_queue_t queue = ((id (*)(id, SEL))objc_msgSend)(manager, sel_registerName("dispatchQueue"));
        dispatch_async(queue, ^{
            if (![VPBTLink(handle)[@"connection"] isEqual:identifier]) return;
            // Let native BTVC consume the disconnect, release the connection and
            // deliver its own HCI event. No unsolicited HCI command is injected.
            uint8_t parameters[] = {0, (uint8_t)handle, (uint8_t)(handle >> 8), 0x08};
            ((VPBTHciEventIMP)objc_msgSend)(manager,
                sel_registerName("_handleHciEvent:parameters:length:"), 0x05, parameters, sizeof(parameters));
        });
    }
}

static void VPBTReadLoop(int fd, uint64_t generation) {
    @autoreleasepool {
        NSMutableData *pending = [NSMutableData data];
        uint8_t buffer[8192];
        for (;;) {
            ssize_t count = recv(fd, buffer, sizeof(buffer), 0);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) break;
            [pending appendBytes:buffer length:(NSUInteger)count];
            for (;;) {
                const uint8_t *bytes = pending.bytes;
                NSUInteger newline = NSNotFound;
                for (NSUInteger index = 0; index < pending.length; index++) {
                    if (bytes[index] == '\n') { newline = index; break; }
                }
                if (newline == NSNotFound) {
                    if (pending.length > 1024 * 1024) [pending setLength:0];
                    break;
                }
                NSData *line = [pending subdataWithRange:NSMakeRange(0, newline)];
                [pending replaceBytesInRange:NSMakeRange(0, newline + 1) withBytes:NULL length:0];
                VPBTHandleLine(line);
            }
        }
    }
    close(fd);
    dispatch_async(VPBTQueue, ^{
        if (VPBTSocketGeneration == generation && VPBTSocket >= 0) {
            close(VPBTSocket);
            VPBTSocket = -1;
        }
    });
}

static int VPBTConnect(void) {
    if (VPBTSocket >= 0) return VPBTSocket;
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in6 address = {0};
    address.sin6_len = sizeof(address);
    address.sin6_family = AF_INET6;
    address.sin6_port = htons(VPBTControllerPort);
    address.sin6_addr = in6addr_loopback;
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return -1;
    }
    VPBTSocket = fd;
    uint64_t generation = ++VPBTSocketGeneration;
    int reader = dup(fd);
    if (reader < 0) {
        close(fd);
        VPBTSocket = -1;
        return -1;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        VPBTReadLoop(reader, generation);
    });
    return fd;
}

static void VPBTForwardACL(NSData *packet) {
    VPBTACLPacketView view = {0};
    if (!VPBTParseACLPacket(packet.bytes, packet.length, &view)) return;
    NSDictionary *link = VPBTLink(view.connectionHandle);
    if (!link) return;
    NSDictionary *message = @{
        @"type": @"hci",
        @"connection": link[@"connection"],
        @"handle": link[@"handle"],
        @"data": [packet base64EncodedStringWithOptions:0],
    };
    VPBTSendMessage(message);
}

static unsigned char VPBTSendDataToPeer(id self, SEL command, const void *bytes, uint16_t length) {
    NSData *packet = bytes && length >= 4 ? [NSData dataWithBytes:bytes length:length] : nil;
    VPBTACLPacketView view = {0};
    BOOL validPacket = packet && VPBTParseACLPacket(packet.bytes, packet.length, &view);
    unsigned char result = VPBTOriginalSendDataToPeer
        ? VPBTOriginalSendDataToPeer(self, command, bytes, length) : 0;
    if (validPacket) {
        os_unfair_lock_lock(&VPBTManagerLock);
        VPBTConnectionManager = self;
        os_unfair_lock_unlock(&VPBTManagerLock);
        VPBTForwardACL(packet);
    }
    return result;
}

static void VPBTSendLEEvent(id self, SEL command, uint8_t subevent, const void *bytes, uint8_t length) {
    VPBTLEConnection connection = {0};
    if (VPBTParseLEConnection(subevent, bytes, length, &connection)) {
        NSDictionary *link = @{
            @"type": @"connection_ready", @"handle": @(connection.handle),
            @"address": [[NSData dataWithBytes:connection.address length:6] base64EncodedStringWithOptions:0],
            @"connection": NSUUID.UUID.UUIDString,
        };
        os_unfair_lock_lock(&VPBTManagerLock);
        VPBTLinks[@(connection.handle)] = link;
        os_unfair_lock_unlock(&VPBTManagerLock);
        VPBTSendMessage(link);
    }
    VPBTOriginalSendLEEvent(self, command, subevent, bytes, length);
}

static void VPBTSendEvent(id self, SEL command, uint8_t event, const void *bytes, uint8_t length) {
    uint16_t handle = 0;
    if (VPBTParseDisconnection(event, bytes, length, &handle)) {
        NSDictionary *link = VPBTLink(handle);
        os_unfair_lock_lock(&VPBTManagerLock);
        if (link) [VPBTLinks removeObjectForKey:link[@"handle"]];
        os_unfair_lock_unlock(&VPBTManagerLock);
        if (link) VPBTSendMessage(@{
            @"type": @"disconnect_request", @"handle": link[@"handle"],
            @"connection": link[@"connection"],
        });
    }
    VPBTOriginalSendEvent(self, command, event, bytes, length);
}

static void VPBTHandleHciCommand(
    id self, SEL command, uint16_t opcode, const void *bytes, uint16_t length
) {
    uint16_t handle = 0;
    if (VPBTDisconnectHandle(opcode, bytes, length, &handle)) {
        NSDictionary *link = VPBTLink(handle);
        if (link) VPBTSendMessage(@{
            @"type": @"disconnect_request", @"handle": link[@"handle"], @"connection": link[@"connection"],
        });
    }
    VPBTOriginalHandleHciCommand(self, command, opcode, bytes, length);
}

static BOOL VPBTInstall(void) {
    if (VPBTOriginalHandleHciCommand) return YES;
    Class hciManager = objc_getClass("BTVCHciManager");
    Class connectionManager = objc_getClass("BTVCConnectionManager");
    if (!hciManager || !connectionManager) return NO;
    Method command = class_getInstanceMethod(hciManager, sel_registerName("handleHciCommand:params:length:"));
    Method complete = class_getInstanceMethod(hciManager, sel_registerName("_sendLeMetaEvent:parameters:length:"));
    Method event = class_getInstanceMethod(hciManager, sel_registerName("_sendHciEvent:parameters:length:"));
    Method disconnect = class_getInstanceMethod(connectionManager, sel_registerName("_handleHciEvent:parameters:length:"));
    Method send = class_getInstanceMethod(connectionManager, sel_registerName("sendDataToPeer:dataLength:"));
    Method receive = class_getInstanceMethod(connectionManager, sel_registerName("receiveDataPacketHandler"));
    const char *commandTypes = command ? method_getTypeEncoding(command) : NULL;
    const char *completeTypes = complete ? method_getTypeEncoding(complete) : NULL;
    const char *eventTypes = event ? method_getTypeEncoding(event) : NULL;
    const char *disconnectTypes = disconnect ? method_getTypeEncoding(disconnect) : NULL;
    const char *sendTypes = send ? method_getTypeEncoding(send) : NULL;
    // Check the entire supported ABI before changing any implementation.
    if (!commandTypes || strcmp(commandTypes, "v32@0:8S16*20S28") != 0
        || !completeTypes || strcmp(completeTypes, "v32@0:8C16*20C28") != 0
        || !eventTypes || strcmp(eventTypes, "v32@0:8C16*20C28") != 0
        || !disconnectTypes || strcmp(disconnectTypes, "v32@0:8C16*20C28") != 0
        || !sendTypes || strcmp(sendTypes, "C28@0:8*16S24") != 0 || !receive) {
        os_log_error(OS_LOG_DEFAULT, "VPBluetoothController unsupported BTVC runtime; hooks disabled");
        return YES;
    }
    VPBTOriginalHandleHciCommand = (VPBTHandleHciCommandIMP)method_getImplementation(command);
    VPBTOriginalSendLEEvent = (VPBTHciEventIMP)method_getImplementation(complete);
    VPBTOriginalSendEvent = (VPBTHciEventIMP)method_getImplementation(event);
    VPBTOriginalSendDataToPeer = (VPBTSendDataToPeerIMP)method_getImplementation(send);
    method_setImplementation(command, (IMP)VPBTHandleHciCommand);
    method_setImplementation(complete, (IMP)VPBTSendLEEvent);
    method_setImplementation(event, (IMP)VPBTSendEvent);
    method_setImplementation(send, (IMP)VPBTSendDataToPeer);
    os_log(OS_LOG_DEFAULT, "VPBluetoothController plaintext HCI bridge installed");
    return YES;
}

static void VPBTInstallWhenReady(NSUInteger attempt) {
    if (VPBTInstall()) return;
    if (attempt >= 300) {
        os_log_error(OS_LOG_DEFAULT, "VPBluetoothController BTVCConnectionManager did not become available");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), VPBTQueue, ^{
        VPBTInstallWhenReady(attempt + 1);
    });
}

__attribute__((constructor)) static void VPBTInitialize(void) {
    VPBTQueue = dispatch_queue_create("com.vphone.bluetooth-controller", DISPATCH_QUEUE_SERIAL);
    VPBTLinks = [NSMutableDictionary dictionary];
    VPBTInstallWhenReady(0);
}

int vphone_bluetooth_controller_version(void) { return 1; }
