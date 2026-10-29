// Contract stubs isolate Apple's BTVC implementation. The production dylib's
// constructor swizzles these methods; messages travel through a real TCP peer.
#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <unistd.h>
#import <assert.h>

static dispatch_semaphore_t received;
static dispatch_semaphore_t disconnected;
static NSData *receivedPayload;
static uint16_t receivedHeader;
static int originalEvents;
static int originalCommands;

@interface BTVCHciManager : NSObject
- (void)handleHciCommand:(uint16_t)opcode params:(char *)params length:(uint16_t)length;
- (void)_sendLeMetaEvent:(uint8_t)event parameters:(char *)params length:(uint8_t)length;
- (void)_sendHciEvent:(uint8_t)event parameters:(char *)params length:(uint8_t)length;
@end
static BTVCHciManager *hci;
@implementation BTVCHciManager
- (void)handleHciCommand:(uint16_t)opcode params:(char *)params length:(uint16_t)length {
    (void)opcode; (void)params; (void)length; originalCommands++;
}
- (void)_sendLeMetaEvent:(uint8_t)event parameters:(char *)params length:(uint8_t)length {
    (void)event; (void)params; (void)length; originalEvents++;
}
- (void)_sendHciEvent:(uint8_t)event parameters:(char *)params length:(uint8_t)length {
    (void)event; (void)params; (void)length; originalEvents++;
}
@end

@interface BTVCConnectionManager : NSObject
+ (instancetype)sharedConnectionManager;
- (dispatch_queue_t)dispatchQueue;
- (unsigned char)sendDataToPeer:(char *)data dataLength:(uint16_t)length;
- (void (^)(uint16_t, NSData *))receiveDataPacketHandler;
- (void)_handleHciEvent:(uint8_t)event parameters:(char *)params length:(uint8_t)length;
@end
@implementation BTVCConnectionManager
+ (instancetype)sharedConnectionManager {
    static BTVCConnectionManager *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [self new]; });
    return instance;
}
- (dispatch_queue_t)dispatchQueue {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("test.native-btvc", DISPATCH_QUEUE_SERIAL); });
    return queue;
}
- (unsigned char)sendDataToPeer:(char *)data dataLength:(uint16_t)length {
    (void)data; (void)length; return 1;
}
- (void (^)(uint16_t, NSData *))receiveDataPacketHandler {
    return ^(uint16_t header, NSData *payload) {
        receivedHeader = header; receivedPayload = payload;
        dispatch_semaphore_signal(received);
    };
}
- (void)_handleHciEvent:(uint8_t)event parameters:(char *)params length:(uint8_t)length {
    const uint8_t expected[] = {0, 0x21, 0, 8};
    assert(event == 5 && length == 4 && memcmp(params, expected, 4) == 0);
    [hci _sendHciEvent:event parameters:params length:length];
    dispatch_semaphore_signal(disconnected);
}
@end

static NSDictionary *readMessage(int fd) {
    NSMutableData *line = [NSMutableData data];
    uint8_t byte;
    while (recv(fd, &byte, 1, 0) == 1) {
        if (byte == '\n') return [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
        [line appendBytes:&byte length:1];
        assert(line.length < 65536);
    }
    assert(!"missing controller message");
    return nil;
}
static void sendMessage(int fd, NSDictionary *message) {
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:message options:0 error:NULL] mutableCopy];
    [data appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    assert(send(fd, data.bytes, data.length, 0) == (ssize_t)data.length);
}
static void complete(uint16_t handle, uint8_t lastAddressByte) {
    uint8_t event[18] = {0, handle & 255, handle >> 8, 0, 1, 0xC1, 2, 3, 4, 5, lastAddressByte};
    [hci _sendLeMetaEvent:1 parameters:(char *)event length:sizeof(event)];
}
static void sendACL(uint16_t wireHandle) {
    uint8_t packet[] = {wireHandle & 255, (wireHandle >> 8) | 0x20, 7, 0, 3, 0, 4, 0, 2, 23, 0};
    assert([[BTVCConnectionManager sharedConnectionManager] sendDataToPeer:(char *)packet dataLength:sizeof(packet)] == 1);
}
int main(void) {
    @autoreleasepool {
        received = dispatch_semaphore_create(0);
        disconnected = dispatch_semaphore_create(0);
        int server = socket(AF_INET6, SOCK_STREAM, 0);
        int yes = 1;
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        struct sockaddr_in6 address = {.sin6_len = sizeof(address), .sin6_family = AF_INET6,
            .sin6_port = htons(55890), .sin6_addr = IN6ADDR_LOOPBACK_INIT};
        assert(bind(server, (struct sockaddr *)&address, sizeof(address)) == 0);
        assert(listen(server, 1) == 0);
        hci = [BTVCHciManager new];
        complete(0x21, 0xC6);
        int fd = accept(server, NULL, NULL);
        assert(fd >= 0);
        struct timeval timeout = {.tv_sec = 2};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        NSDictionary *first = readMessage(fd);
        assert([first[@"type"] isEqual:@"connection_ready"]);
        assert([first[@"handle"] intValue] == 0x21);
        NSData *peer = [[NSData alloc] initWithBase64EncodedString:first[@"address"] options:0];
        const uint8_t expectedPeer[] = {0xC1,2,3,4,5,0xC6};
        assert([peer isEqual:[NSData dataWithBytes:expectedPeer length:6]]);
        sendACL(0x421);
        NSDictionary *acl = readMessage(fd);
        assert([acl[@"type"] isEqual:@"hci"] && [acl[@"handle"] intValue] == 0x21);
        assert([acl[@"connection"] isEqual:first[@"connection"]]);

        // Nonsequential allocation and handle reuse cannot select an old peer.
        complete(9, 0xC7);
        NSDictionary *other = readMessage(fd);
        assert([other[@"handle"] intValue] == 9);
        complete(0x21, 0xC8);
        NSDictionary *replacement = readMessage(fd);
        assert(![replacement[@"connection"] isEqual:first[@"connection"]]);
        sendACL(0x421);
        assert([readMessage(fd)[@"connection"] isEqual:replacement[@"connection"]]);
        const uint8_t response[] = {0x21,0x24,7,0,3,0,4,0,3,23,0};
        NSString *encoded = [[NSData dataWithBytes:response length:sizeof(response)] base64EncodedStringWithOptions:0];
        sendMessage(fd, @{@"type":@"hci_response", @"connection":first[@"connection"], @"data":encoded});
        assert(dispatch_semaphore_wait(received, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0);
        sendMessage(fd, @{@"type":@"hci_response", @"connection":replacement[@"connection"], @"data":encoded});
        assert(dispatch_semaphore_wait(received, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
        assert(receivedHeader == 0x2421);
        assert([receivedPayload isEqual:[NSData dataWithBytes:response + 4 length:7]]);

        sendMessage(fd, @{@"type":@"link_disconnected", @"handle":@0x21, @"connection":first[@"connection"]});
        assert(dispatch_semaphore_wait(disconnected, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0);
        sendMessage(fd, @{@"type":@"link_disconnected", @"handle":@0x21, @"connection":replacement[@"connection"]});
        assert(dispatch_semaphore_wait(disconnected, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
        assert([readMessage(fd)[@"type"] isEqual:@"disconnect_request"]);
        assert(originalEvents == 4);
        uint8_t command[] = {9, 4, 0x13};
        [hci handleHciCommand:0x0406 params:(char *)command length:3];
        NSDictionary *release = readMessage(fd);
        assert([release[@"handle"] intValue] == 9 && [release[@"connection"] isEqual:other[@"connection"]]);
        assert(originalCommands == 1);
        close(fd); close(server);
        puts("Bluetooth runtime tests passed: native identity, reuse, stale reply rejection and native disconnect");
    }
}
