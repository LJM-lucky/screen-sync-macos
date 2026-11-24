import AppKit
import SwiftUI

@MainActor final class CalibrationComparison {
    private var panels: [NSPanel] = []

    func show(on externalID: String) -> Bool {
        close()
        var internalScreen: NSScreen?
        var externalScreen: NSScreen?
        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
            if CGDisplayIsBuiltin(id) != 0 {
                internalScreen = screen
            } else if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                      let string = CFUUIDCreateString(nil, uuid), string as String == externalID {
                externalScreen = screen
            }
        }
        guard let internalScreen, let externalScreen else { return false }
        panels = [internalScreen, externalScreen].map { screen in
            let visible = screen.visibleFrame
            let size = NSSize(width: 230, height: 146)
            let frame = NSRect(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20,
                               width: size.width, height: size.height)
            let panel = NSPanel(contentRect: frame, styleMask: [.titled, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.title = "亮度校准对照"
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: HStack(spacing: 0) {
                ForEach([0.16, 0.36, 0.63, 0.91], id: \.self) { gray in
                    Color(.sRGB, white: gray, opacity: 1)
                }
            })
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            return panel
        }
        return true
    }

    func close() {
        panels.forEach { $0.close() }
        panels.removeAll()
    }
}
