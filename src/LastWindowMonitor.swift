// SPDX-FileCopyrightText: 2026 SternXD <stern@sidestore.io>
// SPDX-License-Identifier: GPL-3.0+

import AppKit
import ApplicationServices
import os.log

@MainActor
final class LastWindowMonitor: NSObject {
  private struct SuspendReason: OptionSet {
    let rawValue: Int
    static let sleep = Self(rawValue: 1 << 0)
    static let screenSleep = Self(rawValue: 1 << 1)
    static let screenLock = Self(rawValue: 1 << 2)
    static let screenSaver = Self(rawValue: 1 << 3)
    static let sessionInactive = Self(rawValue: 1 << 4)
    static let poweringOff = Self(rawValue: 1 << 5)
  }

  private final class TrackedApp {
    let pid: pid_t
    var observer: AXObserver?
    var lastWindowCount = 0
    var isTerminating = false

    init(pid: pid_t, observer: AXObserver? = nil, lastWindowCount: Int = 0) {
      self.pid = pid
      self.observer = observer
      self.lastWindowCount = lastWindowCount
    }
  }

  private let preferences: Preferences
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "xyz.sternserv.Vacate",
    category: "WindowMonitor"
  )

  private var trackedApps: [pid_t: TrackedApp] = [:]
  private var isMonitoring = false
  private var suspendReasons: SuspendReason = []
  private var cooldownUntil: Date?
  private var powerOffTask: Task<Void, Never>?

  private var isSuspended: Bool {
    !suspendReasons.isEmpty || sessionLocked()
  }

  init(preferences: Preferences) {
    self.preferences = preferences
    super.init()
  }

  deinit {
    MainActor.assumeIsolated {
      stop()
    }
  }

  func start() {
    guard !isMonitoring else {
      return
    }
    isMonitoring = true

    addObservers()
    sync()
  }

  func sync() {
    guard isMonitoring, !isSuspended else {
      return
    }

    if AXIsProcessTrusted() {
      attachAll()
    }

    syncCounts()
  }

  func stop() {
    guard isMonitoring else {
      return
    }
    isMonitoring = false

    powerOffTask?.cancel()
    powerOffTask = nil

    removeObservers()

    for pid in trackedApps.keys {
      detachObserver(for: pid)
    }
    trackedApps.removeAll()
  }

  private func resume() {
    guard isMonitoring, !isSuspended else {
      return
    }

    logger.debug("Resuming window monitoring")
    cooldownUntil = Date().addingTimeInterval(2.0)
    sync()
  }

  private func sessionLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
      return false
    }
    return session["CGSSessionScreenIsLocked"] as? Bool == true
      || session["kCGSSessionOnConsoleKey"] as? Bool == false
  }

  private func syncCounts() {
    let runningApps = NSWorkspace.shared.runningApplications
    let runningPIDs = Set(runningApps.map(\.processIdentifier))

    prune(runningPIDs: runningPIDs)

    for app in runningApps where tracks(app: app) {
      let pid = app.processIdentifier
      let count = windowCount(for: pid)
      if let tracked = trackedApps[pid] {
        tracked.lastWindowCount = count
        tracked.isTerminating = false
      } else {
        trackedApps[pid] = TrackedApp(pid: pid, lastWindowCount: count)
      }
    }
  }

  private func prune(runningPIDs: Set<pid_t>) {
    for pid in trackedApps.keys.filter({ !runningPIDs.contains($0) }) {
      detachObserver(for: pid)
      trackedApps.removeValue(forKey: pid)
    }
  }

  // MARK: - Notifications

  private func addObservers() {
    let center = NSWorkspace.shared.notificationCenter
    center.addObserver(
      self, selector: #selector(handleAppLaunch(notification:)),
      name: NSWorkspace.didLaunchApplicationNotification, object: nil)
    center.addObserver(
      self, selector: #selector(handleAppTerminate(notification:)),
      name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    center.addObserver(
      self, selector: #selector(handleSystemWillSleep),
      name: NSWorkspace.willSleepNotification, object: nil)
    center.addObserver(
      self, selector: #selector(handleSystemDidWake),
      name: NSWorkspace.didWakeNotification, object: nil)
    center.addObserver(
      self, selector: #selector(handleScreensDidSleep),
      name: NSWorkspace.screensDidSleepNotification, object: nil)
    center.addObserver(
      self, selector: #selector(handleScreensDidWake),
      name: NSWorkspace.screensDidWakeNotification, object: nil)
    center.addObserver(
      self, selector: #selector(handleSessionDidResignActive),
      name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    center.addObserver(
      self, selector: #selector(handleSessionDidBecomeActive),
      name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    center.addObserver(
      self, selector: #selector(handleSystemWillPowerOff),
      name: NSWorkspace.willPowerOffNotification, object: nil)

    let distCenter = DistributedNotificationCenter.default()
    distCenter.addObserver(
      self, selector: #selector(handleScreenLocked),
      name: NSNotification.Name("com.apple.screenIsLocked"), object: nil,
      suspensionBehavior: .deliverImmediately)
    distCenter.addObserver(
      self, selector: #selector(handleScreenUnlocked),
      name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil,
      suspensionBehavior: .deliverImmediately)
    distCenter.addObserver(
      self, selector: #selector(handleScreensaverDidStart),
      name: NSNotification.Name("com.apple.screensaver.didstart"), object: nil,
      suspensionBehavior: .deliverImmediately)
    distCenter.addObserver(
      self, selector: #selector(handleScreensaverDidStop),
      name: NSNotification.Name("com.apple.screensaver.didstop"), object: nil,
      suspensionBehavior: .deliverImmediately)
  }

  private func removeObservers() {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    DistributedNotificationCenter.default().removeObserver(self)
  }

  @objc private func handleAppLaunch(notification: Notification) {
    guard !isSuspended,
      AXIsProcessTrusted(),
      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
      tracks(app: app)
    else {
      return
    }

    attachObserver(to: app)
    evaluate(app: app)
  }

  @objc private func handleAppTerminate(notification: Notification) {
    guard
      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    else {
      return
    }

    let pid = app.processIdentifier
    detachObserver(for: pid)
    trackedApps.removeValue(forKey: pid)
  }

  @objc private func handleSystemWillSleep() {
    logger.debug("System will sleep")
    suspendReasons.insert(.sleep)
  }

  @objc private func handleSystemDidWake() {
    logger.debug("System did wake")
    suspendReasons.remove(.sleep)
    resume()
  }

  @objc private func handleScreensDidSleep() {
    logger.debug("Screens did sleep")
    suspendReasons.insert(.screenSleep)
  }

  @objc private func handleScreensDidWake() {
    logger.debug("Screens did wake")
    suspendReasons.remove(.screenSleep)
    resume()
  }

  @objc private func handleSessionDidResignActive() {
    logger.debug("Session resigned active")
    suspendReasons.insert(.sessionInactive)
  }

  @objc private func handleSessionDidBecomeActive() {
    logger.debug("Session became active")
    suspendReasons.remove(.sessionInactive)
    resume()
  }

  @objc private func handleScreenLocked() {
    logger.debug("Screen locked")
    suspendReasons.insert(.screenLock)
  }

  @objc private func handleScreenUnlocked() {
    logger.debug("Screen unlocked")
    suspendReasons.remove(.screenLock)
    resume()
  }

  @objc private func handleScreensaverDidStart() {
    logger.debug("Screensaver started")
    suspendReasons.insert(.screenSaver)
  }

  @objc private func handleScreensaverDidStop() {
    logger.debug("Screensaver stopped")
    suspendReasons.remove(.screenSaver)
    resume()
  }

  @objc private func handleSystemWillPowerOff() {
    logger.debug("System will power off / log out")
    suspendReasons.insert(.poweringOff)

    // Logout can be cancelled, don't leave monitoring stuck off.
    powerOffTask?.cancel()
    powerOffTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(10))
      guard let self, !Task.isCancelled else {
        return
      }
      self.suspendReasons.remove(.poweringOff)
      self.resume()
    }
  }

  // MARK: - Window Evaluation

  private func evaluateAll() {
    guard preferences.isEnabled, !isSuspended else {
      return
    }

    if AXIsProcessTrusted() {
      attachAll()
    }

    let runningApps = NSWorkspace.shared.runningApplications
    let runningPIDs = Set(runningApps.map(\.processIdentifier))

    prune(runningPIDs: runningPIDs)

    for app in runningApps where tracks(app: app) {
      evaluate(app: app)
    }
  }

  private func evaluate(app: NSRunningApplication) {
    guard preferences.isEnabled, tracks(app: app), !isSuspended else {
      return
    }

    let pid = app.processIdentifier
    let count = windowCount(for: pid)

    let tracked =
      trackedApps[pid]
      ?? {
        let created = TrackedApp(pid: pid, lastWindowCount: count)
        trackedApps[pid] = created
        return created
      }()

    let previousCount = tracked.lastWindowCount
    tracked.lastWindowCount = count

    let coolingDown = cooldownUntil.map { Date() < $0 } ?? false

    if count > 0 {
      tracked.isTerminating = false
    } else if previousCount > 0, !tracked.isTerminating, !coolingDown {
      tracked.isTerminating = true
      logger.info("Terminating \(app.bundleIdentifier ?? "pid \(pid)") (all windows closed)")
      app.terminate()
    }
  }

  private func tracks(app: NSRunningApplication) -> Bool {
    guard preferences.isEligible(app: app), let bundleID = app.bundleIdentifier else {
      return false
    }
    return !preferences.isExcluded(bundleID: bundleID)
  }

  private func windowCount(for pid: pid_t) -> Int {
    if AXIsProcessTrusted() {
      let appElement = AXUIElementCreateApplication(pid)
      if let windows = appElement.windows {
        return windows.filter { isWindow(window: $0) }.count
      }
    }

    guard
      let windows = CGWindowListCopyWindowInfo(.excludeDesktopElements, kCGNullWindowID)
        as? [[String: Any]]
    else {
      return 0
    }

    return windows.filter { info in
      (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
        && (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        && ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0) > 0
    }.count
  }

  private static let ignoredSubroles: Set<String> = [
    kAXFloatingWindowSubrole as String,
    kAXSystemFloatingWindowSubrole as String,
    "AXUnknown",
  ]

  private func isWindow(window: AXUIElement) -> Bool {
    guard window.role == (kAXWindowRole as String) else {
      return false
    }

    if let subrole = window.subrole, Self.ignoredSubroles.contains(subrole) {
      return false
    }

    // Some apps (e.g. Electron) sometimes keep weird windows open
    if let size = window.size, size.width <= 1 || size.height <= 1 {
      return false
    }

    return true
  }

  // MARK: - Observers

  private func attachAll() {
    for app in NSWorkspace.shared.runningApplications where tracks(app: app) {
      attachObserver(to: app)
    }
  }

  private func attachObserver(to app: NSRunningApplication) {
    let pid = app.processIdentifier
    guard pid > 0, tracks(app: app) else {
      return
    }
    if trackedApps[pid]?.observer != nil {
      return
    }

    var observer: AXObserver?
    guard AXObserverCreate(pid, axObserverCallback, &observer) == .success,
      let observer
    else {
      return
    }

    let appElement = AXUIElementCreateApplication(pid)
    let context = Unmanaged.passUnretained(self).toOpaque()

    AXObserverAddNotification(
      observer, appElement, kAXWindowCreatedNotification as CFString, context)
    AXObserverAddNotification(
      observer, appElement, kAXFocusedWindowChangedNotification as CFString, context)
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

    if let tracked = trackedApps[pid] {
      tracked.observer = observer
    } else {
      trackedApps[pid] = TrackedApp(
        pid: pid,
        observer: observer,
        lastWindowCount: windowCount(for: pid)
      )
    }

    watchWindows(for: pid)
  }

  private func detachObserver(for pid: pid_t) {
    guard let tracked = trackedApps[pid], let observer = tracked.observer else {
      return
    }
    CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    tracked.observer = nil
  }

  fileprivate func handleAX(pid: pid_t, windowCreated: Bool) {
    guard !isSuspended else {
      return
    }

    if windowCreated, pid > 0 {
      watchWindows(for: pid)
    }

    if pid > 0, let app = NSRunningApplication(processIdentifier: pid) {
      evaluate(app: app)
    } else {
      evaluateAll()
    }
  }

  private func watchWindows(for pid: pid_t) {
    guard let observer = trackedApps[pid]?.observer else {
      return
    }
    let context = Unmanaged.passUnretained(self).toOpaque()
    let appElement = AXUIElementCreateApplication(pid)

    if let windows = appElement.windows {
      for window in windows {
        AXObserverAddNotification(
          observer, window, kAXUIElementDestroyedNotification as CFString, context)
      }
    }
  }
}

private func axObserverCallback(
  observer: AXObserver,
  element: AXUIElement,
  notification: CFString,
  refcon: UnsafeMutableRawPointer?
) {
  guard let refcon else {
    return
  }
  let monitor = Unmanaged<LastWindowMonitor>.fromOpaque(refcon).takeUnretainedValue()

  var pid: pid_t = 0
  AXUIElementGetPid(element, &pid)
  let windowCreated = CFEqual(notification, kAXWindowCreatedNotification as CFString)

  MainActor.assumeIsolated {
    monitor.handleAX(pid: pid, windowCreated: windowCreated)
  }
}

extension AXUIElement {
  fileprivate func attribute<T>(named key: String) -> T? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(self, key as CFString, &value) == .success else {
      return nil
    }
    return value as? T
  }

  fileprivate var role: String? { attribute(named: kAXRoleAttribute) }
  fileprivate var subrole: String? { attribute(named: kAXSubroleAttribute) }
  fileprivate var windows: [AXUIElement]? { attribute(named: kAXWindowsAttribute) }

  fileprivate var size: CGSize? {
    guard let value: AXValue = attribute(named: kAXSizeAttribute),
      AXValueGetType(value) == .cgSize
    else {
      return nil
    }
    var size = CGSize.zero
    return AXValueGetValue(value, .cgSize, &size) ? size : nil
  }
}
