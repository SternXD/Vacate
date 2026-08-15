// SPDX-FileCopyrightText: 2026 SternXD <stern@sidestore.io>
// SPDX-License-Identifier: GPL-3.0+

import AppKit
import ApplicationServices
import ServiceManagement
import Sparkle
import UniformTypeIdentifiers
import os.log

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate,
  @preconcurrency SPUStandardUserDriverDelegate
{
  private let preferences = Preferences()
  private var monitor: LastWindowMonitor!
  private var statusItem: NSStatusItem!
  private var updaterController: SPUStandardUpdaterController!
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "xyz.sternserv.Vacate",
    category: "AppDelegate"
  )

  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if !AXIsProcessTrusted() {
      promptForAccessibility()
    }

    setupSparkle()
    setupStatusItem()

    monitor = LastWindowMonitor(preferences: preferences)
    monitor.start()
  }

  // MARK: - Menu

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()

    let toggle = NSMenuItem(
      title: "Quit Apps When Last Window Closes",
      action: #selector(toggleMonitoring),
      keyEquivalent: "w"
    )
    toggle.target = self
    toggle.state = preferences.isEnabled ? .on : .off
    menu.addItem(toggle)

    let login = NSMenuItem(
      title: "Open at Login",
      action: #selector(toggleOpenAtLogin),
      keyEquivalent: "l"
    )
    login.target = self
    login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    menu.addItem(login)

    if !AXIsProcessTrusted() {
      let permission = NSMenuItem(
        title: "Grant Accessibility Permission…",
        action: #selector(requestAccessibilityPermission),
        keyEquivalent: "a"
      )
      permission.target = self
      menu.addItem(permission)
    }

    menu.addItem(.separator())

    let exclusionsMenu = NSMenuItem(title: "Exclusions", action: nil, keyEquivalent: "")
    exclusionsMenu.submenu = buildExclusionsSubmenu()
    menu.addItem(exclusionsMenu)

    menu.addItem(.separator())

    let updates = NSMenuItem(
      title: "Check for Updates…",
      action: #selector(SPUStandardUpdaterController.checkForUpdates),
      keyEquivalent: "u"
    )
    updates.target = updaterController
    updates.isEnabled = hasSparkleKey && updaterController.updater.canCheckForUpdates
    menu.addItem(updates)

    let supportMenu = NSMenuItem(title: "Support Vacate", action: nil, keyEquivalent: "")
    supportMenu.submenu = buildSupportSubmenu()
    menu.addItem(supportMenu)

    menu.addItem(.separator())

    let quit = NSMenuItem(
      title: "Quit Vacate",
      action: #selector(NSApplication.terminate),
      keyEquivalent: "q"
    )
    quit.target = NSApp
    menu.addItem(quit)
  }

  private func buildExclusionsSubmenu() -> NSMenu {
    let menu = NSMenu()

    if let frontmost = NSWorkspace.shared.frontmostApplication,
      preferences.isEligible(app: frontmost),
      let bundleID = frontmost.bundleIdentifier
    {
      let name = frontmost.localizedName ?? preferences.displayName(for: bundleID)
      let isExcluded = preferences.isExcluded(bundleID: bundleID)
      let prefix = isExcluded ? "Stop Excluding Active App: " : "Exclude Active App: "

      let activeItem = NSMenuItem(
        title: "\(prefix)\(name)",
        action: #selector(toggleExcludedApp(sender:)),
        keyEquivalent: "e"
      )
      setIconTitle(item: activeItem, bundleID: bundleID, app: frontmost, prefix: prefix, name: name)
      activeItem.representedObject = bundleID
      activeItem.target = self
      menu.addItem(activeItem)
    }

    let runningMenu = NSMenuItem(title: "Running Apps", action: nil, keyEquivalent: "")
    runningMenu.submenu = buildRunningAppsSubmenu()
    menu.addItem(runningMenu)

    let addExcluded = NSMenuItem(
      title: "Add App…",
      action: #selector(showAddExcludedPanel),
      keyEquivalent: ""
    )
    addExcluded.target = self
    menu.addItem(addExcluded)

    menu.addItem(.separator())

    let excluded = preferences.excludedIDs
    guard !excluded.isEmpty else {
      let placeholder = NSMenuItem(title: "No Excluded Apps", action: nil, keyEquivalent: "")
      placeholder.isEnabled = false
      menu.addItem(placeholder)
      return menu
    }

    for bundleID in excluded {
      let menuItem = NSMenuItem(
        title: preferences.displayName(for: bundleID),
        action: #selector(toggleExcludedApp(sender:)),
        keyEquivalent: ""
      )
      menuItem.state = .on
      setIconTitle(item: menuItem, bundleID: bundleID)
      menuItem.representedObject = bundleID
      menuItem.target = self
      menu.addItem(menuItem)
    }

    return menu
  }

  private func buildRunningAppsSubmenu() -> NSMenu {
    let menu = NSMenu()

    let apps = NSWorkspace.shared.runningApplications
      .filter { preferences.isEligible(app: $0) }
      .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

    guard !apps.isEmpty else {
      let placeholder = NSMenuItem(title: "No Running Apps", action: nil, keyEquivalent: "")
      placeholder.isEnabled = false
      menu.addItem(placeholder)
      return menu
    }

    for app in apps {
      guard let bundleID = app.bundleIdentifier else {
        continue
      }
      let name = app.localizedName ?? preferences.displayName(for: bundleID)
      let menuItem = NSMenuItem(
        title: name,
        action: #selector(toggleExcludedApp(sender:)),
        keyEquivalent: ""
      )
      menuItem.state = preferences.isExcluded(bundleID: bundleID) ? .on : .off
      setIconTitle(item: menuItem, bundleID: bundleID, app: app)
      menuItem.representedObject = bundleID
      menuItem.target = self
      menu.addItem(menuItem)
    }

    return menu
  }

  private func buildSupportSubmenu() -> NSMenu {
    let menu = NSMenu()

    let options = [
      ("Ko-fi…", "https://ko-fi.com/stern"),
      ("GitHub Sponsors…", "https://github.com/sponsors/SternXD"),
      ("Patreon…", "https://patreon.com/SternXD"),
    ]

    for (title, url) in options {
      let menuItem = NSMenuItem(
        title: title,
        action: #selector(openURL(sender:)),
        keyEquivalent: ""
      )
      menuItem.representedObject = url
      menuItem.target = self
      menu.addItem(menuItem)
    }

    return menu
  }

  private var hasSparkleKey: Bool {
    let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
    return !(key ?? "").isEmpty
  }

  private func setupSparkle() {
    updaterController = SPUStandardUpdaterController(
      startingUpdater: false,
      updaterDelegate: nil,
      userDriverDelegate: self
    )
    if hasSparkleKey {
      updaterController.startUpdater()
    }
  }

  private func setupStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    updateStatusItem()

    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu
  }

  private func updateStatusItem() {
    guard let button = statusItem.button else {
      return
    }
    let enabled = preferences.isEnabled

    if let icon = NSImage(named: "MenuBarIcon")?.copy() as? NSImage {
      icon.size = NSSize(width: 18, height: 18)
      icon.isTemplate = true
      button.image = icon
      button.imagePosition = .imageOnly
    }

    button.appearsDisabled = !enabled
    button.toolTip = enabled ? "Vacate" : "Vacate (Disabled)"
  }

  private func setIconTitle(
    item: NSMenuItem,
    bundleID: String,
    app: NSRunningApplication? = nil,
    prefix: String = "",
    name: String? = nil
  ) {
    guard let icon = appIcon(for: bundleID, app: app) else {
      return
    }

    let attachment = NSTextAttachment()
    attachment.image = icon
    attachment.bounds = CGRect(x: 0, y: -2.5, width: 16, height: 16)

    let title = NSMutableAttributedString(string: prefix)
    title.append(NSAttributedString(attachment: attachment))
    title.append(NSAttributedString(string: " \(name ?? item.title)"))
    item.attributedTitle = title
  }

  private func appIcon(for bundleID: String, app: NSRunningApplication? = nil) -> NSImage? {
    let path =
      app?.bundleURL?.path
      ?? preferences.appURL(for: bundleID)?.path

    guard let icon = path.map({ NSWorkspace.shared.icon(forFile: $0) }) ?? app?.icon else {
      return nil
    }

    let image = (icon.copy() as? NSImage) ?? icon
    image.size = NSSize(width: 16, height: 16)
    image.isTemplate = false
    return image
  }

  // MARK: - Actions

  @objc private func openURL(sender: NSMenuItem) {
    guard let urlString = sender.representedObject as? String,
      let url = URL(string: urlString)
    else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  @objc private func toggleMonitoring() {
    preferences.isEnabled.toggle()
    updateStatusItem()
    if preferences.isEnabled {
      monitor.sync()
    }
  }

  @objc private func toggleOpenAtLogin() {
    do {
      let service = SMAppService.mainApp
      if service.status == .enabled {
        try service.unregister()
      } else {
        try service.register()
      }
      if service.status == .requiresApproval {
        SMAppService.openSystemSettingsLoginItems()
      }
    } catch {
      logger.error("Failed to toggle login item: \(error.localizedDescription)")
    }
  }

  @objc private func requestAccessibilityPermission() {
    if promptForAccessibility() {
      monitor.sync()
    } else if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    {
      // Prompt only shows once, open Settings if it was already dismissed.
      NSWorkspace.shared.open(url)
    }
  }

  @discardableResult
  private func promptForAccessibility() -> Bool {
    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
  }

  @objc private func showAddExcludedPanel() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.allowedContentTypes = [.application]
    panel.prompt = "Choose"

    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK else {
      return
    }

    let bundleIDs = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
    if confirmExclusion(bundleIDs: bundleIDs) {
      preferences.addExcluded(bundleIDs: bundleIDs)
    }
  }

  @objc private func toggleExcludedApp(sender: NSMenuItem) {
    guard let bundleID = sender.representedObject as? String else {
      return
    }
    if preferences.isExcluded(bundleID: bundleID) {
      preferences.removeExcluded(bundleID: bundleID)
    } else if confirmExclusion(bundleIDs: [bundleID]) {
      preferences.addExcluded(bundleIDs: [bundleID])
    }
  }

  private func confirmExclusion(bundleIDs: [String]) -> Bool {
    guard !bundleIDs.isEmpty else {
      return false
    }

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Exclude")
    alert.addButton(withTitle: "Cancel")

    if bundleIDs.count == 1, let bundleID = bundleIDs.first {
      let name = preferences.displayName(for: bundleID)
      alert.messageText = "Exclude \(name)?"
      alert.informativeText = "Vacate will not quit \(name) when its last window closes."
      if let icon = appIcon(for: bundleID) {
        alert.icon = icon
      }
    } else {
      let names = bundleIDs.map { preferences.displayName(for: $0) }.joined(separator: "\n• ")
      alert.messageText = "Exclude \(bundleIDs.count) Apps?"
      alert.informativeText =
        "Vacate will not quit these apps when their last windows close:\n\n• \(names)"
    }

    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertFirstButtonReturn
  }

  // MARK: - Sparkle

  var supportsGentleScheduledUpdateReminders: Bool {
    true
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    // Menu bar apps don't automatically focus the Sparkle dialog
    NSApp.activate(ignoringOtherApps: true)
  }
}
