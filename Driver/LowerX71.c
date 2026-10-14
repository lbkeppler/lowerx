// LowerX 7.1 — saída de áudio virtual com 8 canais (7.1) para o Core Audio.
//
// Os apps veem um dispositivo 7.1 e mandam áudio multicanal para ele. O driver não
// toca nada: só anuncia a saída e fornece o relógio. O LowerX captura o que chega
// aqui com um process tap, espacializa os 8 canais e toca no headset.
//
// Objetos: plug-in (1) → dispositivo (2) → stream de saída (3), volume (4), mudo (5).

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <math.h>
#include <stddef.h>
#include <string.h>

enum {
    kObjectPlugIn = kAudioObjectPlugInObject,
    kObjectDevice = 2,
    kObjectStream = 3,
    kObjectVolume = 4,
    kObjectMute = 5,
};

#define kDeviceUID      "dev.local.lowerx.surround71"
#define kModelUID       "dev.local.lowerx.surround71.model"
#define kChannels       8
#define kSampleRate     48000.0
#define kPeriodFrames   16384   // período do relógio (zero time stamp)
#define kVolumeMinDB    -64.0f

static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost;
static UInt32 gRefCount;
static UInt32 gIOCount;
static Float64 gHostTicksPerFrame;
static UInt64 gAnchorHostTime;
static UInt64 gPeriods;
static Float32 gVolume = 1.0f;   // escalar 0–1
static UInt32 gMuted;
static UInt32 gStreamActive = 1;

// MARK: - Valores fixos

static AudioStreamBasicDescription Format(void) {
    AudioStreamBasicDescription f = {
        .mSampleRate = kSampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 4 * kChannels,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = 4 * kChannels,
        .mChannelsPerFrame = kChannels,
        .mBitsPerChannel = 32,
    };
    return f;
}

// Ordem 7.1 do Core Audio (MPEG_7_1_C): L R C LFE Ls Rs Rls Rrs.
static const AudioChannelLabel kLabels[kChannels] = {
    kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
    kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
    kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
};

#define kLayoutSize (offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription))

// Curva de volume: dB = 40·log10(escalar), limitado a −64 dB.
static Float32 ScalarToDB(Float32 s) {
    if (s <= 0) return kVolumeMinDB;
    Float32 db = 40.0f * log10f(s);
    return db < kVolumeMinDB ? kVolumeMinDB : (db > 0 ? 0 : db);
}

static Float32 DBToScalar(Float32 db) {
    if (db <= kVolumeMinDB) return 0;
    if (db >= 0) return 1;
    return powf(10.0f, db / 40.0f);
}

// MARK: - Propriedades
//
// Uma função só responde HasProperty, GetPropertyDataSize e GetPropertyData:
// com outData == NULL ela apenas informa se a propriedade existe e o tamanho.

#define VALUE(type, expr) do { \
        if (outSize) *outSize = sizeof(type); \
        if (outData) { \
            if (inSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
            *(type *)outData = (expr); \
        } \
        return kAudioHardwareNoError; \
    } while (0)

static OSStatus IDs(const AudioObjectID *ids, UInt32 count, UInt32 inSize, UInt32 *outSize, void *outData) {
    if (outData) {
        UInt32 n = inSize / sizeof(AudioObjectID);
        if (n > count) n = count;
        memcpy(outData, ids, n * sizeof(AudioObjectID));
        if (outSize) *outSize = n * sizeof(AudioObjectID);
    } else if (outSize) {
        *outSize = count * sizeof(AudioObjectID);
    }
    return kAudioHardwareNoError;
}

static OSStatus PlugInProperty(const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q,
                               UInt32 inSize, UInt32 *outSize, void *outData) {
    static const AudioObjectID devices[] = { kObjectDevice };
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: VALUE(AudioClassID, kAudioPlugInClassID);
    case kAudioObjectPropertyOwner: VALUE(AudioObjectID, kAudioObjectUnknown);
    case kAudioObjectPropertyManufacturer: VALUE(CFStringRef, CFSTR("LowerX"));
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList:
        return IDs(devices, 1, inSize, outSize, outData);
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        AudioObjectID found = kAudioObjectUnknown;
        if (outData) {
            if (qSize < sizeof(CFStringRef) || !q) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(const CFStringRef *)q;
            if (uid && CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo) found = kObjectDevice;
        }
        VALUE(AudioObjectID, found);
    }
    case kAudioPlugInPropertyResourceBundle: VALUE(CFStringRef, CFSTR(""));
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus DeviceProperty(const AudioObjectPropertyAddress *a,
                               UInt32 inSize, UInt32 *outSize, void *outData) {
    static const AudioObjectID owned[] = { kObjectStream, kObjectVolume, kObjectMute };
    static const AudioObjectID streams[] = { kObjectStream };
    static const AudioObjectID controls[] = { kObjectVolume, kObjectMute };
    static const AudioObjectID related[] = { kObjectDevice };
    bool input = a->mScope == kAudioObjectPropertyScopeInput;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: VALUE(AudioClassID, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner: VALUE(AudioObjectID, kObjectPlugIn);
    case kAudioObjectPropertyName: VALUE(CFStringRef, CFSTR("LowerX 7.1"));
    case kAudioObjectPropertyManufacturer: VALUE(CFStringRef, CFSTR("LowerX"));
    case kAudioObjectPropertyOwnedObjects: return IDs(owned, input ? 0 : 3, inSize, outSize, outData);
    case kAudioDevicePropertyDeviceUID: VALUE(CFStringRef, CFSTR(kDeviceUID));
    case kAudioDevicePropertyModelUID: VALUE(CFStringRef, CFSTR(kModelUID));
    case kAudioDevicePropertyTransportType: VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyRelatedDevices: return IDs(related, 1, inSize, outSize, outData);
    case kAudioDevicePropertyClockDomain: VALUE(UInt32, 0);
    case kAudioDevicePropertyDeviceIsAlive: VALUE(UInt32, 1);
    case kAudioDevicePropertyDeviceIsRunning: VALUE(UInt32, gIOCount > 0);
    case kAudioDevicePropertyDeviceCanBeDefaultDevice: VALUE(UInt32, input ? 0 : 1);
    // Alertas do sistema continuam no dispositivo normal: assim, com o LowerX
    // fechado, ainda se ouve alguma coisa.
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: VALUE(UInt32, 0);
    case kAudioDevicePropertyLatency: VALUE(UInt32, 0);
    case kAudioDevicePropertySafetyOffset: VALUE(UInt32, 0);
    case kAudioDevicePropertyStreams: return IDs(streams, input ? 0 : 1, inSize, outSize, outData);
    case kAudioObjectPropertyControlList: return IDs(controls, 2, inSize, outSize, outData);
    case kAudioDevicePropertyNominalSampleRate: VALUE(Float64, kSampleRate);
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange range = { kSampleRate, kSampleRate };
        VALUE(AudioValueRange, range);
    }
    case kAudioDevicePropertyIsHidden: VALUE(UInt32, 0);
    case kAudioDevicePropertyZeroTimeStampPeriod: VALUE(UInt32, kPeriodFrames);
    case kAudioDevicePropertyClockIsStable: VALUE(UInt32, 1);
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        if (outSize) *outSize = 2 * sizeof(UInt32);
        if (outData) {
            if (inSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32 *)outData)[0] = 1;
            ((UInt32 *)outData)[1] = 2;
        }
        return kAudioHardwareNoError;
    }
    case kAudioDevicePropertyPreferredChannelLayout: {
        if (outSize) *outSize = kLayoutSize;
        if (outData) {
            if (inSize < kLayoutSize) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout *layout = outData;
            memset(layout, 0, kLayoutSize);
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mNumberChannelDescriptions = kChannels;
            for (UInt32 i = 0; i < kChannels; i++) layout->mChannelDescriptions[i].mChannelLabel = kLabels[i];
        }
        return kAudioHardwareNoError;
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus StreamProperty(const AudioObjectPropertyAddress *a,
                               UInt32 inSize, UInt32 *outSize, void *outData) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: VALUE(AudioClassID, kAudioStreamClassID);
    case kAudioObjectPropertyOwner: VALUE(AudioObjectID, kObjectDevice);
    case kAudioObjectPropertyOwnedObjects: return IDs(NULL, 0, inSize, outSize, outData);
    case kAudioStreamPropertyIsActive: VALUE(UInt32, gStreamActive);
    case kAudioStreamPropertyDirection: VALUE(UInt32, 0);   // 0 = saída
    case kAudioStreamPropertyTerminalType: VALUE(UInt32, kAudioStreamTerminalTypeSpeaker);
    case kAudioStreamPropertyStartingChannel: VALUE(UInt32, 1);
    case kAudioStreamPropertyLatency: VALUE(UInt32, 0);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: VALUE(AudioStreamBasicDescription, Format());
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription d = { Format(), { kSampleRate, kSampleRate } };
        VALUE(AudioStreamRangedDescription, d);
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus ControlProperty(AudioObjectID object, const AudioObjectPropertyAddress *a,
                                UInt32 inSize, UInt32 *outSize, void *outData) {
    bool volume = object == kObjectVolume;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass:
        VALUE(AudioClassID, volume ? kAudioLevelControlClassID : kAudioBooleanControlClassID);
    case kAudioObjectPropertyClass:
        VALUE(AudioClassID, volume ? kAudioVolumeControlClassID : kAudioMuteControlClassID);
    case kAudioObjectPropertyOwner: VALUE(AudioObjectID, kObjectDevice);
    case kAudioObjectPropertyOwnedObjects: return IDs(NULL, 0, inSize, outSize, outData);
    case kAudioControlPropertyScope: VALUE(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
    case kAudioControlPropertyElement: VALUE(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
    default: break;
    }
    if (!volume) {
        if (a->mSelector == kAudioBooleanControlPropertyValue) VALUE(UInt32, gMuted);
        return kAudioHardwareUnknownPropertyError;
    }
    switch (a->mSelector) {
    case kAudioLevelControlPropertyScalarValue: VALUE(Float32, gVolume);
    case kAudioLevelControlPropertyDecibelValue: VALUE(Float32, ScalarToDB(gVolume));
    case kAudioLevelControlPropertyDecibelRange: {
        AudioValueRange range = { kVolumeMinDB, 0 };
        VALUE(AudioValueRange, range);
    }
    // Nas conversões, o valor a converter chega no próprio buffer de saída.
    case kAudioLevelControlPropertyConvertScalarToDecibels:
        VALUE(Float32, ScalarToDB(*(Float32 *)outData));
    case kAudioLevelControlPropertyConvertDecibelsToScalar:
        VALUE(Float32, DBToScalar(*(Float32 *)outData));
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Property(AudioObjectID object, const AudioObjectPropertyAddress *a, UInt32 qSize,
                         const void *q, UInt32 inSize, UInt32 *outSize, void *outData) {
    switch (object) {
    case kObjectPlugIn: return PlugInProperty(a, qSize, q, inSize, outSize, outData);
    case kObjectDevice: return DeviceProperty(a, inSize, outSize, outData);
    case kObjectStream: return StreamProperty(a, inSize, outSize, outData);
    case kObjectVolume:
    case kObjectMute: return ControlProperty(object, a, inSize, outSize, outData);
    default: return kAudioHardwareBadObjectError;
    }
}

// MARK: - Interface do driver

static HRESULT QueryInterface(void *driver, REFIID uuid, LPVOID *out);
static ULONG AddRef(void *driver);
static ULONG Release(void *driver);

static OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    gHost = host;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    gHostTicksPerFrame = (1e9 * timebase.denom / timebase.numer) / kSampleRate;
    return kAudioHardwareNoError;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc,
                             const AudioServerPlugInClientInfo *client, AudioObjectID *outID) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID device) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID device,
                                const AudioServerPlugInClientInfo *client) {
    return kAudioHardwareNoError;
}

static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID device,
                                   const AudioServerPlugInClientInfo *client) {
    return kAudioHardwareNoError;
}

static OSStatus PerformConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID device,
                                           UInt64 action, void *info) {
    return kAudioHardwareNoError;
}

static OSStatus AbortConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID device,
                                         UInt64 action, void *info) {
    return kAudioHardwareNoError;
}

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid,
                           const AudioObjectPropertyAddress *a) {
    UInt32 size = 0;
    return Property(object, a, 0, NULL, 0, &size, NULL) == kAudioHardwareNoError;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid,
                                   const AudioObjectPropertyAddress *a, Boolean *outSettable) {
    if (!HasProperty(d, object, pid, a)) return kAudioHardwareUnknownPropertyError;
    switch (object) {
    case kObjectDevice:
        *outSettable = a->mSelector == kAudioDevicePropertyNominalSampleRate;
        break;
    case kObjectStream:
        *outSettable = a->mSelector == kAudioStreamPropertyIsActive ||
                       a->mSelector == kAudioStreamPropertyVirtualFormat ||
                       a->mSelector == kAudioStreamPropertyPhysicalFormat;
        break;
    case kObjectVolume:
        *outSettable = a->mSelector == kAudioLevelControlPropertyScalarValue ||
                       a->mSelector == kAudioLevelControlPropertyDecibelValue;
        break;
    case kObjectMute:
        *outSettable = a->mSelector == kAudioBooleanControlPropertyValue;
        break;
    default:
        *outSettable = false;
    }
    return kAudioHardwareNoError;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid,
                                    const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q,
                                    UInt32 *outSize) {
    return Property(object, a, qSize, q, 0, outSize, NULL);
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid,
                                const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q,
                                UInt32 inSize, UInt32 *outSize, void *outData) {
    pthread_mutex_lock(&gLock);
    OSStatus status = Property(object, a, qSize, q, inSize, outSize, outData);
    pthread_mutex_unlock(&gLock);
    return status;
}

static void Notify(AudioObjectID object, AudioObjectPropertySelector s1, AudioObjectPropertySelector s2) {
    AudioObjectPropertyAddress changed[2] = {
        { s1, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { s2, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    };
    gHost->PropertiesChanged(gHost, object, s2 ? 2 : 1, changed);
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid,
                                const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q,
                                UInt32 inSize, const void *inData) {
    switch (object) {
    case kObjectDevice:
        if (a->mSelector != kAudioDevicePropertyNominalSampleRate) return kAudioHardwareUnknownPropertyError;
        if (inSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return *(const Float64 *)inData == kSampleRate ? kAudioHardwareNoError : kAudioHardwareIllegalOperationError;
    case kObjectStream:
        if (a->mSelector == kAudioStreamPropertyIsActive) {
            if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gLock);
            gStreamActive = *(const UInt32 *)inData != 0;
            pthread_mutex_unlock(&gLock);
            Notify(object, kAudioStreamPropertyIsActive, 0);
            return kAudioHardwareNoError;
        }
        if (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat) {
            if (inSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            const AudioStreamBasicDescription *f = inData;
            return f->mSampleRate == kSampleRate && f->mChannelsPerFrame == kChannels
                ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
        }
        return kAudioHardwareUnknownPropertyError;
    case kObjectVolume: {
        if (inSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
        Float32 value = *(const Float32 *)inData;
        if (a->mSelector == kAudioLevelControlPropertyDecibelValue) value = DBToScalar(value);
        else if (a->mSelector != kAudioLevelControlPropertyScalarValue) return kAudioHardwareUnknownPropertyError;
        value = value < 0 ? 0 : (value > 1 ? 1 : value);
        pthread_mutex_lock(&gLock);
        bool changed = value != gVolume;
        gVolume = value;
        pthread_mutex_unlock(&gLock);
        if (changed) Notify(object, kAudioLevelControlPropertyScalarValue, kAudioLevelControlPropertyDecibelValue);
        return kAudioHardwareNoError;
    }
    case kObjectMute: {
        if (a->mSelector != kAudioBooleanControlPropertyValue) return kAudioHardwareUnknownPropertyError;
        if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        pthread_mutex_lock(&gLock);
        bool changed = (*(const UInt32 *)inData != 0) != (gMuted != 0);
        gMuted = *(const UInt32 *)inData != 0;
        pthread_mutex_unlock(&gLock);
        if (changed) Notify(object, kAudioBooleanControlPropertyValue, 0);
        return kAudioHardwareNoError;
    }
    default:
        return kAudioHardwareBadObjectError;
    }
}

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client) {
    pthread_mutex_lock(&gLock);
    if (gIOCount++ == 0) {
        gAnchorHostTime = mach_absolute_time();
        gPeriods = 0;
    }
    pthread_mutex_unlock(&gLock);
    return kAudioHardwareNoError;
}

static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client) {
    pthread_mutex_lock(&gLock);
    if (gIOCount > 0) gIOCount--;
    pthread_mutex_unlock(&gLock);
    return kAudioHardwareNoError;
}

// Relógio ideal derivado do host time: um "zero time stamp" a cada kPeriodFrames.
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client,
                                 Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    Float64 ticksPerPeriod = gHostTicksPerFrame * kPeriodFrames;
    UInt64 now = mach_absolute_time();
    while (gAnchorHostTime + (UInt64)((gPeriods + 1) * ticksPerPeriod) <= now) gPeriods++;
    *outSampleTime = (Float64)gPeriods * kPeriodFrames;
    *outHostTime = gAnchorHostTime + (UInt64)(gPeriods * ticksPerPeriod);
    *outSeed = 1;
    return kAudioHardwareNoError;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client,
                                  UInt32 operation, Boolean *outWillDo, Boolean *outInPlace) {
    *outWillDo = operation == kAudioServerPlugInIOOperationWriteMix;
    *outInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client,
                                 UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *info) {
    return kAudioHardwareNoError;
}

// O mix chega aqui e é descartado: quem lê o áudio é o tap do LowerX.
static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, AudioObjectID stream,
                              UInt32 client, UInt32 operation, UInt32 frames,
                              const AudioServerPlugInIOCycleInfo *info, void *main, void *secondary) {
    return kAudioHardwareNoError;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client,
                               UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *info) {
    return kAudioHardwareNoError;
}

static AudioServerPlugInDriverInterface gInterface = {
    NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice,
    AddDeviceClient, RemoveDeviceClient, PerformConfigurationChange, AbortConfigurationChange,
    HasProperty, IsPropertySettable, GetPropertyDataSize, GetPropertyData, SetPropertyData,
    StartIO, StopIO, GetZeroTimeStamp, WillDoIOOperation, BeginIOOperation, DoIOOperation, EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePointer = &gInterface;
static AudioServerPlugInDriverRef gDriver = &gInterfacePointer;

static HRESULT QueryInterface(void *driver, REFIID uuid, LPVOID *out) {
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        AddRef(driver);
        *out = gDriver;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG AddRef(void *driver) {
    pthread_mutex_lock(&gLock);
    ULONG count = ++gRefCount;
    pthread_mutex_unlock(&gLock);
    return count;
}

static ULONG Release(void *driver) {
    pthread_mutex_lock(&gLock);
    ULONG count = gRefCount > 0 ? --gRefCount : 0;
    pthread_mutex_unlock(&gLock);
    return count;
}

// Fábrica registrada no Info.plist (CFPlugInFactories).
__attribute__((visibility("default")))
void *LowerX71_Create(CFAllocatorRef allocator, CFUUIDRef type) {
    return CFEqual(type, kAudioServerPlugInTypeUUID) ? gDriver : NULL;
}
