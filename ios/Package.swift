// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PearLiminalCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "PearLiminalCore", targets: ["PearLiminalCore"])],
    targets: [
        .target(name: "PearLiminalCore", path: "PearLiminal",
                exclude: ["ContentView.swift", "ConversationViewport.swift", "ComposerTextView.swift", "PearLiminalApp.swift", "Assets.xcassets", "Info.plist", "LaunchScreenRounded.storyboard"],
                sources: ["APIClient.swift", "AppModel.swift", "MailboxStore.swift", "KeychainStore.swift", "ConversationScrollState.swift"]),
        .testTarget(name: "PearLiminalCoreTests", dependencies: ["PearLiminalCore"], path: "Tests"),
    ]
)
