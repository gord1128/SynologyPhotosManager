# SynologyPhotosManager — v1.2 최종 버그 점검 계획서 (검증판)

작성일: 2026-07-18 · 기준: v1.1 기능 완성 직후(커밋 `402b59e`)
목적: v1.1 마무리 후 **최종 버그 확인**. "확실한 버그"만 남기려고 각 항목을 재검증 → **확정 / 미검증(서버 캡처 필요) / 조사 후 기각**으로 분류했다.

## 0. 점검 방법과 범위

- **FotoKit 코어**: `swift run FotoKitChecks` → 실 DSM 픽스처 + 스텁 서비스 **26개 체크 전부 통과**.
- **App(SwiftUI) 계층**: Xcode 없는 툴체인이라 실행 빌드 불가 → **코드 정독 + 표적 테스트 + 호출 경로 도달성 확인**.
- 재검증으로 초안(N1~N5) 중 2건을 강등/기각함(아래 §3).

---

## 1. 확정 버그 (코드로 재현 경로까지 확인)

| # | 심각도 | 내용 | 근거(재현 경로) | 수정 방향 |
|---|---|---|---|---|
| **B1** ✅ | 🟠 | ~~**개인↔공유 공간 전환 시 필터가 초기화되지 않음**~~ **(수정 완료 2026-07-18)** — `LibraryViewModel.reload()`가 items/sections/facets/namedPeople는 비우지만 **선택된 사람/장소/카메라/렌즈/ISO/조리개 id 세트는 그대로 유지**. 전환 후에도 `hasActiveFilter==true`라 다른 공간에 **이전 공간의 무효 id**로 필터 질의 → 잘못되거나 빈 결과. 특히 `person_id`는 공간별 고유(코드 주석에도 명시) | `ContentView.swift:146`에 실제 공간 Picker 존재(단 `sharedSpaceUsable`일 때). `onChange(of: model.space)` → `library.reload()` 호출하지만 필터 선택은 안 지움. 공유 공간이 있는 NAS + 필터 활성 상태면 재현 | **[반영]** `LibraryViewModel.resetFilterSelections()` 추출(재로딩 없이 선택만 clear), `ContentView`의 `onChange(of: model.space)`에서 `reload()` **직전** 호출. `reload()` 자체엔 넣지 않음 — 업로드(`mutationCounter`)·연결 시에도 호출돼 필터가 풀리는 부작용 방지 |
| **B2** ✅ | 🟠 | ~~**동영상 스트리밍 상태의 데이터 레이스**~~ **(수정 완료 2026-07-18)** — `VideoStreamLoader`의 `totalLength`/`contentUTI`를 직렬 `queue` **밖**에서 도는 `Task` 클로저(`handle`/`fetchContentInfo`/`streamData`)가 읽고 씀. 반면 델리게이트 콜백(`shouldWait`/`didCancel`)과 `tasks` 정리는 `queue`에서 실행. 동시 byte-range 요청(재생 중 탐색)이 겹치면 공유 가변 상태를 **무동기화 접근** | 코드 정독으로 확정되는 결함(`tasks`는 `queue.async`로 마샬링되나 `totalLength`/`contentUTI`는 아님). *증상(간헐 오류/토막 읽기)은 타이밍 의존 → 실기기 재현은 조건부* | **[반영]** `_totalLength`/`_contentUTI` 백킹 저장소 + `NSLock.withLock` 접근자로 보호. `tasks`는 이미 `queue` 전용이라 그대로. 기존 read/write 지점은 접근자 경유라 변경 없음 |

심각도: 🔴 손상 · 🟠 특정 조건서 기능 무력화 · 🟡 열화 · ⚪ 정리

---

## 2. 미검증 — 확정 불가 (실 서버 응답 캡처가 있어야 판단)

| # | 내용 | 왜 확정 못 하나 | 권장 조치 |
|---|---|---|---|
| U1 | **필터 facet 디코딩 취약성** — `FotoFilterFacets`의 `camera/lens/iso/aperture/geocoding`가 전부 **비옵셔널 배열**. 응답에서 한 키라도 빠지면 디코딩 throw → `filterFacets()`의 `?? FotoFilterFacets()`가 삼켜 **필터 UI 전체가 조용히 빔**. (키 누락 시 `keyNotFound` throw는 실측 확인함) | **DSM이 실제로 키를 누락하는지 증거가 없음.** 요청 `setting`이 5개 facet을 모두 `true`로 지정하므로 서버가 항상(빈 배열이라도) 반환할 가능성이 큼. `spike/fixtures`에 facet 응답 캡처가 없어 확인 불가 | 저비용·무해한 **방어적 강화** 권장: 커스텀 `init(from:)`에서 각 배열 `decodeIfPresent ?? []` (다른 모델 관용 디코딩과 동일 패턴). 확정 버그로 취급하진 않되, 넣어두면 위험 0 |

---

## 3. 조사 후 기각 (초안에서 잡았으나 실제 버그 아님)

| 초안# | 판정 | 근거 |
|---|---|---|
| N4 `ensureYearLoaded` MainActor 스핀 | **기각(도달 불가)** | 유일한 호출자가 연도 스크러버(`PhotoGridView.swift:172`)이고, 스크러버는 `library.loadedYears`(= 이미 로드된 연도)만 노출. 그 연도는 `firstSectionID(forYear:)`가 항상 non-nil → `while firstSectionID==nil` 루프 **진입 자체가 안 됨**. 방어 코드로 남겨도 무방 |
| N5 `jsonString` 폴백 죽은 코드 | **기각(버그 아님)** | 이 툴체인에서 `JSONEncoder().encode(String)`이 항상 성공하고 따옴표를 정상 이스케이프(`"홍\"길\"동"` 실측). 폴백 `?? "\"\(value)\""`은 도달 불가. 원하면 폴백 제거만(정리) |

---

## 4. 수정 순서 (권장)

1. **B1** — 공간 전환 필터 리셋. 작은 변경, 눈에 띄는 오작동 제거. 먼저.
2. **U1** — 관용 디코딩(무해·저비용). B1과 같은 파일권역이라 함께 처리.
3. **B2** — 스트리밍 상태 격리. 국소적이나 동시성이라 리뷰 후 신중히 반영.
4. (선택) N4/N5 정리 — 기능 영향 없음, 여유 시.

## 5. 검증 계획

- B1: 개인 공간서 사람 필터 적용 → 공유로 전환 시 필터 해제·전체 재로딩되는지 수동 확인.
- B2: 동시성 정적 리뷰 + 가능하면 `-strict-concurrency=complete` 경고 확인. 실기기서 재생 중 시크 반복.
- U1: facet 응답에서 특정 키를 제거한 픽스처를 `FotoKitChecks`에 추가 → 관용 디코딩이 빈 배열로 통과하는지 확인.
- 전 항목 반영 후 `swift run FotoKitChecks` 재실행(회귀 없음).

---
*정직한 최종 판단: 사용자 눈에 확실히 드러나는 버그는 **B1** 하나, 코드 레벨로 확정되는 결함이 **B2**(증상은 타이밍 의존)다. U1은 방어적 강화, N4/N5는 기각. App 계층은 Xcode 없는 제약상 실행 검증이 아닌 정독으로 도출했으므로 B2는 실기기 재현 확인을 권장한다.*
