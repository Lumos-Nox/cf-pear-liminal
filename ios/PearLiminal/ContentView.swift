import SwiftUI

private enum PearTheme {
    static let ink = Color(red: 0.09, green: 0.28, blue: 0.24)
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.66, green: 0.85, blue: 0.60, alpha: 1)
            : UIColor(red: 0.09, green: 0.28, blue: 0.24, alpha: 1)
    })
    static let canvas = Color(uiColor: .systemGroupedBackground)
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAdmin = false

    var body: some View {
        TabView {
            MailboxView()
                .tabItem { Label("Mailbox", systemImage: "bubble.left.and.bubble.right") }
            SettingsView(showAdmin: $showAdmin)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(PearTheme.accent)
        .alert("Pear Liminal", isPresented: Binding(
            get: { model.errorMessage != nil && !showAdmin },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("OK", role: .cancel) { model.clearError() }
        } message: { Text(model.errorMessage ?? "Please try again.") }
        .sheet(isPresented: $showAdmin, onDismiss: { model.lockAdmin() }) { AdminView() }
        .overlay {
            if scenePhase == .background {
                PearTheme.canvas.ignoresSafeArea()
                    .overlay { Label("Pear Liminal", systemImage: "lock.shield").font(.title2) }
            }
        }
    }
}

private struct PearAvatar: View {
    let name: String
    var size: CGFloat = 48

    var body: some View {
        Text(String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased())
            .font(.system(size: size * 0.42, weight: .medium, design: .serif))
            .foregroundStyle(PearTheme.accent)
            .frame(width: size, height: size)
            .background(PearTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: size * 0.34))
            .accessibilityHidden(true)
    }
}

private struct MailboxSummaryCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var copyFeedbackID: UUID?
    let mailbox: SelfMailbox

    private var conversationCount: Int {
        Set(model.conversations.keys)
            .union(model.history.pending.map(\.peerID))
            .union(model.history.drafts.keys).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                PearAvatar(name: mailbox.label.isEmpty ? "?" : mailbox.label, size: 52)
                VStack(alignment: .leading, spacing: 5) {
                    Text(mailbox.label.isEmpty ? "Your mailbox" : mailbox.label)
                        .font(.title3.weight(.semibold))
                    Button {
                        UIPasteboard.general.string = mailbox.mid
                        copyFeedbackID = UUID()
                    } label: {
                        Label(copyFeedbackID == nil ? mailbox.mid.shortMID : "Copied",
                              systemImage: copyFeedbackID == nil ? "doc.on.doc" : "checkmark")
                            .font(.caption.monospaced())
                            .foregroundStyle(copyFeedbackID == nil ? Color.secondary : PearTheme.accent)
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy full mailbox ID")
                    .accessibilityValue(copyFeedbackID == nil ? mailbox.mid : "Copied")
                    if mailbox.createdAt > 0 {
                        Text("Created \(Date(timeIntervalSince1970: Double(mailbox.createdAt) / 1000).formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .contain)

            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 14) { metrics }
            } else {
                HStack(alignment: .top, spacing: 16) { metrics }
            }

            if !mailbox.capabilities.isEmpty {
                Label(mailbox.capabilities.joined(separator: ", "), systemImage: "tag")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Capabilities: \(mailbox.capabilities.joined(separator: ", "))")
            }
        }
        .padding(.vertical, 8)
        .onChange(of: mailbox.mid) { _, _ in copyFeedbackID = nil }
        .task(id: copyFeedbackID) {
            guard copyFeedbackID != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            copyFeedbackID = nil
        }
    }

    @ViewBuilder private var metrics: some View {
        metric("Conversations", value: conversationCount)
        metric("Local notes", value: model.conversations.values.reduce(0) { $0 + $1.count } + model.history.pending.count)
        metric("Unread", value: model.history.unread.values.reduce(0, +))
    }

    private func metric(_ title: String, value: Int) -> some View {
        VStack(alignment: .center, spacing: 4) {
            Text(value.formatted()).font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }
}

private struct ConnectionNotice: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "wifi.exclamationmark")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
    }
}

/// Shared dimensions keep inputs and mailbox actions equal at every text size.
private struct FormRowContent: ViewModifier {
    var leadingInset: CGFloat = 16
    var trailingInset: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 60

    func body(content: Content) -> some View {
        content
            .font(.body)
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: max(60, rowHeight))
            .contentShape(Rectangle())
    }
}

/// Keep single-line form inputs stable on focus, with a hit target covering
/// the complete row rather than just the text's intrinsic bounds.
private struct FormInputRow: ViewModifier {
    var focus: FocusState<Bool>.Binding? = nil
    @FocusState private var isFocused: Bool

    private var fieldFocus: FocusState<Bool>.Binding { focus ?? $isFocused }

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused(fieldFocus)
            .modifier(FormRowContent(leadingInset: 20))
            .simultaneousGesture(TapGesture().onEnded { fieldFocus.wrappedValue = true })
            .listRowInsets(EdgeInsets())
    }
}

private struct CapsuleFieldSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.2 : 0.05), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

/// Keep authentication forms top aligned and scrollable for the keyboard
/// and larger text sizes.
private struct AuthenticationLayout<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) { content }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(PearTheme.canvas)
    }
}

private struct PasswordActionRow: View {
    let title: String
    @Binding var text: String
    let actionLabel: String
    let isEnabled: Bool
    let isBusy: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool
    @ScaledMetric(relativeTo: .body) private var buttonSize: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var buttonInset: CGFloat = 8

    private var canSubmit: Bool { isEnabled && !isBusy }

    var body: some View {
        HStack(spacing: 0) {
            SecureField(title, text: $text, prompt: Text(title).foregroundStyle(.secondary))
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .focused($isFocused)
                .padding(.leading, 20)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { isFocused = true })
            Button(action: submit) {
                Group {
                    if isBusy {
                        ProgressView().tint(Color(uiColor: .systemBackground))
                    } else {
                        Image(systemName: "arrow.right")
                            .font(.body.weight(.semibold))
                    }
                }
                .foregroundStyle(canSubmit || isBusy ? Color(uiColor: .systemBackground) : PearTheme.accent.opacity(0.65))
                .frame(width: max(44, buttonSize) * 1.25, height: max(44, buttonSize))
                .background(canSubmit || isBusy ? PearTheme.accent : PearTheme.accent.opacity(0.1), in: Capsule(style: .continuous))
                .padding(.trailing, max(8, buttonInset))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .accessibilityLabel(actionLabel)
            .accessibilityValue(isBusy ? "In progress" : "")
        }
        .modifier(FormRowContent(leadingInset: 0, trailingInset: 0))
        .modifier(CapsuleFieldSurface())
        .listRowInsets(EdgeInsets())
    }

    private func submit() {
        guard canSubmit else { return }
        isFocused = false
        action()
    }
}

struct MailboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasStarted = false
    @State private var reconnecting = false
    @State private var label = ""
    @State private var joinSecret = ""
    @State private var token = ""
    @State private var search = ""
    @State private var confirmDelete = false

    private var visiblePeers: [Peer] {
        var peers = model.peers
        let known = Set(peers.map(\.mid))
        let localPeers = Set(model.conversations.keys).union(model.history.pending.map(\.peerID)).union(model.history.drafts.keys)
        for mid in localPeers where !known.contains(mid) {
            peers.append(Peer(mid: mid, label: "", joinedAt: 0, capabilities: nil))
        }
        return peers.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) || $0.mid.localizedCaseInsensitiveContains(search) }
            .sorted {
                let left = max(model.conversations[$0.mid]?.last?.timestamp ?? 0, model.pendingMessages(for: $0.mid).last?.timestamp ?? 0)
                let right = max(model.conversations[$1.mid]?.last?.timestamp ?? 0, model.pendingMessages(for: $1.mid).last?.timestamp ?? 0)
                if left != right { return left > right }
                let comparison = $0.label.localizedStandardCompare($1.label)
                return comparison == .orderedSame ? $0.mid < $1.mid : comparison == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let mailbox = model.mailbox { mailboxHome(mailbox) }
                else if model.isRestoring { ProgressView("Opening your mailbox…") }
                else if hasStarted || model.mailboxConnectionWarning != nil { connectForm }
                else { welcomePanel }
            }
            .navigationTitle(model.mailbox == nil ? "Pear Liminal" : "Mailbox")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if model.mailbox != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Sign out on this iPhone", systemImage: "rectangle.portrait.and.arrow.right") { model.signOut() }
                            Button("Delete mailbox…", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Mailbox actions")
                        .disabled(model.isWorking)
                    }
                }
            }
            .confirmationDialog("Permanently delete this mailbox and erase its inbox?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete mailbox", role: .destructive) { Task { await model.deleteMailbox() } }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { joinSecret = ""; token = "" }
            }
        }
    }

    private var welcomePanel: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(PearTheme.accent)
                    .frame(width: 80, height: 80)
                    .background(PearTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 28))
                VStack(spacing: 16) {
                    Text("Meaning has\nits own pace.")
                        .font(.system(.largeTitle, design: .serif))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Send a note. Let time make room for its answer.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button { hasStarted = true } label: {
                    Label("Create a mailbox", systemImage: "arrow.up.right")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(PearTheme.ink)
                .controlSize(.large)
                Button("I already have a token") { reconnecting = true; hasStarted = true }
                    .frame(minHeight: 44)
                Label("Your token stays in Keychain", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 380)
            .padding(28)
            .padding(.top, 36)
            .frame(maxWidth: .infinity)
        }
        .background(PearTheme.canvas)
    }

    private var connectForm: some View {
        AuthenticationLayout {
            if let warning = model.mailboxConnectionWarning {
                VStack(alignment: .leading, spacing: 12) {
                    ConnectionNotice(text: warning)
                    Button("Retry saved mailbox") { Task { await model.restoreSession() } }
                        .buttonStyle(.bordered)
                        .disabled(model.isWorking || model.isRestoring)
                }
            }
            Picker("Connection", selection: $reconnecting) {
                Text("Create new").tag(false)
                Text("Reconnect").tag(true)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 20) {
                Text(reconnecting ? "Welcome back" : "Your quiet corner")
                    .font(.system(.title, design: .serif))
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 12) {
                    if reconnecting {
                        PasswordActionRow(title: "Mailbox bearer token", text: $token,
                                          actionLabel: "Open mailbox",
                                          isEnabled: !model.isRestoring && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                          isBusy: model.isWorking, action: connectMailbox)
                    } else {
                        TextField("Your name", text: $label,
                                  prompt: Text("Your name").foregroundStyle(.secondary))
                            .textContentType(.nickname)
                            .modifier(FormInputRow())
                            .modifier(CapsuleFieldSurface())
                        PasswordActionRow(title: "Join secret", text: $joinSecret,
                                          actionLabel: "Create mailbox",
                                          isEnabled: !model.isRestoring && !joinSecret.isEmpty,
                                          isBusy: model.isWorking, action: connectMailbox)
                    }
                }
                Text(reconnecting ? "Your mailbox token is saved in Keychain for this server." : "The join secret is used to create your mailbox and is never saved.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Server").font(.caption.weight(.medium))
                Text(model.apiBaseURLText).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    private func connectMailbox() {
        Task {
            if reconnecting { await model.reconnect(token: token) }
            else { await model.createMailbox(label: label, joinSecret: joinSecret) }
            if model.mailbox != nil { token = ""; joinSecret = "" }
        }
    }

    private func mailboxHome(_ mailbox: SelfMailbox) -> some View {
        let peers = visiblePeers
        return List {
            Section {
                MailboxSummaryCard(mailbox: mailbox)
                    .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            }
            if let warning = model.mailboxConnectionWarning {
                Section { ConnectionNotice(text: warning) }
            }
            if peers.isEmpty {
                Section {
                    ContentUnavailableView(search.isEmpty ? "A little quiet here" : "No matching Pears", systemImage: search.isEmpty ? "person.2" : "magnifyingglass", description: Text(search.isEmpty ? "New mailboxes appear automatically. Pull down to refresh." : "Try another name or mailbox ID."))
                        .listRowBackground(Color.clear)
                } header: {
                    conversationsHeader(count: 0)
                } footer: {
                    conversationsFooter
                }
            } else {
                ForEach(peers) { peer in
                    // A single-row section has four rounded corners before
                    // swiping; UIKit need not morph grouped edge-row corners.
                    Section {
                        NavigationLink { ChatView(peer: peer) } label: { peerRow(peer) }
                            .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    model.deleteConversation(peer.mid)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .disabled(!model.canDeleteConversation(peer.mid))
                            }
                    } header: {
                        if peer.mid == peers.first?.mid { conversationsHeader(count: peers.count) }
                    } footer: {
                        if peer.mid == peers.last?.mid { conversationsFooter }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(10)
        .searchable(text: $search, prompt: "Find a Pear")
        .refreshable { await model.refreshPeers(); await model.refreshInbox() }
    }

    private func conversationsHeader(count: Int) -> some View {
        HStack {
            Text("Conversations")
            Spacer()
            if model.isRefreshingPeers { ProgressView().controlSize(.mini) }
            else { Text(count.formatted()).monospacedDigit() }
        }
    }

    private var conversationsFooter: some View {
        Text("Messages stay on the service for 7 days. The latest 500 notes per conversation are kept on this iPhone.")
    }

    private func peerRow(_ peer: Peer) -> some View {
        let last = model.conversations[peer.mid]?.last
        let pending = model.pendingMessages(for: peer.mid).last
        let deliveryUnconfirmed = pending.map { model.unconfirmedIDs.contains($0.id) } ?? false
        let unread = model.history.unread[peer.mid] ?? 0
        let draft = model.draft(for: peer.mid)
        return HStack(alignment: .center, spacing: 13) {
            PearAvatar(name: peer.label.isEmpty ? "?" : peer.label)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(peer.label.isEmpty ? peer.mid.shortMID : peer.label)
                        .font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    if let last {
                        Text(Date(timeIntervalSince1970: Double(last.timestamp) / 1000), style: .time)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .top) {
                    Text(deliveryUnconfirmed ? "Delivery unconfirmed · Tap to retry" : pending.map { "You: " + $0.payload.text } ?? (!draft.isEmpty ? "Draft: \(draft)" : last.map { ($0.from == model.mailbox?.mid ? "You: " : "") + $0.text } ?? "Send the first note"))
                        .font(.subheadline)
                        .foregroundStyle(deliveryUnconfirmed ? Color.orange : Color.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    // Reserve the largest badge's footprint even when read,
                    // so unread changes cannot alter preview wrapping or height.
                    ZStack {
                        Text("99+").hidden()
                        Text(unread > 99 ? "99+" : "\(unread)")
                    }
                    .font(.caption2.bold()).monospacedDigit()
                    .fixedSize()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(PearTheme.ink, in: Capsule())
                    .opacity(unread > 0 ? 1 : 0)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(unread) unread messages")
                    .accessibilityHidden(unread == 0)
                }
                if !peer.label.isEmpty { Text(peer.mid.shortMID).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct TranscriptEntry: Identifiable {
    let message: ChatMessage
    var pending: PendingMessage? = nil

    var id: String { message.presentationID }
}

struct ChatView: View {
    @Environment(AppModel.self) private var model
    let peer: Peer
    @State private var draft = ""
    @State private var followsLatest = true
    @State private var latestRequest = 0
    @State private var hasNewMessages = false
    @State private var composerEditor = ComposerEditorControl()

    private var messages: [ChatMessage] { model.conversations[peer.mid] ?? [] }
    private var pending: [PendingMessage] { model.pendingMessages(for: peer.mid) }

    var body: some View {
        ConversationViewport(contentVersion: contentVersion, latestRequest: latestRequest,
                             transcript: { width in
                                 transcript(width: width).environment(model)
                             }, composer: composer.environment(model)) { following in
            followsLatest = following
            if following { hasNewMessages = false }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onChange(of: messages.last?.id) { _, _ in
            if !followsLatest && messages.last?.from != model.mailbox?.mid { hasNewMessages = true }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(peer.label.isEmpty ? peer.mid.shortMID : peer.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await model.refreshInbox() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh messages")
            }
        }
        .onAppear { draft = model.draft(for: peer.mid); model.enterConversation(peer.mid) }
        .onDisappear { model.updateDraft(draft, for: peer.mid); model.leaveConversation(peer.mid) }
        .onChange(of: draft) { _, text in model.updateDraft(text, for: peer.mid) }
    }

    private var transcriptEntries: [TranscriptEntry] {
        messages.map { TranscriptEntry(message: $0) } + pending.map { item in
            TranscriptEntry(message: ChatMessage(
                id: item.id, from: model.mailbox?.mid ?? "", text: item.payload.text,
                timestamp: item.timestamp, type: item.payload.type, clientID: item.id
            ), pending: item)
        }
    }

    // Keep rows stable across acknowledgement. Draft edits do not invalidate layout.
    private var contentVersion: [String] {
        [model.mailboxConnectionWarning ?? "", peer.mid, peer.label]
            + transcriptEntries.map { entry in
                entry.id + (entry.pending == nil ? ":sent" : model.unconfirmedIDs.contains(entry.id) ? ":retry" : ":pending")
            }
    }

    private func transcript(width: CGFloat) -> some View {
        let entries = transcriptEntries
        return VStack(spacing: 4) {
            if let warning = model.mailboxConnectionWarning { ConnectionNotice(text: warning) }
            if entries.isEmpty {
                VStack(spacing: 12) {
                    PearAvatar(name: peer.label.isEmpty ? "?" : peer.label, size: 64)
                    Text("Every conversation\nstarts with a note.")
                        .font(.system(.title2, design: .serif)).multilineTextAlignment(.center)
                    Text("Say hello when you’re ready.").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 48)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                VStack(spacing: 4) {
                    if showsTimestamp(at: index, in: entries) {
                        Text(Date(timeIntervalSince1970: Double(entry.message.timestamp) / 1000).formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 20).padding(.bottom, 8)
                    }
                    MessageBubble(message: entry.message,
                                  isMine: entry.pending != nil || entry.message.from == model.mailbox?.mid,
                                  maxWidth: min(width * 0.82, 560), isPending: entry.pending != nil)
                        .padding(.top, index > 0 && entries[index - 1].message.from == entry.message.from ? 0 : 10)
                    if let item = entry.pending, model.unconfirmedIDs.contains(item.id) {
                        Button { Task { await model.retryMessage(item) } } label: {
                            Label("Delivery unconfirmed · Retry", systemImage: "arrow.clockwise")
                                .font(.caption.weight(.medium)).frame(minHeight: 44)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
        .frame(maxWidth: 760).frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func showsTimestamp(at index: Int, in entries: [TranscriptEntry]) -> Bool {
        guard index > 0 else { return true }
        let previous = Date(timeIntervalSince1970: Double(entries[index - 1].message.timestamp) / 1000)
        let current = Date(timeIntervalSince1970: Double(entries[index].message.timestamp) / 1000)
        return current.timeIntervalSince(previous) > 300 || !Calendar.current.isDate(previous, inSameDayAs: current)
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if hasNewMessages {
                Button {
                    followsLatest = true
                    latestRequest &+= 1
                    hasNewMessages = false
                } label: {
                    Label("New messages", systemImage: "arrow.down").font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderedProminent).clipShape(Capsule()).padding(.top, 8)
            }
            composerSurface
                .frame(maxWidth: 728)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var composerSurface: some View {
        if #available(iOS 26.0, *) {
            // Keep the capsule and circle distinct while sharing the glass renderer.
            GlassEffectContainer(spacing: 8) { composerControls }
        } else {
            composerControls
        }
    }

    private var composerControls: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ComposerTextInput(text: $draft, control: composerEditor)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(minHeight: 48)
                .modifier(ComposerFieldGlass())
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { composerEditor.view?.becomeFirstResponder() })
                .accessibilityLabel("Message")
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(canSend ? Color.white : Color.secondary)
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .modifier(ComposerSendGlass(isEnabled: canSend))
            .disabled(!canSend)
            .accessibilityLabel("Send message")
        }
    }

    private var canSend: Bool { pending.isEmpty && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func send() {
        guard canSend else { return }
        let text = composerEditor.committedText(fallback: draft)
        guard let pending = model.queueMessage(text, to: peer.mid) else { return }
        composerEditor.clear()
        draft = ""
        model.updateDraft("", for: peer.mid)
        followsLatest = true
        latestRequest &+= 1
        hasNewMessages = false
        Task { await model.retryMessage(pending) }
    }
}

private struct ComposerFieldHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 48
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ComposerFieldGlass: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = 20.5
    @State private var fieldHeight: CGFloat = 48

    private var cornerRadius: CGFloat {
        let singleLineHeight = max(48, lineHeight + 24)
        let additionalLines = max(0, (fieldHeight - singleLineHeight) / lineHeight)
        return max(16, singleLineHeight / 2 - additionalLines * 4)
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular.interactive(), in: shape)
            } else {
                content.background(.ultraThinMaterial, in: shape)
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: ComposerFieldHeightKey.self, value: geometry.size.height)
            }
        }
        .onPreferenceChange(ComposerFieldHeightKey.self) { height in fieldHeight = height }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: cornerRadius)
    }
}

private struct ComposerSendGlass: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(isEnabled ? PearTheme.ink : nil).interactive(), in: .circle)
        } else {
            content.background(isEnabled ? AnyShapeStyle(PearTheme.ink) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
        }
    }
}

private struct MessageBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: ChatMessage
    let isMine: Bool
    let maxWidth: CGFloat
    var isPending = false

    private var bubbleColor: Color {
        if isPending { return PearTheme.accent.opacity(0.08) }
        return isMine ? PearTheme.ink : Color(uiColor: .secondarySystemBackground)
    }

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 6) {
            if message.type != "msg" {
                Text(message.type.capitalized).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(message.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .foregroundStyle(isMine && !isPending ? Color.white : Color.primary)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 19))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isPending)
                .contentShape(.interaction, RoundedRectangle(cornerRadius: 19))
                .overlay {
                    MessageActionOverlay(text: message.text)
                        .accessibilityHidden(true)
                }
                .accessibilityActions {
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = message.text
                    }
                    ShareLink(item: message.text) { Label("Share note", systemImage: "square.and.arrow.up") }
                }
        }
        .frame(maxWidth: maxWidth, alignment: isMine ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isMine ? "You" : "Peer"), \(message.text), \(Date(timeIntervalSince1970: Double(message.timestamp) / 1000).formatted(date: .omitted, time: .shortened))")
    }
}

/// An edit menu has no lifted preview or dimmed conversation backdrop.
private struct MessageActionOverlay: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> MessageActionsView { MessageActionsView() }
    func updateUIView(_ view: MessageActionsView, context: Context) { view.text = text }
}

private final class MessageActionsView: UIView, UIEditMenuInteractionDelegate {
    var text = ""
    private var editMenu: UIEditMenuInteraction?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(showActions(_:)))
        hold.minimumPressDuration = 0.3
        addGestureRecognizer(hold)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        UIBezierPath(roundedRect: bounds, cornerRadius: 19).contains(point)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { editMenu?.dismissMenu() }
    }

    @objc private func showActions(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, window != nil else { return }
        // Allocate a menu only for bubbles that are actually long-pressed.
        let menu: UIEditMenuInteraction
        if let editMenu { menu = editMenu }
        else {
            menu = UIEditMenuInteraction(delegate: self)
            addInteraction(menu)
            editMenu = menu
        }
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: recognizer.location(in: self))
        UIView.performWithoutAnimation { menu.presentEditMenu(with: configuration) }
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        let note = text
        return UIMenu(children: [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = note
            },
            UIAction(title: "Share note", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.share(note)
            },
        ])
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        bounds
    }

    private func share(_ note: String) {
        guard window != nil else { return }
        editMenu?.dismissMenu()
        var responder: UIResponder? = self
        while let next = responder?.next {
            if var presenter = next as? UIViewController {
                while let presented = presenter.presentedViewController { presenter = presented }
                guard !presenter.isBeingDismissed, presenter.viewIfLoaded?.window != nil else { return }
                let sheet = UIActivityViewController(activityItems: [note], applicationActivities: nil)
                sheet.popoverPresentationController?.sourceView = self
                sheet.popoverPresentationController?.sourceRect = bounds
                presenter.present(sheet, animated: true)
                return
            }
            responder = next
        }
    }
}

struct AdminView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var secret = ""
    @State private var section = "Mailboxes"
    @State private var registry: RegistryKind = .capabilities
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if model.isAdminUnlocked {
                    adminConsole
                } else {
                    unlockForm
                }
            }
            .navigationTitle("Admin console")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        secret = ""
                        model.lockAdmin()
                        dismiss()
                    }
                }
            }

        }
        .alert("Operator console", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("OK", role: .cancel) { model.clearError() }
        } message: { Text(model.errorMessage ?? "Please try again.") }
        .onChange(of: scenePhase) { _, phase in if phase != .active { secret = "" } }
        .onDisappear { secret = ""; model.lockAdmin() }
    }

    private var unlockForm: some View {
        AuthenticationLayout {
            VStack(alignment: .leading, spacing: 20) {
                Text("Operator console")
                    .font(.system(.title, design: .serif))
                    .accessibilityAddTraits(.isHeader)
                Text("Use the operator secret to manage mailboxes and public registries.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                PasswordActionRow(title: "Admin secret", text: $secret,
                                  actionLabel: "Unlock", isEnabled: secret.count >= 32,
                                  isBusy: model.isWorking) {
                    Task {
                        await model.unlockAdmin(secret: secret)
                        if model.isAdminUnlocked { secret = "" }
                    }
                }
                Text("The admin secret is held in memory only and cleared when you lock the console or leave the app.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var adminConsole: some View {
        VStack(spacing: 0) {
            Picker("Admin section", selection: $section) {
                Text("Mailboxes").tag("Mailboxes")
                Text("Registries").tag("Registries")
            }
            .pickerStyle(.segmented)
            .padding()

            if section == "Mailboxes" {
                List {
                    Section {
                        ForEach(model.adminAgents) { peer in
                            NavigationLink {
                                AdminAgentDetailView(peer: peer)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(peer.label.isEmpty ? "Unnamed mailbox" : peer.label).font(.headline)
                                    Text(peer.mid.shortMID).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("\(model.adminAgents.count) mailboxes")
                            Spacer()
                            Button("Refresh") { Task { await model.refreshAdminAgents() } }.textCase(nil)
                        }
                    }
                }
                .refreshable { await model.refreshAdminAgents() }
            } else {
                registryEditor
            }
        }
    }

    private var registryEditor: some View {
        Form {
            Section("Public registry") {
                Picker("Resource", selection: $registry) {
                    ForEach(RegistryKind.allCases) { kind in Text(kind.title).tag(kind) }
                }
                if let error = model.registryError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                    Button("Reload registries") { Task { await model.loadAdminRegistries() } }
                        .disabled(model.isLoadingRegistries || model.isWorking)
                }
                TextEditor(text: Binding(
                    get: { model.registryTexts[registry] ?? "" },
                    set: { model.updateRegistryText($0, kind: registry) }
                ))
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 300)
                .disabled(model.isLoadingRegistries || model.registryTexts[registry] == nil)
                .overlay {
                    if model.isLoadingRegistries { ProgressView("Loading registries…") }
                }
                Button {
                    Task { await model.saveRegistry(registry) }
                } label: {
                    if model.isWorking { ProgressView().frame(maxWidth: .infinity) }
                    else { Text("Save \(registry.title.lowercased())").frame(maxWidth: .infinity) }
                }
                .disabled(model.isWorking || model.isLoadingRegistries || model.registryTexts[registry] == nil)
            }
            if let status = model.registryStatus {
                Section { Text(status).foregroundStyle(.secondary) }
            }
        }
    }
}

struct AdminAgentDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let peer: Peer
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let agent = model.selectedAdminAgent, agent.mid == peer.mid {
                List {
                    Section("Mailbox") {
                        LabeledContent("Name", value: agent.label.isEmpty ? "Unnamed" : agent.label)
                        LabeledContent("ID", value: agent.mid.shortMID)
                        LabeledContent("Status", value: agent.active ? "Active" : "Inactive")
                        LabeledContent("Created", value: formattedDate(agent.createdAt))
                    }
                    Section("Inbox usage") {
                        LabeledContent("Messages", value: agent.messageCount.formatted())
                        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(agent.messageBytes), countStyle: .file))
                        LabeledContent("Capabilities", value: agent.capabilities.isEmpty ? "None" : agent.capabilities.joined(separator: ", "))
                    }
                    Section {
                        Button("Delete mailbox and inbox", role: .destructive) { confirmDelete = true }
                            .disabled(model.isWorking)
                    }
                }
            } else if let error = model.adminInspectionError {
                ContentUnavailableView {
                    Label("Could not open mailbox", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("Retry") { Task { await model.inspectAdminAgent(peer) } }
                }
            } else {
                ProgressView("Loading mailbox…")
            }
        }
        .navigationTitle(peer.label.isEmpty ? "Mailbox" : peer.label)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.inspectAdminAgent(peer) }
        .confirmationDialog("Permanently delete this mailbox and erase its inbox?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete mailbox", role: .destructive) {
                Task {
                    if await model.deleteAdminAgent(peer.mid) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func formattedDate(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000).formatted(date: .abbreviated, time: .shortened)
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var baseURL = ""
    @State private var apiAddressSaved = false
    @FocusState private var apiAddressFocused: Bool
    @Binding var showAdmin: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $baseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityLabel("API server address")
                        .modifier(FormInputRow(focus: $apiAddressFocused))
                    Button("Save API address", action: saveAPIAddress)
                        .tint(apiAddressSaved ? Color.secondary : PearTheme.accent)
                        .disabled(model.isWorking || model.isRestoring)
                    Button("Use production API") { model.resetAPIBaseURL(); baseURL = model.apiBaseURLText }
                        .disabled(model.isWorking || model.isRestoring)
                } header: { Text("Connection") }
                footer: { Text("Changing servers disconnects this session. Tokens and message history stay separate for each server. HTTP is supported for private LAN addresses, localhost, and .local hosts.") }
                Section {
                    Label("Mailbox token stored in Keychain", systemImage: "key.horizontal")
                    Button {
                        Task { await model.copyMailboxToken() }
                    } label: {
                        HStack {
                            Label(model.isCopyingMailboxToken ? "Authenticating…" : "Copy mailbox token", systemImage: "doc.on.doc")
                            Spacer()
                            if model.isCopyingMailboxToken { ProgressView() }
                        }
                    }
                    .disabled(!model.canCopyMailboxToken || model.isCopyingMailboxToken)
                    Label("Local history uses iOS file protection", systemImage: "lock.doc")
                } header: { Text("Privacy & security") }
                footer: { Text("Copying a token requires device authentication. Clipboard access is limited to this device and expires after two minutes. Messages are readable by the service operator.") }
                Section {
                    Button { showAdmin = true } label: {
                        Label("Operator console", systemImage: "lock.shield")
                    }
                } footer: { Text("The operator secret stays in memory and is cleared when the console closes or the app leaves the foreground.") }
                if let status = model.statusMessage {
                    Section { Label(status, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Settings")
            .onAppear { baseURL = model.apiBaseURLText; apiAddressSaved = false }
            .onChange(of: apiAddressFocused) { _, focused in
                if focused { apiAddressSaved = false }
            }
        }
    }

    private func saveAPIAddress() {
        apiAddressFocused = false
        let requestedURL = APIClient.validatedBaseURL(baseURL)
        model.updateAPIBaseURL(baseURL)
        apiAddressSaved = requestedURL?.absoluteString == model.apiBaseURLText
        baseURL = model.apiBaseURLText
    }
}

private extension String {
    var shortMID: String {
        let body = hasPrefix("m-") ? dropFirst(2) : self[...]
        return "m-\(body.prefix(6))"
    }
}
