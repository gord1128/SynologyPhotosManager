import SwiftUI

/// The single floating bar at the bottom of a browsing screen.
///
/// Before this, three things floated over the timeline independently and none
/// of them knew about the others: the 연도/월/일 switcher at the bottom, a
/// vertical year rail pinned to the right edge, and the notice banner at the
/// top. They could all be on screen at once, in three different shapes.
/// Everything now lives in — or directly above — this one bar (design handoff
/// §1a, "하단 크롬 바 (핵심 변경)").
///
/// 640 × 44, r22, glass with a lit top edge. Sits on a 24pt baseline.
struct ChromeBar<Content: View>: View {
    static var width: CGFloat { 640 }
    static var height: CGFloat { 44 }
    /// Distance from the window's bottom edge to the bar.
    static var baseline: CGFloat { 24 }

    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: DS.s3) { content }
            .padding(.horizontal, 6)
            .frame(width: Self.width, height: Self.height)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: DS.rBar, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.rBar, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.45), DS.hairline],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
}

/// A capsule segmented control sized for the chrome bar: only the selected
/// item is filled, and only it is semibold.
struct ChromeSegment<T: Hashable>: View {
    let options: [T]
    let selection: T
    let title: (T) -> String
    let onSelect: (T) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options, id: \.self) { option in
                let isOn = option == selection
                Button { onSelect(option) } label: {
                    Text(title(option))
                        .font(.callout)
                        .fontWeight(isOn ? .semibold : .regular)
                        .foregroundStyle(isOn ? Color.primary : .secondary)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background {
                            if isOn {
                                Capsule().fill(.selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(option))
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

/// A hairline divider sized for the bar's interior.
struct ChromeDivider: View {
    var body: some View {
        Rectangle()
            .fill(DS.hairline)
            .frame(width: 1, height: 20)
    }
}

/// A wrapping row. SwiftUI has no built-in flow layout, and the filter panel's
/// condition chips are variable-width text — an `HStack` would push them off
/// the 300pt panel the moment a date range showed up.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
