# tweak-dev — iOS tweak workspace

조직된 트윅 개발 환경. procursus rootless + ellekit 인젝션 기반.

## 디렉토리
```
~/tweak-dev/
├── sdk/iPhoneOS.sdk     -> ~/theos/sdks/iPhoneOS16.5.sdk (symlink)
├── common-include/      # 공용 헤더 (substrate.h 등)
├── template/            # 새 트윅 시작 템플릿
│   ├── Tweak.m
│   └── Template.plist
└── scripts/
    └── build-tweak.sh   # 빌드+서명+설치+재시작
```

## 새 트윅 만들기

```bash
cp -r ~/tweak-dev/template ~/tweaks/MyTweak
cd ~/tweaks/MyTweak
mv Template.plist MyTweak.plist

# Tweak.m 편집 후 빌드/배포
~/tweak-dev/scripts/build-tweak.sh ~/tweaks/MyTweak --target-bundle jp.naver.line --restart
```

## 필터 plist (binary plist 권장)
```python
import plistlib
plistlib.dump({'Filter':{'Bundles':['jp.naver.line']}},
              open('MyTweak.plist','wb'), fmt=plistlib.FMT_BINARY)
```

## 사전 조건 — 폰 쪽 (이미 설정됨)
- procursus clang 16, ld64, ldid 설치됨
- `/var/jb/SDKs/iPhoneOS.sdk/` 에 SDK 푸시됨
- `/var/jb/usr/include/substrate.h` 헤더 있음
- `~/.ssh/config` 에 `iphone-mobile` 별칭 (mobile@192.168.1.202)
- mobile 계정 passwordless sudo

## 빌드 명령 (스크립트가 자동 실행)
```
clang -target arm64-apple-ios14.0 -isysroot /var/jb/SDKs/iPhoneOS.sdk -fobjc-arc \
  -dynamiclib -Wl,-fixup_chains \
  -I /var/jb/usr/include \
  -framework Foundation -framework CydiaSubstrate \
  -Xlinker -rpath -Xlinker /var/jb/Library/Frameworks \
  -Xlinker -rpath -Xlinker /var/jb/usr/lib \
  -install_name '@rpath/MyTweak.dylib' \
  Tweak.m -o MyTweak.dylib
ldid -S -IMyTweak.dylib.<rand>.unsigned -Hsha1 MyTweak.dylib
```

## 설치 위치
`/var/jb/usr/lib/TweakInject/<Name>.dylib` + `.plist` 쌍

## 재로드
```
sudo killall -9 LINE          # 타깃 앱
sudo killall -9 SpringBoard   # SpringBoard 타깃이면
sudo uiopen --bundleid <bid>  # 잠금 풀려있어야 함
```

## 디버깅
- 로그는 `/var/mobile/Library/Caches/<Name>.log` (mobile 계정 쓰기 가능 경로)
- LINE 샌드박스 외부 경로(`/var/jb/tmp` 등) 쓰기 금지 — 샌드박스 차단됨

## ⚡ 자주 빠뜨리는 함정
1. **CydiaSubstrate 의존성 경로**: install-name이 `@rpath/...` 이어야 함.
   SDK의 `CydiaSubstrate.tbd`는 이미 `install-name: '@rpath/CydiaSubstrate.framework/CydiaSubstrate'` 로 작성됨.
2. **LC_RPATH 필요**: `-Xlinker -rpath -Xlinker /var/jb/Library/Frameworks` 와
   `-Xlinker -rpath -Xlinker /var/jb/usr/lib` 둘 다 필요.
3. **필터 plist**: binary plist 형식 권장. XML도 받긴 함.
4. **잠금**: uiopen은 잠금 풀려있어야 동작.

## LINE 후킹용 selector 참조 (K2GE3Air 분석에서 확보)
- 읽음:    `readUpToMessageID`, `lastReceivedMessageID`, `setReadUpToMessageID:`
- 송신취소: `alreadyInserted`, `setAlreadyInserted:`
- 채팅 ID:  `chatMID`, `setChatMID:`

검증된 기준 트윅: `~/tweaks/LineHRU/`
