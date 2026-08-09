import Foundation
import CryptoKit
import SwiftUI
import UIKit

#if canImport(HealthKit)
import HealthKit
#endif

extension GooseLocalDataExporter {
  static func validate(
    exportedRelativePaths: [String],
    requiredOvernightSessionID: String?,
    documentsDirectory: URL,
    fileManager: FileManager
  ) -> GooseLocalDataExportValidation {
    let pathSet = Set(exportedRelativePaths)
    let exportSelfIncluded = exportedRelativePaths.contains { path in
      path == "Documents/GooseSwift/Exports" || path.hasPrefix("Documents/GooseSwift/Exports/")
    }

    let rawNotificationsIncluded: Bool
    let historicalRangePollsIncluded: Bool
    let commandWritesIncluded: Bool
    let overnightEventLogIncluded: Bool
    let checkpointsIncluded: Bool
    let checkpointLatestIncluded: Bool
    let manifestIncluded: Bool
    var manifestSessionMatches = false
    var manifestFinalized = false
    let statusIncluded: Bool
    var statusSessionMatches = false
    var statusFinalized = false
    let crashMarkerIncluded: Bool
    var crashMarkerJSONValid = false
    var crashMarkerSessionMatches = false
    var crashMarkerFinalized = false
    let sqliteDatabasePath = defaultDatabasePath()
    let sqliteDatabaseIncluded = pathSet.contains("Application Support/GooseSwift/goose.sqlite")
    let bleLogURLs = includedBLELogURLs(pathSet: pathSet, documentsDirectory: documentsDirectory, fileManager: fileManager)
    let bleLogIncluded = !bleLogURLs.isEmpty
    let bleLogByteCount = currentBLELogByteCount(logURLs: bleLogURLs, fileManager: fileManager)
    let bleLogSessionIDFound = requiredOvernightSessionID.map {
      currentBLELogContains(
        sessionID: $0,
        logURLs: bleLogURLs,
        fileManager: fileManager
      )
    } ?? false
    let bleLiveLogRelativePath = "Application Support/GooseSwift/goose-ble-live.log"
    let bleLiveLogURL = (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory)
      .appendingPathComponent("GooseSwift", isDirectory: true)
      .appendingPathComponent("goose-ble-live.log")
    let bleLiveLogIncluded = pathSet.contains(bleLiveLogRelativePath)
    let bleLiveLogByteCount = bleLiveLogIncluded
      ? fileByteCount(at: bleLiveLogURL, fileManager: fileManager)
      : 0
    let bleLiveLogSessionIDFound = requiredOvernightSessionID.map { sessionID in
      bleLiveLogIncluded && fileContainsUTF8Needle(at: bleLiveLogURL, needle: sessionID, fileManager: fileManager)
    } ?? false
    var sqliteDatabaseExists = false
    var sqliteDatabaseOpenable = false
    var sqliteStorageCheckPassed = false
    var metrics = GooseOvernightExportMetrics()
    var issues: [String] = []

    validateSQLiteDatabase(
      path: sqliteDatabasePath,
      included: sqliteDatabaseIncluded,
      exists: &sqliteDatabaseExists,
      openable: &sqliteDatabaseOpenable,
      storageCheckPassed: &sqliteStorageCheckPassed,
      issues: &issues
    )

    if let requiredOvernightSessionID {
      let base = "Documents/GooseSwift/OvernightGuard/\(requiredOvernightSessionID)/"
      let sessionDirectory = documentsDirectory
        .appendingPathComponent("GooseSwift", isDirectory: true)
        .appendingPathComponent("OvernightGuard", isDirectory: true)
        .appendingPathComponent(requiredOvernightSessionID, isDirectory: true)
      let rawNotificationsURL = sessionDirectory.appendingPathComponent("raw-notifications.jsonl")
      let historicalRangePollsURL = sessionDirectory.appendingPathComponent("historical-range-polls.jsonl")
      let commandWritesURL = sessionDirectory.appendingPathComponent("command-writes.jsonl")
      let eventLogURL = sessionDirectory.appendingPathComponent("event-log.jsonl")
      let checkpointsURL = sessionDirectory.appendingPathComponent("checkpoints.jsonl")
      let checkpointLatestURL = sessionDirectory.appendingPathComponent("checkpoint-latest.json")
      let manifestURL = sessionDirectory.appendingPathComponent("manifest.json")
      let statusURL = sessionDirectory.appendingPathComponent("status.txt")
      let crashMarkerURL = sessionDirectory.appendingPathComponent("crash-marker.json")
      rawNotificationsIncluded = pathSet.contains(base + "raw-notifications.jsonl")
      historicalRangePollsIncluded = pathSet.contains(base + "historical-range-polls.jsonl")
      commandWritesIncluded = pathSet.contains(base + "command-writes.jsonl")
      overnightEventLogIncluded = pathSet.contains(base + "event-log.jsonl")
      checkpointsIncluded = pathSet.contains(base + "checkpoints.jsonl")
      checkpointLatestIncluded = pathSet.contains(base + "checkpoint-latest.json")
      manifestIncluded = pathSet.contains(base + "manifest.json")
      statusIncluded = pathSet.contains(base + "status.txt")
      crashMarkerIncluded = pathSet.contains(base + "crash-marker.json")
      if !rawNotificationsIncluded {
        issues.append("missing raw-notifications.jsonl")
      }
      if !historicalRangePollsIncluded {
        issues.append("missing historical-range-polls.jsonl")
      }
      if !commandWritesIncluded {
        issues.append("missing command-writes.jsonl")
      }
      if !overnightEventLogIncluded {
        issues.append("missing event-log.jsonl")
      }
      if !checkpointsIncluded {
        issues.append("missing checkpoints.jsonl")
      }
      if !checkpointLatestIncluded {
        issues.append("missing checkpoint-latest.json")
      }
      if !manifestIncluded {
        issues.append("missing manifest.json")
      }
      if !statusIncluded {
        issues.append("missing status.txt")
      }
      if !crashMarkerIncluded {
        issues.append("missing crash-marker.json")
      }
      if fileManager.fileExists(atPath: statusURL.path) {
        validateOvernightStatusFile(
          from: statusURL,
          expectedSessionID: requiredOvernightSessionID,
          to: &metrics,
          sessionMatches: &statusSessionMatches,
          finalized: &statusFinalized,
          issues: &issues
        )
      }
      if fileManager.fileExists(atPath: crashMarkerURL.path) {
        validateCrashMarker(
          from: crashMarkerURL,
          expectedSessionID: requiredOvernightSessionID,
          to: &metrics,
          jsonValid: &crashMarkerJSONValid,
          sessionMatches: &crashMarkerSessionMatches,
          finalized: &crashMarkerFinalized,
          issues: &issues
        )
      }
      if fileManager.fileExists(atPath: manifestURL.path) {
        applyManifestMetrics(
          from: manifestURL,
          expectedSessionID: requiredOvernightSessionID,
          to: &metrics,
          sessionMatches: &manifestSessionMatches,
          finalized: &manifestFinalized,
          issues: &issues
        )
      }
      if fileManager.fileExists(atPath: rawNotificationsURL.path) {
        applyRawNotificationMetrics(from: rawNotificationsURL, to: &metrics)
        if metrics.rawNotificationCount == 0 {
          issues.append("raw-notifications.jsonl has no records")
        }
        if metrics.rawNotificationValueHexInvalidCount > 0 {
          issues.append("raw-notifications.jsonl has \(metrics.rawNotificationValueHexInvalidCount) records with invalid value_hex/frame_hex")
        }
        if metrics.rawNotificationChecksumMismatchCount > 0 {
          issues.append("raw-notifications.jsonl has \(metrics.rawNotificationChecksumMismatchCount) SHA-256 mismatches")
        }
        if metrics.rawNotificationParseErrorCount > 0 {
          issues.append("raw-notifications.jsonl has \(metrics.rawNotificationParseErrorCount) parse errors")
        }
      }
      if fileManager.fileExists(atPath: historicalRangePollsURL.path) {
        applyHistoricalRangeMetrics(from: historicalRangePollsURL, to: &metrics)
        if metrics.historicalRangePollRecordCount == 0 {
          issues.append("historical-range-polls.jsonl has no records")
        }
        if metrics.successfulHistoricalRangePollCount == 0 {
          issues.append("historical-range-polls.jsonl has no successful GET_DATA_RANGE response")
        }
        if metrics.historicalRangeHexInvalidCount > 0 {
          issues.append("historical-range-polls.jsonl has \(metrics.historicalRangeHexInvalidCount) records with invalid raw_payload_hex/raw_body_hex")
        }
        if metrics.historicalRangeChecksumMismatchCount > 0 {
          issues.append("historical-range-polls.jsonl has \(metrics.historicalRangeChecksumMismatchCount) SHA-256 mismatches")
        }
        if metrics.historicalRangePollParseErrorCount > 0 {
          issues.append("historical-range-polls.jsonl has \(metrics.historicalRangePollParseErrorCount) parse errors")
        }
      }
      if fileManager.fileExists(atPath: commandWritesURL.path) {
        applyCommandWriteMetrics(from: commandWritesURL, to: &metrics)
        if metrics.commandWriteRecordCount == 0 {
          issues.append("command-writes.jsonl has no records")
        }
        if metrics.commandWriteHexInvalidCount > 0 {
          issues.append("command-writes.jsonl has \(metrics.commandWriteHexInvalidCount) records with invalid payload_hex/frame_hex")
        }
        if metrics.commandWriteChecksumMissingCount > 0 {
          issues.append("command-writes.jsonl has \(metrics.commandWriteChecksumMissingCount) records without SHA-256 checksums")
        }
        if metrics.commandWriteChecksumMismatchCount > 0 {
          issues.append("command-writes.jsonl has \(metrics.commandWriteChecksumMismatchCount) SHA-256 mismatches")
        }
        if metrics.commandWriteParseErrorCount > 0 {
          issues.append("command-writes.jsonl has \(metrics.commandWriteParseErrorCount) parse errors")
        }
      }
      if fileManager.fileExists(atPath: eventLogURL.path) {
        applyEventLogMetrics(from: eventLogURL, to: &metrics)
        if metrics.overnightEventLogRecordCount == 0 {
          issues.append("event-log.jsonl has no records")
        }
        if metrics.overnightEventLogParseErrorCount > 0 {
          issues.append("event-log.jsonl has \(metrics.overnightEventLogParseErrorCount) parse errors")
        }
      }
      if fileManager.fileExists(atPath: checkpointsURL.path),
         fileByteCount(at: checkpointsURL, fileManager: fileManager) == 0 {
        issues.append("checkpoints.jsonl has no records")
      }
      if fileManager.fileExists(atPath: checkpointLatestURL.path),
         fileByteCount(at: checkpointLatestURL, fileManager: fileManager) == 0 {
        issues.append("checkpoint-latest.json is empty")
      }
      applySQLiteMirrorMetrics(
        databasePath: sqliteDatabasePath,
        sessionID: requiredOvernightSessionID,
        to: &metrics,
        issues: &issues
      )
    } else {
      rawNotificationsIncluded = false
      historicalRangePollsIncluded = false
      commandWritesIncluded = false
      overnightEventLogIncluded = false
      checkpointsIncluded = false
      checkpointLatestIncluded = false
      manifestIncluded = false
      manifestSessionMatches = false
      manifestFinalized = false
      statusIncluded = false
      statusSessionMatches = false
      statusFinalized = false
      crashMarkerIncluded = false
      crashMarkerJSONValid = false
      crashMarkerSessionMatches = false
      crashMarkerFinalized = false
    }

    if exportSelfIncluded {
      issues.append("export contains files from Documents/GooseSwift/Exports")
    }
    if requiredOvernightSessionID != nil, !bleLogIncluded {
      issues.append("missing BLE log side channel")
    }
    if requiredOvernightSessionID != nil, bleLogIncluded, bleLogByteCount == 0 {
      issues.append("BLE log side channel is empty")
    }
    if requiredOvernightSessionID != nil, bleLogIncluded, bleLogByteCount > 0, !bleLogSessionIDFound {
      issues.append("BLE log side channel does not contain current overnight session ID")
    }
    if requiredOvernightSessionID != nil, GooseDiagnosticsPolicy.loggingEnabled, !bleLiveLogIncluded {
      issues.append("missing always-on BLE live log side channel")
    }
    if requiredOvernightSessionID != nil, bleLiveLogIncluded, bleLiveLogByteCount == 0 {
      issues.append("always-on BLE live log side channel is empty")
    }
    if requiredOvernightSessionID != nil, bleLiveLogIncluded, bleLiveLogByteCount > 0, !bleLiveLogSessionIDFound {
      issues.append("always-on BLE live log side channel does not contain current overnight session ID")
    }

    return GooseLocalDataExportValidation(
      requiredOvernightSessionID: requiredOvernightSessionID,
      bundleJSONValid: false,
      bundleJSONValidationError: "not checked",
      rawNotificationsIncluded: rawNotificationsIncluded,
      historicalRangePollsIncluded: historicalRangePollsIncluded,
      commandWritesIncluded: commandWritesIncluded,
      overnightEventLogIncluded: overnightEventLogIncluded,
      checkpointsIncluded: checkpointsIncluded,
      checkpointLatestIncluded: checkpointLatestIncluded,
      manifestIncluded: manifestIncluded,
      manifestSessionMatches: manifestSessionMatches,
      manifestFinalized: manifestFinalized,
      statusIncluded: statusIncluded,
      statusSessionMatches: statusSessionMatches,
      statusFinalized: statusFinalized,
      crashMarkerIncluded: crashMarkerIncluded,
      crashMarkerJSONValid: crashMarkerJSONValid,
      crashMarkerSessionMatches: crashMarkerSessionMatches,
      crashMarkerFinalized: crashMarkerFinalized,
      exportSelfIncluded: exportSelfIncluded,
      sqliteDatabaseIncluded: sqliteDatabaseIncluded,
      sqliteDatabaseExists: sqliteDatabaseExists,
      sqliteDatabaseOpenable: sqliteDatabaseOpenable,
      sqliteStorageCheckPassed: sqliteStorageCheckPassed,
      sqliteDatabasePath: sqliteDatabasePath,
      sqliteMirrorSessionExists: metrics.sqliteMirrorSessionExists,
      sqliteMirrorRawNotificationCount: metrics.sqliteMirrorRawNotificationCount,
      sqliteMirrorHistoricalRangePollCount: metrics.sqliteMirrorHistoricalRangePollCount,
      sqliteMirrorSuccessfulHistoricalRangePollCount: metrics.sqliteMirrorSuccessfulHistoricalRangePollCount,
      bleLogIncluded: bleLogIncluded,
      bleLogByteCount: bleLogByteCount,
      bleLogSessionIDFound: bleLogSessionIDFound,
      bleLiveLogIncluded: bleLiveLogIncluded,
      bleLiveLogByteCount: bleLiveLogByteCount,
      bleLiveLogSessionIDFound: bleLiveLogSessionIDFound,
      rawNotificationCount: metrics.rawNotificationCount,
      historicalRangePollRecordCount: metrics.historicalRangePollRecordCount,
      successfulHistoricalRangePollCount: metrics.successfulHistoricalRangePollCount,
      commandWriteRecordCount: metrics.commandWriteRecordCount,
      commandWriteChecksumPresentCount: metrics.commandWriteChecksumPresentCount,
      commandWriteChecksumMissingCount: metrics.commandWriteChecksumMissingCount,
      commandWriteChecksumMismatchCount: metrics.commandWriteChecksumMismatchCount,
      commandWriteHexInvalidCount: metrics.commandWriteHexInvalidCount,
      commandWriteParseErrorCount: metrics.commandWriteParseErrorCount,
      historicalPacketCount: metrics.historicalPacketCount,
      k18Count: metrics.k18Count,
      k24Count: metrics.k24Count,
      k25Count: metrics.k25Count,
      k26Count: metrics.k26Count,
      packet47Count: metrics.packet47Count,
      event17Count: metrics.event17Count,
      event29Count: metrics.event29Count,
      metadata49Count: metrics.metadata49Count,
      metadata56Count: metrics.metadata56Count,
      firstRawNotificationAt: metrics.firstRawNotificationAt,
      lastRawNotificationAt: metrics.lastRawNotificationAt,
      maxRawNotificationGapSeconds: metrics.maxRawNotificationGapSeconds,
      rawNotificationGapsOver5Minutes: metrics.rawNotificationGapsOver5Minutes,
      rawNotificationChecksumPresentCount: metrics.rawNotificationChecksumPresentCount,
      rawNotificationChecksumMissingCount: metrics.rawNotificationChecksumMissingCount,
      rawNotificationChecksumMismatchCount: metrics.rawNotificationChecksumMismatchCount,
      rawNotificationValueHexInvalidCount: metrics.rawNotificationValueHexInvalidCount,
      rawNotificationParseErrorCount: metrics.rawNotificationParseErrorCount,
      historicalRangeChecksumPresentCount: metrics.historicalRangeChecksumPresentCount,
      historicalRangeChecksumMissingCount: metrics.historicalRangeChecksumMissingCount,
      historicalRangeChecksumMismatchCount: metrics.historicalRangeChecksumMismatchCount,
      historicalRangeHexInvalidCount: metrics.historicalRangeHexInvalidCount,
      historicalRangePollParseErrorCount: metrics.historicalRangePollParseErrorCount,
      overnightEventLogRecordCount: metrics.overnightEventLogRecordCount,
      overnightEventLogParseErrorCount: metrics.overnightEventLogParseErrorCount,
      proofSidecarWarningCount: metrics.proofSidecarWarningCount,
      proofSidecarWarnings: metrics.proofSidecarWarnings,
      issues: issues
    )
    }

}
