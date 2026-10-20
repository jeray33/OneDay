import UIKit

/// Top safe-area inset of the active window. Needed because the paged stack
/// draws full-bleed (ignoring safe area), so chrome must re-apply the inset.
@MainActor
func topSafeAreaInset() -> CGFloat {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }?
        .safeAreaInsets.top ?? 0
}

/// Bottom safe-area inset of the active window. Used so full-bleed chrome
/// (e.g. the preview's bottom controls) does not sit under the home indicator.
@MainActor
func bottomSafeAreaInset() -> CGFloat {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }?
        .safeAreaInsets.bottom ?? 0
}
