import Foundation
import FotoKit

// 증분 병합(appending)이 전량 재그룹(sections)과 같은 결과를 내는가.
// FotoItem은 Decodable이므로 JSON으로 만든다(이니셜라이저가 디코더 전용).
func makeItems(_ times: [Int]) -> [FotoItem] {
    let rows = times.enumerated().map { i, t in
        #"{"id":\#(i + 1),"filename":"p\#(i).jpg","filesize":1,"folder_id":1,"owner_user_id":1,"time":\#(t),"indexed_time":\#(t),"type":"photo"}"#
    }.joined(separator: ",")
    let data = Data(#"{"list":[\#(rows)]}"#.utf8)
    let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
    return (try! d.decode(FotoItemListData.self, from: data)).list
}

func describe(_ s: [TimelineSection]) -> String {
    s.map { "\($0.id):\($0.items.count):\($0.title)" }.joined(separator: " | ")
}

var failures = 0
func expect(_ ok: Bool, _ msg: String) {
    print(ok ? "  ✓ \(msg)" : "  ✘ \(msg)"); if !ok { failures += 1 }
}

// 2024-01 ~ 2026-08 사이 시각들을 최신순으로. 페이지 경계가 섹션 한가운데에
// 떨어지는 경우를 반드시 포함시킨다 — 거기가 병합이 틀리기 쉬운 자리다.
let base = 1_770_000_000        // 2026-02 언저리
let times = (0..<37).map { base - $0 * 86_400 * 9 }   // 9일 간격 37장

for scale in [TimelineScale.year, .month, .day] {
    let all = makeItems(times)
    let whole = TimelineGrouping.sections(from: all, scale: scale)

    // 페이지 크기를 바꿔 가며 증분 병합
    for pageSize in [1, 4, 10, 37] {
        var incremental: [TimelineSection] = []
        var offset = 0
        while offset < all.count {
            let page = Array(all[offset..<min(offset + pageSize, all.count)])
            incremental = TimelineGrouping.appending(page, to: incremental, scale: scale)
            offset += pageSize
        }
        expect(describe(incremental) == describe(whole),
               "\(scale.rawValue) · 페이지 \(pageSize)장 → 전량 재그룹과 동일 (섹션 \(whole.count)개)")
    }
}

// 빈 페이지는 아무것도 바꾸지 않는다
let one = TimelineGrouping.sections(from: makeItems([base]), scale: .month)
expect(describe(TimelineGrouping.appending([], to: one, scale: .month)) == describe(one),
       "빈 페이지는 무시된다")

print(failures == 0 ? "✅ 통과" : "❌ \(failures)건 실패")
exit(failures == 0 ? 0 : 1)
