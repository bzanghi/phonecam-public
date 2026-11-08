// PhoneCam Mic: a Core Audio (AudioServerPlugIn) driver with one input-only device, "PhoneCam Mic".
// The PhoneCam app forwards the phone's microphone to it over loopback UDP on 127.0.0.1:47801. Each packet is
// "PCM1", a 32-bit sequence number, then 480 Float32 samples (10 ms, 48 kHz mono). The driver keeps about 20 ms buffered;
// with no packets it delivers silence. Structure follows Apple's NullAudio sample driver, trimmed to what an input
// device needs: no controls, one fixed format.
//
// Installed in /Library/Audio/Plug-Ins/HAL by the app (admin password) only on Macs that switch the phone microphone on.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

#pragma mark Constants (keep in step with PhoneMic.swift)

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device = 2,
    kObjectID_Stream = 3,
};

#define kDeviceUID        "com.zanghi.phonecam.mic"
#define kDeviceModelUID   "com.zanghi.phonecam.mic.model"
#define kDeviceName       "PhoneCam Mic"
#define kManufacturer     "PhoneCam"
#define kSampleRate       48000.0
#define kChannels         1
#define kPort             47801
#define kChunkFrames      480
#define kTargetFrames     960       // keep ~20 ms buffered
#define kMaxFrames        4800      // above 100 ms buffered: drop back to the target (latency beats completeness)
#define kRingFrames       16384     // power of two
#define kZeroPeriod       16384

#pragma mark State

static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 0;
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt64 gIORunning = 0;
static Float64 gHostTicksPerFrame = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gTimestampCount = 0;

// Single producer (UDP thread) / single consumer (IO thread) ring of samples.
static float gRing[kRingFrames];
static _Atomic UInt64 gWritten = 0;
static _Atomic UInt64 gRead = 0;
static bool gPriming = true;
static pthread_t gReceiver;
static int gSocket = -1;

#pragma mark Receiver

static void *ReceiveLoop(void *unused) {
    (void)unused;
    uint8_t packet[8 + kChunkFrames * 4 + 16];
    for (;;) {
        ssize_t n = recv(gSocket, packet, sizeof packet, 0);
        if (n < 0) { usleep(100000); continue; }
        if (n != 8 + kChunkFrames * 4 || memcmp(packet, "PCM1", 4) != 0) continue;
        UInt64 w = atomic_load_explicit(&gWritten, memory_order_relaxed);
        UInt64 r = atomic_load_explicit(&gRead, memory_order_acquire);
        if (w - r + kChunkFrames > kRingFrames) continue;   // full (nobody reading): drop the newest
        const float *samples = (const float *)(packet + 8);
        for (UInt32 i = 0; i < kChunkFrames; i++) gRing[(w + i) & (kRingFrames - 1)] = samples[i];
        atomic_store_explicit(&gWritten, w + kChunkFrames, memory_order_release);
    }
    return NULL;
}

static void StartReceiver(void) {
    gSocket = socket(AF_INET, SOCK_DGRAM, 0);
    if (gSocket < 0) return;
    struct sockaddr_in addr = {0};
    addr.sin_len = sizeof addr;
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);   // loopback only: nothing on the network can feed the mic
    if (bind(gSocket, (struct sockaddr *)&addr, sizeof addr) != 0) { close(gSocket); gSocket = -1; return; }
    pthread_create(&gReceiver, NULL, ReceiveLoop, NULL);
}

static void ReadInput(float *out, UInt32 frames) {
    UInt64 w = atomic_load_explicit(&gWritten, memory_order_acquire);
    UInt64 r = atomic_load_explicit(&gRead, memory_order_relaxed);
    UInt64 avail = w - r;
    if (avail > kMaxFrames) { r = w - kTargetFrames; avail = kTargetFrames; }   // stale backlog (e.g. at StartIO)
    if (gPriming && avail < kTargetFrames) { memset(out, 0, frames * sizeof(float)); return; }
    gPriming = false;
    UInt32 take = avail < frames ? (UInt32)avail : frames;
    for (UInt32 i = 0; i < take; i++) out[i] = gRing[(r + i) & (kRingFrames - 1)];
    if (take < frames) { memset(out + take, 0, (frames - take) * sizeof(float)); gPriming = true; }   // underrun
    atomic_store_explicit(&gRead, r + take, memory_order_release);
}

#pragma mark Helpers

static AudioStreamBasicDescription Format(void) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = 4 * kChannels;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = 4 * kChannels;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

#define RETURN_SIZE(T) do { *outDataSize = sizeof(T); return noErr; } while (0)
#define CHECK_SIZE(T) do { if (inDataSize < sizeof(T)) return kAudioHardwareBadPropertySizeError; *outDataSize = sizeof(T); } while (0)

static bool IsInputScope(AudioObjectPropertyScope s) { return s == kAudioObjectPropertyScopeGlobal || s == kAudioObjectPropertyScopeInput; }

#pragma mark Properties

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a) {
    (void)d; (void)pid;
    switch (obj) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice: case kAudioPlugInPropertyResourceBundle:
            return true;
        }
        return false;
    case kObjectID_Device:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning: case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams: case kAudioObjectPropertyControlList: case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate: case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden: case kAudioDevicePropertyZeroTimeStampPeriod: case kAudioDevicePropertyClockIsStable:
            return true;
        }
        return false;
    case kObjectID_Stream:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects: case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType: case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        }
        return false;
    }
    return false;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *out) {
    if (!HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
    *out = false;   // one fixed format; nothing is settable
    return noErr;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                    UInt32 qSize, const void *q, UInt32 *outDataSize) {
    (void)qSize; (void)q;
    if (!HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: RETURN_SIZE(AudioClassID);
    case kAudioObjectPropertyOwner: RETURN_SIZE(AudioObjectID);
    case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID: case kAudioPlugInPropertyResourceBundle: RETURN_SIZE(CFStringRef);
    case kAudioPlugInPropertyTranslateUIDToDevice: RETURN_SIZE(AudioObjectID);
    case kAudioObjectPropertyOwnedObjects:
        if (obj == kObjectID_PlugIn) RETURN_SIZE(AudioObjectID);
        if (obj == kObjectID_Device) { *outDataSize = IsInputScope(a->mScope) ? sizeof(AudioObjectID) : 0; return noErr; }
        *outDataSize = 0; return noErr;
    case kAudioPlugInPropertyDeviceList: case kAudioDevicePropertyRelatedDevices: RETURN_SIZE(AudioObjectID);
    case kAudioDevicePropertyStreams:
        *outDataSize = IsInputScope(a->mScope) ? sizeof(AudioObjectID) : 0; return noErr;
    case kAudioObjectPropertyControlList: *outDataSize = 0; return noErr;
    case kAudioDevicePropertyNominalSampleRate: RETURN_SIZE(Float64);
    case kAudioDevicePropertyAvailableNominalSampleRates: RETURN_SIZE(AudioValueRange);
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: RETURN_SIZE(AudioStreamBasicDescription);
    case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: RETURN_SIZE(AudioStreamRangedDescription);
    default: RETURN_SIZE(UInt32);
    }
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                UInt32 qSize, const void *q, UInt32 inDataSize, UInt32 *outDataSize, void *out) {
    if (!HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass:
        CHECK_SIZE(AudioClassID);
        *(AudioClassID *)out = kAudioObjectClassID;
        return noErr;
    case kAudioObjectPropertyClass:
        CHECK_SIZE(AudioClassID);
        *(AudioClassID *)out = obj == kObjectID_PlugIn ? kAudioPlugInClassID : obj == kObjectID_Device ? kAudioDeviceClassID : kAudioStreamClassID;
        return noErr;
    case kAudioObjectPropertyOwner:
        CHECK_SIZE(AudioObjectID);
        *(AudioObjectID *)out = obj == kObjectID_PlugIn ? kAudioObjectUnknown : obj == kObjectID_Device ? kObjectID_PlugIn : kObjectID_Device;
        return noErr;
    case kAudioObjectPropertyManufacturer:
        CHECK_SIZE(CFStringRef); *(CFStringRef *)out = CFSTR(kManufacturer); return noErr;
    case kAudioObjectPropertyName:
        CHECK_SIZE(CFStringRef); *(CFStringRef *)out = CFSTR(kDeviceName); return noErr;
    case kAudioDevicePropertyDeviceUID:
        CHECK_SIZE(CFStringRef); *(CFStringRef *)out = CFSTR(kDeviceUID); return noErr;
    case kAudioDevicePropertyModelUID:
        CHECK_SIZE(CFStringRef); *(CFStringRef *)out = CFSTR(kDeviceModelUID); return noErr;
    case kAudioPlugInPropertyResourceBundle:
        CHECK_SIZE(CFStringRef); *(CFStringRef *)out = CFSTR(""); return noErr;
    case kAudioObjectPropertyOwnedObjects:
        if (obj == kObjectID_PlugIn) { CHECK_SIZE(AudioObjectID); *(AudioObjectID *)out = kObjectID_Device; return noErr; }
        if (obj == kObjectID_Device && IsInputScope(a->mScope) && inDataSize >= sizeof(AudioObjectID)) {
            *(AudioObjectID *)out = kObjectID_Stream; *outDataSize = sizeof(AudioObjectID); return noErr;
        }
        *outDataSize = 0; return noErr;
    case kAudioPlugInPropertyDeviceList:
        if (inDataSize >= sizeof(AudioObjectID)) { *(AudioObjectID *)out = kObjectID_Device; *outDataSize = sizeof(AudioObjectID); }
        else *outDataSize = 0;
        return noErr;
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        CHECK_SIZE(AudioObjectID);
        CFStringRef uid = (qSize == sizeof(CFStringRef) && q) ? *(const CFStringRef *)q : NULL;
        *(AudioObjectID *)out = (uid && CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo) ? kObjectID_Device : kAudioObjectUnknown;
        return noErr;
    }
    case kAudioDevicePropertyTransportType: CHECK_SIZE(UInt32); *(UInt32 *)out = kAudioDeviceTransportTypeVirtual; return noErr;
    case kAudioDevicePropertyRelatedDevices:
        if (inDataSize >= sizeof(AudioObjectID)) { *(AudioObjectID *)out = kObjectID_Device; *outDataSize = sizeof(AudioObjectID); }
        else *outDataSize = 0;
        return noErr;
    case kAudioDevicePropertyClockDomain: CHECK_SIZE(UInt32); *(UInt32 *)out = 0; return noErr;
    case kAudioDevicePropertyDeviceIsAlive: CHECK_SIZE(UInt32); *(UInt32 *)out = 1; return noErr;
    case kAudioDevicePropertyDeviceIsRunning:
        CHECK_SIZE(UInt32);
        pthread_mutex_lock(&gStateMutex); *(UInt32 *)out = gIORunning > 0; pthread_mutex_unlock(&gStateMutex);
        return noErr;
    case kAudioDevicePropertyDeviceCanBeDefaultDevice: CHECK_SIZE(UInt32); *(UInt32 *)out = IsInputScope(a->mScope); return noErr;
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: CHECK_SIZE(UInt32); *(UInt32 *)out = 0; return noErr;
    case kAudioDevicePropertyLatency:   // same selector as kAudioStreamPropertyLatency; the stream adds none
        CHECK_SIZE(UInt32); *(UInt32 *)out = (obj == kObjectID_Device && IsInputScope(a->mScope)) ? kTargetFrames : 0; return noErr;
    case kAudioDevicePropertyStreams:
        if (IsInputScope(a->mScope) && inDataSize >= sizeof(AudioObjectID)) {
            *(AudioObjectID *)out = kObjectID_Stream; *outDataSize = sizeof(AudioObjectID);
        } else *outDataSize = 0;
        return noErr;
    case kAudioObjectPropertyControlList: *outDataSize = 0; return noErr;
    case kAudioDevicePropertySafetyOffset: CHECK_SIZE(UInt32); *(UInt32 *)out = 0; return noErr;
    case kAudioDevicePropertyNominalSampleRate: CHECK_SIZE(Float64); *(Float64 *)out = kSampleRate; return noErr;
    case kAudioDevicePropertyAvailableNominalSampleRates:
        CHECK_SIZE(AudioValueRange);
        ((AudioValueRange *)out)->mMinimum = kSampleRate; ((AudioValueRange *)out)->mMaximum = kSampleRate;
        return noErr;
    case kAudioDevicePropertyIsHidden: CHECK_SIZE(UInt32); *(UInt32 *)out = 0; return noErr;
    case kAudioDevicePropertyZeroTimeStampPeriod: CHECK_SIZE(UInt32); *(UInt32 *)out = kZeroPeriod; return noErr;
    case kAudioDevicePropertyClockIsStable: CHECK_SIZE(UInt32); *(UInt32 *)out = 1; return noErr;
    case kAudioStreamPropertyIsActive: CHECK_SIZE(UInt32); *(UInt32 *)out = 1; return noErr;
    case kAudioStreamPropertyDirection: CHECK_SIZE(UInt32); *(UInt32 *)out = 1; return noErr;   // 1 = input
    case kAudioStreamPropertyTerminalType: CHECK_SIZE(UInt32); *(UInt32 *)out = kAudioStreamTerminalTypeMicrophone; return noErr;
    case kAudioStreamPropertyStartingChannel: CHECK_SIZE(UInt32); *(UInt32 *)out = 1; return noErr;
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        CHECK_SIZE(AudioStreamBasicDescription); *(AudioStreamBasicDescription *)out = Format(); return noErr;
    case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
        if (inDataSize < sizeof(AudioStreamRangedDescription)) { *outDataSize = 0; return noErr; }
        AudioStreamRangedDescription *r = out;
        r->mFormat = Format();
        r->mSampleRateRange.mMinimum = kSampleRate; r->mSampleRateRange.mMaximum = kSampleRate;
        *outDataSize = sizeof(AudioStreamRangedDescription);
        return noErr;
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                UInt32 qSize, const void *q, UInt32 size, const void *data) {
    (void)qSize; (void)q; (void)size; (void)data;
    if (!HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
    // The format is fixed, but Core Audio may "set" it to what it already is.
    if (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat ||
        a->mSelector == kAudioDevicePropertyNominalSampleRate) return noErr;
    return kAudioHardwareUnsupportedOperationError;
}

#pragma mark IO

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)d; (void)client;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIORunning++ == 0) {
        gTimestampCount = 0;
        gAnchorHostTime = mach_absolute_time();
        gPriming = true;
    }
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)d; (void)client;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIORunning > 0) gIORunning--;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, Float64 *sampleTime, UInt64 *hostTime, UInt64 *seed) {
    (void)d; (void)client;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * kZeroPeriod;
    UInt64 next = gAnchorHostTime + (UInt64)((gTimestampCount + 1) * ticksPerPeriod);
    if (next <= now) gTimestampCount++;
    *sampleTime = gTimestampCount * (Float64)kZeroPeriod;
    *hostTime = gAnchorHostTime + (UInt64)(gTimestampCount * ticksPerPeriod);
    *seed = 1;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, Boolean *will, Boolean *inPlace) {
    (void)d; (void)dev; (void)client;
    *will = op == kAudioServerPlugInIOOperationReadInput;
    *inPlace = true;
    return noErr;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *info) {
    (void)d; (void)dev; (void)client; (void)op; (void)frames; (void)info;
    return noErr;
}

static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, AudioObjectID stream, UInt32 client, UInt32 op, UInt32 frames,
                              const AudioServerPlugInIOCycleInfo *info, void *main, void *secondary) {
    (void)d; (void)client; (void)info; (void)secondary;
    if (dev != kObjectID_Device || stream != kObjectID_Stream) return kAudioHardwareBadObjectError;
    if (op == kAudioServerPlugInIOOperationReadInput && main) ReadInput(main, frames);
    return noErr;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *info) {
    (void)d; (void)dev; (void)client; (void)op; (void)frames; (void)info;
    return noErr;
}

#pragma mark Plug-in lifecycle

static OSStatus Initialize(AudioServerPlugInDriverRef d, AudioServerPlugInHostRef host) {
    (void)d;
    gHost = host;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    gHostTicksPerFrame = (1e9 * tb.denom / tb.numer) / kSampleRate;
    StartReceiver();
    return noErr;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c, AudioObjectID *out) {
    (void)d; (void)desc; (void)c; (void)out; return kAudioHardwareUnsupportedOperationError;
}
static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID dev) { (void)d; (void)dev; return kAudioHardwareUnsupportedOperationError; }
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo *c) { (void)d; (void)dev; (void)c; return noErr; }
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo *c) { (void)d; (void)dev; (void)c; return noErr; }
static OSStatus PerformConfigChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 action, void *info) { (void)d; (void)dev; (void)action; (void)info; return noErr; }
static OSStatus AbortConfigChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 action, void *info) { (void)d; (void)dev; (void)action; (void)info; return noErr; }

static HRESULT QueryInterface(void *d, REFIID iid, LPVOID *out);
static ULONG AddRef(void *d) { (void)d; return ++gRefCount; }
static ULONG Release(void *d) { (void)d; if (gRefCount > 0) gRefCount--; return gRefCount; }

static AudioServerPlugInDriverInterface gInterface = {
    NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice, AddDeviceClient, RemoveDeviceClient,
    PerformConfigChange, AbortConfigChange, HasProperty, IsPropertySettable, GetPropertyDataSize, GetPropertyData,
    SetPropertyData, StartIO, StopIO, GetZeroTimeStamp, WillDoIOOperation, BeginIOOperation, DoIOOperation, EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

static HRESULT QueryInterface(void *d, REFIID iid, LPVOID *out) {
    (void)d;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, iid);
    bool ok = CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!ok) { *out = NULL; return E_NOINTERFACE; }
    gRefCount++;
    *out = gDriverRef;
    return S_OK;
}

// Named in Info.plist (CFPlugInFactories).
void *PhoneCamMic_Create(CFAllocatorRef allocator, CFUUIDRef requestedType);
void *PhoneCamMic_Create(CFAllocatorRef allocator, CFUUIDRef requestedType) {
    (void)allocator;
    return CFEqual(requestedType, kAudioServerPlugInTypeUUID) ? gDriverRef : NULL;
}
