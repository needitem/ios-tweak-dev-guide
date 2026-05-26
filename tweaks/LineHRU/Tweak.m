// LineHRU — Hide Read + Block Unsend for LINE
// References K2GE3Air's hookpoints: readUpToMessageID / lastReceivedMessageID /
// setReadUpToMessageID: / alreadyInserted / setAlreadyInserted:

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <unistd.h>
#import <dlfcn.h>
#import <stdatomic.h>

// libsqlite3 dynamic dlsym (LINE 의 sandbox 안 talk.sqlite 점검용)
typedef int  (*sqlite3_open_v2_fn)(const char*, void**, int, const char*);
typedef int  (*sqlite3_close_v2_fn)(void*);
typedef int  (*sqlite3_prepare_v2_fn)(void*, const char*, int, void**, const char**);
typedef int  (*sqlite3_step_fn)(void*);
typedef const unsigned char* (*sqlite3_column_text_fn)(void*, int);
typedef int  (*sqlite3_column_int_fn)(void*, int);
typedef int  (*sqlite3_finalize_fn)(void*);
typedef const char* (*sqlite3_errmsg_fn)(void*);
#define SQLITE_OK         0
#define SQLITE_ROW        100
#define SQLITE_DONE       101
#define SQLITE_OPEN_READONLY  0x00000001
#define SQLITE_OPEN_NOMUTEX   0x00008000

#define LOG_PATH @"/var/mobile/Library/Caches/LineHRU.log"

static NSMutableDictionary<NSString *, NSValue *> *g_origIMPs;
static void hlog(NSString *fmt, ...) __attribute__((format(__NSString__, 1, 2)));

// === sqlite3_prepare_v2 후킹 (Phase 1: monitor) ===
static sqlite3_prepare_v2_fn orig_sqlite3_prepare_v2 = NULL;
typedef int (*sqlite3_prepare_v3_fn)(void*, const char*, int, unsigned int, void**, const char**);
static sqlite3_prepare_v3_fn orig_sqlite3_prepare_v3 = NULL;

static atomic_int g_sql_log_count = 0;
static atomic_int g_sql_total_count = 0;
static atomic_int g_block_unsend_count = 0;
static atomic_int g_block_read_count = 0;
static atomic_int g_step_expanded_dump_count = 0;

static BOOL hideReadOn(void);
static BOOL blockUnsendOn(void);

// step 시점에 쓸 추가 sqlite3 API
typedef int   (*sqlite3_step_fn_t)(void*);
typedef char* (*sqlite3_expanded_sql_fn)(void*);
typedef void  (*sqlite3_free_fn)(void*);
typedef int   (*sqlite3_finalize_fn_full)(void*);
static sqlite3_step_fn_t        orig_sqlite3_step = NULL;
static sqlite3_finalize_fn_full orig_sqlite3_finalize = NULL;
static sqlite3_expanded_sql_fn  p_expanded_sql = NULL;
static sqlite3_free_fn          p_sqlite3_free = NULL;

// 의심 stmt (SQL 에 ZMESSAGE 또는 ZCHAT/ZTHREAD READUPTO 포함) 만 step 시 expanded 검사
// stmt pointer → kind: 1=unsent-candidate, 2=read-candidate
static NSMutableDictionary<NSNumber*, NSNumber*> *g_suspect_stmts;

#define SUSPECT_UNSEND  1
#define SUSPECT_READ    2

// 관심 SQL 키워드 — ZCHAT/ZMESSAGE/ZTHREAD/READUP/SYNCED/UNSEND/UNSENT
static int sql_is_interesting(const char *sql) {
    if (!sql) return 0;
    // 빠른 prefix 체크 — 첫 8자 안에 UPDATE/INSERT/DELETE 있는 것만
    const char *p = sql;
    while (*p == ' ' || *p == '\t' || *p == '\n') p++;
    if (strncmp(p, "UPDATE", 6) != 0 &&
        strncmp(p, "INSERT", 6) != 0 &&
        strncmp(p, "DELETE", 6) != 0 &&
        strncmp(p, "update", 6) != 0 &&
        strncmp(p, "insert", 6) != 0 &&
        strncmp(p, "delete", 6) != 0) return 0;
    return (strstr(sql, "ZCHAT") ||
            strstr(sql, "ZMESSAGE") ||
            strstr(sql, "ZTHREAD") ||
            strstr(sql, "ZREAD") ||
            strstr(sql, "ZUNREAD") ||
            strstr(sql, "ZSEND")) ? 1 : 0;
}

static int classify_suspect(const char *sql) {
    if (!sql) return 0;
    if (strstr(sql, "ZMESSAGE") &&
        (strstr(sql, "DELETE") || strstr(sql, "INSERT") ||
         strstr(sql, "delete") || strstr(sql, "insert"))) {
        return SUSPECT_UNSEND;
    }
    if ((strstr(sql, "UPDATE ZCHAT") || strstr(sql, "UPDATE ZTHREAD") ||
         strstr(sql, "update ZCHAT") || strstr(sql, "update ZTHREAD")) &&
        (strstr(sql, "READUPTOMESSAGEID") || strstr(sql, "ZUNREAD"))) {
        return SUSPECT_READ;
    }
    return 0;
}

// Block: prepare 시점에 SQL text 자체로 차단 (step/finalize 후킹 없이)
// unsent 시그니처:
//   1) DELETE FROM ZMESSAGE WHERE Z_PK = ? AND Z_OPT = ?
//   2) INSERT INTO ZMESSAGE(...) — placeholder row
// 가장 단순한 첫 시도: DELETE FROM ZMESSAGE 만 차단 (LINE 의 정상 동작에서
// ZMESSAGE row 를 DELETE 하는 건 unsent / 사용자 수동삭제 외엔 거의 없음).
static int should_block_unsend(const char *sql) {
    if (!sql) return 0;
    return (strstr(sql, "DELETE FROM ZMESSAGE") != NULL ||
            strstr(sql, "delete from ZMESSAGE") != NULL) ? 1 : 0;
}

// Hide Read 시그니처:
//   UPDATE ZCHAT SET ... ZREADUPTOMESSAGEIDSYNCED ...
//   UPDATE ZTHREAD SET ... ZREADUPTOMESSAGEIDSYNCED ...
static int should_block_read(const char *sql) {
    if (!sql) return 0;
    if (!(strstr(sql, "UPDATE ZCHAT")   || strstr(sql, "UPDATE ZTHREAD") ||
          strstr(sql, "update ZCHAT")   || strstr(sql, "update ZTHREAD"))) return 0;
    return (strstr(sql, "ZREADUPTOMESSAGEIDSYNCED") ||
            strstr(sql, "ZREADUPTOMESSAGEID")) ? 1 : 0;
}

// 차단 시 사용할 NO-OP SQL — prepare 자체는 성공시키되 실행해도 변경 없음
static const char *kNoopSQL = "SELECT 0 WHERE 0";

static int hk_sqlite3_prepare_v2(void* db, const char* sql, int nbytes,
                                  void** stmt, const char** tail) {
    atomic_fetch_add(&g_sql_total_count, 1);

    // 차단 검사 먼저
    if (sql && blockUnsendOn() && should_block_unsend(sql)) {
        int n = atomic_fetch_add(&g_block_unsend_count, 1);
        if (n < 50) hlog(@"[BLOCK unsend v2 #%d] %.300s", n, sql);
        return orig_sqlite3_prepare_v2(db, kNoopSQL, (int)strlen(kNoopSQL), stmt, tail);
    }
    if (sql && hideReadOn() && should_block_read(sql)) {
        int n = atomic_fetch_add(&g_block_read_count, 1);
        if (n < 50) hlog(@"[BLOCK read v2 #%d] %.300s", n, sql);
        return orig_sqlite3_prepare_v2(db, kNoopSQL, (int)strlen(kNoopSQL), stmt, tail);
    }

    // 모니터링 로그
    if (sql && sql_is_interesting(sql)) {
        int n = atomic_fetch_add(&g_sql_log_count, 1);
        if (n < 300) hlog(@"[SQL #%d v2] %.500s", n, sql);
    }
    return orig_sqlite3_prepare_v2(db, sql, nbytes, stmt, tail);
}

static int hk_sqlite3_prepare_v3(void* db, const char* sql, int nbytes,
                                  unsigned int flags, void** stmt, const char** tail) {
    atomic_fetch_add(&g_sql_total_count, 1);

    if (sql && blockUnsendOn() && should_block_unsend(sql)) {
        int n = atomic_fetch_add(&g_block_unsend_count, 1);
        if (n < 50) hlog(@"[BLOCK unsend v3 #%d] %.300s", n, sql);
        return orig_sqlite3_prepare_v3(db, kNoopSQL, (int)strlen(kNoopSQL), flags, stmt, tail);
    }
    if (sql && hideReadOn() && should_block_read(sql)) {
        int n = atomic_fetch_add(&g_block_read_count, 1);
        if (n < 50) hlog(@"[BLOCK read v3 #%d] %.300s", n, sql);
        return orig_sqlite3_prepare_v3(db, kNoopSQL, (int)strlen(kNoopSQL), flags, stmt, tail);
    }

    if (sql && sql_is_interesting(sql)) {
        int n = atomic_fetch_add(&g_sql_log_count, 1);
        if (n < 300) hlog(@"[SQL #%d v3] %.500s", n, sql);
    }
    return orig_sqlite3_prepare_v3(db, sql, nbytes, flags, stmt, tail);
}

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

        // === sqlite3_prepare_v2/v3 후킹 — prepare 단계에서만 차단 ===
        void *sqh = dlopen("/usr/lib/libsqlite3.dylib", RTLD_LAZY | RTLD_GLOBAL);
        if (!sqh) sqh = dlopen("libsqlite3.dylib", RTLD_LAZY | RTLD_GLOBAL);
        if (sqh) {
            void *sym_v2 = dlsym(sqh, "sqlite3_prepare_v2");
            if (sym_v2) {
                MSHookFunction(sym_v2, (void*)hk_sqlite3_prepare_v2,
                               (void**)&orig_sqlite3_prepare_v2);
                hlog(@"sqlite3_prepare_v2 hooked at %p", sym_v2);
            }
            void *sym_v3 = dlsym(sqh, "sqlite3_prepare_v3");
            if (sym_v3) {
                MSHookFunction(sym_v3, (void*)hk_sqlite3_prepare_v3,
                               (void**)&orig_sqlite3_prepare_v3);
                hlog(@"sqlite3_prepare_v3 hooked at %p", sym_v3);
            }
        } else {
            hlog(@"sqlite3 dlopen FAILED");
        }

        // === diagnostic: LINE init 후 background queue 에서 ===
        // 메인 init 을 막지 않기 위해 5초 delay + 별도 큐. 결과는 한 번에 dump.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            @autoreleasepool {
                const struct { const char *name; SEL sel; } probes[] = {
                    {"readUpToMessageID",    @selector(readUpToMessageID)},
                    {"setReadUpToMessageID:",NSSelectorFromString(@"setReadUpToMessageID:")},
                    {"lastReceivedMessageID",@selector(lastReceivedMessageID)},
                    {"alreadyInserted",      @selector(alreadyInserted)},
                    {"setAlreadyInserted:",  NSSelectorFromString(@"setAlreadyInserted:")},
                    {"chatMID",              @selector(chatMID)},
                };
                NSMutableString *report = [NSMutableString stringWithCapacity:16384];
                [report appendString:@"=== LineHRU diagnostic report ===\n"];
                unsigned int n = 0;
                Class *classes = objc_copyClassList(&n);
                [report appendFormat:@"  total classes in process: %u\n", n];

                for (size_t p = 0; p < sizeof(probes)/sizeof(probes[0]); p++) {
                    int total_resp = 0, line_resp = 0;
                    NSMutableArray *line_names = [NSMutableArray array];
                    for (unsigned i = 0; i < n; i++) {
                        Class c = classes[i];
                        if (!c) continue;
                        Method m = class_getInstanceMethod(c, probes[p].sel);
                        if (!m) continue;
                        total_resp++;
                        if (isLineClass(c)) {
                            line_resp++;
                            [line_names addObject:[NSString stringWithUTF8String:class_getName(c)]];
                        }
                    }
                    [report appendFormat:@"\n--- %s: total=%d, LINE=%d ---\n",
                        probes[p].name, total_resp, line_resp];
                    NSUInteger limit = MIN((NSUInteger)50, line_names.count);
                    for (NSUInteger k = 0; k < limit; k++) {
                        [report appendFormat:@"  %@\n", line_names[k]];
                    }
                    if (line_names.count > limit) {
                        [report appendFormat:@"  ... (+%lu more)\n",
                            (unsigned long)(line_names.count - limit)];
                    }
                }

                // === 2nd diag: LINE-image 출신 클래스의 selector 중 관심 키워드 ===
                static const char *kw[] = {
                    "send", "Send", "unsend", "Unsend", "unsent", "Unsent",
                    "recall", "Recall", "delete", "Delete", "remove", "Remove",
                    "markAs", "MarkAs", "markedAs", "MarkedAs",
                    "unread", "Unread", "readUp", "ReadUp", "lastRead", "LastRead",
                    "Receipt", "receipt", "watermark", "Watermark",
                    "notifyRead", "NotifyRead", "ackRead", "AckRead",
                    "lastSeen", "LastSeen", "lastViewed", "LastViewed",
                };
                size_t nkw = sizeof(kw)/sizeof(kw[0]);
                int line_class_count = 0;
                NSMutableSet *hits_by_class = [NSMutableSet set];
                NSMutableArray *hits = [NSMutableArray array];
                for (unsigned i = 0; i < n; i++) {
                    Class c = classes[i];
                    if (!c || !isLineClass(c)) continue;
                    line_class_count++;
                    unsigned int methCount = 0;
                    Method *methods = class_copyMethodList(c, &methCount);
                    const char *cname = class_getName(c);
                    for (unsigned j = 0; j < methCount; j++) {
                        const char *sname = sel_getName(method_getName(methods[j]));
                        // 한 selector 가 여러 키워드 매치해도 한 번만 (break 유지)
                        // 단, "read:" 같은 wire-format 메서드 (Thrift) 제외
                        if (strcmp(sname, "read:") == 0) continue;
                        for (size_t k = 0; k < nkw; k++) {
                            if (strstr(sname, kw[k])) {
                                [hits addObject:[NSString stringWithFormat:@"-[%s %s]", cname, sname]];
                                [hits_by_class addObject:[NSString stringWithUTF8String:cname]];
                                break;
                            }
                        }
                    }
                    if (methods) free(methods);
                }
                [report appendFormat:@"\n=== LINE-image classes: %d ===\n", line_class_count];
                [report appendFormat:@"keyword-hit selectors: %lu in %lu unique classes\n",
                    (unsigned long)hits.count, (unsigned long)hits_by_class.count];
                // limit 풀고 전부 dump
                for (NSString *line in hits) {
                    [report appendFormat:@"  %@\n", line];
                }

                if (classes) free(classes);
                hlog(@"%@", report);   // 한 번에 dump

                // === 3rd diag: LINE sandbox 안 sqlite 파일 + schema ===
                NSMutableString *db_report = [NSMutableString stringWithCapacity:16384];
                [db_report appendString:@"\n=== LINE sandbox SQLite scan ===\n"];

                // sandbox + App Group containers
                NSMutableArray *roots = [NSMutableArray arrayWithObjects:
                    NSHomeDirectory(),
                    [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject] ?: @"",
                    [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject] ?: @"",
                    [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject] ?: @"",
                    nil];
                NSString *appGroupBase = @"/var/mobile/Containers/Shared/AppGroup";
                NSArray *groups = [[NSFileManager defaultManager]
                    contentsOfDirectoryAtPath:appGroupBase error:nil] ?: @[];
                for (NSString *gid in groups) {
                    [roots addObject:[appGroupBase stringByAppendingPathComponent:gid]];
                }
                [db_report appendFormat:@"app-group containers: %lu\n", (unsigned long)groups.count];
                [db_report appendFormat:@"sandbox home: %@\n", NSHomeDirectory()];

                // 모든 *.sqlite / *.db 파일 enumerate
                NSMutableSet *dbpaths = [NSMutableSet set];
                for (NSString *root in roots) {
                    if (root.length == 0) continue;
                    NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:root];
                    NSString *path;
                    while ((path = [en nextObject])) {
                        if ([path hasSuffix:@".sqlite"] || [path hasSuffix:@".db"]) {
                            [dbpaths addObject:[root stringByAppendingPathComponent:path]];
                        }
                    }
                }
                [db_report appendFormat:@"found %lu sqlite/db files\n", (unsigned long)dbpaths.count];

                // libsqlite3 dlsym
                void *h = dlopen("/usr/lib/libsqlite3.dylib", RTLD_LAZY | RTLD_GLOBAL);
                if (!h) h = dlopen("libsqlite3.dylib", RTLD_LAZY | RTLD_GLOBAL);
                if (!h) {
                    [db_report appendString:@"  ERROR: libsqlite3 dlopen failed\n"];
                } else {
                    sqlite3_open_v2_fn      sql_open   = (sqlite3_open_v2_fn)     dlsym(h, "sqlite3_open_v2");
                    sqlite3_close_v2_fn     sql_close  = (sqlite3_close_v2_fn)    dlsym(h, "sqlite3_close_v2");
                    sqlite3_prepare_v2_fn   sql_prep   = (sqlite3_prepare_v2_fn)  dlsym(h, "sqlite3_prepare_v2");
                    sqlite3_step_fn         sql_step   = (sqlite3_step_fn)        dlsym(h, "sqlite3_step");
                    sqlite3_column_text_fn  sql_ctext  = (sqlite3_column_text_fn) dlsym(h, "sqlite3_column_text");
                    sqlite3_finalize_fn     sql_final  = (sqlite3_finalize_fn)    dlsym(h, "sqlite3_finalize");
                    sqlite3_errmsg_fn       sql_errmsg = (sqlite3_errmsg_fn)      dlsym(h, "sqlite3_errmsg");

                    for (NSString *path in dbpaths) {
                        void *db = NULL;
                        // READONLY + NOMUTEX → LINE 이 동시에 쓰고 있어도 충돌 안 함
                        int rc = sql_open([path UTF8String], &db,
                                          SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL);
                        if (rc != SQLITE_OK) {
                            [db_report appendFormat:@"  [LOCK/ERR] %@  rc=%d\n",
                                [path lastPathComponent], rc];
                            if (db) sql_close(db);
                            continue;
                        }
                        // 테이블 + view 목록
                        const char *q = "SELECT type, name FROM sqlite_master "
                                        "WHERE type IN ('table','view') ORDER BY name";
                        void *stmt = NULL;
                        if (sql_prep(db, q, -1, &stmt, NULL) == SQLITE_OK) {
                            NSMutableArray *tabs = [NSMutableArray array];
                            while (sql_step(stmt) == SQLITE_ROW) {
                                const unsigned char *type = sql_ctext(stmt, 0);
                                const unsigned char *name = sql_ctext(stmt, 1);
                                if (type && name) {
                                    [tabs addObject:[NSString stringWithFormat:@"%s:%s", type, name]];
                                }
                            }
                            sql_final(stmt);
                            [db_report appendFormat:@"\n=== %@  (%lu tables) ===\n",
                                [path lastPathComponent], (unsigned long)tabs.count];
                            for (NSString *t in tabs) [db_report appendFormat:@"  %@\n", t];
                            // ZMESSAGE, ZCHAT 같은 흥미로운 테이블 의 컬럼도 dump
                            for (NSString *t in tabs) {
                                NSString *tname = [t componentsSeparatedByString:@":"].lastObject;
                                if (!tname) continue;
                                NSString *lc = [tname lowercaseString];
                                if ([lc containsString:@"message"] || [lc containsString:@"chat"] ||
                                    [lc containsString:@"read"]    || [lc containsString:@"unsent"]) {
                                    NSString *pq = [NSString stringWithFormat:
                                        @"PRAGMA table_info(\"%@\")", tname];
                                    void *st2 = NULL;
                                    if (sql_prep(db, [pq UTF8String], -1, &st2, NULL) == SQLITE_OK) {
                                        NSMutableArray *cols = [NSMutableArray array];
                                        while (sql_step(st2) == SQLITE_ROW) {
                                            const unsigned char *cname = sql_ctext(st2, 1);
                                            const unsigned char *ctype = sql_ctext(st2, 2);
                                            if (cname && ctype) {
                                                [cols addObject:[NSString stringWithFormat:
                                                    @"%s:%s", cname, ctype]];
                                            }
                                        }
                                        sql_final(st2);
                                        [db_report appendFormat:@"    --- %@: %@\n", tname,
                                            [cols componentsJoinedByString:@", "]];
                                    }
                                }
                            }
                        } else {
                            const char *e = sql_errmsg ? sql_errmsg(db) : "?";
                            [db_report appendFormat:@"  [PREP ERR] %@: %s\n",
                                [path lastPathComponent], e];
                        }
                        sql_close(db);
                    }
                }
                hlog(@"%@", db_report);
            }
        });

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
