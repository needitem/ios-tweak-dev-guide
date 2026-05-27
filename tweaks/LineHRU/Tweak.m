// LineHRU v0.4 — Block Unsend + Hide Read + in-app settings overlay for LINE 15.7.2
//
// Behaviour summary
// =================
//
//   Block Unsend  – when LINE issues `DELETE FROM ZMESSAGE WHERE Z_PK = ?` we ask
//     the same sqlite3 connection whether that row's ZSENDER is NULL.  ZSENDER is
//     NULL only for messages we sent ourselves, so non-NULL means the row belongs
//     to a remote sender — exactly the unsent case — and we short-circuit step()
//     to SQLITE_DONE.  User-initiated deletion of own messages keeps working.
//
//   Hide Read     – when LINE issues UPDATE that touches ZREADUPTOMESSAGEIDSYNCED
//     (the server-synced read cursor), we substitute the prepared statement with
//     `SELECT 0 WHERE 0`.  Local UI cursors that update ZREADUPTOMESSAGEID in a
//     separate UPDATE keep working; combined UPDATEs lose the local indicator
//     too — that is the documented Hide-Read trade-off.
//
//   Settings UI   – long-press anywhere in the chat title bar (Swift class
//     LineMessagingUI.ChatTitleView, the same hookpoint K2GE3Air uses) opens a
//     UIAlertController action sheet with toggles for the two features, a recent-
//     blocks viewer, and a counter-reset.
//
// UIKit is referenced only via the ObjC runtime to avoid pulling QuartzCore /
// OpenGLES headers that are not present in the local SDK.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <unistd.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>

// --- forward declarations of the UIKit types we touch via msg send ---
@class UIView, UIWindow, UIWindowScene, UIApplication, UIViewController;
@class UIAlertController, UIAlertAction, UILongPressGestureRecognizer;

#define LOG_PATH @"/var/mobile/Library/Caches/LineHRU.log"
#define UIGestureRecognizerStateBegan    1
#define UIAlertControllerStyleActionSheet 0
#define UIAlertActionStyleDefault        0
#define UIAlertActionStyleCancel         1
#define UIAlertActionStyleDestructive    2

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

static atomic_int g_block_unsend  = 0;
static atomic_int g_block_read    = 0;
static atomic_int g_allow_delete  = 0;
static atomic_int g_lookup_errors = 0;

// recent-block ring buffer (for the in-app viewer)
#define LH_RING_CAP 32
static NSMutableArray<NSString*> *g_recent_blocks = nil;  // strings, newest last
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
    if (!g_ring_q || !g_recent_blocks) return;
    dispatch_async(g_ring_q, ^{
        if (g_recent_blocks.count >= LH_RING_CAP) [g_recent_blocks removeObjectAtIndex:0];
        [g_recent_blocks addObject:entry];
    });
}

static NSArray<NSString*> *ring_snapshot(void) {
    if (!g_ring_q || !g_recent_blocks) return @[];
    __block NSArray *snap = nil;
    dispatch_sync(g_ring_q, ^{ snap = [g_recent_blocks copy]; });
    return snap ?: @[];
}

static void ring_clear(void) {
    if (!g_ring_q || !g_recent_blocks) return;
    dispatch_async(g_ring_q, ^{ [g_recent_blocks removeAllObjects]; });
}

static BOOL prefBlockUnsend(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"LineHRU.blockUnsend"];
}
static BOOL prefHideRead(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"LineHRU.hideRead"];
}

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
            ring_push([NSString stringWithFormat:@"%@  read  %.180s",
                       [NSDate date], sql]);
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
            ring_push([NSString stringWithFormat:@"%@  read  %.180s",
                       [NSDate date], sql]);
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
// In-app settings overlay (via objc_msgSend, no UIKit headers needed)
// ============================================================================

static IMP orig_chatTitleView_layoutSubviews = NULL;
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
    return ((id(*)(id, SEL, NSString*, NSString*, NSInteger))objc_msgSend)(
        C, S, title, message, (NSInteger)style);
}

static id makeAlertAction(NSString *title, int style, void (^handler)(id)) {
    Class C = objc_getClass("UIAlertAction");
    SEL S = sel_registerName("actionWithTitle:style:handler:");
    return ((id(*)(id, SEL, NSString*, NSInteger, id))objc_msgSend)(
        C, S, title, (NSInteger)style, handler);
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
    NSMutableString *msg = [NSMutableString stringWithCapacity:2048];
    if (snap.count == 0) {
        [msg appendString:@"(no blocks recorded yet)"];
    } else {
        for (NSString *e in [snap reverseObjectEnumerator]) {  // newest first
            [msg appendFormat:@"%@\n\n", e];
        }
    }
    id alert = makeAlert(@"LineHRU — recent blocks (newest first)", msg, UIAlertControllerStyleActionSheet);
    addAction(alert, makeAlertAction(@"Clear", UIAlertActionStyleDestructive, ^(id a) {
        ring_clear();
    }));
    addAction(alert, makeAlertAction(@"Close", UIAlertActionStyleCancel, nil));
    presentVC(rootPresentingVC(), alert);
}

static void presentSettings(id anchor) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    BOOL bu = [d boolForKey:@"LineHRU.blockUnsend"];
    BOOL hr = [d boolForKey:@"LineHRU.hideRead"];

    NSString *msg = [NSString stringWithFormat:
        @"v0.4 · unsend=%d  read=%d\nblocked: unsend=%d  read=%d  allowDel=%d  errs=%d",
        bu, hr,
        atomic_load(&g_block_unsend), atomic_load(&g_block_read),
        atomic_load(&g_allow_delete), atomic_load(&g_lookup_errors)];

    id alert = makeAlert(@"LineHRU", msg, UIAlertControllerStyleActionSheet);

    NSString *buLabel = [NSString stringWithFormat:@"Block Unsend: %@", bu ? @"ON" : @"OFF"];
    addAction(alert, makeAlertAction(buLabel, UIAlertActionStyleDefault, ^(id a) {
        [d setBool:!bu forKey:@"LineHRU.blockUnsend"];
        [d synchronize];
        hlog(@"toggled blockUnsend -> %d", !bu);
    }));

    NSString *hrLabel = [NSString stringWithFormat:@"Hide Read: %@", hr ? @"ON" : @"OFF"];
    addAction(alert, makeAlertAction(hrLabel, UIAlertActionStyleDefault, ^(id a) {
        [d setBool:!hr forKey:@"LineHRU.hideRead"];
        [d synchronize];
        hlog(@"toggled hideRead -> %d", !hr);
    }));

    addAction(alert, makeAlertAction(@"View recent blocks…", UIAlertActionStyleDefault, ^(id a) {
        // present after this sheet dismisses
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ presentRecentBlocks(); });
    }));

    addAction(alert, makeAlertAction(@"Reset counters", UIAlertActionStyleDestructive, ^(id a) {
        atomic_store(&g_block_unsend, 0);
        atomic_store(&g_block_read, 0);
        atomic_store(&g_allow_delete, 0);
        atomic_store(&g_lookup_errors, 0);
        ring_clear();
    }));

    addAction(alert, makeAlertAction(@"Cancel", UIAlertActionStyleCancel, nil));

    // For iPad popover anchoring (cheap: anchor to source view if possible).
    if (anchor) {
        id pop = ((id(*)(id, SEL))objc_msgSend)(alert, sel_registerName("popoverPresentationController"));
        if (pop) {
            ((void(*)(id, SEL, id))objc_msgSend)(pop, sel_registerName("setSourceView:"), anchor);
            struct CGRect { double x, y, w, h; } bounds =
                ((struct CGRect(*)(id, SEL))objc_msgSend)(anchor, sel_registerName("bounds"));
            ((void(*)(id, SEL, struct CGRect))objc_msgSend)(
                pop, sel_registerName("setSourceRect:"), bounds);
        }
    }

    presentVC(rootPresentingVC(), alert);
}

static void lineHRU_longPressHandler(id self, SEL _cmd, id g) {
    NSInteger state = ((NSInteger(*)(id, SEL))objc_msgSend)(g, sel_registerName("state"));
    if (state != UIGestureRecognizerStateBegan) return;
    presentSettings(self);
}

static void hook_chatTitleView_layoutSubviews(id self, SEL _cmd) {
    if (orig_chatTitleView_layoutSubviews) {
        ((void(*)(id, SEL))orig_chatTitleView_layoutSubviews)(self, _cmd);
    }
    if (objc_getAssociatedObject(self, &kRecognizerInstalledKey)) return;
    objc_setAssociatedObject(self, &kRecognizerInstalledKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    Class LPCls = objc_getClass("UILongPressGestureRecognizer");
    id lp = ((id(*)(id, SEL))objc_msgSend)(LPCls, sel_registerName("alloc"));
    lp = ((id(*)(id, SEL, id, SEL))objc_msgSend)(
        lp, sel_registerName("initWithTarget:action:"),
        self, sel_registerName("_lineHRU_longPress:"));
    ((void(*)(id, SEL, double))objc_msgSend)(
        lp, sel_registerName("setMinimumPressDuration:"), 1.0);
    ((void(*)(id, SEL, BOOL))objc_msgSend)(
        lp, sel_registerName("setCancelsTouchesInView:"), NO);

    ((void(*)(id, SEL, id))objc_msgSend)(
        self, sel_registerName("addGestureRecognizer:"), lp);
    ((void(*)(id, SEL, BOOL))objc_msgSend)(
        self, sel_registerName("setUserInteractionEnabled:"), YES);
}

static void installSettingsUI(void) {
    Class chatTitleView = objc_getClass("LineMessagingUI.ChatTitleView");
    if (!chatTitleView) {
        hlog(@"settings UI: LineMessagingUI.ChatTitleView NOT FOUND — retrying in 5s");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ installSettingsUI(); });
        return;
    }
    class_addMethod(chatTitleView, sel_registerName("_lineHRU_longPress:"),
                    (IMP)lineHRU_longPressHandler, "v@:@");

    SEL layoutSel = sel_registerName("layoutSubviews");
    if (!class_getInstanceMethod(chatTitleView, layoutSel)) {
        hlog(@"settings UI: layoutSubviews missing on ChatTitleView");
        return;
    }
    MSHookMessageEx(chatTitleView, layoutSel, (IMP)hook_chatTitleView_layoutSubviews,
                    (IMP*)&orig_chatTitleView_layoutSubviews);
    hlog(@"settings UI ready — long-press the chat title bar (1s) to open");
}

// ============================================================================
// init
// ============================================================================

__attribute__((constructor))
static void lineHRU_init(void) {
    @autoreleasepool {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if (![d objectForKey:@"LineHRU.blockUnsend"]) [d setBool:YES forKey:@"LineHRU.blockUnsend"];
        if (![d objectForKey:@"LineHRU.hideRead"])    [d setBool:YES forKey:@"LineHRU.hideRead"];
        [d synchronize];

        g_recent_blocks = [NSMutableArray arrayWithCapacity:LH_RING_CAP];
        g_ring_q = dispatch_queue_create("com.LineHRU.ring", DISPATCH_QUEUE_SERIAL);

        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        hlog(@"=== LineHRU v0.4 loaded into %@ (pid=%d) blockUnsend=%d hideRead=%d ===",
             bid, getpid(), prefBlockUnsend(), prefHideRead());

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

        if (sym_prep_v2) MSHookFunction(sym_prep_v2, (void*)hk_sqlite3_prepare_v2,
                                        (void**)&orig_sqlite3_prepare_v2);
        if (sym_prep_v3) MSHookFunction(sym_prep_v3, (void*)hk_sqlite3_prepare_v3,
                                        (void**)&orig_sqlite3_prepare_v3);
        if (sym_step)    MSHookFunction(sym_step,    (void*)hk_sqlite3_step,
                                        (void**)&orig_sqlite3_step);
        if (sym_finalize) MSHookFunction(sym_finalize, (void*)hk_sqlite3_finalize,
                                         (void**)&orig_sqlite3_finalize);

        hlog(@"sqlite hooks: prep_v2=%p prep_v3=%p step=%p finalize=%p expanded_sql=%p",
             sym_prep_v2, sym_prep_v3, sym_step, sym_finalize, p_expanded_sql);

        // Settings UI install: defer to main queue after Swift bundle loads.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ installSettingsUI(); });
    }
}
