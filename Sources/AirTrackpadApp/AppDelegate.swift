import AppKit
import AirTrackpadCore
import Foundation
import os
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let pinchEngineDefaultsKey = "AirTrackpad.PinchEngine"

    private let appState: AppState
    private let tokenStore = TokenStore()
    private let networkDiscovery = NetworkDiscovery()
    private let inputSynthesizer: InputSynthesizer

    private var server: HTTPWebSocketServer?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var fallbackWindow: NSWindow?
    private var pollTimer: Timer?

    public override init() {
        let savedEngine = UserDefaults.standard.string(forKey: Self.pinchEngineDefaultsKey)
            .flatMap(PinchEngine.init(rawValue:)) ?? .nativeType29
        self.inputSynthesizer = InputSynthesizer(pinchEngine: savedEngine)
        self.appState = AppState(token: tokenStore.currentToken)
        self.appState.pinchEngine = savedEngine
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItemAndPopover()
        startNetworkMonitoring()
        startServer()
        startStatusPolling()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        networkDiscovery.stopMonitoring()
        inputSynthesizer.releaseAllHeldState()
        server?.stop()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlUI()
        return true
    }

    private func makeRootView() -> MenuBarPopoverView {
        MenuBarPopoverView(
            state: appState,
            onRequestAccessibility: { [weak self] in
                guard let self else { return }
                PermissionsAndLogin.requestAccessibilityPrompt(openSystemSettings: true)
                self.refreshPermissionsAndLoginState()
            },
            onRotateToken: { [weak self] in
                guard let self else { return }
                let newToken = self.tokenStore.rotateToken()
                self.appState.token = newToken
                self.server?.disconnectAllClients(reason: "Pairing token reset")
            },
            onPinchEngineChanged: { [weak self] engine in
                guard let self else { return }
                UserDefaults.standard.set(engine.rawValue, forKey: Self.pinchEngineDefaultsKey)
                self.inputSynthesizer.setPinchEngine(engine)
            },
            onSelfTest: { [weak self] action in
                self?.inputSynthesizer.runSelfTest(action)
            },
            onToggleLoginItem: { [weak self] enabled in
                guard let self else { return }
                self.appState.loginErrorText = nil
                do {
                    try PermissionsAndLogin.setLoginItemEnabled(enabled)
                } catch {
                    self.appState.loginErrorText = error.localizedDescription
                }
                self.refreshPermissionsAndLoginState()
            },
            onOpenLoginItemsSettings: {
                PermissionsAndLogin.openLoginItemsSettings()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
    }

    private func setupStatusItemAndPopover() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = true
        if let button = item.button {
            button.image = Self.makeTrackpadIcon(connected: false)
            button.imagePosition = .imageOnly
            button.toolTip = "AirTrackpad"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        self.statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 348, height: 480)
        popover.contentViewController = NSHostingController(rootView: makeRootView())
        self.popover = popover
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            refreshPermissionsAndLoginState()
            appState.applyNetworkSnapshot(networkDiscovery.currentSnapshot())
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showControlUI() {
        refreshPermissionsAndLoginState()
        appState.applyNetworkSnapshot(networkDiscovery.currentSnapshot())

        if let item = statusItem,
           item.isVisible,
           let button = item.button,
           button.window != nil,
           let popover {
            if !popover.isShown {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
            popover.contentViewController?.view.window?.makeKey()
            return
        }

        let window: NSWindow
        if let existing = fallbackWindow {
            window = existing
        } else {
            let hosting = NSHostingController(rootView: makeRootView())
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 348, height: 500),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            created.title = "AirTrackpad"
            created.isReleasedWhenClosed = false
            created.contentViewController = hosting
            created.center()
            self.fallbackWindow = created
            window = created
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func startNetworkMonitoring() {
        networkDiscovery.startMonitoring { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.appState.applyNetworkSnapshot(snapshot)
            }
        }
    }

    private func startServer() {
        let webDirectory = resolveWebDirectory()
        let preferredPort = TokenStore.loadPreferredPort()
        let synth = inputSynthesizer
        let lastDispatchedLabel = OSAllocatedUnfairLock(initialState: appState.lastEventText)

        let callbacks = HTTPWebSocketServer.Callbacks(
            onMessage: { [weak self] clientID, message in
                synth.handle(message, from: clientID)
                if case .ping = message {
                    return
                }
                let label = message.summaryLabel
                let shouldUpdateLabel = lastDispatchedLabel.withLock { current in
                    guard current != label else { return false }
                    current = label
                    return true
                }
                guard shouldUpdateLabel else { return }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if self.appState.lastEventText != label {
                            self.appState.lastEventText = label
                        }
                    }
                }
            },
            onClientDisconnected: { clientID in
                synth.clientDisconnected(clientID)
            },
            onClientCountChanged: { [weak self] count in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.appState.connectedClientCount = count
                    self.statusItem?.button?.image = Self.makeTrackpadIcon(connected: count > 0)
                }
            },
            onAllClientsDisconnected: {
                synth.releaseAllHeldState()
            }
        )

        let httpServer = HTTPWebSocketServer(
            tokenStore: tokenStore,
            webDirectory: webDirectory,
            callbacks: callbacks
        )
        self.server = httpServer

        httpServer.start(port: preferredPort, persistPort: true) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let boundPort):
                    self.appState.port = boundPort
                    self.appState.serverError = nil
                case .failure(let error):
                    self.appState.serverError = error.localizedDescription
                }
            }
        }
    }

    private func startStatusPolling() {
        refreshPermissionsAndLoginState()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let uiVisible = self.popover?.isShown == true || self.fallbackWindow?.isVisible == true
                if !self.appState.isAccessibilityTrusted || uiVisible {
                    self.refreshAccessibilityOnly()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func refreshAccessibilityOnly() {
        let trusted = PermissionsAndLogin.isAccessibilityTrusted()
        if appState.isAccessibilityTrusted != trusted {
            appState.isAccessibilityTrusted = trusted
        }
    }

    private func refreshPermissionsAndLoginState() {
        refreshAccessibilityOnly()
        let loginState = PermissionsAndLogin.loginItemState()
        if appState.loginItemState != loginState {
            appState.loginItemState = loginState
        }
    }

    private func resolveWebDirectory() -> URL {
        let fm = FileManager.default
        if let bundleWeb = Bundle.main.resourceURL?.appendingPathComponent("web"),
           fm.fileExists(atPath: bundleWeb.appendingPathComponent("index.html").path) {
            return bundleWeb
        }

        let sourceRootWeb = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Web")
        if fm.fileExists(atPath: sourceRootWeb.appendingPathComponent("index.html").path) {
            return sourceRootWeb
        }

        return URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Web")
    }

    private static func makeTrackpadIcon(connected: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.setStroke()
            NSColor.labelColor.setFill()

            let padRect = NSRect(x: 1.75, y: 3.25, width: 14.5, height: 11.5)
            let outline = NSBezierPath(roundedRect: padRect, xRadius: 2.8, yRadius: 2.8)
            outline.lineWidth = 1.4
            outline.stroke()

            let bottomDivider = NSBezierPath()
            bottomDivider.move(to: NSPoint(x: 3.5, y: 6.0))
            bottomDivider.line(to: NSPoint(x: 14.5, y: 6.0))
            bottomDivider.lineWidth = 1.0
            bottomDivider.stroke()

            if connected {
                let dot = NSBezierPath(ovalIn: NSRect(x: 7.4, y: 8.6, width: 3.2, height: 3.2))
                dot.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
