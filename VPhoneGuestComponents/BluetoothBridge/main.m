#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <dns_sd.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/vsock.h>
#import <unistd.h>

static const uint16_t VPBTWebSocketPort = 55889;
static const uint16_t VPBTControllerPort = 55890;
static const uint32_t VPBTHostPort = 1340;
static NSMutableDictionary<NSString *, NSDictionary *> *VPBTReports;
static dispatch_queue_t VPBTReportsQueue;
static dispatch_queue_t VPBTHostQueue;
static dispatch_queue_t VPBTControllerQueue;
static dispatch_queue_t VPBTWebSocketQueue;
static int VPBTHostClient = -1;
static int VPBTControllerClient = -1;
static int VPBTWebSocketClient = -1;
static uint64_t VPBTHostGeneration;
static uint64_t VPBTControllerGeneration;
static uint64_t VPBTWebSocketGeneration;

static int VPBTReplaceClient(int *slot, uint64_t *generation, int client) {
    if (*slot >= 0) {
        shutdown(*slot, SHUT_RDWR);
        close(*slot);
    }
    *slot = dup(client);
    *generation += 1;
    return *slot;
}

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

static void VPBTSendHostMessage(NSDictionary *message) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:message options:0 error:NULL];
    if (!json) return;
    NSMutableData *line = [json mutableCopy];
    uint8_t newline = '\n';
    [line appendBytes:&newline length:1];
    dispatch_sync(VPBTHostQueue, ^{
        if (VPBTHostClient >= 0 && !VPBTSendAll(VPBTHostClient, line)) {
            shutdown(VPBTHostClient, SHUT_RDWR);
        }
    });
}

static void VPBTSendControllerMessage(NSDictionary *message) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:message options:0 error:NULL];
    if (!json) return;
    NSMutableData *line = [json mutableCopy];
    uint8_t newline = '\n';
    [line appendBytes:&newline length:1];
    dispatch_sync(VPBTControllerQueue, ^{
        if (VPBTControllerClient >= 0 && !VPBTSendAll(VPBTControllerClient, line)) {
            shutdown(VPBTControllerClient, SHUT_RDWR);
        }
    });
}

static BOOL VPBTReceiveAll(int fd, void *buffer, size_t length) {
    uint8_t *bytes = buffer;
    size_t received = 0;
    while (received < length) {
        ssize_t count = recv(fd, bytes + received, length - received, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        received += (size_t)count;
    }
    return YES;
}

static NSData *VPBTReceiveWebSocketFrame(int fd, uint8_t *opcode) {
    uint8_t header[2];
    if (!VPBTReceiveAll(fd, header, sizeof(header))) return nil;
    *opcode = header[0] & 0x0f;
    BOOL masked = (header[1] & 0x80) != 0;
    uint64_t length = header[1] & 0x7f;
    if (length == 126) {
        uint16_t encoded;
        if (!VPBTReceiveAll(fd, &encoded, sizeof(encoded))) return nil;
        length = ntohs(encoded);
    } else if (length == 127) {
        uint64_t encoded;
        if (!VPBTReceiveAll(fd, &encoded, sizeof(encoded))) return nil;
        length = CFSwapInt64BigToHost(encoded);
    }
    if (length > 1024 * 1024) return nil;
    uint8_t mask[4] = {0};
    if (masked && !VPBTReceiveAll(fd, mask, sizeof(mask))) return nil;
    NSMutableData *payload = [NSMutableData dataWithLength:(NSUInteger)length];
    if (length && !VPBTReceiveAll(fd, payload.mutableBytes, (size_t)length)) return nil;
    if (masked) {
        uint8_t *bytes = payload.mutableBytes;
        for (NSUInteger index = 0; index < payload.length; index++) bytes[index] ^= mask[index % 4];
    }
    return payload;
}

static NSData *VPBTAdvertisementMessage(void) {
    __block NSArray *reports;
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-10];
    dispatch_sync(VPBTReportsQueue, ^{
        NSMutableArray *live = [NSMutableArray array];
        NSMutableArray *expired = [NSMutableArray array];
        [VPBTReports enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *entry, BOOL *stop) {
            (void)stop;
            if ([entry[@"seen"] compare:cutoff] == NSOrderedAscending) [expired addObject:key];
        }];
        [VPBTReports removeObjectsForKeys:expired];
        // A legacy scan response augments the advertisement immediately before
        // it. Dictionary enumeration order is undefined, so sort the paired
        // keys to keep ":advertisement" before ":scan" on every update.
        for (NSString *key in [[VPBTReports allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            [live addObject:VPBTReports[key][@"report"]];
        }
        reports = live;
    });
    NSDictionary *value = @{@"BTVCBonjourLinkType": @1, @"BTVCBonjourPayloadKey": reports};
    NSDictionary *message = @{
        @"BTVCBonjourServiceMessageType": @"BTVCBonjourServiceMessageTypeStartAdvertiseData",
        @"BTVCBonjourServiceMessageValue": @[value],
    };
    return [NSPropertyListSerialization dataWithPropertyList:message
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
}

static NSData *VPBTWebSocketFrame(NSData *payload) {
    NSMutableData *frame = [NSMutableData dataWithCapacity:payload.length + 10];
    uint8_t opcode = 0x82;
    [frame appendBytes:&opcode length:1];
    if (payload.length <= 125) {
        uint8_t size = (uint8_t)payload.length;
        [frame appendBytes:&size length:1];
    } else if (payload.length <= UINT16_MAX) {
        uint8_t marker = 126;
        uint16_t size = htons((uint16_t)payload.length);
        [frame appendBytes:&marker length:1];
        [frame appendBytes:&size length:2];
    } else {
        uint8_t marker = 127;
        uint64_t size = CFSwapInt64HostToBig((uint64_t)payload.length);
        [frame appendBytes:&marker length:1];
        [frame appendBytes:&size length:8];
    }
    [frame appendData:payload];
    return frame;
}

static void VPBTSendWebSocketMessage(NSData *payload) {
    NSData *frame = VPBTWebSocketFrame(payload);
    dispatch_sync(VPBTWebSocketQueue, ^{
        if (VPBTWebSocketClient >= 0 && !VPBTSendAll(VPBTWebSocketClient, frame)) {
            shutdown(VPBTWebSocketClient, SHUT_RDWR);
        }
    });
}

static NSString *VPBTHeader(NSString *request, NSString *name) {
    for (NSString *line in [request componentsSeparatedByString:@"\r\n"]) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *key = [[line substringToIndex:colon.location] lowercaseString];
        if (![key isEqualToString:name.lowercaseString]) continue;
        return [[line substringFromIndex:colon.location + 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    return nil;
}

static NSString *VPBTWebSocketAccept(NSString *key) {
    NSData *data = [[key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"]
        dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    return [[NSData dataWithBytes:digest length:sizeof(digest)] base64EncodedStringWithOptions:0];
}

// BTVC connects through the guest's own en0 address. It cannot use a
// loopback-only listener, but peers on another guest or LAN must not replace
// this guest's controller connection.
static BOOL VPBTIsLocalConnection(int client) {
    struct sockaddr_in6 local = {0}, peer = {0};
    socklen_t localLength = sizeof(local), peerLength = sizeof(peer);
    return getsockname(client, (struct sockaddr *)&local, &localLength) == 0
        && getpeername(client, (struct sockaddr *)&peer, &peerLength) == 0
        && local.sin6_family == AF_INET6 && peer.sin6_family == AF_INET6
        && memcmp(&local.sin6_addr, &peer.sin6_addr, sizeof(local.sin6_addr)) == 0;
}

static BOOL VPBTUpgradeWebSocket(int client) {
    NSMutableData *requestData = [NSMutableData data];
    NSData *end = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t buffer[4096];
    while ([requestData rangeOfData:end options:0 range:NSMakeRange(0, requestData.length)].location == NSNotFound
           && requestData.length < 16384) {
        ssize_t count = recv(client, buffer, sizeof(buffer), 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        [requestData appendBytes:buffer length:(NSUInteger)count];
    }
    NSString *request = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];
    NSString *key = VPBTHeader(request, @"Sec-WebSocket-Key");
    if (!key) return NO;
    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: %@\r\n"
         "BTVCBonjourEndpointServerUUIDHeader: %@\r\nUpgrade: WebSocket\r\nConnection: Upgrade\r\n\r\n",
        VPBTWebSocketAccept(key), NSUUID.UUID.UUIDString];
    return VPBTSendAll(client, [response dataUsingEncoding:NSUTF8StringEncoding]);
}

static void VPBTHandleWebSocket(int client) {
    if (!VPBTIsLocalConnection(client)) { close(client); return; }
    if (!VPBTUpgradeWebSocket(client)) { close(client); return; }
    __block int registered = -1;
    __block uint64_t generation = 0;
    dispatch_sync(VPBTWebSocketQueue, ^{
        registered = VPBTReplaceClient(&VPBTWebSocketClient, &VPBTWebSocketGeneration, client);
        generation = VPBTWebSocketGeneration;
    });
    if (registered < 0) { close(client); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (;;) {
            __block BOOL active;
            dispatch_sync(VPBTWebSocketQueue, ^{
                active = VPBTWebSocketClient == registered && VPBTWebSocketGeneration == generation;
            });
            if (!active) break;
            VPBTSendWebSocketMessage(VPBTAdvertisementMessage());
            sleep(1);
        }
    });
    for (;;) {
        uint8_t opcode = 0;
        NSData *payload = VPBTReceiveWebSocketFrame(client, &opcode);
        if (!payload || opcode == 0x8) break;
        __block BOOL active;
        dispatch_sync(VPBTWebSocketQueue, ^{
            active = VPBTWebSocketClient == registered && VPBTWebSocketGeneration == generation;
        });
        if (!active) break;
        if (opcode != 0x2) continue;
        id message = [NSPropertyListSerialization propertyListWithData:payload
            options:NSPropertyListImmutable format:NULL error:NULL];
        if (message) {
            VPBTSendHostMessage(@{
                @"type": @"btvc",
                @"data": [payload base64EncodedStringWithOptions:0],
            });
        }
    }
    dispatch_sync(VPBTWebSocketQueue, ^{
        if (VPBTWebSocketClient == registered && VPBTWebSocketGeneration == generation) {
            close(VPBTWebSocketClient);
            VPBTWebSocketClient = -1;
        }
    });
    close(client);
}

static int VPBTInternetListener(void) {
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    int no = 0, yes = 1;
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no));
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in6 address = {0};
    address.sin6_len = sizeof(address);
    address.sin6_family = AF_INET6;
    address.sin6_port = htons(VPBTWebSocketPort);
    address.sin6_addr = in6addr_any;
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) || listen(fd, 8)) return -1;
    return fd;
}

static void VPBTUpdateReport(NSDictionary *message) {
    NSString *identifier = message[@"id"];
    if (![identifier isKindOfClass:NSString.class]
        || ![message[@"address"] isKindOfClass:NSString.class]
        || ![message[@"data"] isKindOfClass:NSString.class]) return;
    NSData *address = [[NSData alloc] initWithBase64EncodedString:message[@"address"] ?: @"" options:0];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:message[@"data"] ?: @"" options:0];
    if (![identifier isKindOfClass:NSString.class] || identifier.length == 0 ||
        address.length != 6 || !data) return;
    BOOL scanResponse = [message[@"scan_response"] boolValue];
    BOOL connectable = [message[@"connectable"] boolValue];
    BOOL scannable = [message[@"scannable"] boolValue];
    NSInteger signedRSSI = [message[@"rssi"] integerValue];
    NSInteger signedTX = [message[@"tx"] integerValue];
    if (data.length > 31) return;
    NSDictionary *report = @{
        // CoreBluetooth aggregates the legacy advertisement and scan response.
        // The host rebuilds both reports so bluetoothd can merge the full name
        // and identity fields as it does for a physical controller.
        @"et": scanResponse ? (connectable ? @27 : @26) : (connectable ? @19 : (scannable ? @18 : @16)),
        @"dtl": @(data.length), @"da": @0, @"dat": @0, @"sPHY": @0,
        @"tp": @(signedTX >= -127 && signedTX <= 20 ? signedTX : 127),
        @"pPHY": @1, @"pai": @0, @"pa": address, @"at": @1, @"aSID": @255,
        @"data": data,
        @"rssi": @(signedRSSI >= -127 && signedRSSI <= 20 ? signedRSSI : 127),
    };
    NSString *reportIdentifier = [identifier stringByAppendingString:scanResponse ? @":scan" : @":advertisement"];
    dispatch_async(VPBTReportsQueue, ^{
        VPBTReports[reportIdentifier] = @{@"report": report, @"seen": NSDate.date};
    });
}

static void VPBTHandleHost(int client) {
    __block int registered = -1;
    __block uint64_t generation = 0;
    dispatch_sync(VPBTHostQueue, ^{
        registered = VPBTReplaceClient(&VPBTHostClient, &VPBTHostGeneration, client);
        generation = VPBTHostGeneration;
    });
    if (registered < 0) { close(client); return; }
    NSMutableData *pending = [NSMutableData data];
    uint8_t buffer[8192];
    for (;;) {
        ssize_t count = recv(client, buffer, sizeof(buffer), 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        __block BOOL active;
        dispatch_sync(VPBTHostQueue, ^{
            active = VPBTHostClient == registered && VPBTHostGeneration == generation;
        });
        if (!active) break;
        [pending appendBytes:buffer length:(NSUInteger)count];
        for (;;) {
            const uint8_t *bytes = pending.bytes;
            NSUInteger newline = NSNotFound;
            for (NSUInteger index = 0; index < pending.length; index++) if (bytes[index] == '\n') { newline = index; break; }
            if (newline == NSNotFound) {
                if (pending.length > 1024 * 1024) [pending setLength:0];
                break;
            }
            NSData *line = [pending subdataWithRange:NSMakeRange(0, newline)];
            [pending replaceBytesInRange:NSMakeRange(0, newline + 1) withBytes:NULL length:0];
            NSDictionary *message = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
            if (![message isKindOfClass:NSDictionary.class]) continue;
            if ([message[@"type"] isEqualToString:@"btvc_response"]) {
                NSData *payload = [[NSData alloc] initWithBase64EncodedString:message[@"data"] ?: @"" options:0];
                if (payload) VPBTSendWebSocketMessage(payload);
            } else if ([message[@"type"] isEqualToString:@"hci_response"]) {
                VPBTSendControllerMessage(message);
            } else {
                VPBTUpdateReport(message);
            }
        }
    }
    dispatch_sync(VPBTHostQueue, ^{
        if (VPBTHostClient == registered && VPBTHostGeneration == generation) {
            close(VPBTHostClient);
            VPBTHostClient = -1;
        }
    });
    close(client);
}

static void VPBTHandleController(int client) {
    __block int registered = -1;
    __block uint64_t generation = 0;
    dispatch_sync(VPBTControllerQueue, ^{
        registered = VPBTReplaceClient(&VPBTControllerClient, &VPBTControllerGeneration, client);
        generation = VPBTControllerGeneration;
    });
    if (registered < 0) { close(client); return; }
    NSMutableData *pending = [NSMutableData data];
    uint8_t buffer[8192];
    for (;;) {
        ssize_t count = recv(client, buffer, sizeof(buffer), 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        __block BOOL active;
        dispatch_sync(VPBTControllerQueue, ^{
            active = VPBTControllerClient == registered && VPBTControllerGeneration == generation;
        });
        if (!active) break;
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
            NSDictionary *message = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
            if ([message isKindOfClass:NSDictionary.class] &&
                ([message[@"type"] isEqualToString:@"hci"] ||
                 [message[@"type"] isEqualToString:@"connect_request"] ||
                 [message[@"type"] isEqualToString:@"disconnect_request"])) {
                VPBTSendHostMessage(message);
            }
        }
    }
    dispatch_sync(VPBTControllerQueue, ^{
        if (VPBTControllerClient == registered && VPBTControllerGeneration == generation) {
            close(VPBTControllerClient);
            VPBTControllerClient = -1;
        }
    });
    close(client);
}

static void VPBTRunControllerListener(void) {
    int server = socket(AF_INET6, SOCK_STREAM, 0);
    int yes = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in6 address = {0};
    address.sin6_len = sizeof(address);
    address.sin6_family = AF_INET6;
    address.sin6_port = htons(VPBTControllerPort);
    address.sin6_addr = in6addr_loopback;
    if (server < 0 || bind(server, (struct sockaddr *)&address, sizeof(address)) || listen(server, 1)) {
        NSLog(@"Bluetooth controller bridge could not listen on %u: %s", VPBTControllerPort, strerror(errno));
        exit(4);
    }
    for (;;) {
        int client = accept(server, NULL, NULL);
        if (client >= 0) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ VPBTHandleController(client); });
        }
    }
}

static void VPBTRunHostListener(void) {
    int server = socket(AF_VSOCK, SOCK_STREAM, 0);
    struct sockaddr_vm address = {.svm_len = sizeof(address), .svm_family = AF_VSOCK,
        .svm_port = VPBTHostPort, .svm_cid = VMADDR_CID_ANY};
    if (server < 0 || bind(server, (struct sockaddr *)&address, sizeof(address)) || listen(server, 4)) {
        NSLog(@"Bluetooth bridge could not listen on VSOCK %u: %s", VPBTHostPort, strerror(errno));
        exit(2);
    }
    for (;;) {
        int client = accept(server, NULL, NULL);
        if (client >= 0) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ VPBTHandleHost(client); });
    }
}

int main(void) {
    @autoreleasepool {
        VPBTReports = [NSMutableDictionary dictionary];
        VPBTReportsQueue = dispatch_queue_create("com.vphone.bluetooth-bridge.reports", DISPATCH_QUEUE_SERIAL);
        VPBTHostQueue = dispatch_queue_create("com.vphone.bluetooth-bridge.host", DISPATCH_QUEUE_SERIAL);
        VPBTControllerQueue = dispatch_queue_create("com.vphone.bluetooth-bridge.controller", DISPATCH_QUEUE_SERIAL);
        VPBTWebSocketQueue = dispatch_queue_create("com.vphone.bluetooth-bridge.websocket", DISPATCH_QUEUE_SERIAL);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ VPBTRunHostListener(); });
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ VPBTRunControllerListener(); });
        int listener = VPBTInternetListener();
        if (listener < 0) return 1;
        DNSServiceRef service = NULL;
        if (DNSServiceRegister(&service, 0, 0, "3-vphone-bridge-", "_btvc._tcp", "local.", NULL,
                               htons(VPBTWebSocketPort), 0, NULL, NULL, NULL) != kDNSServiceErr_NoError) return 3;
        DNSServiceSetDispatchQueue(service, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        NSLog(@"Bluetooth bridge ready: BTVC %u, host VSOCK %u", VPBTWebSocketPort, VPBTHostPort);
        for (;;) {
            int client = accept(listener, NULL, NULL);
            if (client >= 0) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ VPBTHandleWebSocket(client); });
        }
    }
}
