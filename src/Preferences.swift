// SPDX-FileCopyrightText: 2026 SternXD <stern@sidestore.io>
// SPDX-License-Identifier: GPL-3.0+

import AppKit

@MainActor
final class Preferences {
  private enum Keys {
    static let isEnabled = "isEnabled"
    static let excludedBundleIDs = "excludedBundleIDs"
  }

  private let defaults: UserDefaults
  private var nameCache: [String: String] = [:]

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var isEnabled: Bool {
    get { defaults.object(forKey: Keys.isEnabled) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Keys.isEnabled) }
  }

  var excludedIDs: [String] {
    get { defaults.stringArray(forKey: Keys.excludedBundleIDs) ?? [] }
    set { defaults.set(newValue, forKey: Keys.excludedBundleIDs) }
  }

  func isSystemApp(app: NSRunningApplication) -> Bool {
    if app.bundleIdentifier == "com.apple.finder" {
      return true
    }

    guard let url = app.bundleURL else {
      return false
    }

    let path = url.path
    let resolved = url.resolvingSymlinksInPath().path
    return path.contains("/System/Library/") || resolved.contains("/System/Library/")
  }

  func isEligible(app: NSRunningApplication) -> Bool {
    app.activationPolicy == .regular
      && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
      && !isSystemApp(app: app)
  }

  func isExcluded(bundleID: String) -> Bool {
    excludedIDs.contains(bundleID)
  }

  func addExcluded(bundleIDs: [String]) {
    var set = Set(excludedIDs)
    set.formUnion(bundleIDs)
    excludedIDs = set.sorted {
      displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1))
        == .orderedAscending
    }
  }

  func removeExcluded(bundleID: String) {
    excludedIDs.removeAll { $0 == bundleID }
  }

  func appURL(for bundleID: String) -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
  }

  func displayName(for bundleID: String) -> String {
    if let cached = nameCache[bundleID] {
      return cached
    }

    let name: String
    if let appURL = appURL(for: bundleID),
      let bundle = Bundle(url: appURL)
    {
      let info = bundle.infoDictionary
      name =
        (info?["CFBundleDisplayName"] as? String)
        ?? (info?["CFBundleName"] as? String)
        ?? appURL.deletingPathExtension().lastPathComponent
    } else {
      name = bundleID
    }

    nameCache[bundleID] = name
    return name
  }
}
