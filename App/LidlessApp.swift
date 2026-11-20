import SwiftUI
import AppKit

@main
struct LidlessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
        } label: {
            Image(nsImage: StatusIcon.image(state: model.iconState, fans: model.fansBlasting))
                .accessibilityLabel(StatusIcon.label(state: model.iconState, fans: model.fansBlasting))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

extension AppModel {
    static let shared = AppModel()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }
}

/// Template menu bar image: main symbol for idle/awake/lid, plus a fan glyph when fans are overridden.
enum StatusIcon {
    static func symbol(_ s: IconState) -> String {
        switch s {
        case .idle: return "eye.slash"
        case .awake: return "eye"
        case .lid: return "eye.trianglebadge.exclamationmark.fill"
        }
    }

    static func label(state: IconState, fans: Bool) -> String {
        let base: String
        switch state {
        case .idle: base = "Lidless: idle"
        case .awake: base = "Lidless: keeping awake"
        case .lid: base = "Lidless: lid-closed mode ON"
        }
        return fans ? base + ", fans overridden" : base
    }

    static func image(state: IconState, fans: Bool) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let main = NSImage(systemSymbolName: symbol(state), accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) ?? NSImage()
        guard fans, let fan = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)) else {
            main.isTemplate = true
            return main
        }
        let gap: CGFloat = 2
        let size = NSSize(width: main.size.width + gap + fan.size.width, height: max(main.size.height, fan.size.height))
        let img = NSImage(size: size, flipped: false) { _ in
            main.draw(in: NSRect(x: 0, y: (size.height - main.size.height) / 2, width: main.size.width, height: main.size.height))
            fan.draw(in: NSRect(x: main.size.width + gap, y: (size.height - fan.size.height) / 2, width: fan.size.width, height: fan.size.height))
            return true
        }
        img.isTemplate = true
        return img
    }
}
