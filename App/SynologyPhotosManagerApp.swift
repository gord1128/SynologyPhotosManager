import SwiftUI
import AppKit
import SynoKit

/// Dev-only: when PHOTOS_SMOKE_OUT is set, renders a real grid PNG then exits.
/// `applicationDidFinishLaunching` fires whether or not a window is shown.
final class SmokeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        if let out = env["PHOTOS_SMOKE_OUT"] {
            Task { @MainActor in await SmokeSnapshot.run(outPath: out) }
        } else if let out = env["PHOTOS_SMOKE_FOLDER"] {
            Task { @MainActor in await SmokeSnapshot.runFolder(outPath: out) }
        } else if let out = env["PHOTOS_SMOKE_ALBUMS"] {
            Task { @MainActor in await SmokeSnapshot.runAlbums(outPath: out) }
        } else if let out = env["PHOTOS_SMOKE_PEOPLE"] {
            Task { @MainActor in await SmokeSnapshot.runPeople(outPath: out) }
        } else if let out = env["PHOTOS_SMOKE_PERSON"] {
            Task { @MainActor in await SmokeSnapshot.runPersonDetail(outPath: out) }
        } else if let out = env["PHOTOS_SMOKE_VIDEOSTREAM"] {
            Task { @MainActor in await SmokeSnapshot.runVideoStream(outPath: out) }
        } else if let out = env["PHOTOS_SMOKE_SEARCH"] {
            Task { @MainActor in await SmokeSnapshot.runSearch(outPath: out) }
        } else if let out = env["PHOTOS_SMOKE_ITEMDETAIL"] {
            Task { @MainActor in await SmokeSnapshot.runItemDetail(outPath: out) }
        } else if let out = env["PHOTOS_SMOKE_SUGGEST"] {
            Task { @MainActor in await SmokeSnapshot.runSuggest(outPath: out) }
        } else if let out = env["PHOTOS_SMOKE_FILTER"] {
            Task { @MainActor in await SmokeSnapshot.runFilter(outPath: out) }
        } else if let out = env["PHOTOS_SMOKE_TLFILTER"] {
            Task { @MainActor in await SmokeSnapshot.runTimelineFilter(outPath: out) }
        } else if let out = env["PHOTOS_SMOKE_SHARE"] {
            Task { @MainActor in await SmokeSnapshot.runShare(outPath: out) }
        } else if let out = env["PHOTOS_SMOKE_ALBUMTEST"] {
            Task { @MainActor in await SmokeSnapshot.runAlbumTest(outPath: out) }
        } else if let out = env["PHOTOS_SMOKE_ALBUMSPACE"] {
            Task { @MainActor in await SmokeSnapshot.runAlbumSpaces(outPath: out) }
        } else if let out = env["PHOTOS_SMOKE_DISCOVER"] {
            Task { @MainActor in await SmokeSnapshot.runDiscover(outPath: out) }
        } else if let out = env["PHOTOS_SMOKE_DISKCACHE"] {
            Task { @MainActor in await SmokeSnapshot.runDiskCache(outPath: out) }
        } else if let out = env["PHOTOS_SMOKE_SIMILAR"] {
            Task { @MainActor in await SmokeSnapshot.runSimilar(outPath: out) }
        } else if let out = env["PHOTOS_SMOKE_FAVRECENT"] {
            Task { @MainActor in await SmokeSnapshot.runFavRecent(outPath: out) }
        } else if let out = env["PHOTOS_SMOKE_STACK"] {
            Task { @MainActor in await SmokeSnapshot.runStack(outPath: out) }
        } else if let out = env["PHOTOS_SMOKE_SETTINGS"] {
            Task { @MainActor in await SmokeSnapshot.runSettings(outPath: out) }
        }
    }
}

@main
struct SynologyPhotosManagerApp: App {
    @NSApplicationDelegateAdaptor(SmokeAppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        // Namespace this app's on-disk secure store / caches so it never
        // collides with SynologyMonitor's, even though both use SynoKit.
        // ⚠️ MUST run BEFORE `AppModel()` — the model reads saved credentials in
        // its init, so if the namespace isn't set yet it reads the wrong (default)
        // directory, finds no connection, and lands on "NAS를 추가하세요" /
        // "연결 안 됨". Creating the model here (after this line) guarantees order.
        SecureLocalStore.appDirectoryName = "SynologyPhotosManager"
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
