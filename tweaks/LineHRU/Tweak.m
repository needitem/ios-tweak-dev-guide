// LineHRU v0.5 — comprehensive LINE 15.7.2 tweak
//
// Features
// ========
//
//   sqlite-level
//     • Block Unsend  – DELETE FROM ZMESSAGE with non-NULL ZSENDER short-circuits
//                       to SQLITE_DONE. ZSENDER lookup runs on the same connection.
//     • Hide Read     – UPDATE … ZREADUPTOMESSAGEIDSYNCED … is substituted with
//                       `SELECT 0 WHERE 0`.
//
//   ObjC-level (modelled on K2GE3Air's hookpoints, identified via Frida enum)
//     • Ad Block         – -[LineAdvertiseSDK2.LADAdvertise initWithCoder:]
//                          returns nil, so ad payloads fail to deserialise.
//     • Track Unsent     – -[LineMessage setContentMetadata:] records each call
//                          (length + bplist top-level keys) to the ring buffer.
//     • Track Send       – -[ManagedMessage sendWithCompletionHandler:] records
//                          self.description prefix to the ring buffer.
//     • Track Ops        – -[LineOperation setParam3:] records the new param to
//                          the ring buffer.
//     • Track Config     – -[LineConfigurations configMap] records the returned
//                          dictionary key count to the ring buffer.
//
//   In-app overlay
//     • LineMessagingUI.ChatTitleView long-press (1s) → UIAlertController action
//       sheet with one toggle per feature + recent-blocks viewer + counter reset.
//
// Excluded (deliberate)
//   ▸ NLAgeVerificationManager bypass (age-gate / parental controls)
//   ▸ LineShopProductDetail priceTier override (paid sticker theft)

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <unistd.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>

@class UIView, UIWindow, UIWindowScene, UIApplication, UIViewController;
@class UIAlertController, UIAlertAction, UILongPressGestureRecognizer;

#define LOG_PATH @"/var/mobile/Library/Caches/LineHRU.log"
#define UIGestureRecognizerStateBegan     1
#define UIAlertControllerStyleActionSheet 0
#define UIAlertActionStyleDefault         0
#define UIAlertActionStyleCancel          1
#define UIAlertActionStyleDestructive     2

// ============================================================================
// sqlite3 layer
// ============================================================================

typedef int       (*sqlite3_prepare_v2_fn)(void*, const char*, int, void**, const char**);
typedef int       (*sqlite3_prepare_v3_fn)(void*, const char*, int, unsigned int, void**, const char**);
typedef int       (*sqlite3_step_fn)(void*);
typedef int       (*sqlite3_finalize_fn)(void*);
typedef char*     (*sqlite3_expanded_sql_fn)(void*);
typedef void      (*sqlite3_free_fn)(void*);
typedef int       (*sqlite3_bind_int64_fn)(void*, int, long long);
typedef int       (*sqlite3_column_type_fn)(void*, int);

#define SQLITE_OK    0
#define SQLITE_ROW   100
#define SQLITE_DONE  101
#define SQLITE_NULL  5

static sqlite3_prepare_v2_fn  orig_sqlite3_prepare_v2 = NULL;
static sqlite3_prepare_v3_fn  orig_sqlite3_prepare_v3 = NULL;
static sqlite3_step_fn        orig_sqlite3_step       = NULL;
static sqlite3_finalize_fn    orig_sqlite3_finalize   = NULL;

static sqlite3_expanded_sql_fn  p_expanded_sql  = NULL;
static sqlite3_free_fn          p_sqlite3_free  = NULL;
static sqlite3_bind_int64_fn    p_bind_int64    = NULL;
static sqlite3_column_type_fn   p_column_type   = NULL;

// counters
static atomic_int g_block_unsend  = 0;
static atomic_int g_block_read    = 0;
static atomic_int g_block_ad      = 0;
static atomic_int g_track_unsent  = 0;
static atomic_int g_track_send    = 0;
static atomic_int g_track_op      = 0;
static atomic_int g_track_config  = 0;
static atomic_int g_allow_delete  = 0;
static atomic_int g_lookup_errors = 0;

#define LH_RING_CAP 48
static NSMutableArray<NSString*> *g_ring = nil;
static dispatch_queue_t g_ring_q = NULL;

static __thread void *tls_suspect_stmt = NULL;
static __thread void *tls_suspect_db   = NULL;

static void hlog(NSString *fmt, ...) __attribute__((format(__NSString__, 1, 2)));
static void hlog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
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

static void ring_push(NSString *entry) {
    if (!g_ring_q || !g_ring) return;
    dispatch_async(g_ring_q, ^{
        if (g_ring.count >= LH_RING_CAP) [g_ring removeObjectAtIndex:0];
        [g_ring addObject:entry];
    });
}

static NSArray<NSString*> *ring_snapshot(void) {
    if (!g_ring_q || !g_ring) return @[];
    __block NSArray *snap = nil;
    dispatch_sync(g_ring_q, ^{ snap = [g_ring copy]; });
    return snap ?: @[];
}

static void ring_clear(void) {
    if (!g_ring_q || !g_ring) return;
    dispatch_async(g_ring_q, ^{ [g_ring removeAllObjects]; });
}

#define DEFAULT_BOOL_TRUE(k)   if (![d objectForKey:k]) [d setBool:YES forKey:k]
#define DEFAULT_BOOL_FALSE(k)  if (![d objectForKey:k]) [d setBool:NO  forKey:k]
static BOOL prefBlockUnsend(void)   { return [[NSUserDefaults standardUserDefaults] boolForKey:@"LineHRU.blockUnsend"]; }
static BOOL prefHideRead(void)      { return [[NSUserDefaults standardUserDefaults] boolForKey:@"LineHRU.hideRead"]; }
static BOOL prefAdBlock(void)       { return [[NSUserDefaults standardUserDefaults] boolForKey:@"LineHRU.adBlock"]; }
static BOOL prefTrackUnsent(void)   { return [[NSUserDefaults standardUserDefaults] boolForKey:@"LineHRU.trackUnsent"]; }
static BOOL prefTrackSend(void)     { return [[NSUserDefaults standardUserDefaults] boolForKey:@"LineHRU.trackSend"]; }
static BOOL prefTrackOps(void)      { return [[NSUserDefaults standardUserDefaults] boolForKey:@"LineHRU.trackOps"]; }
static BOOL prefTrackConfig(void)   { return [[NSUserDefaults standardUserDefaults] boolForKey:@"LineHRU.trackConfig"]; }

static int is_unsend_candidate(const char *sql) {
    if (!sql) return 0;
    const char *p = sql;
    while (*p == ' ' || *p == '\t' || *p == '\n') p++;
    return (strncmp(p, "DELETE FROM ZMESSAGE WHERE Z_PK", 31) == 0) ? 1 : 0;
}

static int is_hide_read_candidate(const char *sql) {
    if (!sql) return 0;
    const char *p = sql;
    while (*p == ' ' || *p == '\t' || *p == '\n') p++;
    if (strncmp(p, "UPDATE", 6) != 0 && strncmp(p, "update", 6) != 0) return 0;
    return strstr(sql, "ZREADUPTOMESSAGEIDSYNCED") ? 1 : 0;
}

static long long parse_pk_from_expanded(const char *expanded) {
    if (!expanded) return -1;
    const char *p = strstr(expanded, "Z_PK");
    if (!p) return -1;
    p += 4;
    while (*p == ' ' || *p == '\t' || *p == '=') p++;
    if (*p < '0' || *p > '9') return -1;
    return strtoll(p, NULL, 10);
}

static int zsender_is_remote(void *db, long long pk) {
    if (!db || !orig_sqlite3_prepare_v2 || !orig_sqlite3_step || !orig_sqlite3_finalize ||
        !p_bind_int64 || !p_column_type) return -1;
    static const char *kQ = "SELECT ZSENDER FROM ZMESSAGE WHERE Z_PK = ?";
    void *stmt = NULL;
    int rc = orig_sqlite3_prepare_v2(db, kQ, -1, &stmt, NULL);
    if (rc != SQLITE_OK || !stmt) {
        atomic_fetch_add(&g_lookup_errors, 1);
        if (stmt) orig_sqlite3_finalize(stmt);
        return -1;
    }
    p_bind_int64(stmt, 1, pk);
    int result = -1;
    if (orig_sqlite3_step(stmt) == SQLITE_ROW) {
        result = (p_column_type(stmt, 0) == SQLITE_NULL) ? 0 : 1;
    }
    orig_sqlite3_finalize(stmt);
    return result;
}

static const char *kNoopSQL = "SELECT 0 WHERE 0";

static int hk_sqlite3_prepare_v2(void* db, const char* sql, int nbytes,
                                 void** stmt, const char** tail) {
    if (sql && prefHideRead() && is_hide_read_candidate(sql)) {
        int rc = orig_sqlite3_prepare_v2(db, kNoopSQL, (int)strlen(kNoopSQL), stmt, tail);
        if (rc == SQLITE_OK) {
            atomic_fetch_add(&g_block_read, 1);
            ring_push([NSString stringWithFormat:@"%@  read  %.180s", [NSDate date], sql]);
        }
        return rc;
    }
    int rc = orig_sqlite3_prepare_v2(db, sql, nbytes, stmt, tail);
    if (rc == SQLITE_OK && stmt && *stmt && prefBlockUnsend() && is_unsend_candidate(sql)) {
        tls_suspect_stmt = *stmt;
        tls_suspect_db   = db;
    }
    return rc;
}

static int hk_sqlite3_prepare_v3(void* db, const char* sql, int nbytes,
                                 unsigned int flags, void** stmt, const char** tail) {
    if (sql && prefHideRead() && is_hide_read_candidate(sql)) {
        int rc = orig_sqlite3_prepare_v3(db, kNoopSQL, (int)strlen(kNoopSQL), flags, stmt, tail);
        if (rc == SQLITE_OK) {
            atomic_fetch_add(&g_block_read, 1);
            ring_push([NSString stringWithFormat:@"%@  read  %.180s", [NSDate date], sql]);
        }
        return rc;
    }
    int rc = orig_sqlite3_prepare_v3(db, sql, nbytes, flags, stmt, tail);
    if (rc == SQLITE_OK && stmt && *stmt && prefBlockUnsend() && is_unsend_candidate(sql)) {
        tls_suspect_stmt = *stmt;
        tls_suspect_db   = db;
    }
    return rc;
}

static int hk_sqlite3_step(void *stmt) {
    if (stmt && stmt == tls_suspect_stmt) {
        void *db = tls_suspect_db;
        tls_suspect_stmt = NULL;
        tls_suspect_db   = NULL;
        if (db && p_expanded_sql) {
            char *exp = p_expanded_sql(stmt);
            long long pk = parse_pk_from_expanded(exp);
            NSString *expStr = exp ? [NSString stringWithUTF8String:exp] : @"<?>";
            if (p_sqlite3_free && exp) p_sqlite3_free(exp);
            if (pk > 0) {
                int remote = zsender_is_remote(db, pk);
                if (remote == 1) {
                    atomic_fetch_add(&g_block_unsend, 1);
                    ring_push([NSString stringWithFormat:@"%@  unsend  Z_PK=%lld  %@",
                               [NSDate date], pk, expStr]);
                    return SQLITE_DONE;
                }
                atomic_fetch_add(&g_allow_delete, 1);
            }
        }
    }
    return orig_sqlite3_step(stmt);
}

static int hk_sqlite3_finalize(void *stmt) {
    if (stmt && stmt == tls_suspect_stmt) {
        tls_suspect_stmt = NULL;
        tls_suspect_db   = NULL;
    }
    return orig_sqlite3_finalize(stmt);
}

// ============================================================================
// ObjC-level hooks
// ============================================================================

// -- Ad Block ---------------------------------------------------------------
//
// LineAdvertiseSDK2.LADAdvertise is the NSKeyedArchiver model for an ad payload.
// Returning nil from initWithCoder: makes every cached/inflated ad fail to
// deserialise; the caller treats that as "no ad available", so banner slots
// stay empty rather than crashing.

static IMP orig_LADAdvertise_initWithCoder = NULL;
static id hk_LADAdvertise_initWithCoder(id self, SEL _cmd, id coder) {
    if (prefAdBlock()) {
        atomic_fetch_add(&g_block_ad, 1);
        return nil;
    }
    return ((id(*)(id, SEL, id))orig_LADAdvertise_initWithCoder)(self, _cmd, coder);
}

// -- Track Unsent (LineMessage.setContentMetadata:) -------------------------
//
// LINE's unsent flow eventually writes a marker into the LineMessage's
// contentMetadata NSDictionary. Logging the value (BLOB length + first few hex
// bytes) lets the user inspect what the marker actually looks like — useful
// when refining the sqlite-level rule.

static IMP orig_LineMessage_setContentMetadata = NULL;
static void hk_LineMessage_setContentMetadata(id self, SEL _cmd, NSData *metadata) {
    if (prefTrackUnsent()) {
        atomic_fetch_add(&g_track_unsent, 1);
        NSUInteger len = [metadata isKindOfClass:[NSData class]] ? metadata.length : 0;
        NSString *hex = @"<nil>";
        if (len > 0) {
            const unsigned char *b = metadata.bytes;
            NSUInteger n = MIN((NSUInteger)32, len);
            NSMutableString *s = [NSMutableString stringWithCapacity:n*3];
            for (NSUInteger i=0; i<n; i++) [s appendFormat:@"%02x ", b[i]];
            hex = s;
        }
        ring_push([NSString stringWithFormat:@"%@  setContentMetadata  len=%lu  hex=%@",
                   [NSDate date], (unsigned long)len, hex]);
    }
    ((void(*)(id, SEL, NSData*))orig_LineMessage_setContentMetadata)(self, _cmd, metadata);
}

// -- Track Send (ManagedMessage.sendWithCompletionHandler:) ----------------

static IMP orig_ManagedMessage_send = NULL;
static void hk_ManagedMessage_send(id self, SEL _cmd, id completion) {
    if (prefTrackSend()) {
        atomic_fetch_add(&g_track_send, 1);
        NSString *desc = @"<?>";
        @try {
            id text = [self valueForKey:@"text"];      // ZTEXT
            id chat = [self valueForKey:@"chat"];      // ZCHAT (relationship)
            id chatMID = chat ? [chat valueForKey:@"mid"] : nil;
            desc = [NSString stringWithFormat:@"to=%@ text=%@",
                    chatMID ?: @"?",
                    [text isKindOfClass:[NSString class]] ? text : @"<?>"];
        } @catch (__unused NSException *e) {}
        ring_push([NSString stringWithFormat:@"%@  send  %@", [NSDate date], desc]);
    }
    ((void(*)(id, SEL, id))orig_ManagedMessage_send)(self, _cmd, completion);
}

// -- Track Operation (LineOperation.setParam3:) -----------------------------

static IMP orig_LineOperation_setParam3 = NULL;
static void hk_LineOperation_setParam3(id self, SEL _cmd, NSString *p3) {
    if (prefTrackOps()) {
        atomic_fetch_add(&g_track_op, 1);
        NSString *typeRepr = @"?";
        @try {
            id t = [self valueForKey:@"type"];
            if (t) typeRepr = [t description];
        } @catch (__unused NSException *e) {}
        ring_push([NSString stringWithFormat:@"%@  op  type=%@  param3=%@",
                   [NSDate date], typeRepr,
                   [p3 isKindOfClass:[NSString class]] ? p3 : @"<?>"]);
    }
    ((void(*)(id, SEL, NSString*))orig_LineOperation_setParam3)(self, _cmd, p3);
}

// -- Track Config (LineConfigurations.configMap) ----------------------------

static IMP orig_LineConfigurations_configMap = NULL;
static id hk_LineConfigurations_configMap(id self, SEL _cmd) {
    id result = ((id(*)(id, SEL))orig_LineConfigurations_configMap)(self, _cmd);
    if (prefTrackConfig()) {
        atomic_fetch_add(&g_track_config, 1);
        NSUInteger n = ([result isKindOfClass:[NSDictionary class]]) ? [result count] : 0;
        // Only every 50th call to avoid log flooding
        if (atomic_load(&g_track_config) % 50 == 1) {
            ring_push([NSString stringWithFormat:@"%@  configMap  keys=%lu",
                       [NSDate date], (unsigned long)n]);
        }
    }
    return result;
}

// ============================================================================
// In-app settings overlay
// ============================================================================

static IMP orig_ChatTitleView_layoutSubviews = NULL;
static char kRecognizerInstalledKey;

static id keyWindow(void) {
    Class UIAppCls = objc_getClass("UIApplication");
    id app = ((id(*)(id, SEL))objc_msgSend)(UIAppCls, sel_registerName("sharedApplication"));
    if (!app) return nil;
    id scenes = ((id(*)(id, SEL))objc_msgSend)(app, sel_registerName("connectedScenes"));
    for (id scene in scenes) {
        NSArray *windows = ((id(*)(id, SEL))objc_msgSend)(scene, sel_registerName("windows"));
        for (id win in windows) {
            BOOL isKey = ((BOOL(*)(id, SEL))objc_msgSend)(win, sel_registerName("isKeyWindow"));
            if (isKey) return win;
        }
        if (windows.count) return windows.firstObject;
    }
    return nil;
}

static id rootPresentingVC(void) {
    id win = keyWindow();
    if (!win) return nil;
    id root = ((id(*)(id, SEL))objc_msgSend)(win, sel_registerName("rootViewController"));
    while (1) {
        id presented = ((id(*)(id, SEL))objc_msgSend)(root, sel_registerName("presentedViewController"));
        if (!presented) break;
        root = presented;
    }
    return root;
}

static id makeAlert(NSString *title, NSString *message, int style) {
    Class C = objc_getClass("UIAlertController");
    SEL S = sel_registerName("alertControllerWithTitle:message:preferredStyle:");
    return ((id(*)(id, SEL, NSString*, NSString*, NSInteger))objc_msgSend)(C, S, title, message, (NSInteger)style);
}

static id makeAlertAction(NSString *title, int style, void (^handler)(id)) {
    Class C = objc_getClass("UIAlertAction");
    SEL S = sel_registerName("actionWithTitle:style:handler:");
    return ((id(*)(id, SEL, NSString*, NSInteger, id))objc_msgSend)(C, S, title, (NSInteger)style, handler);
}

static void addAction(id alert, id action) {
    ((void(*)(id, SEL, id))objc_msgSend)(alert, sel_registerName("addAction:"), action);
}

static void presentVC(id presenter, id vc) {
    ((void(*)(id, SEL, id, BOOL, id))objc_msgSend)(
        presenter, sel_registerName("presentViewController:animated:completion:"), vc, YES, nil);
}

static void presentRecentBlocks(void) {
    NSArray *snap = ring_snapshot();
    NSMutableString *msg = [NSMutableString stringWithCapacity:4096];
    if (snap.count == 0) {
        [msg appendString:@"(no events recorded yet)"];
    } else {
        for (NSString *e in [snap reverseObjectEnumerator]) [msg appendFormat:@"%@\n\n", e];
    }
    id alert = makeAlert(@"LineHRU — recent events (newest first)", msg, UIAlertControllerStyleActionSheet);
    addAction(alert, makeAlertAction(@"Clear", UIAlertActionStyleDestructive, ^(id a) { ring_clear(); }));
    addAction(alert, makeAlertAction(@"Close", UIAlertActionStyleCancel, nil));
    presentVC(rootPresentingVC(), alert);
}

typedef struct { const char *key; const char *label; } LH_Toggle;

static void presentSettings(id anchor) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    static const LH_Toggle togs[] = {
        { "LineHRU.blockUnsend",  "Block Unsend"        },
        { "LineHRU.hideRead",     "Hide Read"           },
        { "LineHRU.adBlock",      "Ad Block"            },
        { "LineHRU.trackUnsent",  "Track Unsent (log)"  },
        { "LineHRU.trackSend",    "Track Send (log)"    },
        { "LineHRU.trackOps",     "Track Ops (log)"     },
        { "LineHRU.trackConfig",  "Track Config (log)"  },
    };
    const size_t nT = sizeof(togs)/sizeof(togs[0]);

    NSString *msg = [NSString stringWithFormat:
        @"v0.5 · counters\n"
        @"  unsend=%d  read=%d  ad=%d\n"
        @"  trackU=%d  trackS=%d  trackO=%d  trackC=%d\n"
        @"  allowDel=%d  errs=%d",
        atomic_load(&g_block_unsend), atomic_load(&g_block_read), atomic_load(&g_block_ad),
        atomic_load(&g_track_unsent), atomic_load(&g_track_send),
        atomic_load(&g_track_op),     atomic_load(&g_track_config),
        atomic_load(&g_allow_delete), atomic_load(&g_lookup_errors)];

    id alert = makeAlert(@"LineHRU", msg, UIAlertControllerStyleActionSheet);

    for (size_t i = 0; i < nT; i++) {
        NSString *key = [NSString stringWithUTF8String:togs[i].key];
        BOOL on = [d boolForKey:key];
        NSString *label = [NSString stringWithFormat:@"%s: %@", togs[i].label, on ? @"ON" : @"OFF"];
        addAction(alert, makeAlertAction(label, UIAlertActionStyleDefault, ^(id a) {
            [d setBool:!on forKey:key];
            [d synchronize];
            hlog(@"toggled %@ -> %d", key, !on);
        }));
    }

    addAction(alert, makeAlertAction(@"View recent events…", UIAlertActionStyleDefault, ^(id a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ presentRecentBlocks(); });
    }));
    addAction(alert, makeAlertAction(@"Reset counters", UIAlertActionStyleDestructive, ^(id a) {
        atomic_store(&g_block_unsend, 0); atomic_store(&g_block_read, 0); atomic_store(&g_block_ad, 0);
        atomic_store(&g_track_unsent, 0); atomic_store(&g_track_send, 0);
        atomic_store(&g_track_op, 0);     atomic_store(&g_track_config, 0);
        atomic_store(&g_allow_delete, 0); atomic_store(&g_lookup_errors, 0);
        ring_clear();
    }));
    addAction(alert, makeAlertAction(@"Cancel", UIAlertActionStyleCancel, nil));

    if (anchor) {
        id pop = ((id(*)(id, SEL))objc_msgSend)(alert, sel_registerName("popoverPresentationController"));
        if (pop) {
            ((void(*)(id, SEL, id))objc_msgSend)(pop, sel_registerName("setSourceView:"), anchor);
            struct CGRect { double x, y, w, h; } bounds =
                ((struct CGRect(*)(id, SEL))objc_msgSend)(anchor, sel_registerName("bounds"));
            ((void(*)(id, SEL, struct CGRect))objc_msgSend)(pop, sel_registerName("setSourceRect:"), bounds);
        }
    }
    presentVC(rootPresentingVC(), alert);
}

static void lineHRU_longPressHandler(id self, SEL _cmd, id g) {
    NSInteger state = ((NSInteger(*)(id, SEL))objc_msgSend)(g, sel_registerName("state"));
    if (state != UIGestureRecognizerStateBegan) return;
    presentSettings(self);
}

static void hk_ChatTitleView_layoutSubviews(id self, SEL _cmd) {
    if (orig_ChatTitleView_layoutSubviews) {
        ((void(*)(id, SEL))orig_ChatTitleView_layoutSubviews)(self, _cmd);
    }
    if (objc_getAssociatedObject(self, &kRecognizerInstalledKey)) return;
    objc_setAssociatedObject(self, &kRecognizerInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    Class LP = objc_getClass("UILongPressGestureRecognizer");
    id lp = ((id(*)(id, SEL))objc_msgSend)(LP, sel_registerName("alloc"));
    lp = ((id(*)(id, SEL, id, SEL))objc_msgSend)(
        lp, sel_registerName("initWithTarget:action:"),
        self, sel_registerName("_lineHRU_longPress:"));
    ((void(*)(id, SEL, double))objc_msgSend)(lp, sel_registerName("setMinimumPressDuration:"), 1.0);
    ((void(*)(id, SEL, BOOL))objc_msgSend)(lp, sel_registerName("setCancelsTouchesInView:"), NO);
    ((void(*)(id, SEL, id))objc_msgSend)(self, sel_registerName("addGestureRecognizer:"), lp);
    ((void(*)(id, SEL, BOOL))objc_msgSend)(self, sel_registerName("setUserInteractionEnabled:"), YES);
}

// ============================================================================
// Hook installation with retry
// ============================================================================

// Install one method swizzle. If the class is not yet loaded, retry in `retrySec`
// seconds. Returns YES if installed (or class is already known-missing in this run).
static void install_hook(NSString *className, SEL sel, IMP newImp, IMP *origPtr,
                         NSString *label, int retrySec) {
    Class c = objc_getClass([className UTF8String]);
    if (!c) {
        // class not loaded yet — schedule retry, ceiling 3 retries
        static NSMutableDictionary<NSString*, NSNumber*> *attempts;
        if (!attempts) attempts = [NSMutableDictionary dictionary];
        NSString *k = [NSString stringWithFormat:@"%@_%s", className, sel_getName(sel)];
        NSInteger n = attempts[k].integerValue + 1;
        attempts[k] = @(n);
        if (n > 6) {
            hlog(@"hook %@ — class %@ never loaded (gave up)", label, className);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(retrySec * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            install_hook(className, sel, newImp, origPtr, label, retrySec);
        });
        return;
    }
    if (!class_getInstanceMethod(c, sel)) {
        hlog(@"hook %@ — selector %s missing on %@", label, sel_getName(sel), className);
        return;
    }
    MSHookMessageEx(c, sel, newImp, origPtr);
    hlog(@"hook %@ installed: -[%@ %s]", label, className, sel_getName(sel));
}

static void installAllObjCHooks(void) {
    // ChatTitleView — settings UI. We also pre-register the long-press selector here.
    Class chatTitleView = objc_getClass("LineMessagingUI.ChatTitleView");
    if (chatTitleView && !class_getInstanceMethod(chatTitleView, sel_registerName("_lineHRU_longPress:"))) {
        class_addMethod(chatTitleView, sel_registerName("_lineHRU_longPress:"),
                        (IMP)lineHRU_longPressHandler, "v@:@");
    }
    install_hook(@"LineMessagingUI.ChatTitleView",  @selector(layoutSubviews),
                 (IMP)hk_ChatTitleView_layoutSubviews, &orig_ChatTitleView_layoutSubviews,
                 @"settingsUI", 3);

    // Ad Block
    install_hook(@"LineAdvertiseSDK2.LADAdvertise", @selector(initWithCoder:),
                 (IMP)hk_LADAdvertise_initWithCoder, &orig_LADAdvertise_initWithCoder,
                 @"adBlock", 3);

    // Trackers
    install_hook(@"LineMessage",         @selector(setContentMetadata:),
                 (IMP)hk_LineMessage_setContentMetadata, &orig_LineMessage_setContentMetadata,
                 @"trackUnsent", 3);
    install_hook(@"ManagedMessage",      @selector(sendWithCompletionHandler:),
                 (IMP)hk_ManagedMessage_send, &orig_ManagedMessage_send,
                 @"trackSend", 3);
    install_hook(@"LineOperation",       @selector(setParam3:),
                 (IMP)hk_LineOperation_setParam3, &orig_LineOperation_setParam3,
                 @"trackOps", 3);
    install_hook(@"LineConfigurations",  @selector(configMap),
                 (IMP)hk_LineConfigurations_configMap, &orig_LineConfigurations_configMap,
                 @"trackConfig", 3);
}

// ============================================================================
// init
// ============================================================================

__attribute__((constructor))
static void lineHRU_init(void) {
    @autoreleasepool {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        DEFAULT_BOOL_TRUE(@"LineHRU.blockUnsend");
        DEFAULT_BOOL_TRUE(@"LineHRU.hideRead");
        DEFAULT_BOOL_TRUE(@"LineHRU.adBlock");
        DEFAULT_BOOL_FALSE(@"LineHRU.trackUnsent");
        DEFAULT_BOOL_FALSE(@"LineHRU.trackSend");
        DEFAULT_BOOL_FALSE(@"LineHRU.trackOps");
        DEFAULT_BOOL_FALSE(@"LineHRU.trackConfig");
        [d synchronize];

        g_ring = [NSMutableArray arrayWithCapacity:LH_RING_CAP];
        g_ring_q = dispatch_queue_create("com.LineHRU.ring", DISPATCH_QUEUE_SERIAL);

        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        hlog(@"=== LineHRU v0.5 loaded into %@ (pid=%d) ===", bid, getpid());
        hlog(@"  blockUnsend=%d hideRead=%d adBlock=%d", prefBlockUnsend(), prefHideRead(), prefAdBlock());
        hlog(@"  trackUnsent=%d trackSend=%d trackOps=%d trackConfig=%d",
             prefTrackUnsent(), prefTrackSend(), prefTrackOps(), prefTrackConfig());

        void *h = dlopen("/usr/lib/libsqlite3.dylib", RTLD_LAZY | RTLD_GLOBAL);
        if (!h) h = dlopen("libsqlite3.dylib", RTLD_LAZY | RTLD_GLOBAL);
        if (!h) { hlog(@"libsqlite3 dlopen FAILED"); return; }

        p_expanded_sql = (sqlite3_expanded_sql_fn) dlsym(h, "sqlite3_expanded_sql");
        p_sqlite3_free = (sqlite3_free_fn)         dlsym(h, "sqlite3_free");
        p_bind_int64   = (sqlite3_bind_int64_fn)   dlsym(h, "sqlite3_bind_int64");
        p_column_type  = (sqlite3_column_type_fn)  dlsym(h, "sqlite3_column_type");

        void *sym_prep_v2  = dlsym(h, "sqlite3_prepare_v2");
        void *sym_prep_v3  = dlsym(h, "sqlite3_prepare_v3");
        void *sym_step     = dlsym(h, "sqlite3_step");
        void *sym_finalize = dlsym(h, "sqlite3_finalize");

        if (sym_prep_v2) MSHookFunction(sym_prep_v2, (void*)hk_sqlite3_prepare_v2, (void**)&orig_sqlite3_prepare_v2);
        if (sym_prep_v3) MSHookFunction(sym_prep_v3, (void*)hk_sqlite3_prepare_v3, (void**)&orig_sqlite3_prepare_v3);
        if (sym_step)    MSHookFunction(sym_step,    (void*)hk_sqlite3_step,       (void**)&orig_sqlite3_step);
        if (sym_finalize) MSHookFunction(sym_finalize, (void*)hk_sqlite3_finalize, (void**)&orig_sqlite3_finalize);

        hlog(@"sqlite hooks installed: prep_v2=%p prep_v3=%p step=%p finalize=%p",
             sym_prep_v2, sym_prep_v3, sym_step, sym_finalize);

        // ObjC hooks rely on LINE bundle / Swift frameworks being loaded.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ installAllObjCHooks(); });
    }
}
