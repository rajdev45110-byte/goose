import Foundation
import OSLog

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
  /// Stable, non-sensitive identifiers used in failure diagnostics.
  /// Deliberately a closed enum rather than a free-form string so a file path
  /// can never be passed into a log line.
  enum Artifact: String {
    case container
    case database
    case healthSeries = "health_series"
    case validationSidecar = "validation_sidecar"
    case legacyDiagnostic = "legacy_diagnostic"
    case sweepItem = "sweep_item"
  }

  enum ApplyOutcome {
    case applied
    case absent
    case failed
  }

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

  /// Bounded per-launch set: the only artifacts that are not already protected
  /// at the point they are written. The overnight spool, diagnostic logs,
  /// export bundles, crash markers, and validation sidecars all apply
  /// protection at creation, so they need no recurring sweep.
  private static let launchProtectedNames = [
    "goose.sqlite",
    "goose.sqlite-wal",
    "goose.sqlite-shm",
    "heart-rate-samples.json",
    "hrv-samples.json",
  ]

  private static let deepSweepVersion = 1
  private static let deepSweepVersionDefaultsKey = "goose.security.fileProtectionSweepVersion"

  private static let logger = Logger(subsystem: "com.goose.swift", category: "security")
  private static let failureLock = NSLock()
  private static var failureCountsByArtifact: [String: Int] = [:]

  @discardableResult
  static func apply(
    _ protection: FileProtectionType,
    to url: URL,
    artifact: Artifact
  ) -> ApplyOutcome {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return .absent
    }
    do {
      try FileManager.default.setAttributes(
        [.protectionKey: protection],
        ofItemAtPath: url.path
      )
      return .applied
    } catch {
      recordFailure(artifact: artifact, error: error)
      return .failed
    }
  }

  /// Records a protection failure without exposing any path or health data.
  /// Only the artifact class and the error domain and code are emitted.
  /// `localizedDescription` and `userInfo` are never read: Cocoa file errors
  /// embed NSFilePath in both.
  private static func recordFailure(artifact: Artifact, error: Error) {
    let nsError = error as NSError
    failureLock.lock()
    failureCountsByArtifact[artifact.rawValue, default: 0] += 1
    let count = failureCountsByArtifact[artifact.rawValue] ?? 0
    failureLock.unlock()
    logger.error(
      "data protection not applied: artifact=\(artifact.rawValue, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) count=\(count, privacy: .public)"
    )
  }

  /// Snapshot of protection failures for on-device inspection. Keys are
  /// artifact classes, never paths.
  static func failureSnapshot() -> [String: Int] {
    failureLock.lock()
    defer { failureLock.unlock() }
    return failureCountsByArtifact
  }

  /// Pure path computation. Performs no filesystem work.
  static func applicationSupportDirectoryURL() -> URL {
    (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory)
      .appendingPathComponent("GooseSwift", isDirectory: true)
  }

  /// Application Support/GooseSwift, created on demand and protected.
  static func applicationSupportDirectory() -> URL {
    let directory = applicationSupportDirectoryURL()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    apply(backgroundWritable, to: directory, artifact: .container)
    return directory
  }

  static func isForegroundOnlyArtifact(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    return foregroundOnlyNamePrefixes.contains { name.hasPrefix($0) }
  }

  /// Bounded, O(1) launch setup. Creates and protects the container, then
  /// re-asserts protection on the small set of artifacts not protected at
  /// creation time. Cheap enough to run synchronously before anything resolves
  /// the database path, and again when the app backgrounds so the WAL and SHM
  /// sidecars SQLite created during the session are covered.
  static func prepareLocalStores() {
    let directory = applicationSupportDirectory()
    for name in launchProtectedNames {
      let artifact: Artifact = name.hasPrefix("goose.sqlite") ? .database : .healthSeries
      apply(backgroundWritable, to: directory.appendingPathComponent(name), artifact: artifact)
    }
  }

  /// One-time deep migration for containers written by pre-Phase-1 builds.
  /// Runs at most once per `deepSweepVersion`. The version is recorded only
  /// when the sweep completes with no failures, so a run that happens before
  /// the first unlock after reboot is retried next launch rather than being
  /// silently skipped forever.
  static func runDeepMigrationIfNeeded() {
    let defaults = UserDefaults.standard
    guard defaults.integer(forKey: deepSweepVersionDefaultsKey) < deepSweepVersion else {
      return
    }
    migrateLegacyDocumentsDiagnostics()
    guard protectExistingHealthArtifacts() else {
      logger.error("deep protection sweep incomplete; will retry next launch")
      return
    }
    defaults.set(deepSweepVersion, forKey: deepSweepVersionDefaultsKey)
  }

  /// Applies Class C to every existing Goose health artifact, leaving
  /// foreground-only artifacts at Class A. Idempotent. Returns false if any
  /// item failed, so the caller can retry instead of recording completion.
  @discardableResult
  static func protectExistingHealthArtifacts() -> Bool {
    let fileManager = FileManager.default
    var roots: [URL] = []
    if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      roots.append(appSupport.appendingPathComponent("GooseSwift", isDirectory: true))
    }
    if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
      roots.append(documents.appendingPathComponent("GooseSwift", isDirectory: true))
    }
    var succeeded = true
    for root in roots {
      guard fileManager.fileExists(atPath: root.path) else {
        continue
      }
      if apply(backgroundWritable, to: root, artifact: .container) == .failed {
        succeeded = false
      }
      guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
        continue
      }
      for case let url as URL in enumerator {
        let isForegroundOnly = isForegroundOnlyArtifact(url)
        let outcome = apply(
          isForegroundOnly ? foregroundOnly : backgroundWritable,
          to: url,
          artifact: isForegroundOnly ? .validationSidecar : .sweepItem
        )
        if outcome == .failed {
          succeeded = false
        }
      }
    }
    return succeeded
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
        apply(backgroundWritable, to: destination, artifact: .legacyDiagnostic)
      }
    }
  }
}
