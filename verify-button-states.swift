// verify-button-states.swift
//
// 把工具栏更新按钮的五种状态离屏渲染成一张图，用来核对「置灰 / 红点 / 转圈 / 重试」的外观。
//
// 为什么不用截屏：screencapture 需要「屏幕录制」权限，而权限未必一直可用；而且应用未取得焦点时
// 窗口截图会直接报 `could not create image from window`。离屏渲染不碰屏幕，任何环境下都能跑。
//
// 注意两个坑：
//   · ImageRenderer 画不了 AppKit 支撑的控件（默认样式的 Button、ProgressView），
//     会输出一张黄底禁止符的占位图。所以这里用 NSHostingView + cacheDisplay 走真实绘制路径。
//   · 「正在检查」只存在于发起与完成之间那一瞬，而成像发生在取图时。所以要把它放到最后：
//     先 await 完其余状态，再发起一个检查并立刻成像。
//
// 用法：
//   SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX15*.sdk | sort -r | head -1)
//   xcrun swiftc -sdk "$SDK" -target x86_64-apple-macos15.0 -swift-version 5 \
//     -o /tmp/verify-button-states \
//     Compositor/IO/ForkUpdateChecker.swift Compositor/UI/ForkUpdateButton.swift \
//     Compositor/IO/LocalUpdateLauncher.swift Compositor/Localization.swift \
//     verify-button-states.swift
//   /tmp/verify-button-states      # 输出 按钮状态-离屏渲染.png

import AppKit
import Foundation
import SwiftUI

@MainActor
private func seeded(_ name: String, _ seed: [String: Any] = [:]) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    for (key, value) in seed { defaults.set(value, forKey: key) }
    return defaults
}

/// 走真实 AppKit 绘制路径成像。见文件头关于 ImageRenderer 的说明。
@MainActor
private func rasterize<V: View>(_ view: V, width: CGFloat, height: CGFloat, to path: String) -> Bool {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
    // 无边框且不 front 的窗口：只为让控件完成布局，不会在屏幕上闪现。
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.contentView = hosting
    window.layoutIfNeeded()
    hosting.layoutSubtreeIfNeeded()
    guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
    hosting.cacheDisplay(in: hosting.bounds, to: representation)
    guard let png = representation.representation(using: .png, properties: [:]) else { return false }
    try? png.write(to: URL(fileURLWithPath: path))
    return true
}

@MainActor
private func panel(_ label: String, _ checker: ForkUpdateChecker) -> some View {
    VStack(spacing: 8) {
        ForkUpdateButton(updates: checker).frame(width: 46, height: 30)
        Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.92))
        Text("\(checker.status)").font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45))
    }
    .frame(width: 156)
}

@main
struct VerifyButtonStates {
    @MainActor
    static func main() async {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)

        // 用应用真实的版本号，这样「已是最新」那一格跑的是真实网络检查。
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.2.1"

        let unchecked = ForkUpdateChecker(defaults: seeded("verify.unchecked"),
                                          currentVersion: current, canPresent: { false })

        // 手动路径（checkForUpdates）不受 NSApp.isActive 限制，命令行里也能跑通。
        let currentState = ForkUpdateChecker(defaults: seeded("verify.current"),
                                             currentVersion: current, canPresent: { false })
        currentState.checkForUpdates()
        while currentState.isChecking { try? await Task.sleep(for: .seconds(0.25)) }

        // 有新版本：写入持久化状态，走的是应用启动时同一条恢复路径。
        let available = ForkUpdateChecker(defaults: seeded("verify.available", [
            "forkUpdates.availableVersion": "1.2.3",
            "forkUpdates.availableReleaseURL":
                "https://github.com/Penny777btc/Compositor/releases/tag/zh-beta-v1.2.3",
        ]), currentVersion: current, canPresent: { false })

        // 失败态：本机版本号无法解析会走 invalidCurrentVersion，与网络失败落在同一分支。
        let failed = ForkUpdateChecker(defaults: seeded("verify.failed"),
                                       currentVersion: "", canPresent: { false })
        failed.checkForUpdates()
        while failed.isChecking { try? await Task.sleep(for: .seconds(0.25)) }

        // 最后发起，紧接着成像 —— 否则它已经变成 current 了。
        let checking = ForkUpdateChecker(defaults: seeded("verify.checking"),
                                         currentVersion: current, canPresent: { false })
        checking.checkForUpdates()

        let strip = ZStack {
            Color(white: 0.20)
            HStack(spacing: 0) {
                panel("① 尚未检查", unchecked)
                panel("② 正在检查", checking)
                panel("③ 已是最新", currentState)
                panel("④ 有新版本", available)
                panel("⑤ 检查失败", failed)
            }
        }
        .frame(width: 800, height: 118)
        .environment(\.colorScheme, .dark)

        let output = FileManager.default.currentDirectoryPath + "/按钮状态-离屏渲染.png"
        print(rasterize(strip, width: 800, height: 118, to: output) ? "✓ 已输出 \(output)" : "✗ 光栅化失败")
        for (name, checker) in [("尚未检查", unchecked), ("正在检查", checking), ("已是最新", currentState),
                                ("有新版本", available), ("检查失败", failed)] {
            print("   \(name) → \(checker.status)")
        }
        exit(0)
    }
}
