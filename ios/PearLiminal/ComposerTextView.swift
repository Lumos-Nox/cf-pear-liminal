import SwiftUI
import UIKit

/// Gives Send synchronous access to the current edit, including marked input.
/// Clearing UIKit as well as the binding prevents an editing callback from
/// restoring the submitted text before SwiftUI next updates the hosted view.
@MainActor final class ComposerEditorControl {
    weak var view: ComposerTextView?

    func committedText(fallback: String) -> String {
        guard let view else { return fallback }
        view.unmarkText()
        return view.text ?? ""
    }

    func clear() {
        guard let view else { return }
        view.text = ""
        view.selectedRange = NSRange(location: 0, length: 0)
        view.undoManager?.removeAllActions()
        view.setContentOffset(.zero, animated: false)
        view.invalidateIntrinsicContentSize()
    }
}

struct ComposerTextInput: UIViewRepresentable {
    @Binding var text: String
    let control: ComposerEditorControl

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerTextView {
        let view = ComposerTextView()
        view.delegate = context.coordinator
        view.text = text
        control.view = view
        return view
    }

    func updateUIView(_ view: ComposerTextView, context: Context) {
        context.coordinator.parent = self
        control.view = view
        // Never replace an in-progress IME composition on an unrelated redraw.
        if view.text != text, view.markedTextRange == nil {
            view.text = text
        }
        view.font = .preferredFont(forTextStyle: .body)
        view.updatePlaceholder()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        return CGSize(width: width, height: uiView.fittingHeight(for: width))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextInput
        init(_ parent: ComposerTextInput) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text ?? ""
            (textView as? ComposerTextView)?.updatePlaceholder()
            textView.invalidateIntrinsicContentSize()
        }
    }
}

final class ComposerTextView: UITextView {
    private let placeholder = UILabel()

    init() {
        // Use a stable TextKit layout for both wrapping and height measurement.
        super.init(frame: .zero, textContainer: nil)
        backgroundColor = .clear
        font = .preferredFont(forTextStyle: .body)
        textColor = .label
        tintColor = .tintColor
        adjustsFontForContentSizeCategory = true
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        contentInset = .zero
        contentInsetAdjustmentBehavior = .never
        isScrollEnabled = true
        bounces = false
        showsVerticalScrollIndicator = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        accessibilityLabel = "Message"

        placeholder.text = "Write a note…"
        placeholder.textColor = .placeholderText
        placeholder.isUserInteractionEnabled = false
        placeholder.isAccessibilityElement = false
        addSubview(placeholder)
        updatePlaceholder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func fittingHeight(for width: CGFloat) -> CGFloat {
        updateTextInsets(for: width)
        let lineHeight = font?.lineHeight ?? 20.5
        let naturalHeight = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let maximumHeight = lineHeight * 4 + textContainerInset.top + textContainerInset.bottom
        return ceil(min(max(24, naturalHeight), max(24, maximumHeight)))
    }

    func updatePlaceholder() {
        updateTextInsets()
        placeholder.isHidden = !(text ?? "").isEmpty
        placeholder.font = font
        setNeedsLayout()
    }

    override var text: String! {
        didSet { updatePlaceholder() }
    }

    override func layoutSubviews() {
        updateTextInsets()
        super.layoutSubviews()
        let placeholderHeight = font?.lineHeight ?? 20.5
        placeholder.frame = CGRect(x: 0, y: max(0, (bounds.height - placeholderHeight) / 2),
                                   width: bounds.width, height: placeholderHeight)
        // At four lines UITextView keeps the caret visible by scrolling inside
        // the capsule; the conversation's keyboard layout remains independent.
    }

    private func updateTextInsets(for width: CGFloat? = nil) {
        let width = width ?? bounds.width
        guard width > 0, width.isFinite else { return }
        // UIKit rounds its line box differently from UILabel's font metrics.
        // Center the actual text layout inside the 24-point minimum, rather
        // than padding only the placeholder or adding height to the capsule.
        let fitted = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let textHeight = ceil(fitted - textContainerInset.top - textContainerInset.bottom)
        let padding = max(0, (24 - textHeight) / 2)
        let insets = UIEdgeInsets(top: padding, left: 0, bottom: padding, right: 0)
        if textContainerInset != insets { textContainerInset = insets }
    }
}
