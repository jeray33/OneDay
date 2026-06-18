import SwiftUI
import UIKit

struct ShakeDetector: UIViewControllerRepresentable {
    var onShake: () -> Void

    func makeUIViewController(context: Context) -> ShakeViewController {
        let controller = ShakeViewController()
        controller.onShake = onShake
        return controller
    }

    func updateUIViewController(_ controller: ShakeViewController, context: Context) {
        controller.onShake = onShake
    }
}

final class ShakeViewController: UIViewController {
    var onShake: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { onShake?() }
    }
}

extension View {
    func onShake(perform action: @escaping () -> Void) -> some View {
        background(ShakeDetector(onShake: action).frame(width: 0, height: 0))
    }
}
