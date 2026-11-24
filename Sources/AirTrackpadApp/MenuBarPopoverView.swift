import AppKit
import AirTrackpadCore
import SwiftUI

@MainActor
public final class AppState: ObservableObject {
    @Published public var connectedClientCount: Int = 0
    @Published public var port: UInt16 = TokenStore.defaultPort {
        didSet {
            if port != oldValue {
                refreshPairingQRIfNeeded()
            }
        }
    }
    @Published public var serverError: String?
    @Published public var isAccessibilityTrusted: Bool = PermissionsAndLogin.isAccessibilityTrusted()
    @Published public var token: String = "" {
        didSet {
            if token != oldValue {
                refreshPairingQRIfNeeded()
            }
        }
    }
    @Published public var networkSnapshot: NetworkSnapshot = NetworkSnapshot(localHostName: nil, interfaces: [])
    @Published public var selectedHost: String = "127.0.0.1" {
        didSet {
            if selectedHost != oldValue {
                refreshPairingQRIfNeeded()
            }
        }
    }
    @Published public var userPinnedHost: Bool = false
    @Published public var pinchEngine: PinchEngine = .nativeType29
    @Published public var lastEventText: String = "尚无触控事件"
    @Published public var loginItemState: LoginItemState = PermissionsAndLogin.loginItemState()
    @Published public var loginErrorText: String?

    public private(set) var pairingQRImage: NSImage?
    private var cachedPairingQRURL: String?

    public init(
        port: UInt16 = TokenStore.defaultPort,
        token: String = "",
        selectedHost: String = "127.0.0.1"
    ) {
        self.port = port
        self.token = token
        self.selectedHost = selectedHost
        refreshPairingQRIfNeeded()
    }

    public var pairingURL: String {
        "http://\(selectedHost):\(port)/?token=\(token)"
    }

    public func applyNetworkSnapshot(_ snapshot: NetworkSnapshot) {
        if networkSnapshot != snapshot {
            networkSnapshot = snapshot
        }
        let availableHosts = Set(snapshot.addressOptions.map(\.host))
        if !userPinnedHost || !availableHosts.contains(selectedHost) {
            if selectedHost != snapshot.preferredHost {
                selectedHost = snapshot.preferredHost
            }
            if userPinnedHost {
                userPinnedHost = false
            }
        }
    }

    private func refreshPairingQRIfNeeded() {
        let currentURL = pairingURL
        guard currentURL != cachedPairingQRURL else { return }
        cachedPairingQRURL = currentURL
        pairingQRImage = QRCodeGenerator.generate(from: currentURL, size: 144)
    }
}

public struct MenuBarPopoverView: View {
    @ObservedObject var state: AppState
    let onRequestAccessibility: () -> Void
    let onRotateToken: () -> Void
    let onPinchEngineChanged: (PinchEngine) -> Void
    let onSelfTest: (InputSynthesizer.SelfTestAction) -> Void
    let onToggleLoginItem: (Bool) -> Void
    let onOpenLoginItemsSettings: () -> Void
    let onQuit: () -> Void

    @State private var diagnosticsExpanded = false
    @State private var copiedFeedback = false

    public init(
        state: AppState,
        onRequestAccessibility: @escaping () -> Void,
        onRotateToken: @escaping () -> Void,
        onPinchEngineChanged: @escaping (PinchEngine) -> Void,
        onSelfTest: @escaping (InputSynthesizer.SelfTestAction) -> Void,
        onToggleLoginItem: @escaping (Bool) -> Void,
        onOpenLoginItemsSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.state = state
        self.onRequestAccessibility = onRequestAccessibility
        self.onRotateToken = onRotateToken
        self.onPinchEngineChanged = onPinchEngineChanged
        self.onSelfTest = onSelfTest
        self.onToggleLoginItem = onToggleLoginItem
        self.onOpenLoginItemsSettings = onOpenLoginItemsSettings
        self.onQuit = onQuit
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                statusHeader

                if !state.isAccessibilityTrusted {
                    accessibilityBanner
                }

                if let error = state.serverError {
                    Text("服务启动失败：\(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                pairingSection

                Divider()

                diagnosticsSection

                Divider()

                footerSection
            }
            .padding(14)
        }
        .frame(width: 348)
        .frame(maxHeight: 620)
    }

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.connectedClientCount > 0 ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 9, height: 9)

            Text(state.connectedClientCount > 0 ? "已连接 \(state.connectedClientCount) 台设备" : "等待 iPhone 连接")
                .font(.headline)

            Spacer()

            Text("端口 \(state.port > 0 ? String(state.port) : "--")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.14), in: Capsule())
        }
    }

    private var accessibilityBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("需要辅助功能权限才能控制光标与手势")
                    .font(.caption.weight(.medium))
            }
            Button("授权辅助功能") {
                onRequestAccessibility()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if let qrImage = state.pairingQRImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 128, height: 128)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("iPhone 扫码打开后，点 Safari 底部「分享 → 添加到主屏幕」即可全屏使用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Button(copiedFeedback ? "已复制" : "复制链接") {
                            copyPairingURL()
                        }
                        .controlSize(.small)

                        Button("重置配对码") {
                            onRotateToken()
                        }
                        .controlSize(.small)
                    }
                }
            }

            if !state.networkSnapshot.addressOptions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("连接地址")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(state.networkSnapshot.addressOptions) { option in
                                addressPill(option)
                            }
                        }
                    }
                }
            }

            if state.networkSnapshot.hasHotspotOrUSB {
                Text("检测到个人热点 / USB 共享，推荐直接使用上方 172.20.10.x 地址。")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }

            Text(state.pairingURL)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func addressPill(_ option: AddressOption) -> some View {
        let isSelected = state.selectedHost == option.host
        return Button {
            state.selectedHost = option.host
            state.userPinnedHost = true
        } label: {
            HStack(spacing: 4) {
                Text(option.host)
                    .font(.caption2.monospaced())
                if let badge = option.badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            (option.isHotspotOrUSB ? Color.blue : Color.secondary)
                                .opacity(isSelected ? 0.25 : 0.16),
                            in: Capsule()
                        )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var diagnosticsSection: some View {
        DisclosureGroup("诊断与自测", isExpanded: $diagnosticsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("捏合缩放引擎")
                        .font(.caption)
                    Spacer()
                    Picker("", selection: $state.pinchEngine) {
                        ForEach(PinchEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .onChange(of: state.pinchEngine) { _, newValue in
                        onPinchEngineChanged(newValue)
                    }
                }

                HStack(spacing: 6) {
                    Text("最近事件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(state.lastEventText)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 6),
                        GridItem(.flexible(), spacing: 6),
                        GridItem(.flexible(), spacing: 6)
                    ],
                    spacing: 6
                ) {
                    selfTestButton("调度中心", .missionControl)
                    selfTestButton("App Exposé", .appExpose)
                    selfTestButton("显示桌面", .showDesktop)
                    selfTestButton("启动台 / Apps", .launchpad)
                    selfTestButton("左切桌面", .spaceLeft)
                    selfTestButton("右切桌面", .spaceRight)
                    selfTestButton("查词 Look Up", .lookup)
                    selfTestButton("捏合放大", .zoomIn)
                    selfTestButton("捏合缩小", .zoomOut)
                }
            }
            .padding(.top, 8)
        }
        .font(.subheadline.weight(.medium))
    }

    private func selfTestButton(_ title: String, _ action: InputSynthesizer.SelfTestAction) -> some View {
        Button(title) {
            onSelfTest(action)
        }
        .font(.caption2)
        .frame(maxWidth: .infinity)
        .controlSize(.small)
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(
                    "开机自启",
                    isOn: Binding(
                        get: { state.loginItemState == .enabled || state.loginItemState == .requiresApproval },
                        set: { onToggleLoginItem($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)

                Spacer()

                Button("退出") {
                    onQuit()
                }
                .controlSize(.small)
            }

            if state.loginItemState == .requiresApproval {
                HStack(spacing: 6) {
                    Text("需在系统设置中允许后台登录项")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("打开登录项设置") {
                        onOpenLoginItemsSettings()
                    }
                    .font(.caption2)
                    .controlSize(.mini)
                }
            } else if case .unavailable(let reason) = state.loginItemState {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let loginError = state.loginErrorText {
                Text(loginError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private func copyPairingURL() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(state.pairingURL, forType: .string)
        copiedFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copiedFeedback = false
        }
    }
}
