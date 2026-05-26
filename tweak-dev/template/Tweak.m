// Tweak template — manual %ctor + MSHookMessageEx (no Logos).
// Build:  ~/tweak-dev/scripts/build-tweak.sh <project-dir> [--restart]
// Filter: <Project>.plist (binary plist with Filter.Bundles)

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <unistd.h>

#define LOG_PATH @"/var/mobile/Library/Caches/PROJECT.log"

static void hlog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *out = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], line];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:LOG_PATH];
    if (!fh) [out writeToFile:LOG_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
    else { [fh seekToEndOfFile];
           [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
           [fh closeFile]; }
    NSLog(@"[PROJECT] %@", line);
}

// Example: replacement IMP for `- (NSString *)title`
// static IMP g_orig_title;
// static id repl_title(id self, SEL _cmd) {
//     id orig = ((id(*)(id,SEL))g_orig_title)(self, _cmd);
//     hlog(@"title called -> %@", orig);
//     return orig;
// }

__attribute__((constructor))
static void tweak_init(void) {
    @autoreleasepool {
        hlog(@"=== loaded into %@ (pid=%d) ===",
             [[NSBundle mainBundle] bundleIdentifier], getpid());

        // Class targetCls = objc_getClass("TargetClassName");
        // if (targetCls) {
        //     MSHookMessageEx(targetCls, @selector(title), (IMP)repl_title, &g_orig_title);
        //     hlog(@"hooked -[TargetClassName title]");
        // }
    }
}
