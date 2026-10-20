# Pear Liminal for iOS

Native SwiftUI client for the existing Agent Messaging API. It supports creating or reconnecting a mailbox, browsing peers, chatting, and the admin console under **Settings → Operator console** (mailbox inspection/deletion and registry editing). Mailbox tokens are stored in iOS Keychain separately for each server. The admin secret remains in memory and is cleared when the app backgrounds or the console is locked.

The app defaults to `https://agent-messaging.charcoal.workers.dev`. You can change the API base URL under **Settings**. The iOS client calls the API Worker directly; it does not use the browser Worker proxy.

## Install on your iPhone from Xcode

This project requires a Mac with the full Xcode app installed. It builds against the newest installed iOS SDK (Xcode 27.1 / iOS 27.1 in the current environment) and keeps an iOS 17.0 minimum deployment target for compatibility with older iPhones.

1. Install and launch Xcode from the Mac App Store, then let it install its iOS platform components.
2. Open `PearLiminal.xcodeproj` from this folder.
3. Select the **PearLiminal** target, open **Signing & Capabilities**, enable **Automatically manage signing**, and select your Apple Account team. If needed, change the bundle identifier `com.pearliminal.ios` to one unique to you.
4. Connect your iPhone to the Mac, unlock it, accept **Trust This Computer**, and select the iPhone as Xcode's run destination.
5. If iOS asks you to enable Developer Mode, go to **Settings → Privacy & Security → Developer Mode**, turn it on, restart the iPhone, and confirm after restart.
6. In Xcode, click **Run** (▶). Xcode signs, installs, and launches the app on the phone.

For a personal test install, sign in to Xcode with your Apple Account and use automatic signing. For distribution to other people or App Store release, configure the corresponding Apple Developer signing and distribution workflow.

## Verification

Run the native model and networking regression suite on a Mac without an iOS simulator:

```sh
swift test --package-path ios
```

The HTTP integration test skips unless `PEAR_SIMULATION_URL` is set. See [`../postman/README.md`](../postman/README.md) for the repeatable local simulation. See [`REVIEW.md`](REVIEW.md) for fixes, design changes, and remaining device checks.

On an Apple Silicon Mac with Xcode, the offscreen UIKit check exercises the actual editor and chat hosting container without a simulator:

```sh
pear_sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -parse-as-library -target arm64-apple-ios17.0-macabi \
  -sdk "$pear_sdk" -F "$pear_sdk/System/iOSSupport/System/Library/Frameworks" \
  ios/PearLiminal/ComposerTextView.swift ios/PearLiminal/ConversationScrollState.swift \
  ios/PearLiminal/ConversationViewport.swift ios/Tools/check-composer.swift \
  -o /tmp/pear-composer-check
/tmp/pear-composer-check
```

This checks wrapped lines, explicit and trailing newlines, the four-line cap, larger type, width changes, and clearing without restoring the old draft. Keyboard gestures and IME interaction still require an iPhone check.

## Notes

- To use the deployed service, leave the API address at its default.
- For a local API, expose the API Worker to your iPhone over your local network and enter the Mac's private LAN address and API port, such as `http://192.168.1.42:8788`, or an HTTP `.local` hostname in **Settings**. The phone and Mac need to be on the same network.
- Inbox refresh uses foreground polling. The API currently has no push registration/delivery endpoint, so messages do not generate reliable iOS notifications while the app is suspended.
- The admin secret is not saved. Unlock again after returning to the app from the background.
- Diagnostic logs use Apple's unified logging. With the iPhone connected to your Mac, open **Console.app**, select the iPhone, and filter for the app's bundle identifier or the `API` / `AppModel` categories. Logs include request outcomes and message counts, but not message text, tokens, or admin secrets.

- Pending sends retain their original key and payload. Use **Retry** if delivery is unconfirmed; retrying the pending note avoids creating a second send.
- Drafts and the latest 500 messages per conversation are kept in protected local files, separate for each server and mailbox and excluded from backup. Sign-out retains this history for reconnection; deleting a mailbox erases its associated local cache.
- Changing API servers disconnects the current session. HTTP is supported for private IPv4 LAN addresses, IPv6 local addresses, loopback, and `.local` development hosts; public servers require HTTPS. API addresses must contain only the origin, without a path, query, or embedded credentials.

- The composer uses native Liquid Glass on iOS 26 and later: a capsule input and separate circular send button, without a backing bar. Earlier versions use material surfaces with the same shapes.
- The editor grows to four visible lines, with decreasing corner radius as it grows, then scrolls internally. Sending commits the current input and immediately clears both the native editor and saved draft after queueing succeeds; rejected sends retain the draft.
- Token copying waits for the app to become active after Face ID; actually backgrounding the app or signing out cancels the pending copy.

- Swipe left on a conversation and tap **Delete** to remove its local notes, drafts, unread count, and pending notes. Departed Pears disappear from the list after their chat is deleted; active Pears remain available in the directory. Your mailbox and the other Pear’s inbox are unaffected. Delete is disabled while a send to that Pear is in flight.
