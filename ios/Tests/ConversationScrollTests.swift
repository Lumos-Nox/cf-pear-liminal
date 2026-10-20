import XCTest
@testable import PearLiminalCore

final class ConversationScrollTests: XCTestCase {
    // The same geometry functions run inside the native scroll view's bounds
    // setter, not in a delayed keyboard notification handler.
    func testShortTranscriptStaysAboveComposerAcrossKeyboardAndTypingResizes() {
        let contentHeight: CGFloat = 180
        for viewportHeight: CGFloat in [720, 400, 380, 340, 720, 400, 380] {
            let offset = ConversationScrollState.offsetAfterResize(
                contentHeight: contentHeight, viewportHeight: viewportHeight,
                offset: -540, followsLatest: true)
            XCTAssertEqual(contentHeight - offset, viewportHeight)
            XCTAssertEqual(offset, -ConversationScrollState.topInset(
                contentHeight: contentHeight, viewportHeight: viewportHeight))
        }
    }

    func testLongTranscriptBottomMovesByTheKeyboardHeightWithinResize() {
        let before = ConversationScrollState.bottomOffset(contentHeight: 1600, viewportHeight: 720)
        let after = ConversationScrollState.offsetAfterResize(
            contentHeight: 1600, viewportHeight: 400, offset: before, followsLatest: true)
        XCTAssertEqual(after - before, 320)
        XCTAssertEqual(1600 - after, 400)
    }

    func testGrowingAndClearingMultilineComposerKeepsLastNoteVisible() {
        var offset: CGFloat = 880
        for viewport: CGFloat in [400, 380, 360, 340, 320, 400] {
            offset = ConversationScrollState.offsetAfterResize(
                contentHeight: 1600, viewportHeight: viewport, offset: offset, followsLatest: true)
            XCTAssertEqual(1600 - offset, viewport)
        }
    }

    func testReadingOlderMessagesPreservesPositionWhenKeyboardOpens() {
        XCTAssertEqual(ConversationScrollState.offsetAfterResize(
            contentHeight: 1600, viewportHeight: 400, offset: 350, followsLatest: false), 350)
    }

    func testContentRemovalAndViewportGrowthClampToValidRange() {
        XCTAssertEqual(ConversationScrollState.offsetAfterResize(
            contentHeight: 180, viewportHeight: 720, offset: 350, followsLatest: false), -540)
        XCTAssertEqual(ConversationScrollState.offsetAfterResize(
            contentHeight: 1600, viewportHeight: 720, offset: -300, followsLatest: false), 0)
        XCTAssertEqual(ConversationScrollState.offsetAfterResize(
            contentHeight: 1600, viewportHeight: 720, offset: 1500, followsLatest: false), 880)
    }

    func testPassiveLayoutNeverChangesReaderIntent() {
        var state = ConversationScrollState()
        state.observeScroll(isNearBottom: false, userInitiated: false)
        XCTAssertTrue(state.followsLatest)
        state.observeScroll(isNearBottom: false, userInitiated: true)
        state.observeScroll(isNearBottom: true, userInitiated: false)
        XCTAssertFalse(state.followsLatest)
        state.followLatest()
        XCTAssertTrue(state.followsLatest)
    }

    func testShortThreadCannotLoseBottomAttachmentThroughBackgroundSwipe() {
        XCTAssertTrue(ConversationScrollState.isNearBottom(
            contentHeight: 180, topInset: 220, bottomInset: 0, viewportHeight: 400, offset: -300))
    }
}
