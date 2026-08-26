#!/bin/bash
# 배포본을 만든다 — 검사 · 빌드 · **ad-hoc 서명** · 검증 · DMG.
#
# **왜 손으로 하지 않고 스크립트인가.** 그냥 빌드해서 올리면 Xcode가 붙인 개발 서명이
# 조용히 함께 나간다. 그 서명에는 `get-task-allow`가 들어 있어 hardened runtime의
# 디버거 차단이 풀리고, 그러면 같은 사용자 권한의 아무 프로세스나 이 앱의 메모리를
# 읽을 수 있다. 이 앱은 **NAS 평문 비밀번호를 메모리에 들고 있다**
# (SynologyClient의 세션 자동 재로그인용). 즉 그 유출은 이론이 아니다.
#
# **왜 ad-hoc인가.** 노터라이즈에는 유료 Apple Developer Program의 Developer ID
# 인증서가 필요하고 그것이 없다. 개발 인증서로 서명해 봐야 남의 맥에서 Gatekeeper를
# 통과하지 못하는 건 같으면서, 대신 만료(2027-07-08)와 `get-task-allow`만 떠안는다.
# ad-hoc은 셋 다 없다. hardened runtime은 켠 채로 둔다 — 노터라이즈가 없어 얻는 것이
# 줄지만 디버거 차단은 살아 있고, 그게 위에서 막으려는 바로 그것이다.
#
# **샌드박스 앱이라 엔타이틀먼트를 함께 넣어 서명해야 한다.** 빼먹으면 앱이 실행은
# 되지만 로컬 네트워크·파일 접근이 조용히 죽는다. 그래서 서명 뒤에 검사한다.
#
#   사용: Tools/release.sh [출력폴더]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-"$ROOT/build/release"}
DEV=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
APP_NAME=SynologyPhotosManager

cd "$ROOT"

VERSION=$(awk -F'"' '/MARKETING_VERSION:/{print $2}' project.yml)
[ -n "$VERSION" ] || { echo "거부: project.yml에서 MARKETING_VERSION을 못 읽었다" >&2; exit 1; }

# **배포본은 어느 커밋에서 나왔는지 말할 수 있어야 한다.** 앱과 SynoKit 둘 다 봐야
# 한다 — SynoKit은 벤더링이 아니라 ../SynoKit 상대경로 의존이라, 그쪽이 더러우면
# 같은 커밋에서 같은 물건이 다시 나오지 않는다.
for repo in "$ROOT" "$ROOT/../SynoKit"; do
    dirty=$(git -C "$repo" status --porcelain 2>/dev/null || true)
    if [ -n "$dirty" ]; then
        echo "거부: $(basename "$repo")에 커밋 안 된 변경이 있다" >&2
        printf '%s\n' "$dirty" | sed 's/^/    /' >&2
        exit 1
    fi
done

# 빌드 번호는 손으로 올리지 않는다. 손으로 올리는 값이면 아무도 안 올린다 —
# 옆 프로젝트의 릴리스 셋이 전부 빌드 `1`이었다. 커밋 수는 저절로 오르고
# 되짚어 세면 같은 값이 나온다.
BUILD=$(git rev-list --count HEAD)
COMMIT=$(git rev-parse --short HEAD)
SYNOKIT_COMMIT=$(git -C "$ROOT/../SynoKit" rev-parse --short HEAD)

echo "· $APP_NAME $VERSION (빌드 $BUILD · $COMMIT · SynoKit $SYNOKIT_COMMIT)"

# 자기 검사를 통과 못 하는 물건은 내보내지 않는다.
echo "· 검사"
DEVELOPER_DIR="$DEV" swift run --package-path "$ROOT/../SynoKit" SynoKitChecks | tail -1 | sed 's/^/    /'
DEVELOPER_DIR="$DEV" swift run --package-path "$ROOT/FotoKit" FotoKitChecks | tail -1 | sed 's/^/    /'
"$ROOT/Tools/check-grouping.sh" | tail -1 | sed 's/^/    /'

rm -rf "$OUT"; mkdir -p "$OUT"

echo "· 프로젝트 생성"
xcodegen generate > /dev/null

# **서명을 끄고 빌드한다.** Xcode가 붙이는 개발 서명을 지우고 다시 하는 것보다 애초에
# 안 붙이는 편이 낫다 — 인증서가 아예 없는 기계에서도 이 스크립트가 돈다.
# `-derivedDataPath`로 격리한다. 없이 돌리면 평소 개발 빌드 자리를 덮어쓴다.
echo "· 빌드 (Release, 서명 없음)"
DEVELOPER_DIR="$DEV" xcodebuild \
    -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -derivedDataPath "$OUT/dd" \
    CONFIGURATION_BUILD_DIR="$OUT/build" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build > "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }

APP="$OUT/build/$APP_NAME.app"
[ -d "$APP" ] || { echo "앱이 안 나왔다: $APP" >&2; exit 1; }

# 커밋 해시를 plist에 박는다. 「문제 보고」가 이 값을 함께 보내므로, 제보 하나로
# 어느 트리에서 나온 물건인지 되짚을 수 있다. 서명 전에 넣어야 봉인에 들어간다.
/usr/libexec/PlistBuddy -c "Add :SPMCommit string $COMMIT" "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :SPMSynoKitCommit string $SYNOKIT_COMMIT" "$APP/Contents/Info.plist" >/dev/null

echo "· ad-hoc 서명"
codesign --force --sign - --options runtime --timestamp=none \
    --entitlements App/$APP_NAME.entitlements "$APP"

echo "· 검증"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

# ★ 이 세 검사가 이 스크립트의 존재 이유다.
ENT=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)
if printf '%s' "$ENT" | grep -q 'get-task-allow'; then
    echo "거부: 배포본에 get-task-allow가 들어 있다 — 디버거가 붙어 비밀번호를 읽을 수 있다" >&2
    exit 1
fi
if ! printf '%s' "$ENT" | grep -q 'app-sandbox'; then
    echo "거부: 샌드박스 엔타이틀먼트가 없다 — 서명할 때 --entitlements를 빠뜨렸다" >&2
    exit 1
fi
if ! codesign -dv --verbose=2 "$APP" 2>&1 | grep -q 'Signature=adhoc'; then
    echo "거부: ad-hoc 서명이 아니다 — 개발 서명이 새어 들어왔다" >&2
    exit 1
fi
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E 'flags|Signature|Identifier' | sed 's/^/    /'

echo "· DMG"
DMG="$OUT/$APP_NAME-$VERSION.dmg"
STAGE="$OUT/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format ULFO "$DMG"
rm -rf "$STAGE"

echo
echo "됐다: $DMG"
echo "  크기   $(/usr/bin/du -h "$DMG" | cut -f1)"
echo "  SHA256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "  커밋   $COMMIT (빌드 $BUILD) · SynoKit $SYNOKIT_COMMIT"
echo
echo "릴리스 설명에 반드시 적을 것 — 서명이 ad-hoc이라 처음 열 때 Gatekeeper가 막는다:"
echo "  시스템 설정 › 개인 정보 보호 및 보안 › 맨 아래 「무시하고 열기」"
echo "  (글로만 적으면 절반은 못 한다. 스크린샷을 함께 넣을 것.)"
