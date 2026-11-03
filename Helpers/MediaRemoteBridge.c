// Ponte para o "Tocando Agora" do macOS (MediaRemote): o que toca em qualquer app, inclusive navegadores.
//
// Desde o macOS 15.4 o MediaRemote só responde a processos da própria Apple. Por isso esta biblioteca
// é carregada pelo /usr/bin/perl do sistema (mesmo método do NotchNook e do Boring Notch) e conversa
// com o app pela saída padrão:
//   - sem variáveis: fica rodando e escreve uma linha JSON a cada mudança;
//   - SK_MR_COMMAND=<n>: manda um comando (2 = tocar/pausar, 4 = próxima, 5 = anterior) e sai.
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <math.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef void (*GetInfoFn)(CFTypeRef origin, Boolean withArtwork, dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetBoolFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetPIDFn)(dispatch_queue_t, void (^)(int));
typedef Boolean (*SendCommandFn)(int, CFDictionaryRef);

static GetInfoFn getInfo;
static GetBoolFn getIsPlaying;
static GetPIDFn getPID;

// MARK: JSON

typedef struct { char *data; size_t length, capacity; } Buffer;

static void append(Buffer *b, const char *text, size_t length) {
    if (b->length + length + 1 > b->capacity) {
        b->capacity = (b->length + length + 1) * 2;
        b->data = realloc(b->data, b->capacity);
    }
    memcpy(b->data + b->length, text, length);
    b->length += length;
    b->data[b->length] = 0;
}

static void appendText(Buffer *b, const char *text) { append(b, text, strlen(text)); }

static void appendString(Buffer *b, CFStringRef value) {
    appendText(b, "\"");
    if (value) {
        CFIndex size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(value), kCFStringEncodingUTF8) + 1;
        char *utf8 = malloc(size);
        if (CFStringGetCString(value, utf8, size, kCFStringEncodingUTF8)) {
            for (char *c = utf8; *c; c++) {
                char escaped[8];
                if (*c == '"' || *c == '\\') { escaped[0] = '\\'; escaped[1] = *c; append(b, escaped, 2); }
                else if ((unsigned char)*c < 0x20) { snprintf(escaped, sizeof escaped, "\\u%04x", *c); appendText(b, escaped); }
                else append(b, c, 1);
            }
        }
        free(utf8);
    }
    appendText(b, "\"");
}

static double number(CFDictionaryRef info, CFStringRef key) {
    CFTypeRef value = CFDictionaryGetValue(info, key);
    double result = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberDoubleType, &result);
    return isfinite(result) ? result : 0; // transmissões ao vivo têm duração infinita (inválida em JSON)
}

static CFStringRef string(CFDictionaryRef info, CFStringRef key) {
    CFTypeRef value = CFDictionaryGetValue(info, key);
    return value && CFGetTypeID(value) == CFStringGetTypeID() ? value : NULL;
}

static void appendBase64(Buffer *b, CFDataRef data) {
    static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const UInt8 *bytes = CFDataGetBytePtr(data);
    CFIndex length = CFDataGetLength(data);
    char chunk[4];
    for (CFIndex i = 0; i < length; i += 3) {
        UInt32 n = (UInt32)bytes[i] << 16;
        if (i + 1 < length) n |= (UInt32)bytes[i + 1] << 8;
        if (i + 2 < length) n |= bytes[i + 2];
        chunk[0] = table[(n >> 18) & 63];
        chunk[1] = table[(n >> 12) & 63];
        chunk[2] = i + 1 < length ? table[(n >> 6) & 63] : '=';
        chunk[3] = i + 2 < length ? table[n & 63] : '=';
        append(b, chunk, 4);
    }
}

// MARK: Leitura

static char *lastLine;
static unsigned long lastArtworkHash;
static CFStringRef lastArtworkIdentifier;
static CFDataRef currentArtwork;
static void requestArtwork(void);

static unsigned long hashData(CFDataRef data) {
    unsigned long hash = 5381;
    const UInt8 *bytes = CFDataGetBytePtr(data);
    CFIndex length = CFDataGetLength(data);
    for (CFIndex i = 0; i < length; i += (length / 512) + 1) hash = hash * 33 + bytes[i];
    return hash ^ (unsigned long)length;
}

static void emit(CFDictionaryRef info, Boolean playing, int pid) {
    Buffer b = {0};
    appendText(&b, "{");
    if (info) {
        char numbers[256];
        appendText(&b, "\"title\":"); appendString(&b, string(info, CFSTR("kMRMediaRemoteNowPlayingInfoTitle")));
        appendText(&b, ",\"artist\":"); appendString(&b, string(info, CFSTR("kMRMediaRemoteNowPlayingInfoArtist")));
        appendText(&b, ",\"album\":"); appendString(&b, string(info, CFSTR("kMRMediaRemoteNowPlayingInfoAlbum")));
        CFTypeRef timestamp = CFDictionaryGetValue(info, CFSTR("kMRMediaRemoteNowPlayingInfoTimestamp"));
        double time = timestamp && CFGetTypeID(timestamp) == CFDateGetTypeID()
            ? CFDateGetAbsoluteTime(timestamp) + kCFAbsoluteTimeIntervalSince1970 : 0;
        snprintf(numbers, sizeof numbers, ",\"duration\":%.3f,\"elapsed\":%.3f,\"rate\":%.3f,\"timestamp\":%.3f,",
                 number(info, CFSTR("kMRMediaRemoteNowPlayingInfoDuration")),
                 number(info, CFSTR("kMRMediaRemoteNowPlayingInfoElapsedTime")),
                 number(info, CFSTR("kMRMediaRemoteNowPlayingInfoPlaybackRate")), time);
        appendText(&b, numbers);
    }
    char tail[64];
    snprintf(tail, sizeof tail, "\"playing\":%s,\"pid\":%d", playing ? "true" : "false", pid);
    appendText(&b, tail);

    // A capa só vai quando muda (é grande). Sem a imagem na resposta, a capa anterior continua valendo,
    // a não ser que a música/vídeo tenha mudado (aí a capa é apagada até a nova chegar).
    Buffer artwork = {0};
    CFTypeRef data = info ? CFDictionaryGetValue(info, CFSTR("kMRMediaRemoteNowPlayingInfoArtworkData")) : NULL;
    if (!data) data = currentArtwork;
    CFStringRef identifier = info ? string(info, CFSTR("kMRMediaRemoteNowPlayingInfoArtworkIdentifier")) : NULL;
    Boolean newArtwork = !lastArtworkIdentifier != !identifier
        || (identifier && CFStringCompare(identifier, lastArtworkIdentifier, 0) != kCFCompareEqualTo);
    if (newArtwork) {
        if (currentArtwork) CFRelease(currentArtwork);
        currentArtwork = NULL;
        data = info ? CFDictionaryGetValue(info, CFSTR("kMRMediaRemoteNowPlayingInfoArtworkData")) : NULL;
        if (lastArtworkIdentifier) CFRelease(lastArtworkIdentifier);
        lastArtworkIdentifier = identifier ? CFRetain(identifier) : NULL;
        if (identifier) requestArtwork();
    }
    unsigned long hash = data && CFGetTypeID(data) == CFDataGetTypeID() ? hashData(data) : (newArtwork ? 0 : lastArtworkHash);
    if (hash != lastArtworkHash) {
        appendText(&artwork, ",\"artwork\":\"");
        if (hash) appendBase64(&artwork, data);
        appendText(&artwork, "\"");
    }

    if (!lastLine || strcmp(lastLine, b.data) != 0 || artwork.length) {
        fputs(b.data, stdout);
        if (artwork.length) fputs(artwork.data, stdout);
        fputs("}\n", stdout);
        fflush(stdout);
        free(lastLine);
        lastLine = strdup(b.data);
        lastArtworkHash = hash;
    }
    free(b.data);
    free(artwork.data);
}

// O MediaRemote só responde de forma confiável a quem se registra para os avisos de mudança e
// mantém um run loop rodando; perguntar em loop faz ele parar de responder depois de alguns segundos.
static CFDictionaryRef currentInfo;
static Boolean currentPlaying;
static int currentPID;

// A capa não vem junto com as informações: é pedida à parte, pela fila de reprodução, com o tamanho
// da imagem (como faz o player da barra de menu). Uma vez por música/vídeo.
typedef void (*RequestQueueFn)(id request, id playerPath, dispatch_queue_t, void (^)(id queue, id error));
static RequestQueueFn requestQueue;

static void requestArtwork(void) {
    Class requestClass = objc_getClass("MRPlaybackQueueRequest");
    if (!requestQueue || !requestClass) return;
    id request = ((id (*)(Class, SEL))objc_msgSend)(requestClass, sel_registerName("defaultPlaybackQueueRequest"));
    int side = 300;
    CFNumberRef size = CFNumberCreate(NULL, kCFNumberIntType, &side);
    ((void (*)(id, SEL, id, id))objc_msgSend)(request, sel_registerName("setValue:forKey:"), (id)size, (id)CFSTR("artworkWidth"));
    ((void (*)(id, SEL, id, id))objc_msgSend)(request, sel_registerName("setValue:forKey:"), (id)size, (id)CFSTR("artworkHeight"));
    CFRelease(size);

    requestQueue(request, NULL, dispatch_get_main_queue(), ^(id queue, id error) {
        if (!queue) return;
        id items = ((id (*)(id, SEL))objc_msgSend)(queue, sel_registerName("contentItems"));
        id item = items ? ((id (*)(id, SEL))objc_msgSend)(items, sel_registerName("firstObject")) : NULL;
        id artwork = item ? ((id (*)(id, SEL))objc_msgSend)(item, sel_registerName("artwork")) : NULL;
        CFDataRef image = artwork ? (CFDataRef)((id (*)(id, SEL))objc_msgSend)(artwork, sel_registerName("imageData")) : NULL;
        if (!image || CFDataGetLength(image) == 0) return;
        if (currentArtwork) CFRelease(currentArtwork);
        currentArtwork = CFRetain(image);
        emit(currentInfo, currentPlaying, currentPID);
    });
}

static void fetchAll(void) {
    dispatch_queue_t main = dispatch_get_main_queue();
    getInfo(NULL, false, main, ^(CFDictionaryRef value) {
        if (currentInfo) CFRelease(currentInfo);
        currentInfo = value ? CFRetain(value) : NULL;
        emit(currentInfo, currentPlaying, currentPID);
    });
    getIsPlaying(main, ^(Boolean value) {
        currentPlaying = value;
        emit(currentInfo, currentPlaying, currentPID);
    });
    getPID(main, ^(int value) {
        currentPID = value;
        emit(currentInfo, currentPlaying, currentPID);
    });
}

static void changed(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                    const void *object, CFDictionaryRef userInfo) {
    fetchAll();
}

static pid_t parent;

static void tick(CFRunLoopTimerRef timer, void *info) {
    if (getppid() != parent) exit(0); // o ShortcutKey fechou
    fetchAll();
}

typedef void (*RegisterFn)(dispatch_queue_t);

__attribute__((constructor)) static void start(void) {
    void *framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!framework) exit(1);

    const char *command = getenv("SK_MR_COMMAND");
    if (command) {
        SendCommandFn send = (SendCommandFn)dlsym(framework, "MRMediaRemoteSendCommand");
        if (send) send(atoi(command), NULL);
        usleep(200000);
        exit(0);
    }

    getInfo = (GetInfoFn)dlsym(framework, "MRMediaRemoteGetNowPlayingInfoWithOptionalArtwork");
    requestQueue = (RequestQueueFn)dlsym(framework, "MRMediaRemoteRequestNowPlayingPlaybackQueueForPlayer");
    getIsPlaying = (GetBoolFn)dlsym(framework, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getPID = (GetPIDFn)dlsym(framework, "MRMediaRemoteGetNowPlayingApplicationPID");
    RegisterFn registerForNotifications = (RegisterFn)dlsym(framework, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getIsPlaying || !getPID || !registerForNotifications) exit(1);

    parent = getppid();
    registerForNotifications(dispatch_get_main_queue());
    CFNotificationCenterRef center = CFNotificationCenterGetLocalCenter();
    const CFStringRef names[] = {
        CFSTR("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
        CFSTR("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
        CFSTR("kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
        // A capa chega depois do resto das informações, com este aviso.
        CFSTR("kMRPlaybackQueueContentItemArtworkChangedNotification"),
    };
    for (int i = 0; i < 4; i++) {
        CFNotificationCenterAddObserver(center, NULL, changed, names[i], NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }

    fetchAll();
    // Uma conferida de vez em quando, caso algum aviso se perca.
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 3, 3, 0, 0, tick, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
    CFRunLoopRun();
    exit(0);
}
