# FileExplorer — Feature Checklist

**Goal**: Windows 11 File Explorer의 UX와 기능을 **정확히** macOS에 재현. Finder를 대체할 수 있는 수준.

기존 코드는 모두 폐기 (`~/dev/FileExplorer.archive-20260511/`에 보관). 본 문서를 기반으로 처음부터 다시 작성.

---

## 0. 기술 스택 결정

| 항목 | 선택 | 이유 |
|---|---|---|
| **언어** | Swift 5.9+ | macOS 네이티브, AppKit/SwiftUI 양쪽 사용 가능 |
| **UI** | SwiftUI + 일부 NSViewRepresentable | 빠른 개발 + 부족한 부분만 AppKit 보강 |
| **타깃 OS** | macOS 14 (Sonoma) 이상 | NavigationSplitView, Inspector API 안정 |
| **아키텍처** | MVVM | `FileSystemViewModel` per tab, 명령은 `FileOperationService` |
| **샌드박스** | **OFF** (개발 단계) → 배포 시 `entitlements.app-sandbox = NO` 로 유지 | Finder 대체 목적이라 임의 경로 접근 필수. App Store 대신 직접 배포(Developer ID) |

---

## P0 — MVP 필수 (이게 없으면 못 씀)

### P0-1. 윈도우 레이아웃
- [ ] **3-pane 기본 구조**: 좌측 사이드바 | 가운데 파일 리스트 | (옵션) 우측 프리뷰
- [ ] **상단 툴바**: ← / → / ↑ / 새로고침 + 주소 표시줄 + 검색 박스
- [ ] **하단 status bar**: 항목 수 / 선택 수 / 선택 크기 합계
- [ ] **사이드바 토글** (⌘\)
- [ ] **창 크기 / 분할 비율 영속화** (`@AppStorage`)
- [ ] **다크/라이트 모드 모두** 자연스럽게

### P0-2. 사이드바 (Navigation Pane)
- [ ] **즐겨찾기** 섹션 (Pinned, Quick Access 등가) — 사용자가 폴더 추가/제거
- [ ] **iCloud** 섹션 — `~/Library/Mobile Documents` 매핑
- [ ] **이 PC** 섹션:
  - 데스크탑, 문서, 다운로드, 사진, 음악, 동영상 (Windows 표준 6개)
  - 사용자 홈
  - 시스템 루트 `/`
  - 마운트된 외장 드라이브 (volume) — `NSWorkspace` 또는 `DADiskArbitration` 으로 감지
- [ ] **휴지통** — `~/.Trash`
- [ ] 각 항목 우클릭: 사이드바에서 제거 / 새 창에서 열기 등
- [ ] 사이드바 폴더에 **펼침 ▶ 아이콘** — 자식 디렉토리 inline 표시 (Windows 트리 동작)

### P0-3. 파일 리스트 (Detail View — Windows 기본값)
- [ ] **컬럼**: 이름 / 수정한 날짜 / 유형 / 크기
- [ ] **컬럼 헤더 클릭 → 정렬** (asc/desc 토글)
- [ ] **컬럼 너비 조정** (드래그) + 영속화 per 폴더 또는 전역
- [ ] **컬럼 추가/제거** 우클릭 메뉴 (만든 날짜, 접근한 날짜, 확장자, 태그 등)
- [ ] **행 선택 highlight** Windows 스타일 파란 박스 (Finder의 옅은 회색 X)
- [ ] **다중 선택**:
  - 클릭 = 단일
  - ⇧ + 클릭 = 범위
  - ⌘ + 클릭 = 토글
  - ⌘A = 전체 선택
  - 빈 공간 드래그 = 박스 선택 (lasso)
- [ ] **더블클릭** = 열기 (폴더면 진입, 파일이면 기본 앱)
- [ ] **Enter** = 더블클릭과 동일 (Windows 동작)
- [ ] **F2** = 이름 변경 인라인
- [ ] **Backspace** = 상위 폴더 (Mac은 보통 ⌘↑이지만 Windows 동작 우선)
- [ ] **Delete** = 휴지통 이동 (⌘⌫ 대신 Delete 키 직접 동작 — Windows 동작)
- [ ] **⇧+Delete** = 영구 삭제 (확인 다이얼로그)

### P0-4. 주소 표시줄 (Address Bar)
- [ ] **Breadcrumb 모드** (기본): `이 PC › 사용자 › myungsanjun › 다운로드`
  - 각 세그먼트 클릭 → 해당 폴더로 이동
  - 세그먼트 우측 ▾ 클릭 → 그 폴더의 자식 폴더 드롭다운 (Windows 동작)
- [ ] **편집 모드** — 빈 부분 클릭 시 텍스트 입력으로 전환
  - 경로 직접 입력 → Enter → 이동
  - `~`, `/Users/...`, `~/Desktop` 등 표준 표기 지원
  - Tab/자동완성
- [ ] **경로 복사** (우클릭 → 주소 복사)
- [ ] **이전 경로 history dropdown** (← 버튼 우측의 ▾)

### P0-5. 네비게이션
- [ ] ← (Back) / → (Forward) — tab 단위 history stack
- [ ] ↑ (Up) — 상위 폴더
- [ ] **Alt + ←/→/↑** 키보드 단축키 (Windows 표준)
- [ ] 새로고침 F5

### P0-6. 파일 작업
- [ ] **새 폴더** (⌘⇧N — Mac 표준 / Windows는 Ctrl+Shift+N 동일 매핑)
- [ ] **이름 변경** (F2 또는 두 번째 클릭)
- [ ] **잘라내기** ⌘X / **복사** ⌘C / **붙여넣기** ⌘V
  - 잘라내기 후 항목은 **반투명 표시** (Windows 동작)
  - 붙여넣기 시 동일 이름 충돌 → "건너뛰기 / 덮어쓰기 / 둘 다 유지" 다이얼로그
- [ ] **휴지통 이동** Delete
- [ ] **영구 삭제** ⇧+Delete (확인 dialog)
- [ ] **드래그-드롭**:
  - 같은 볼륨 내부 = 이동 (기본)
  - 다른 볼륨 = 복사 (기본)
  - ⌥ 누른 상태 = 항상 복사
  - ⌘ 누른 상태 = 항상 이동 (Mac 표준이지만 Windows는 ⇧, 양쪽 다 지원)
- [ ] **진행률 다이얼로그** (대용량 파일):
  - 현재 파일명, 전송 속도, ETA, 남은 항목 수
  - 일시정지 / 취소 가능
  - 충돌 처리 inline (모두 적용 체크박스)

### P0-7. 우클릭 컨텍스트 메뉴
빈 공간:
- [ ] 새로 만들기 ▶ 폴더 / 텍스트 파일 / 기타 (정의된 템플릿)
- [ ] 붙여넣기 (클립보드에 항목 있을 때만)
- [ ] 새로고침
- [ ] 정렬 기준 ▶ / 보기 ▶
- [ ] 속성 (⌘I — Mac에서 익숙한 단축키)

파일/폴더:
- [ ] 열기 / 다른 앱으로 열기 ▶
- [ ] 잘라내기 / 복사 / 붙여넣기 / 이름 바꾸기 / 삭제
- [ ] 사이드바에 즐겨찾기 추가
- [ ] 휴지통으로 이동
- [ ] 압축하기 (ZIP)
- [ ] **속성** — 크기, 만든 날짜, 권한, 태그

### P0-8. 검색 (현재 폴더 내)
- [ ] 툴바 우측 검색 박스 (⌘F focus)
- [ ] 입력 즉시 incremental filter (300ms debounce)
- [ ] 결과는 파일 리스트 영역에 표시 (별도 화면 X)
- [ ] **Esc** = 검색 취소, 원래 폴더 뷰로

### P0-9. 키보드 네비게이션
- [ ] 방향키로 항목 이동 (Windows 표준 동작)
- [ ] Home/End = 첫/마지막 항목
- [ ] PgUp/PgDn = 페이지 단위
- [ ] **첫 글자 타이핑** → 그 글자로 시작하는 첫 항목 점프 (Type-ahead)
- [ ] Esc = 선택 해제

### P0-10. 기본 보안 / 안정성
- [ ] **숨김 파일 토글** (⌘⇧.) — Mac 표준 단축키
- [ ] **확장자 표시 토글**
- [ ] 잘못된 경로 / 권한 거부 → friendly error 메시지
- [ ] 외부 변경 감지 (FSEvents) → 자동 새로고침

---

## P1 — 중요 (MVP 직후 추가)

### P1-1. 탭 (Windows 11 동작)
- [ ] ⌘T 새 탭 / ⌘W 탭 닫기 / ⌘⇧T 닫은 탭 복원
- [ ] 탭 드래그로 순서 변경
- [ ] 탭을 창 밖으로 드래그 → 새 창으로 분리
- [ ] 가운데 클릭 = 탭 닫기

### P1-2. 보기 모드
- [ ] **아주 큰 아이콘 / 큰 아이콘 / 보통 아이콘 / 작은 아이콘 / 목록 / 자세히 / 타일 / 콘텐츠** (Windows 8가지 = 우리는 4가지로 압축)
  - Extra Large Icons
  - Large Icons
  - List (compact 1줄)
  - **Details** (default, P0에서 구현)
- [ ] ⌘1/2/3/4 단축키
- [ ] 폴더별 마지막 view 모드 영속화

### P1-3. 미리보기 패널 (Preview Pane)
- [ ] 우측 패널 토글 (⌘⇧P)
- [ ] 선택 항목 미리보기 — `QLPreviewView` (QuickLook framework)
- [ ] 이미지/PDF/텍스트/오디오/비디오 자동 처리
- [ ] 폴더 선택 시 → 폴더 통계 (항목 수, 크기 합계)

### P1-4. 즐겨찾기 / 핀
- [ ] 파일/폴더를 즐겨찾기로 핀 (사이드바 상단 섹션)
- [ ] 드래그로 즐겨찾기에 추가
- [ ] 즐겨찾기 정렬 (사용자 정의 순서)
- [ ] 별표 ★ 아이콘으로 표시

### P1-5. 최근 항목 (Recent)
- [ ] 최근 열어본 파일/폴더 자동 추적
- [ ] 사이드바 "최근" 섹션
- [ ] N개 제한 (기본 50)

### P1-6. 글로벌 검색 (Spotlight)
- [ ] 검색 박스에서 ⌘⇧F → 전체 시스템 검색 (NSMetadataQuery / Core Spotlight)
- [ ] 결과에 파일 경로 표시
- [ ] 검색 필터: 종류 (이미지/문서/...), 크기, 수정일

### P1-7. 압축 / 압축 풀기
- [ ] ZIP 압축 (선택 항목 → "압축") — 진행률 표시
- [ ] ZIP/7z/RAR/TAR.GZ 압축 풀기 (라이브러리: libarchive)
- [ ] 우클릭 메뉴에서 진입

### P1-8. 태그
- [ ] macOS 표준 태그(Finder Tags) 읽기/쓰기 — `URLResourceKey.tagNamesKey`
- [ ] 컬럼으로 태그 표시
- [ ] 우클릭 → 태그 토글

### P1-9. 외부 드래그
- [ ] FileExplorer → 다른 앱 (Finder, 메일, 메신저)
- [ ] 다른 앱 → FileExplorer (Finder 드래그 받기)

### P1-10. 충돌/오류 정교화
- [ ] 복사 충돌 다이얼로그: 미리보기 + 양쪽 정보 비교 (Windows 10+ 동작)
- [ ] 권한 부족 → 관리자 권한 요청 (`AuthorizationServices`)
- [ ] 파일 사용 중 → 어느 프로세스가 잠갔는지 표시 (`lsof`)

---

## P2 — 있으면 좋음

### P2-1. 그룹화 / 필터
- [ ] "그룹화 기준 ▶ 유형 / 만든 날짜 / 크기 / 태그"
- [ ] 그룹 펼치기/접기
- [ ] 컬럼 헤더 우클릭 → 필터 (Windows Vista+ 동작)

### P2-2. 폴더 크기 계산
- [ ] 폴더 행에서 우클릭 → "크기 계산" — 백그라운드 비동기, 진행률 표시
- [ ] 결과 캐싱 (FSEvents로 무효화)
- [ ] 옵션: 항상 자동 계산 (트리 깊은 폴더에서 비쌈, 기본 OFF)

### P2-3. 네트워크 / 원격
- [ ] SMB / AFP / NFS / FTP / SFTP 마운트 (macOS 표준 `Connect to Server`)
- [ ] 사이드바 "네트워크" 섹션
- [ ] 즐겨찾기에 원격 경로 핀

### P2-4. 속성 다이얼로그
- [ ] ⌘I (또는 Alt+Enter — Windows)
- [ ] 일반 / 보안 / 자세히 / 이전 버전 탭 (Windows 동작)
- [ ] 권한 변경 (chmod GUI)
- [ ] 잠금 / 숨김 attribute 변경

### P2-5. 일괄 이름 변경
- [ ] 다중 선택 후 우클릭 → "일괄 이름 변경..."
- [ ] 찾기/바꾸기, 패턴 (예: `image_{n:03}.png`), 정규식
- [ ] 미리보기 후 적용

### P2-6. 디스크 사용량 (Sunburst / TreeMap)
- [ ] 우클릭 폴더 → "디스크 사용량 분석"
- [ ] WinDirStat 스타일 시각화 (별도 window)

### P2-7. 휴지통 관리
- [ ] 휴지통 클릭 → 내용 표시
- [ ] 항목별 원래 위치 표시
- [ ] 우클릭 → 복원 / 영구 삭제
- [ ] "휴지통 비우기" 버튼

### P2-8. 알 림 / 토스트
- [ ] 백그라운드 작업 (대용량 복사) 완료 시 macOS 알림센터

### P2-9. 사용자 정의
- [ ] 단축키 커스터마이징
- [ ] 컬럼 셋 프리셋 저장
- [ ] 우클릭 메뉴에 사용자 커맨드 추가 (예: "터미널에서 열기")

---

## P3 — 장기 / 선택적

- [ ] 플러그인 시스템 (.fxplugin)
- [ ] AppleScript / Shortcuts.app 통합
- [ ] 다국어 (i18n) — 한/영 우선
- [ ] VoiceOver 완전 지원
- [ ] Dual-pane 모드 옵션 (Norton Commander 스타일 사용자용)
- [ ] FTP/SFTP/Cloud (Dropbox, Google Drive) 통합
- [ ] Git 상태 표시 (파일 옆 아이콘)
- [ ] 썸네일 캐싱 (대용량 사진 폴더 빠른 로딩)

---

## 의도적 비범위 (Windows에는 있지만 Mac/이 앱에서는 안 함)

- ❌ **OneDrive 통합** — Mac에서는 별도 앱
- ❌ **Cortana / 검색 제안** — Spotlight로 대체
- ❌ **Windows 라이브러리** — Mac에는 Smart Folder 개념
- ❌ **레지스트리 편집** — Mac엔 없음
- ❌ **시스템 도구 통합** (제어판 등) — 시스템 환경설정으로 대체

---

## 아키텍처 스케치

```
FileExplorer.app
├── App
│   └── FileExplorerApp.swift           ── @main, 윈도우 그룹
├── Views/
│   ├── Window/
│   │   ├── WindowChrome.swift          ── 툴바 + 주소바 + 검색
│   │   └── StatusBar.swift             ── 하단 상태 표시
│   ├── Sidebar/
│   │   ├── SidebarView.swift
│   │   └── SidebarItem.swift           ── 폴더 트리 행
│   ├── FileList/
│   │   ├── FileListView.swift          ── 메인 디테일 뷰
│   │   ├── FileRowView.swift
│   │   └── ColumnHeader.swift
│   ├── Preview/
│   │   └── PreviewPane.swift           ── QLPreviewView 래퍼
│   ├── AddressBar/
│   │   ├── AddressBar.swift
│   │   ├── BreadcrumbSegment.swift
│   │   └── PathEditor.swift            ── 직접 입력 모드
│   └── Modals/
│       ├── PropertiesSheet.swift
│       ├── ConflictDialog.swift        ── 복사/이동 충돌
│       └── ProgressDialog.swift        ── 대용량 작업
├── ViewModels/
│   ├── TabViewModel.swift              ── 탭 1개 상태 (current path, history, selection)
│   ├── SidebarViewModel.swift
│   └── PreferencesViewModel.swift
├── Services/
│   ├── FileOperationService.swift      ── copy / move / delete / rename
│   ├── ClipboardService.swift          ── Cut/Copy/Paste 추적 + Cut 시 반투명 마킹
│   ├── FileWatcherService.swift        ── FSEvents 래퍼
│   ├── BookmarkService.swift           ── 즐겨찾기 / 핀 영속화
│   ├── RecentItemsService.swift
│   ├── ArchiveService.swift            ── ZIP/TAR 압축·해제
│   └── ThumbnailService.swift          ── 이미지 썸네일 캐시
├── Models/
│   ├── FileItem.swift                  ── 파일 메타데이터 (lazy-loaded)
│   ├── FolderNode.swift                ── 사이드바 트리 노드
│   └── HistoryEntry.swift              ── 탭별 back/forward
└── Utilities/
    ├── ByteFormatter.swift
    ├── PathUtilities.swift
    └── IconProvider.swift              ── NSWorkspace icon → SwiftUI Image
```

---

## 작업 순서 제안

1. **Sprint 1 — 골격** (1-2일)
   - 빈 SwiftUI 앱 + WindowGroup
   - 3-pane 레이아웃 (NavigationSplitView)
   - Sidebar mock (정적 항목만)
   - FileListView mock (디렉토리 한 곳 listing — `FileManager.contentsOfDirectory`)
   - 주소바 read-only breadcrumb

2. **Sprint 2 — 네비게이션** (1-2일)
   - 사이드바 클릭 → 가운데 영역 갱신
   - 폴더 더블클릭 → 진입
   - 사이드바 트리 펼침
   - ← / → / ↑ 동작 + history stack

3. **Sprint 3 — 파일 작업** (2-3일)
   - 선택 시스템 (단일/다중/박스)
   - Copy/Cut/Paste/Delete/Rename
   - Trash 통합
   - 진행률 다이얼로그
   - 충돌 다이얼로그

4. **Sprint 4 — UX polish** (1-2일)
   - 키보드 단축키 전부
   - 우클릭 메뉴 완성
   - 컬럼 정렬/너비
   - 주소바 편집 모드 + 자동완성
   - 검색

5. **Sprint 5 — Preview + Quality** (1-2일)
   - QLPreviewView 통합
   - FSEvents 자동 새로고침
   - 숨김 파일 / 확장자 토글
   - Status bar 통계

여기까지가 **P0 MVP**. 이후 P1 항목들을 사용자 피드백 받아가며 우선순위 조정.

---

## 결정해야 할 것들

- [ ] **앱 이름** — 'FileExplorer'로 유지? 다른 이름?
- [ ] **번들 ID** — 예: `com.myungsan.fileexplorer`
- [ ] **배포 방식** — Developer ID 직접 배포 / App Store / 둘 다
- [ ] **샌드박스** — 모든 경로 접근 위해 OFF 권장 (App Store 제한적)
- [ ] **아이콘 컨셉** — 폴더? 트리? 윈도우 익스플로러 같은 노란 폴더?
