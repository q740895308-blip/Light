import SwiftUI
import Darwin

// Included only in the temporary simulator UI-test target.
struct MenuMaterialTestScene: UIViewRepresentable {
    final class Stripes: UIView {
        private var token: Int32 = 0
        private var blue = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = true
            isAccessibilityElement = false
            contentMode = .redraw
            notify_register_dispatch("stilltone.ui-test.blue-scene", &token, .main) { [weak self] _ in
                self?.blue = true
                self?.setNeedsDisplay()
            }
        }
        required init?(coder: NSCoder) { return nil }
        deinit { notify_cancel(token) }

        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            for x in stride(from: CGFloat.zero, to: bounds.width, by: 4) {
                let channel: CGFloat = Int(x / 4).isMultiple(of: 2) ? 1 : 0.32
                let color = UIColor(red: blue ? 0.04 : channel, green: 0.04, blue: blue ? channel : 0.04, alpha: 1)
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: x, y: 0, width: 4, height: bounds.height))
            }
        }
    }
    func makeUIView(context: Context) -> Stripes { Stripes(frame: .zero) }
    func updateUIView(_ view: Stripes, context: Context) {}
}
