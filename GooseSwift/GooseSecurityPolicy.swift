import Foundation

/// Security Phase 1 policy switches.
///
/// Coach forwards locally derived health data to a remote model endpoint
/// (chatgpt.com/backend-api/codex/responses) as function-call output: live and
/// resting heart rate, sleep/recovery/strain/stress scores, activity sessions
/// with average and max HR, capture and device state, and the recent chat
/// transcript. There is no per-message consent gate today, so remote Coach
/// execution is refused at every network entry point until one exists.
enum GooseCoachPolicy {
  /// When false, no Coach request, OAuth request, or token refresh may leave
  /// the device. There is no fallback path.
  static let remoteExecutionEnabled = false

  static let disabledTitle = "Online Coach is disabled"

  static let disabledSummary = """
  Online Coach is off for privacy. It previously sent your health metrics, \
  derived scores, activity sessions, and device details to a remote model with \
  no per-message approval. It stays off until explicit per-message consent is \
  implemented. Nothing is sent, and there is no silent network fallback.
  """
}

/// Diagnostic logging policy. Opt-in only, and it now governs every on-disk
/// diagnostic side channel, including the previously always-on live log.
enum GooseDiagnosticsPolicy {
  static let loggingEnabled: Bool = {
    let processInfo = ProcessInfo.processInfo
    if processInfo.arguments.contains("--goose-disable-diagnostics")
      || processInfo.environment["GOOSE_DISABLE_DIAGNOSTICS"] == "1"
      || processInfo.environment["GOOSE_DIAGNOSTIC_LOGGING"] == "0" {
      return false
    }
    return processInfo.arguments.contains("--goose-enable-diagnostics")
      || processInfo.environment["GOOSE_ENABLE_DIAGNOSTICS"] == "1"
      || processInfo.environment["GOOSE_DIAGNOSTIC_LOGGING"] == "1"
  }()
}

/// iOS Data Protection classes for locally stored health artifacts.
enum GooseFileProtection {
  /// Files on the background BLE capture path. The app declares the
  /// bluetooth-central background mode and runs a 12-hour overnight guard with
  /// the screen locked, so FileProtectionType.complete would make those writes
  /// fail with EPERM once the device locks and would risk SQLite WAL
  /// corruption. Class C keeps the data encrypted at rest and unreadable
  /// before the first unlock after reboot, while allowing locked-screen writes.
  static let backgroundWritable: FileProtectionType = .completeUntilFirstUserAuthentication

  /// Files only ever written and read while the app is in the foreground.
  static let foregroundOnly: FileProtectionType = .complete

  /// File name prefixes that are deliberately held at `foregroundOnly` and
  /// must not be downgraded by the launch sweep.
  private static let foregroundOnlyNamePrefixes = ["local-health-validation-"]

  @discardableResult
  static func apply(_ protection: FileProtectionType, to url: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return false
    }
    do {
      try FileManager.default.setAttributes(
        [.protectionKey: protection],
        ofItemAtPath: url.path
      )
      return true
    } catch {
      return false
    }
  }

  /// Application Support/GooseSwift, created on demand and protected.
  static func applicationSupportDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let directory = base.appendingPathComponent("GooseSwift", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    apply(backgroundWritable, to: directory)
    return directory
  }

  static func isForegroundOnlyArtifact(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    return foregroundOnlyNamePrefixes.contains { name.hasPrefix($0) }
  }

  /// Applies Class C to every existing Goose health artifact, leaving
  /// foreground-only artifacts at Class A. Idempotent, and covers files the
  /// Swift layer never creates itself: goose.sqlite and its WAL/SHM sidecars
  /// are opened by the Rust core.
  static func protectExistingHealthArtifacts() {
    let fileManager = FileManager.default
    var roots: [URL] = []
    if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      roots.append(appSupport.appendingPathComponent("GooseSwift", isDirectory: true))
    }
    if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
      roots.append(documents.appendingPathComponent("GooseSwift", isDirectory: true))
    }
    for root in roots {
      guard fileManager.fileExists(atPath: root.path) else {
        continue
      }
      apply(backgroundWritable, to: root)
      guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
        continue
      }
      for case let url as URL in enumerator {
        apply(isForegroundOnlyArtifact(url) ? foregroundOnly : backgroundWritable, to: url)
      }
    }
  }

  /// Moves diagnostic side-channel files written by earlier builds out of the
  /// user-visible Documents container into Application Support/GooseSwift.
  /// These are rolling diagnostic logs, not user documents.
  static func migrateLegacyDocumentsDiagnostics() {
    let fileManager = FileManager.default
    guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
      return
    }
    let legacyDirectory = documents.appendingPathComponent("GooseSwift", isDirectory: true)
    let destinationDirectory = applicationSupportDirectory()
    for name in ["goose-ble-live.log", "capture-status.txt", "debug-bt-commands.json"] {
      let source = legacyDirectory.appendingPathComponent(name)
      guard fileManager.fileExists(atPath: source.path) else {
        continue
      }
      let destination = destinationDirectory.appendingPathComponent(name)
      if fileManager.fileExists(atPath: destination.path) {
        try? fileManager.removeItem(at: source)
      } else {
        try? fileManager.moveItem(at: source, to: destination)
        apply(backgroundWritable, to: destination)
      }
    }
  }
}
