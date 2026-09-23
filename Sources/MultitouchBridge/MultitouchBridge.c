#include "MultitouchBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdbool.h>

// Estruturas do framework privado MultitouchSupport (mesmo layout usado por MiddleClick/Jitouch).
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTVector;

typedef struct {
    int frame;
    double timestamp;
    int identifier;
    int state;
    int fingerId;
    int handId;
    MTVector normalized;
    float size;
    int zero1;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector mm;
    int zero2[2];
    float unk2;
} MTFinger;

typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef, MTFinger *, int, double, int);

typedef CFMutableArrayRef (*MTDeviceCreateListFn)(void);
typedef void (*MTRegisterContactFrameCallbackFn)(MTDeviceRef, MTContactCallback);
typedef void (*MTUnregisterContactFrameCallbackFn)(MTDeviceRef, MTContactCallback);
typedef int (*MTDeviceStartFn)(MTDeviceRef, int);
typedef int (*MTDeviceStopFn)(MTDeviceRef);

static MTDeviceCreateListFn pCreateList;
static MTRegisterContactFrameCallbackFn pRegister;
static MTUnregisterContactFrameCallbackFn pUnregister;
static MTDeviceStartFn pStart;
static MTDeviceStopFn pStop;

static CFMutableArrayRef gDevices;
static SKTouchHandler gHandler;

#define SK_MAX_TOUCHES 20

static int loadFramework(void) {
    static int loaded = -1;
    if (loaded != -1) return loaded;

    void *handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (handle) {
        pCreateList = (MTDeviceCreateListFn)dlsym(handle, "MTDeviceCreateList");
        pRegister = (MTRegisterContactFrameCallbackFn)dlsym(handle, "MTRegisterContactFrameCallback");
        pUnregister = (MTUnregisterContactFrameCallbackFn)dlsym(handle, "MTUnregisterContactFrameCallback");
        pStart = (MTDeviceStartFn)dlsym(handle, "MTDeviceStart");
        pStop = (MTDeviceStopFn)dlsym(handle, "MTDeviceStop");
    }
    loaded = (pCreateList && pRegister && pStart && pStop) ? 1 : 0;
    return loaded;
}

static int contactCallback(MTDeviceRef device, MTFinger *fingers, int count, double timestamp, int frame) {
    (void)device;
    (void)frame;
    SKTouchHandler handler = gHandler;
    if (!handler) return 0;

    SKTouch touches[SK_MAX_TOUCHES];
    int n = count < SK_MAX_TOUCHES ? count : SK_MAX_TOUCHES;
    for (int i = 0; i < n; i++) {
        touches[i].identifier = fingers[i].identifier;
        touches[i].state = fingers[i].state;
        touches[i].x = fingers[i].normalized.pos.x;
        touches[i].y = fingers[i].normalized.pos.y;
        touches[i].size = fingers[i].size;
    }
    handler(touches, n, timestamp);
    return 0;
}

int SKMultitouchStart(SKTouchHandler handler) {
    if (!loadFramework()) return -1;
    SKMultitouchStop();

    gHandler = handler;
    gDevices = pCreateList();
    if (!gDevices) return 0;

    CFIndex total = CFArrayGetCount(gDevices);
    for (CFIndex i = 0; i < total; i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(gDevices, i);
        pRegister(device, contactCallback);
        pStart(device, 0);
    }
    return (int)total;
}

void SKMultitouchStop(void) {
    if (!gDevices) return;
    CFIndex total = CFArrayGetCount(gDevices);
    for (CFIndex i = 0; i < total; i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(gDevices, i);
        if (pUnregister) pUnregister(device, contactCallback);
        pStop(device);
    }
    CFRelease(gDevices);
    gDevices = NULL;
}

typedef void (*CoreDockSendNotificationFn)(CFStringRef, int);

int SKCoreDockSend(const char *notification) {
    static CoreDockSendNotificationFn fn;
    static int tried;
    if (!tried) {
        tried = 1;
        dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW);
        fn = (CoreDockSendNotificationFn)dlsym(RTLD_DEFAULT, "CoreDockSendNotification");
    }
    if (!fn) return 0;

    CFStringRef name = CFStringCreateWithCString(NULL, notification, kCFStringEncodingUTF8);
    fn(name, 0);
    CFRelease(name);
    return 1;
}

typedef int (*AXGetWindowFn)(const void *, unsigned int *);

unsigned int SKWindowIDForAXElement(const void *element) {
    static AXGetWindowFn fn;
    static int tried;
    if (!tried) {
        tried = 1;
        dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW);
        fn = (AXGetWindowFn)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    }
    unsigned int windowID = 0;
    if (!fn || !element || fn(element, &windowID) != 0) return 0;
    return windowID;
}

typedef int (*SetSymbolicHotKeyFn)(int, bool);

int SKSetSymbolicHotKeyEnabled(int hotKey, int enabled) {
    static SetSymbolicHotKeyFn fn;
    static int tried;
    if (!tried) {
        tried = 1;
        void *handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
        if (handle) fn = (SetSymbolicHotKeyFn)dlsym(handle, "CGSSetSymbolicHotKeyEnabled");
    }
    if (!fn) return 0;
    fn(hotKey, enabled != 0);
    return 1;
}
