import SwiftUI

/// Native menu bar + keyboard shortcuts (plan D1). Item-level actions (download,
/// delete, select-all) are dispatched through `AppModel`'s command bus and
/// applied by whichever center view is active; upload runs directly on the model.
struct AppCommands: Commands {
    @Bindable var model: AppModel

    var body: some Commands {
        // File → 업로드 / 다운로드 / 삭제
        CommandGroup(after: .newItem) {
            Button("업로드…") { Task { await model.pickAndUpload() } }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(model.fotoService == nil || model.isUploading)

            Button("다운로드…") { model.sendMenuCommand(.download) }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.canOperateOnItems)

            Button("내보내기…") { model.sendMenuCommand(.export) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!model.canOperateOnItems)

            Divider()

            Button("삭제") { model.sendMenuCommand(.delete) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.canOperateOnItems)
        }

        // Edit → 전체 선택 / 선택 해제
        CommandGroup(after: .pasteboard) {
            Button("전체 선택") { model.sendMenuCommand(.selectAll) }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!model.canOperateOnItems)

            Button("선택 해제") { model.sendMenuCommand(.deselectAll) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!model.canOperateOnItems)
        }

        // View → 타임라인 단위 + 필터
        CommandGroup(after: .toolbar) {
            Button("연도별 보기") { model.sendMenuCommand(.scale(.year)) }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(!model.isTimelineActive || model.fotoService == nil)
            Button("월별 보기") { model.sendMenuCommand(.scale(.month)) }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(!model.isTimelineActive || model.fotoService == nil)
            Button("일별 보기") { model.sendMenuCommand(.scale(.day)) }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(!model.isTimelineActive || model.fotoService == nil)

            Divider()

            Button("필터…") { model.sendMenuCommand(.toggleFilter) }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!model.isTimelineActive || model.fotoService == nil)
        }
    }
}
