import SwiftUI
import FotoKit

/// Export-options sheet (T5): pick format / size / quality / metadata-strip, then
/// export. Photos are processed locally; videos always export as their original.
struct ExportOptionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let items: [FotoItem]

    @State private var options = ExportOptions()

    private var videoCount: Int { items.filter { $0.type == .video }.count }
    private var photoCount: Int { items.count - videoCount }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s4) {
            VStack(alignment: .leading, spacing: 4) {
                Text("내보내기").font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }

            Form {
                Picker("형식", selection: $options.format) {
                    ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("크기", selection: sizeSelection) {
                    ForEach(ImageExporter.sizeOptions.indices, id: \.self) { i in
                        Text(ImageExporter.sizeOptions[i].label).tag(i)
                    }
                }
                if options.format == .jpeg {
                    HStack {
                        Text("품질")
                        Slider(value: $options.jpegQuality, in: 0.5...1.0)
                        Text("\(Int(options.jpegQuality * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Toggle("메타데이터·위치(GPS) 제거", isOn: $options.stripMetadata)
            }
            .formStyle(.grouped)
            .frame(height: options.format == .jpeg ? 200 : 160)
            .disabled(photoCount == 0)   // all-video selection: nothing to process

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button(model.isExporting ? "내보내는 중…" : "내보내기") {
                    let opts = options
                    let its = items
                    dismiss()
                    Task { await model.performExport(its, options: opts) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isExporting)
            }
        }
        .padding(DS.s5)
        .frame(width: 400)
    }

    private var subtitle: String {
        var parts: [String] = ["\(items.count)개 항목"]
        if videoCount > 0 && photoCount > 0 { parts.append("동영상 \(videoCount)개는 원본으로 저장") }
        else if videoCount > 0 && photoCount == 0 { parts.append("동영상은 원본으로 저장됩니다") }
        return parts.joined(separator: " · ")
    }

    /// Maps the size-preset picker index ↔ `options.maxDimension`.
    private var sizeSelection: Binding<Int> {
        Binding(
            get: { ImageExporter.sizeOptions.firstIndex { $0.value == options.maxDimension } ?? 0 },
            set: { options.maxDimension = ImageExporter.sizeOptions[$0].value })
    }
}
