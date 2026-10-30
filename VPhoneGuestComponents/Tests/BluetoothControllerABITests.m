// Exercise production admission against runtime methods with incompatible ABIs.
#import "../BluetoothController/libvphonebluetoothcontroller.m"
#import <assert.h>
static void unused(void) {}
int main(int argc, const char **argv) {
    const char *invalid = argc > 1 ? argv[1] : "receive";
    Class hci = objc_allocateClassPair(NSObject.class, "BTVCHciManager", 0);
    Class manager = objc_allocateClassPair(NSObject.class, "BTVCConnectionManager", 0);
    class_addMethod(hci, sel_registerName("handleHciCommand:params:length:"), (IMP)unused, "v32@0:8S16*20S28");
    class_addMethod(hci, sel_registerName("_sendLeMetaEvent:parameters:length:"), (IMP)unused, "v32@0:8C16*20C28");
    class_addMethod(hci, sel_registerName("_sendHciEvent:parameters:length:"), (IMP)unused, "v32@0:8C16*20C28");
    class_addMethod(manager, sel_registerName("_handleHciEvent:parameters:length:"), (IMP)unused, "v32@0:8C16*20C28");
    class_addMethod(manager, sel_registerName("sendDataToPeer:dataLength:"), (IMP)unused, "C28@0:8*16S24");
    class_addMethod(manager, sel_registerName("receiveDataPacketHandler"), (IMP)unused, strcmp(invalid, "receive") == 0 ? "Q16@0:8" : "@?16@0:8");
    class_addMethod(manager, sel_registerName("dispatchQueue"), (IMP)unused, strcmp(invalid, "queue") == 0 ? "Q16@0:8" : "@16@0:8");
    class_addMethod(object_getClass(manager), sel_registerName("sharedConnectionManager"), (IMP)unused, strcmp(invalid, "shared") == 0 ? "Q16@0:8" : "@16@0:8");
    objc_registerClassPair(hci); objc_registerClassPair(manager);
    assert(VPBTInstall());
    assert(VPBTOriginalHandleHciCommand == NULL);
    assert(class_getMethodImplementation(hci, sel_registerName("handleHciCommand:params:length:")) == (IMP)unused);
    puts("Bluetooth ABI tests passed: incompatible getter leaves native methods untouched");
}
