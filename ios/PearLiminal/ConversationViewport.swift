import SwiftUI
import UIKit

/// One layout owner for the keyboard, transcript and composer. The editor is a
/// sibling of the scroll view, so focusing it cannot scroll the transcript.
struct ConversationViewport<Transcript: View, Composer: View>: UIViewControllerRepresentable {
    let contentVersion: [String]
    let latestRequest: Int
    let transcript: (CGFloat) -> Transcript
    let composer: Composer
    let onFollowChange: (Bool) -> Void

    func makeUIViewController(context: Context) -> ConversationViewportController {
        ConversationViewportController()
    }

    func updateUIViewController(_ controller: ConversationViewportController, context: Context) {
        controller.update(contentVersion: contentVersion, latestRequest: latestRequest,
                          transcript: { AnyView(transcript($0)) }, composer: AnyView(composer),
                          onFollowChange: onFollowChange)
    }
}

final class ConversationViewportController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let scrollView = ConversationScrollView()
    private let transcriptHost = UIHostingController(rootView: AnyView(EmptyView()))
    private let composerHost = UIHostingController(rootView: AnyView(EmptyView()))
    private var transcript: ((CGFloat) -> AnyView)?
    private var contentVersion: [String]?
    private var latestRequest = 0
    private var measuredWidth: CGFloat = 0
    private var needsMeasurement = true
    private var onFollowChange: ((Bool) -> Void)?
    private var composerHeight: NSLayoutConstraint!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.keyboardDismissMode = .interactive
        scrollView.delegate = self
        scrollView.clipsToBounds = true
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: ConversationViewportController, _: UITraitCollection) in
            controller.needsMeasurement = true
            controller.view.setNeedsLayout()
        }
        view.addSubview(scrollView)

        for host in [transcriptHost, composerHost] {
            addChild(host)
            // The keyboard guide below is the only keyboard avoidance mechanism.
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
        }
        // Its measured content height must not autoresize with the viewport.
        transcriptHost.view.autoresizingMask = []
        scrollView.addSubview(transcriptHost.view)
        transcriptHost.didMove(toParent: self)
        view.addSubview(composerHost.view)
        composerHost.didMove(toParent: self)
        composerHost.view.translatesAutoresizingMaskIntoConstraints = false
        // Intrinsic size is measured without a useful wrapping width. Measure
        // the hosted composer explicitly at its actual width instead.
        composerHeight = composerHost.view.heightAnchor.constraint(equalToConstant: 68)

        let safeArea = view.safeAreaLayoutGuide
        view.keyboardLayoutGuide.usesBottomSafeArea = true
        NSLayoutConstraint.activate([
            composerHeight,
            scrollView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: composerHost.view.topAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            composerHost.view.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            composerHost.view.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            composerHost.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        // A short transcript has nothing to scroll or rubber-band. Still allow
        // a downward background swipe to dismiss its keyboard.
        let dismiss = UISwipeGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        dismiss.direction = .down
        dismiss.cancelsTouchesInView = false
        dismiss.delegate = self
        scrollView.addGestureRecognizer(dismiss)
    }

    func update(contentVersion: [String], latestRequest: Int, transcript: @escaping (CGFloat) -> AnyView,
                composer: AnyView, onFollowChange: @escaping (Bool) -> Void) {
        loadViewIfNeeded()
        self.onFollowChange = onFollowChange
        // Draft changes update only the composer. Do not remeasure or replace
        // the transcript on each keystroke.
        if self.contentVersion != contentVersion {
            self.contentVersion = contentVersion
            self.transcript = transcript
            needsMeasurement = true
        }
        composerHost.rootView = composer
        if self.latestRequest != latestRequest {
            self.latestRequest = latestRequest
            scrollView.scrollState.followLatest()
            scrollView.needsBottomAlignment = true
        }
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let composerWidth = composerHost.view.bounds.width
        if composerWidth > 0 {
            let size = composerHost.sizeThatFits(in: CGSize(width: composerWidth, height: .greatestFiniteMagnitude))
            let height = ceil(size.height)
            if height.isFinite, height > 0, composerHeight.constant != height {
                composerHeight.constant = height
                // Resize the transcript with the composer, through the same
                // bounds/offset path already used for keyboard movement.
                view.layoutIfNeeded()
            }
        }
        let width = scrollView.bounds.width
        guard width > 0, let transcript else { return }
        if needsMeasurement || measuredWidth != width {
            needsMeasurement = false
            measuredWidth = width
            transcriptHost.rootView = transcript(width)
            let size = transcriptHost.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            let height = ceil(size.height)
            scrollView.applyContentSize(CGSize(width: width, height: height)) {
                transcriptHost.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
            }
        }
        scrollView.layoutIfNeeded()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { observeUserScroll() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        observeUserScroll(ending: true)
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { observeUserScroll(ending: true) }

    private func observeUserScroll(ending: Bool = false) {
        guard !scrollView.isApplyingLayout,
              ending || scrollView.isDragging || scrollView.isDecelerating else { return }
        let previous = scrollView.scrollState.followsLatest
        scrollView.scrollState.observeScroll(isNearBottom: ConversationScrollState.isNearBottom(
            contentHeight: scrollView.contentSize.height, topInset: scrollView.contentInset.top,
            bottomInset: 0, viewportHeight: scrollView.bounds.height, offset: scrollView.contentOffset.y
        ), userInitiated: true)
        if previous != scrollView.scrollState.followsLatest {
            onFollowChange?(scrollView.scrollState.followsLatest)
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        scrollView.contentSize.height <= scrollView.bounds.height
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    @objc private func dismissKeyboard() { view.endEditing(true) }
}

private final class ConversationScrollView: UIScrollView {
    var scrollState = ConversationScrollState()
    private(set) var isApplyingLayout = false
    var needsBottomAlignment = true

    override var bounds: CGRect {
        get { super.bounds }
        set {
            guard newValue.height != super.bounds.height else { super.bounds = newValue; return }
            // Change viewport size and offset together, within the keyboard's
            // own animation transaction. No notification, delay or scrollTo.
            let wasApplyingLayout = isApplyingLayout
            isApplyingLayout = true
            defer { isApplyingLayout = wasApplyingLayout }
            var adjusted = newValue
            adjusted.origin.y = ConversationScrollState.offsetAfterResize(
                contentHeight: contentSize.height, viewportHeight: newValue.height,
                offset: super.bounds.minY, followsLatest: scrollState.followsLatest)
            super.bounds = adjusted
            needsBottomAlignment = true
        }
    }

    func applyContentSize(_ size: CGSize, layout: () -> Void) {
        let wasApplyingLayout = isApplyingLayout
        isApplyingLayout = true
        defer { isApplyingLayout = wasApplyingLayout }
        layout()
        contentSize = size
        needsBottomAlignment = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        let wasApplyingLayout = isApplyingLayout
        isApplyingLayout = true
        defer { isApplyingLayout = wasApplyingLayout }
        super.layoutSubviews()
        let top = ConversationScrollState.topInset(contentHeight: contentSize.height, viewportHeight: bounds.height)
        if contentInset.top != top { contentInset = UIEdgeInsets(top: top, left: 0, bottom: 0, right: 0) }
        bounces = contentSize.height > bounds.height
        if needsBottomAlignment {
            needsBottomAlignment = false
            let offset = ConversationScrollState.offsetAfterResize(
                contentHeight: contentSize.height, viewportHeight: bounds.height,
                offset: contentOffset.y, followsLatest: scrollState.followsLatest)
            if contentOffset.y != offset { contentOffset.y = offset }
        }
    }
}
