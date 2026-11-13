#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <AppKit/AppKit.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDUsageTables.h>
#include <os/log.h>

#define CAPACITY 1024
#define CLICK 19
#define WHEEL 20
#define REQUIRED ((1u << WHEEL) - 1u)
#define MODE CFSTR("KeydialCommanderHID")

enum CaptureState { DISCONNECTED, CAPTURING, CAPTURE_FAILED, MISSING_INPUT, DEVICE_BUSY };

typedef struct {
    int control;
    int value;
} ControlEvent;

static IOHIDManagerRef manager;
static CFSetRef detected;
static CFMutableSetRef grabbed;
static CFAbsoluteTime retry_after;
static enum CaptureState state;
static ControlEvent events[CAPACITY];
static size_t event_count;
static uint32_t held;
static bool overflow;

static int control_for_element(IOHIDElementRef element) {
    static const uint32_t button_usages[] = {
        0x0E, 0x0A, 0x0F, 0x4C, 0x0C, 0x07, 0x05, 0x08, 0x16,
        0x1D, 0x06, 0x19, 0xE0, 0xE2, 0xE1, 0x28, 0x2C, 0x11,
    };
    uint32_t page = IOHIDElementGetUsagePage(element);
    uint32_t usage = IOHIDElementGetUsage(element);
    switch (IOHIDElementGetType(element)) {
        case kIOHIDElementTypeInput_Misc:
        case kIOHIDElementTypeInput_Button:
        case kIOHIDElementTypeInput_Axis:
        case kIOHIDElementTypeInput_ScanCodes:
            break;
        default:
            return 0;
    }
    if (page == 0x07) {
        for (size_t i = 0; i < sizeof(button_usages) / sizeof(*button_usages); i++) {
            if (usage == button_usages[i]) return (int)i + 1;
        }
    }
    if (page == 0x0C && usage == 0xCD) return CLICK;
    if (page == 0x01 && usage == 0x38 && IOHIDElementIsRelative(element)) return WHEEL;
    return 0;
}

static void on_value(void *context, IOReturn result, void *sender, IOHIDValueRef value) {
    if (result != kIOReturnSuccess) {
        overflow = true;
        return;
    }
    int control = control_for_element(IOHIDValueGetElement(value));
    if (!control) return;
    CFIndex raw = IOHIDValueGetIntegerValue(value);
    int direction_or_down = (raw > 0) - (raw < 0);
    if (control != WHEEL) {
        uint32_t bit = 1u << (control - 1);
        bool down = raw != 0;
        if (down == ((held & bit) != 0)) return;
        if (down) held |= bit;
        else held &= ~bit;
        direction_or_down = down;
    }
    if (event_count == CAPACITY) {
        overflow = true;
        return;
    }
    events[event_count++] = (ControlEvent){control, direction_or_down};
}

static void release_device(const void *value, void *context) {
    IOHIDDeviceRef device = (IOHIDDeviceRef)value;
    IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), MODE);
    IOHIDDeviceClose(device, kIOHIDOptionsTypeSeizeDevice);
}

static void release_devices(void) {
    CFSetApplyFunction(grabbed, release_device, NULL);
    CFSetRemoveAllValues(grabbed);
    held = 0;
    event_count = 0;
    overflow = false;
}

typedef struct {
    uint32_t controls;
    uint32_t location;
    bool location_known;
    enum CaptureState error;
    bool prefer_usb;
} CaptureSetup;

static const char *device_transport(IOHIDDeviceRef device) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDTransportKey));
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return NULL;
    if (CFStringCompare(value, CFSTR("USB"), kCFCompareCaseInsensitive) == kCFCompareEqualTo)
        return "usb";
    if (CFStringFind(value, CFSTR("Bluetooth"), kCFCompareCaseInsensitive).location != kCFNotFound)
        return "bluetooth";
    return NULL;
}

static void check_usb(const void *value, void *context) {
    const char *transport = device_transport((IOHIDDeviceRef)value);
    if (transport && !strcmp(transport, "usb")) *(bool *)context = true;
}

static void grab_device(const void *value, void *context) {
    CaptureSetup *setup = context;
    if (setup->error) return;
    IOHIDDeviceRef device = (IOHIDDeviceRef)value;
    if (setup->prefer_usb) {
        const char *transport = device_transport(device);
        if (!transport || strcmp(transport, "usb")) return;
    }
    CFArrayRef elements = IOHIDDeviceCopyMatchingElements(device, NULL, 0);
    if (!elements) return;
    uint32_t controls = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(elements); i++) {
        int control = control_for_element((IOHIDElementRef)CFArrayGetValueAtIndex(elements, i));
        if (control) controls |= 1u << (control - 1);
    }
    if (controls) {
        uint32_t location = 0;
        CFTypeRef property = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDLocationIDKey));
        bool known = property && CFGetTypeID(property) == CFNumberGetTypeID()
                     && CFNumberGetValue(property, kCFNumberSInt32Type, &location);
        // A session covers one physical unit. Duplicate controls also catch
        // multiple units when the transport supplies no location ID.
        if ((controls & setup->controls) ||
            (known && setup->location_known && location != setup->location)) {
            setup->error = CAPTURE_FAILED;
            os_log_error(OS_LOG_DEFAULT, "K20 HID interfaces overlap or report different locations (existing=%{public}x, new=%{public}x)", setup->controls, controls);
        } else {
            IOReturn result = IOHIDDeviceOpen(device, kIOHIDOptionsTypeSeizeDevice);
            if (result != kIOReturnSuccess) {
                setup->error = result == kIOReturnExclusiveAccess ? DEVICE_BUSY : CAPTURE_FAILED;
                os_log_error(OS_LOG_DEFAULT, "K20 HID exclusive open returned %{public}08x", result);
                CFRelease(elements);
                return;
            }
            if (known) {
                setup->location = location;
                setup->location_known = true;
            }
            setup->controls |= controls;
            CFSetAddValue(grabbed, device);
            for (CFIndex i = 0; i < CFArrayGetCount(elements); i++) {
                IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
                int control = control_for_element(element);
                IOHIDValueRef value = NULL;
                if (control && control != WHEEL &&
                    IOHIDDeviceGetValue(device, element, &value) == kIOReturnSuccess &&
                    value && IOHIDValueGetIntegerValue(value)) {
                    held |= 1u << (control - 1);
                }
            }
            IOHIDDeviceRegisterInputValueCallback(device, on_value, NULL);
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), MODE);
        }
    }
    CFRelease(elements);
}

static CFDictionaryRef match_product(int product) {
    int vendor = 0x256C;
    const void *keys[] = {CFSTR(kIOHIDVendorIDKey), CFSTR(kIOHIDProductIDKey)};
    CFNumberRef vid = CFNumberCreate(NULL, kCFNumberIntType, &vendor);
    CFNumberRef pid = CFNumberCreate(NULL, kCFNumberIntType, &product);
    const void *values[] = {vid, pid};
    CFDictionaryRef match = CFDictionaryCreate(NULL, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(vid);
    CFRelease(pid);
    return match;
}

static PyObject *start_capture(PyObject *self, PyObject *args) {
    if (manager) Py_RETURN_TRUE;
    manager = IOHIDManagerCreate(NULL, kIOHIDManagerOptionIndependentDevices);
    grabbed = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
    // The same K20 uses different product IDs over Bluetooth and USB.
    const void *products[] = {match_product(0x8251), match_product(0x0069)};
    CFArrayRef matching = CFArrayCreate(NULL, products, 2, &kCFTypeArrayCallBacks);
    IOHIDManagerSetDeviceMatchingMultiple(manager, matching);
    CFRelease(matching);
    CFRelease(products[0]);
    CFRelease(products[1]);
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), MODE);
    if (IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), MODE);
        CFRelease(manager);
        CFRelease(grabbed);
        manager = NULL;
        grabbed = NULL;
        Py_RETURN_FALSE;
    }
    state = DISCONNECTED;
    retry_after = 0;
    Py_RETURN_TRUE;
}

static PyObject *stop_capture(PyObject *self, PyObject *args) {
    if (manager) {
        release_devices();
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), MODE);
        IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
        if (detected) CFRelease(detected);
        CFRelease(grabbed);
        CFRelease(manager);
        detected = NULL;
        grabbed = NULL;
        manager = NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *poll_capture(PyObject *self, PyObject *args) {
    if (!manager) {
        PyErr_SetString(PyExc_RuntimeError, "K20 capture is closed");
        return NULL;
    }
    CFRunLoopRunInMode(MODE, 0.001, false);
    CFSetRef devices = IOHIDManagerCopyDevices(manager);
    bool changed = devices != detected &&
                   (!devices || !detected || !CFEqual(devices, detected));
    bool retry = (state == CAPTURE_FAILED || state == MISSING_INPUT || state == DEVICE_BUSY)
                 && CFAbsoluteTimeGetCurrent() >= retry_after;
    if (changed || retry) {
        release_devices();
        CaptureSetup setup = {0};
        if (devices) {
            CFSetApplyFunction(devices, check_usb, &setup.prefer_usb);
            CFSetApplyFunction(devices, grab_device, &setup);
        }
        if (setup.error) state = setup.error;
        else if (!devices || !CFSetGetCount(devices)) state = DISCONNECTED;
        else if (setup.controls != REQUIRED) state = MISSING_INPUT;
        else state = CAPTURING;
        if (state != CAPTURING) release_devices();
        retry_after = CFAbsoluteTimeGetCurrent() + 2.0;
    }
    if (detected) CFRelease(detected);
    detected = devices;

    bool reset = changed || retry || overflow;
    size_t count = reset ? 0 : event_count;
    PyObject *batch = PyList_New((Py_ssize_t)count);
    if (!batch) return NULL;
    for (size_t i = 0; i < count; i++) {
        PyObject *event = Py_BuildValue("(ii)", events[i].control, events[i].value);
        if (!event) {
            Py_DECREF(batch);
            return NULL;
        }
        PyList_SET_ITEM(batch, (Py_ssize_t)i, event);
    }
    event_count = 0;
    overflow = false;
    return Py_BuildValue("(iiIN)", state, reset, held, batch);
}

typedef struct {
    const char *transport;
    bool usb;
    char product[256];
    int battery;
    int charging;
} DeviceInfo;

static int integer_property(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef property = IOHIDDeviceGetProperty(device, key);
    int value;
    if (!property) return -1;
    if (CFGetTypeID(property) == CFBooleanGetTypeID()) return CFBooleanGetValue(property);
    if (CFGetTypeID(property) == CFNumberGetTypeID() &&
        CFNumberGetValue(property, kCFNumberIntType, &value)) return value;
    return -1;
}

static void read_device_info(const void *value, void *context) {
    DeviceInfo *info = context;
    IOHIDDeviceRef device = (IOHIDDeviceRef)value;
    const char *transport = device_transport(device);
    if (!transport || (info->usb && strcmp(transport, "usb")) ||
        (info->transport && strcmp(info->transport, transport))) return;
    info->transport = transport;
    CFTypeRef product = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    if (!info->product[0] && product && CFGetTypeID(product) == CFStringGetTypeID())
        CFStringGetCString(product, info->product, sizeof(info->product), kCFStringEncodingUTF8);
    if (info->battery < 0) {
        int percent = integer_property(device, CFSTR("BatteryPercent"));
        if (percent < 0) percent = integer_property(device, CFSTR("BatteryLevel"));
        if (percent >= 0 && percent <= 100) info->battery = percent;
    }
    if (info->charging < 0) {
        int charging = integer_property(device, CFSTR("IsCharging"));
        if (charging < 0) charging = integer_property(device, CFSTR("BatteryIsCharging"));
        if (charging == 0 || charging == 1) info->charging = charging;
    }

    if (!CFSetContainsValue(grabbed, device) || (info->battery >= 0 && info->charging >= 0)) return;
    CFArrayRef elements = IOHIDDeviceCopyMatchingElements(device, NULL, 0);
    if (!elements) return;
    for (CFIndex i = 0; i < CFArrayGetCount(elements); i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
        if (IOHIDElementGetUsagePage(element) != kHIDPage_BatterySystem) continue;
        IOHIDElementType type = IOHIDElementGetType(element);
        if (type < kIOHIDElementTypeInput_Misc || type > kIOHIDElementTypeInput_ScanCodes) continue;
        uint32_t usage = IOHIDElementGetUsage(element);
        bool battery = info->battery < 0 && usage == kHIDUsage_BS_RelativeStateOfCharge;
        bool charging = info->charging < 0 && usage == kHIDUsage_BS_Charging;
        if (!battery && !charging) continue;
        IOHIDValueRef reading = NULL;
        if (IOHIDDeviceGetValue(device, element, &reading) != kIOReturnSuccess || !reading) continue;
        CFIndex raw = IOHIDValueGetIntegerValue(reading);
        if (battery && raw >= 0 && raw <= 100) info->battery = (int)raw;
        if (charging && (raw == 0 || raw == 1)) info->charging = (int)raw;
    }
    CFRelease(elements);
}

static PyObject *device_info(PyObject *self, PyObject *args) {
    DeviceInfo info = {.battery = -1, .charging = -1};
    if (detected) {
        CFSetApplyFunction(detected, check_usb, &info.usb);
        CFSetApplyFunction(detected, read_device_info, &info);
    }
    PyObject *battery = info.battery < 0 ? Py_None : PyLong_FromLong(info.battery);
    if (!battery) return NULL;
    PyObject *result = Py_BuildValue("{s:z,s:z,s:O,s:O}",
        "transport", info.transport,
        "product", info.product[0] ? info.product : NULL,
        "battery", battery,
        "charging", info.charging < 0 ? Py_None : (info.charging ? Py_True : Py_False));
    if (battery != Py_None) Py_DECREF(battery);
    return result;
}

static PyObject *can_listen(PyObject *self, PyObject *args) {
    return PyBool_FromLong(CGPreflightListenEventAccess());
}

static PyObject *can_post(PyObject *self, PyObject *args) {
    return PyBool_FromLong(CGPreflightPostEventAccess());
}

static PyObject *post_key(PyObject *self, PyObject *args) {
    unsigned int code;
    int down, modifier;
    unsigned long long flags;
    if (!PyArg_ParseTuple(args, "IppK", &code, &down, &modifier, &flags)) return NULL;
    @autoreleasepool {
        CGEventRef event = NULL;
        if (code >= 0x100) {
            // Auxiliary system keys use an AppKit system-defined event.
            NSInteger data = ((code - 0x100) << 16) | ((down ? 0xA : 0xB) << 8);
            NSEvent *media = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0
                context:nil subtype:8 data1:data data2:-1];
            if (media.CGEvent) event = (CGEventRef)CFRetain(media.CGEvent);
        } else {
            event = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)code, down);
            if (event) {
                if (modifier) CGEventSetType(event, kCGEventFlagsChanged);
                CGEventSetFlags(event, (CGEventFlags)flags);
            }
        }
        if (!event) {
            PyErr_SetString(PyExc_RuntimeError, "Could not create macOS key event");
            return NULL;
        }
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
    }
    Py_RETURN_NONE;
}

static PyMethodDef methods[] = {
    {"start_capture", start_capture, METH_NOARGS, NULL},
    {"stop_capture", stop_capture, METH_NOARGS, NULL},
    {"poll_capture", poll_capture, METH_NOARGS, NULL},
    {"device_info", device_info, METH_NOARGS, NULL},
    {"can_listen", can_listen, METH_NOARGS, NULL},
    {"can_post", can_post, METH_NOARGS, NULL},
    {"post_key", post_key, METH_VARARGS, NULL},
    {NULL}
};

static struct PyModuleDef module = {
    PyModuleDef_HEAD_INIT, "_macos", NULL, -1, methods
};

PyMODINIT_FUNC PyInit__macos(void) {
    return PyModule_Create(&module);
}
