import Foundation

/// Geometry shared by the native viewport and its regression tests.
struct ConversationScrollState {
    private(set) var followsLatest = true

    mutating func observeScroll(isNearBottom: Bool, userInitiated: Bool) {
        guard userInitiated else { return }
        followsLatest = isNearBottom
    }

    mutating func followLatest() { followsLatest = true }

    static func topInset(contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        max(0, viewportHeight - contentHeight)
    }

    static func bottomOffset(contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        contentHeight - viewportHeight
    }

    static func offsetAfterResize(contentHeight: CGFloat, viewportHeight: CGFloat,
                                  offset: CGFloat, followsLatest: Bool) -> CGFloat {
        let bottom = bottomOffset(contentHeight: contentHeight, viewportHeight: viewportHeight)
        let top = -topInset(contentHeight: contentHeight, viewportHeight: viewportHeight)
        return followsLatest ? bottom : min(bottom, max(top, offset))
    }

    static func isNearBottom(contentHeight: CGFloat, topInset: CGFloat, bottomInset: CGFloat,
                             viewportHeight: CGFloat, offset: CGFloat) -> Bool {
        // Short threads remain attached to the composer even during overscroll.
        let contentFits = contentHeight + topInset + bottomInset <= viewportHeight + 1
        let distance = contentHeight + bottomInset - offset - viewportHeight
        return contentFits || distance <= 90
    }
}
