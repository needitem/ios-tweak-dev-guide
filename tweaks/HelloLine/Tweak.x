//
// HelloLine — 첫 트윅. LINE이 켤 때 로그 남기고,
// 모든 UIViewController가 viewDidLoad 될 때 클래스 이름 기록.
// 후킹 패턴 3종(%ctor / %hook / %orig)을 모두 보여주는 게 목적.
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// 한 줄을 mobile이 쓸 수 있는 캐시 디렉터리에 append
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
    NSLog(@"[HelloLine] %@", line);  // syslog에도
}

// (1) 모든 UIViewController의 viewDidLoad 후킹 — 어떤 VC가 뜨는지 추적
%hook UIViewController
- (void)viewDidLoad {
    %orig;   // 원본 동작 먼저 실행
    hwlog([NSString stringWithFormat:@"VC: %@  title=%@",
           NSStringFromClass([self class]),
           self.title ?: @"(no title)"]);
}
%end

// (2) 생성자 — 트윅이 로드될 때 한 번 실행
%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        hwlog([NSString stringWithFormat:@"=== HelloLine loaded into %@ (pid=%d) ===",
               bid, getpid()]);
    }
}
