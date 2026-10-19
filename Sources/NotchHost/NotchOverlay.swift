import AppKit
import SwiftUI

/// One host owns geometry, painting and hit surface. Extensions supply only data.
@MainActor
final class NotchOverlay {
    private var panels: [NSPanel] = []
    private var content: (String, String, Double)?
    private var observer: NSObjectProtocol?
    init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let value = self.content else { return }
                self.show(title: value.0, subtitle: value.1, progress: value.2)
            }
        }
    }
    func show(title: String, subtitle: String, progress: Double) {
        hide(); content = (title, subtitle, progress)
        // Public APIs describe camera exclusion bounds, not the exact hardware curve.
        let targets = NSScreen.screens.filter { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil }
        for screen in targets {
            guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { continue }
            let notchWidth = right.minX - left.maxX
            guard notchWidth > 0 else { continue }
            let width = max(320, notchWidth + 40), height: CGFloat = screen.safeAreaInsets.top + 70
            let center = (left.maxX + right.minX) / 2
            let frame = NSRect(x: center-width/2, y: screen.frame.maxY-height, width: width, height: height)
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.level = .statusBar; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: OverlayContent(title: title, subtitle: subtitle, progress: progress, topInset: screen.safeAreaInsets.top))
            panel.orderFrontRegardless(); panels.append(panel)
        }
        // No automatic fake notch on external/no-notch displays.
    }
    func hide() { for panel in panels { panel.orderOut(nil); panel.close() }; panels.removeAll(); content = nil }
}
struct OpenContour: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(24, rect.height/2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX,y: rect.maxY-radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX+radius,y: rect.maxY), control: CGPoint(x: rect.minX,y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX-radius,y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX,y: rect.maxY-radius), control: CGPoint(x: rect.maxX,y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX,y: rect.minY))
        return path
    }
}
struct OverlayContent: View {
    let title: String
    let subtitle: String
    let progress: Double
    let topInset: CGFloat
    var body: some View {
        VStack(spacing: 5) {
            Color.clear.frame(height: topInset)
            Text(title).font(.headline).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16).foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black, in: UnevenBottomShape())
        .overlay(OpenContour().trim(from: 0, to: min(1,max(0,progress.isFinite ? progress : 0)))
            .stroke(.mint, style: StrokeStyle(lineWidth: 2, lineCap: .round)).padding(1))
        .accessibilityElement(children: .combine)
    }
}
struct UnevenBottomShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = OpenContour().path(in: rect);p.closeSubpath();return p
    }
}
