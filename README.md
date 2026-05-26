# iOS 트윅 개발 가이드 — 처음부터 LINE 후킹까지

velog 시리즈 [iOS 트윅 처음부터 LINE 후킹까지](https://velog.io/@needitem) 의 예제 코드와 SDK 구조 모음.

## 구조

```
ios-tweak-dev-guide/
├── tweak-dev/              # 트윅 개발 공통 환경
│   ├── sdk/                # iOS SDK 위치 (별도 다운 — Part 3 참고)
│   ├── common-include/     # substrate.h 등 공용 헤더
│   ├── template/           # 새 트윅 시작 템플릿
│   └── scripts/
│       └── build-tweak.sh  # 빌드/서명/설치/재시작 자동화
│
└── tweaks/
    ├── HelloLine/          # Part 4 — SpringBoard에 Hello World 인젝트
    │   ├── Tweak.x         # Logos 문법
    │   ├── Tweak.m         # Logos 전처리 결과 (참고용)
    │   ├── Makefile        # Theos
    │   ├── control         # .deb 메타데이터
    │   └── HelloLine.plist
    │
    └── LineHRU/            # Part 5 — LINE의 Hide Read + Block Unsend
        ├── Tweak.m         # 순수 ObjC + MSHookMessageEx (Logos 미사용)
        └── LineHRU.plist
```

## 환경 사전 조건

- 탈옥된 iOS 디바이스 (palera1n procursus rootless 기준 — Part 2)
- 디바이스에서 SSH 접속 가능 (Part 2)
- 폰에 clang/ld64/ldid 설치 (Part 3)
- iOS SDK 폰에 푸시 (Part 3)

## 사용법

```bash
# 새 트윅 시작
cp -r tweak-dev/template tweaks/MyTweak
cd tweaks/MyTweak
mv Template.plist MyTweak.plist

# 빌드 → 서명 → 설치 → 재시작 한방
~/tweak-dev/scripts/build-tweak.sh ~/tweaks/MyTweak --target-bundle jp.naver.line --restart
```

## 시리즈 링크

- Part 1 — iOS 트윅 개요 + palera1n 탈옥
- Part 2 — SSH 접속 + 패스워드리스 sudo 설정
- Part 3 — 빌드 환경 (clang + SDK + substrate.h + CydiaSubstrate.tbd)
- Part 4 — 첫 트윅 HelloLine (SpringBoard 후킹)
- Part 5 — 실전 LineHRU (LINE의 Hide Read + Block Unsend)

## 라이선스

MIT — 자유롭게 가져다 쓰세요. 출처만 남겨주시면 감사하겠습니다.
