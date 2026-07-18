# SynologyPhotosManager — v1.3 로드맵 (추가 버그 + 기능 아이디어)

작성일: 2026-07-18 · 기준: v1.2 버그 수정(B1/B2 완료) 직후
비전 재확인: **"백업이 아니라 관리"** — 솔로 사용, 키보드 친화, macOS 네이티브. DSM Photos API 위에서 *빠르게 훑고 · 정리하고 · 필요한 것만 꺼내는* 앱.
방법론: 기존 원칙 유지 — **spike(실 API 캡처) → 헤드리스 스모크 → 실데이터 무손상 검증**.

---

## 1. 추가로 발견한 버그 (이번 정독)

| # | 심각도 | 내용 | 근거 | 수정 방향 |
|---|---|---|---|---|
| **B3** ✅ | 🟠 | **(수정 완료)** ~~동영상 재생 실패가 무표시~~ — `PhotoPreviewView.prepareVideo()`가 `AVPlayer` 생성 직후 곧바로 `videoState=.ready`로 전환하고 재생 시작. `AVPlayerItem.status==.failed`나 `AVPlayer.error`를 **관찰하지 않음** → 스트리밍이 도중 실패(인증서·네트워크·미지원 코덱)하면 사용자는 **검은 화면에 멈춤**, 오류 안내 없음 | `PhotoPreviewView.swift:165`. `.failed`는 `makeAsset`가 nil일 때만 설정됨 | `AVPlayerItem.status`를 KVO/`publisher`로 관찰 → `.failed`면 `videoState=.failed`. 필요시 타임아웃(예: 15s 내 `.readyToPlay` 없으면 실패 처리) |
| **B4** ✅ | 🟡 | **(수정 완료)** ~~"앨범에 추가 / 새 앨범" 실패·성공이 무표시~~ — `AppModel.addToAlbum`·`createAlbum`이 `try?`로 오류를 삼키고 `showInfo/showError` 알림도 없음. 삭제·즐겨찾기(알림 있음)와 불일치 → 추가 실패 시 사용자는 됐는지 알 수 없음 | `AppModel.swift`(`addToAlbum`/`createAlbum`). 인스펙터 `AddToAlbumMenu`도 피드백 없음 | 삭제/즐겨찾기와 동일하게 성공 시 "N장을 '앨범'에 추가", 실패 시 오류 배너. `try?` → `do/catch` |

*이전 문서 `PLAN-v1.2-bugfix.md`의 B1/B2는 수정 완료, U1(facet 방어 디코딩)은 선택 강화 항목으로 남아 있음.*

---

## 2. 기능 아이디어 (벤치마킹 → 이 앱에 최적화)

각 항목: **무엇 / 어느 앱이 잘하나 / 왜 이 앱에 맞나 / 기존 배선 재사용도 / 검증 필요**.

### Tier 1 — 비전 정중앙, 백엔드가 이미 지원 (권장 우선 착수)

| 아이디어 | 벤치마크 | 이 앱에 맞는 이유 & 재사용 | 검증 |
|---|---|---|---|
| **T1. 정리 큐(Triage 모드)** ✅ **구현** — 한 장씩 크게 띄우고 키보드로 `→유지 / ⌫삭제 / A앨범 / ←되돌리기`. 삭제는 *예정 표시*만 → 세션 끝(또는 하단 바)에서 한 번의 확인으로 일괄 삭제. "결정/유지/삭제 예정" 카운트 표시 | Slidebox, Google Photos "공간 확보", Apple Photos 정리 | **[구현]** `TriageViewModel`+`TriageView` 신규, 사이드바 "정리" 섹션. 삭제는 `AppModel.deleteItems` 재사용 → `deletedIDs`가 `applyCommitted`로 커서/카운트 갱신(모든 그리드와 동일 경로). 되돌리기 스택 신규 | 불필요(기존 API) |
| **T2. 스마트 앨범 / 저장된 검색** ✅ **구현** — FilterPanel "스마트 앨범으로 저장" → 이름 지정 → 사이드바 "스마트 앨범" 섹션. 클릭하면 타임라인 선택 + 저장된 필터 재적용 | Apple Photos 스마트 앨범, Lightroom 컬렉션 | **[구현]** `SmartAlbum`/`SmartAlbumStore`(UserDefaults) + `LibraryViewModel.currentCriteria`/`apply(_:)` + `AppModel` 저장/삭제/열기 버스. **공간별 스코프**(`isShared`)로 B1식 교차-공간 id 불일치 원천 차단. 새 중앙 뷰 없이 필터 엔진 재사용 | 불필요(로컬 저장) |
| **T3. 지도 뷰(장소)** ✅ **구현 완료** — 라이브러리 전체를 지도에 클러스터링, 핀/영역 탭 → 해당 위치 사진 | Apple Photos "지도/장소", Google Photos 지도 | GPS·geocoding facet이 이미 배선됨. 인스펙터 미니맵(`MapKit`) 확장. **차별화 포인트** | **[spike 결과]** `additional=["gps"]`로 전체 페이징이 **2813장 6페이지 0.78s / 0.6MB, 84%가 GPS(~2353장)** — 한 번에 전 좌표 로드 후 클라이언트 클러스터링이 정답. geocoding facet은 count 없음(불필요). `MapSpike`/FINDINGS.md 참조 |
| **T4. "이 날의 추억" / On this day** ✅ **구현** — 사이드바 "추억": 오늘의 월·일을 지난 해별로 가로 스트립, 탭하면 미리보기(그 해 안에서 이동) | Google Photos Memories, Apple Photos "추억" | **[구현]** `MemoriesViewModel`+`MemoriesView`. 서버 변경 0 — **검증된 단일 time-range** 쿼리를 지난 15년 각각에 대해 **병렬 호출** 후 연도별 그룹핑(다중-range는 미검증이라 회피). `ThumbnailCell` 재사용 | 불필요(파생) |

### Tier 2 — 강력, 중간 비용

| 아이디어 | 벤치마크 | 이 앱에 맞는 이유 & 재사용 | 검증 |
|---|---|---|---|
| **T5. 내보내기 프리셋** ✅ **구현+검증** — 형식(원본/JPEG/PNG)·크기(원본/4096/2048/1024)·품질·메타데이터/GPS 제거 시트. 인스펙터 버튼 + 메뉴바 ⇧⌘E | Lightroom Export, Apple Photos 내보내기 | **[구현]** `ImageExporter`(ImageIO 로컬, 방향보존 리사이즈+재인코딩 GPS제거)+`ExportOptionsView`+`AppModel.performExport`(단일=파일/다중=폴더/pass-through 스트리밍). **실사진 검증**: 5712×4284 HEIC GPS→1024 JPEG GPS제거 133KB, PNG원본크기, pass-through 무손상 ALL PASS | 불필요(로컬 변환) |
| **T6. 정확 중복 찾기** — 파일명+크기(또는 콘텐츠 해시)로 라이브러리 전역 **정확 중복** 검출. 유사-스택 정리와 상보 | PhotoSweeper, Gemini Photos | 유사(`SimilarItem`)는 있으나 정확 중복은 별개. 정리 비전에 직결. `filesize`/`filename`은 이미 디코딩됨 | 대량 스캐닝 페이징·해시 전략 spike |
| **T7. 일괄 촬영일 이동(오프셋)** — 여러 장을 골라 "＋N시간/일" 상대 이동(시차·카메라 시계 오차 보정) | Lightroom "Edit Capture Time", Apple Photos 날짜 조정 | 단건 `setTakenTime`은 검증 완료(v1.1). 배치+상대 오프셋만 추가 | 배치 `set time` 다건 동작 spike(단건은 검증됨) |
| **T8. 태그(키워드)** — general_tag 추가/제거, 태그로 필터 | Lightroom 키워드, Apple Photos 키워드 | search facet에 `general_tag` 존재. 관리 축을 사람/장소 밖으로 확장 | **쓰기 API 미검증** — 태그 set/delete 엔드포인트 spike 필수 |

### Tier 3 — 폴리시 / 네이티브 감성

| 아이디어 | 벤치마크 | 비고 |
|---|---|---|
| **T9. 미리보기 필름스트립** — 뷰어 하단 스크럽 가능한 썸네일 스트립 | Lightroom, Apple Photos | `PhotoPreviewView`에 하단 오버레이. 현 좌우 화살표 보완 |
| **T10. 앨범/사람을 새 창으로** — 멀티 윈도우, `⌘N` | Finder, Apple Photos | SwiftUI `WindowGroup`/`openWindow` |
| **T11. 뷰어 줌 단축키 정리** — `⌘+/⌘-/0`, `F` 전체화면 | macOS Quick Look | 이미 핀치/더블클릭 줌 있음 → 키보드 보강 |

---

## 3. 진행 현황 (2026-07-18 마감)

**완료 (전부 Xcode 빌드 통과 + 해당 항목 라이브 데이터 검증):**
- ✅ 버그 **B3**(동영상 실패 표시) · **B4**(앨범 추가 피드백)
- ✅ **T1 정리 큐** — 라이브 스모크 `PHOTOS_SMOKE_TRIAGE` ALL PASS(유지/삭제/되돌리기/커밋 커서)
- ✅ **T2 스마트 앨범** — 공간별 스코프로 B1 재발 차단
- ✅ **T4 이 날의 추억** — 단일 range 병렬 쿼리(다중 range 회피)
- ✅ **T3 지도 뷰** — `MapSpike` 선행, `PHOTOS_SMOKE_MAP`(2353/2813 좌표, 클러스터 병합/분리) 검증
- ✅ **T5 내보내기 프리셋** — `PHOTOS_SMOKE_EXPORT`(리사이즈·포맷·GPS제거·pass-through) ALL PASS

**미착수 (남은 Tier 2 — 각 선행 조건 있음):**
- ⏳ **T6 정확 중복 찾기** — 읽기 전용이나 이 NAS엔 정확 중복 0(양성 검증 불가) + 유사항목 정리와 일부 겹침.
- ⏳ **T7 일괄 촬영일 오프셋** — 실사진 **쓰기** → 다건 set-time write-spike 선행 필요.
- ⏳ **T8 태그** — general_tag **쓰기 API 미검증** → write-API spike 선행 필요.
- Tier 3(T9 필름스트립 / T10 멀티윈도우 / T11 줌 단축키)는 폴리시, 수요 보고.

## 4. 착수 전 spike가 필요한 항목 (실 API 캡처)

- **T3 지도**: GPS 보유 아이템만 대량으로 끌어오는 질의/페이징(현 필터에 "위치 있음" 축 없음).
- **T6 정확 중복**: 전역 스캔 비용 — 서버 페이징 vs 로컬 해시 트레이드오프.
- **T7 배치 날짜**: `set time` 다건 id 동작(단건만 검증됨).
- **T8 태그**: general_tag **쓰기** 엔드포인트 존재/포맷 — 미검증. spike 없이는 착수 금지.

---
*원칙: 로컬 파생/저장으로 되는 것(T2/T4/T5)은 서버 무변경이라 위험이 낮으니 먼저, 서버 쓰기가 필요한 것(T7/T8)은 반드시 spike 후. 모든 신규 기능은 실데이터 무손상(삭제·이동은 확인 다이얼로그) 원칙을 따른다.*
