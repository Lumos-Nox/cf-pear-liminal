import SwiftUI
import UIKit

@main struct ComposerChecks {
    @MainActor static func main() {
        let editor = ComposerTextView()
        let control = ComposerEditorControl()
        control.view = editor
        editor.font = .systemFont(ofSize: 17)
        let width: CGFloat = 240
        editor.frame = CGRect(x: 0, y: 0, width: width, height: 24)
        for font in [UIFont.systemFont(ofSize: 17), .preferredFont(forTextStyle: .body)] {
            editor.font = font
            for value in ["", "Write a note…", "A"] {
                editor.text = value
                editor.frame.size.height = editor.fittingHeight(for: width)
                editor.layoutIfNeeded()
                let caret = editor.caretRect(for: editor.beginningOfDocument)
                let placeholder = editor.subviews.compactMap { $0 as? UILabel }.first!
                precondition(abs(placeholder.frame.midY - editor.bounds.midY) < 0.5,
                             "Placeholder must remain centered")
                precondition(abs(caret.midY - editor.bounds.midY) < 1,
                             "Typing must keep the first line centered")
            }
        }
        editor.font = .systemFont(ofSize: 17)
        var heights: [CGFloat] = []
        for lines in 1...6 {
            editor.text = Array(repeating: "A line", count: lines).joined(separator: "\n")
            heights.append(editor.fittingHeight(for: width))
        }
        precondition(heights[1] > heights[0], "Second line must grow the editor")
        precondition(heights[2] > heights[1], "Third line must grow the editor")
        precondition(heights[3] > heights[2], "Fourth line must grow the editor")
        precondition(heights[4] == heights[3] && heights[5] == heights[3], "Height must stop at four lines")
        editor.text = String(repeating: "a long wrapped message ", count: 12)
        let wrapped = editor.fittingHeight(for: width)
        precondition(wrapped == heights[3], "Wrapped input must also grow to four lines")
        editor.text = "trailing\n"
        precondition(editor.fittingHeight(for: width) > heights[0], "Trailing newline must grow")
        editor.text = "你好 🌏 e\u{301}"
        var draft = editor.text ?? ""
        let input = ComposerTextInput(text: Binding(get: { draft }, set: { draft = $0 }), control: control)
        let delegate = input.makeCoordinator()
        editor.delegate = delegate
        precondition(control.committedText(fallback: "stale draft") == editor.text, "Send must read live editor")
        control.clear()
        draft = ""
        delegate.textViewDidChange(editor)
        precondition(draft.isEmpty, "A late editing callback must not restore submitted text")
        precondition(editor.text.isEmpty && editor.selectedRange.location == 0, "Send must clear UIKit immediately")
        precondition(editor.fittingHeight(for: width) == heights[0], "Clearing must restore single-line height")
        editor.text = "Next draft"
        delegate.textViewDidChange(editor)
        precondition(draft == "Next draft", "New input after sending must still reach the draft")
        precondition(control.committedText(fallback: "") == "Next draft", "A new draft must remain editable")
        editor.font = .systemFont(ofSize: 34)
        editor.text = "a\nb\nc\nd\ne"
        precondition(editor.fittingHeight(for: width) == ceil(editor.font!.lineHeight * 4), "Large type must keep four lines")
        // Exercise the actual width-constrained hosting/container path too.
        func composer(_ text: String) -> AnyView {
            AnyView(HStack(alignment: .bottom, spacing: 12) {
                ComposerTextInput(text: .constant(text), control: control)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .frame(minHeight: 48)
                Color.clear.frame(width: 48, height: 48)
            }.padding(.horizontal, 16).padding(.vertical, 10))
        }
        let viewport = ConversationViewportController()
        viewport.loadViewIfNeeded()
        viewport.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        func height(_ text: String) -> CGFloat {
            viewport.update(contentVersion: ["test"], latestRequest: 0,
                            transcript: { _ in AnyView(Text("A note")) },
                            composer: composer(text), onFollowChange: { _ in })
            viewport.view.layoutIfNeeded()
            return viewport.view.subviews[1].bounds.height
        }
        let oneLine = height("One")
        let twoLines = height("One\nTwo")
        let fourLines = height("One\nTwo\nThree\nFour")
        let sixLines = height("One\nTwo\nThree\nFour\nFive\nSix")
        precondition(twoLines > oneLine && fourLines > twoLines, "Hosted composer must grow at its real width")
        precondition(sixLines == fourLines, "Hosted composer must stop at four lines")
        precondition(height("") == oneLine, "Hosted composer must shrink after sending")
        let rotatingText = "A note that wraps on a narrow phone but fits on a wider screen"
        let narrowHeight = height(rotatingText)
        viewport.view.frame.size.width = 700
        let wideHeight = height(rotatingText)
        precondition(wideHeight < narrowHeight, "Width changes must remeasure wrapping")

        let safeArea = CGRect(x: 0, y: 44, width: 390, height: 766)
        for invalidGuide in [CGRect.zero, CGRect(x: 0, y: 0, width: 390, height: 844),
                             CGRect(x: 0, y: 400, width: 390, height: 0)] {
            precondition(!ConversationViewportController.keyboardGuideIsUsable(
                invalidGuide, safeArea: safeArea, composerHeight: 68),
                "A suspended or incomplete keyboard frame must use the safe bottom anchor")
        }
        for validGuide in [CGRect(x: 0, y: 810, width: 390, height: 34),
                           CGRect(x: 0, y: 500, width: 390, height: 344)] {
            precondition(ConversationViewportController.keyboardGuideIsUsable(
                validGuide, safeArea: safeArea, composerHeight: 68),
                "Valid hidden and visible keyboard guides must remain usable")
        }

        viewport.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let savedDraft = "A draft that survives backgrounding"
        let restoredHeight = height(savedDraft)
        for _ in 0..<3 {
            viewport.setScenePhase(.background)
            viewport.view.frame = .zero
            viewport.view.layoutIfNeeded()
            viewport.setScenePhase(.inactive)
            viewport.view.layoutIfNeeded()
            viewport.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            viewport.setScenePhase(.active)
            viewport.view.layoutIfNeeded()
            let composerFrame = viewport.view.subviews[1].frame
            precondition(composerFrame.height == restoredHeight, "Resume must restore the composer height")
            precondition(abs(composerFrame.maxY - viewport.view.safeAreaLayoutGuide.layoutFrame.maxY) < 1,
                         "Resume must anchor the composer at the bottom, without re-entering the chat")
            precondition(control.committedText(fallback: "") == savedDraft, "Resume must preserve the draft")
        }

        let scrollView = viewport.view.subviews[0] as! UIScrollView
        viewport.update(contentVersion: ["long transcript"], latestRequest: 1,
                        transcript: { _ in AnyView(Color.clear.frame(height: 1800)) },
                        composer: composer(savedDraft), onFollowChange: { _ in })
        viewport.view.layoutIfNeeded()
        scrollView.contentOffset.y = 350
        viewport.scrollViewDidEndDragging(scrollView, willDecelerate: false)
        viewport.setScenePhase(.background)
        viewport.view.frame = .zero
        viewport.view.layoutIfNeeded()
        viewport.setScenePhase(.inactive)
        viewport.view.layoutIfNeeded()
        viewport.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        viewport.setScenePhase(.active)
        viewport.view.layoutIfNeeded()
        precondition(abs(scrollView.contentOffset.y - 350) < 1, "Resume must preserve the older-message reading position")
        print("Hosted composer heights: \(oneLine), \(twoLines), \(fourLines), \(sixLines)")
        print("Background/resume, keyboard guide, draft and reading-position checks passed.")
        print("Composer checks passed. Line heights: \(heights), wrapped: \(wrapped)")
    }
}
