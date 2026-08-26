#!/bin/bash
# 타임라인 증분 그룹핑이 전량 재그룹과 같은 결과를 내는지 확인한다.
#
# **왜 스크립트인가.** `TimelineGrouping.appending`은 성능을 위한 지름길이다 —
# 페이지마다 전체를 다시 묶는 대신 새 페이지만 묶어 마지막 섹션에 잇는다.
# 지름길이 원래 결과와 어긋나면 사진이 엉뚱한 달에 들어가고, 그건 화면을 봐서는
# 좀처럼 눈치채지 못한다. 앱 타깃에는 테스트 하네스가 없으므로(SwiftPM 패키지가
# 아니다) 해당 파일만 떼어 FotoKit에 링크해 돌린다.
#
#   사용: Tools/check-grouping.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEV=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# FotoKit(과 그 의존인 SynoKit)의 오브젝트 파일에 직접 링크한다. SwiftPM은 라이브러리
# 타깃을 .a 로 남기지 않으므로 `-lFotoKit` 은 쓸 수 없다.
DEVELOPER_DIR="$DEV" swift build -c release --package-path "$ROOT/FotoKit" > /dev/null
FK="$ROOT/FotoKit/.build/release"

DEVELOPER_DIR="$DEV" swiftc \
    -I "$FK/Modules" \
    "$ROOT/App/DayGrouping.swift" "$ROOT/Tools/GroupingCheck/main.swift" \
    "$FK"/FotoKit.build/*.o "$FK"/SynoKit.build/*.o \
    -o "$OUT/groupcheck"

"$OUT/groupcheck"
