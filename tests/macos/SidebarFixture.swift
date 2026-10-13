import AppKit
import SwiftUI

@MainActor final class Selection: ObservableObject {
    @Published var current: PendingNetSection? = .connection
}
struct Fixture: View {
    @ObservedObject var selection: Selection
    var body: some View {
        VStack(spacing: 0) {
            PendingNetSidebar(selection: $selection.current).frame(width: 196, height: 310)
            HStack {
                PendingPill(title: "TUN", selected: true) {}
                Spacer()
            }.frame(height: 40)
        }
        .frame(width: 196, height: 350)
        .background(PendingNetTheme.Palette.canvas)
    }
}
@main enum SidebarFixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let selection = Selection()
        let host = NSHostingView(rootView: Fixture(selection: selection))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 196, height: 350), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "PendingNet Sidebar Fixture"
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        if ProcessInfo.processInfo.arguments.contains("--interactive") {
            app.run()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            func findOutline(_ view: NSView) -> NSOutlineView? {
                if let table = view as? NSOutlineView { return table }
                for child in view.subviews { if let found = findOutline(child) { return found } }
                return nil
            }
            guard let outline = findOutline(host) else { fatalError("No native outline view") }
            let row = (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? PendingNetSidebar.Node)?.section == .management }!
            guard (0..<outline.numberOfRows).allSatisfy({ !outline.isExpandable(outline.item(atRow: $0)!) }) else { fatalError("Statistics must be a static label") }
            let rect = outline.rect(ofRow: row)
            let point = outline.convert(NSPoint(x: outline.bounds.maxX - 12, y: rect.midY), to: nil)
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            app.postEvent(up, atStart: true)
            outline.mouseDown(with: down)
            guard selection.current == .management else { fatalError("Click in empty right side failed to select Manage") }
            guard rect.height == 34 else { fatalError("Unexpected sidebar row height: \(rect.height)") }
            host.display()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // Compare against the real selected pill in the same rendered
            // bitmap so display/profile conversion applies equally to both.
            let reference = bitmap.colorAt(x: 18, y: bitmap.pixelsHigh - 40)!.usingColorSpace(.sRGB)!
            let expected = (red: reference.redComponent, green: reference.greenComponent, blue: reference.blueComponent)
            guard expected.green > expected.red + 0.05 && expected.green > expected.blue + 0.02 else {
                fatalError("Pill reference pixel is not green")
            }
            var matchingPixels = 0
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: bitmap.pixelsWide - 24, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(color.redComponent - expected.red) < 0.02 &&
                   abs(color.greenComponent - expected.green) < 0.02 &&
                   abs(color.blueComponent - expected.blue) < 0.02 { matchingPixels += 1 }
            }
            print("Selection matches real TUN pill; matching pixels:", matchingPixels)
            fflush(stdout)
            guard matchingPixels >= 20 else { fatalError("Selection background does not match the pill accent color") }
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["PENDINGNET_SIDEBAR_SCREENSHOT"] ?? "/private/tmp/pn-sidebar-fixture.png"))
            print("PASS: native NSOutlineView; 34pt rows \(rect.height)pt; empty right side click selected Manage")
            fflush(stdout)
            app.terminate(nil)
        }
        app.run()
    }
}
