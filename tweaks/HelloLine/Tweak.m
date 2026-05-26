#line 1 "Tweak.x"






#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>


static void hwlog(NSString *line) {
    NSString *path = @"/var/mobile/Library/Caches/HelloLine.log";
    NSString *withTime = [NSString stringWithFormat:@"[%@] %@\n",
                          [NSDate date], line];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [withTime writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[withTime dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
    NSLog(@"[HelloLine] %@", line);  
}



#include <substrate.h>
#if defined(__clang__)
#if __has_feature(objc_arc)
#define _LOGOS_SELF_TYPE_NORMAL __unsafe_unretained
#define _LOGOS_SELF_TYPE_INIT __attribute__((ns_consumed))
#define _LOGOS_SELF_CONST const
#define _LOGOS_RETURN_RETAINED __attribute__((ns_returns_retained))
#else
#define _LOGOS_SELF_TYPE_NORMAL
#define _LOGOS_SELF_TYPE_INIT
#define _LOGOS_SELF_CONST
#define _LOGOS_RETURN_RETAINED
#endif
#else
#define _LOGOS_SELF_TYPE_NORMAL
#define _LOGOS_SELF_TYPE_INIT
#define _LOGOS_SELF_CONST
#define _LOGOS_RETURN_RETAINED
#endif

__asm__(".linker_option \"-framework\", \"CydiaSubstrate\"");

@class UIViewController; 
static void (*_logos_orig$_ungrouped$UIViewController$viewDidLoad)(_LOGOS_SELF_TYPE_NORMAL UIViewController* _LOGOS_SELF_CONST, SEL); static void _logos_method$_ungrouped$UIViewController$viewDidLoad(_LOGOS_SELF_TYPE_NORMAL UIViewController* _LOGOS_SELF_CONST, SEL); 

#line 27 "Tweak.x"

static void _logos_method$_ungrouped$UIViewController$viewDidLoad(_LOGOS_SELF_TYPE_NORMAL UIViewController* _LOGOS_SELF_CONST __unused self, SEL __unused _cmd) {
    _logos_orig$_ungrouped$UIViewController$viewDidLoad(self, _cmd);   
    hwlog([NSString stringWithFormat:@"VC: %@  title=%@",
           NSStringFromClass([self class]),
           self.title ?: @"(no title)"]);
}



static __attribute__((constructor)) void _logosLocalCtor_d1a00f3d(int __unused argc, char __unused **argv, char __unused **envp) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        hwlog([NSString stringWithFormat:@"=== HelloLine loaded into %@ (pid=%d) ===",
               bid, getpid()]);
    }
}
static __attribute__((constructor)) void _logosLocalInit() {
{Class _logos_class$_ungrouped$UIViewController = objc_getClass("UIViewController"); { MSHookMessageEx(_logos_class$_ungrouped$UIViewController, @selector(viewDidLoad), (IMP)&_logos_method$_ungrouped$UIViewController$viewDidLoad, (IMP*)&_logos_orig$_ungrouped$UIViewController$viewDidLoad);}} }
#line 44 "Tweak.x"
