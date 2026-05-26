// LineHRU — Hide Read + Block Unsend for LINE
// References K2GE3Air's hookpoints: readUpToMessageID / lastReceivedMessageID /
// setReadUpToMessageID: / alreadyInserted / setAlreadyInserted:

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <unistd.h>

#define LOG_PATH @"/var/mobile/Library/Caches/LineHRU.log"

static NSMutableDictionary<NSString *, NSValue *> *g_origIMPs;

static void hlog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *out = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], line];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:LOG_PATH];
    if (!fh) {
        [out writeToFile:LOG_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
    NSLog(@"[LineHRU] %@", line);
}

static NSString *origKey(Class c, SEL s) {
    return [NSString stringWithFormat:@"%s_%s", class_getName(c), sel_getName(s)];
}

static IMP getOrig(id self, SEL _cmd) {
    NSString *k = origKey(object_getClass(self), _cmd);
    NSValue *v = g_origIMPs[k];
    return v ? (IMP)[v pointerValue] : NULL;
}

static BOOL hideReadOn(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"LineHRU.hideRead"];
}
static BOOL blockUnsendOn(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"LineHRU.blockUnsend"];
}

// ---- Hide Read hooks ----
static id hook_readUpToMessageID(id self, SEL _cmd) {
    IMP o = getOrig(self, _cmd);
    if (!hideReadOn()) {
        return o ? ((id(*)(id, SEL))o)(self, _cmd) : nil;
    }
    return nil;
}
static void hook_setReadUpToMessageID(id self, SEL _cmd, id val) {
    if (!hideReadOn()) {
        IMP o = getOrig(self, _cmd);
        if (o) ((void(*)(id, SEL, id))o)(self, _cmd, val);
        return;
    }
    // drop: don't record read cursor
}
static id hook_lastReceivedMessageID(id self, SEL _cmd) {
    IMP o = getOrig(self, _cmd);
    if (!hideReadOn()) {
        return o ? ((id(*)(id, SEL))o)(self, _cmd) : nil;
    }
    return nil;
}

// ---- Block Unsend hooks ----
// LINE unsend flow: when a message is recalled, alreadyInserted is toggled to mark
// "should be removed from UI / DB". Forcing the getter to YES and ignoring setter=NO
// causes unsend to be a no-op for our side.
static BOOL hook_alreadyInserted(id self, SEL _cmd) {
    IMP o = getOrig(self, _cmd);
    if (!blockUnsendOn()) {
        return o ? ((BOOL(*)(id, SEL))o)(self, _cmd) : NO;
    }
    return YES;
}
static void hook_setAlreadyInserted(id self, SEL _cmd, BOOL val) {
    if (!blockUnsendOn()) {
        IMP o = getOrig(self, _cmd);
        if (o) ((void(*)(id, SEL, BOOL))o)(self, _cmd, val);
        return;
    }
    if (val) {
        IMP o = getOrig(self, _cmd);
        if (o) ((void(*)(id, SEL, BOOL))o)(self, _cmd, val);
    }
    // drop: don't unset (don't mark message as "to be removed")
}

static BOOL isLineClass(Class c) {
    const char *imgName = class_getImageName(c);
    if (!imgName) return NO;
    if (strstr(imgName, "/System/Library/")) return NO;
    if (strstr(imgName, "/usr/lib/")) return NO;
    if (strstr(imgName, "/var/jb/usr/lib/TweakInject/")) return NO;
    if (strstr(imgName, "LineHRU")) return NO;
    return YES;
}

static int discover_and_hook(SEL sel, IMP newImp, const char *label) {
    unsigned int n = 0;
    Class *classes = objc_copyClassList(&n);
    int hooked = 0;
    for (unsigned i = 0; i < n; i++) {
        Class c = classes[i];
        if (!c) continue;
        if (!isLineClass(c)) continue;
        unsigned int methCount = 0;
        Method *methods = class_copyMethodList(c, &methCount);
        BOOL has = NO;
        for (unsigned j = 0; j < methCount; j++) {
            if (sel_isEqual(method_getName(methods[j]), sel)) { has = YES; break; }
        }
        if (methods) free(methods);
        if (!has) continue;
        IMP orig = NULL;
        MSHookMessageEx(c, sel, newImp, &orig);
        if (orig) {
            g_origIMPs[origKey(c, sel)] = [NSValue valueWithPointer:orig];
        }
        hlog(@"[%s] hooked -[%s %s]", label, class_getName(c), sel_getName(sel));
        hooked++;
    }
    if (classes) free(classes);
    return hooked;
}

__attribute__((constructor))
static void lineHRU_init(void) {
    @autoreleasepool {
        g_origIMPs = [NSMutableDictionary dictionary];

        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if (![d objectForKey:@"LineHRU.hideRead"])    [d setBool:YES forKey:@"LineHRU.hideRead"];
        if (![d objectForKey:@"LineHRU.blockUnsend"]) [d setBool:YES forKey:@"LineHRU.blockUnsend"];
        [d synchronize];

        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        hlog(@"=== LineHRU loaded into %@ (pid=%d) ===", bid, getpid());
        hlog(@"hideRead=%d blockUnsend=%d", hideReadOn(), blockUnsendOn());

        int total = 0;
        total += discover_and_hook(@selector(readUpToMessageID),
                                   (IMP)hook_readUpToMessageID, "HR/readUpTo");
        total += discover_and_hook(NSSelectorFromString(@"setReadUpToMessageID:"),
                                   (IMP)hook_setReadUpToMessageID, "HR/setReadUpTo");
        total += discover_and_hook(@selector(lastReceivedMessageID),
                                   (IMP)hook_lastReceivedMessageID, "HR/lastRecv");

        total += discover_and_hook(@selector(alreadyInserted),
                                   (IMP)hook_alreadyInserted, "BU/get");
        total += discover_and_hook(NSSelectorFromString(@"setAlreadyInserted:"),
                                   (IMP)hook_setAlreadyInserted, "BU/set");

        hlog(@"hook setup complete: %d hooks across %lu cached origs",
             total, (unsigned long)g_origIMPs.count);
    }
}
