import Foundation
import Security
import XCTest

@testable import GooseSwift

/// Migration safety tests for `OnboardingProfilePersistence`.
///
/// These exercise the production source via `@testable import`. The test target
/// is hosted by the app, so the Keychain calls run with the app's bundle
/// identity rather than a bare `xctest` process.
final class OnboardingProfilePersistenceTests: XCTestCase {
  private let keychainService = "com.goose.swift.onboarding"
  private let keychainAccount = "profile"

  private let profileKeys = [
    OnboardingStorage.firstName,
    OnboardingStorage.dateOfBirth,
    OnboardingStorage.unitSystem,
    OnboardingStorage.heightInput,
    OnboardingStorage.heightFeetInput,
    OnboardingStorage.heightInchesInput,
    OnboardingStorage.weightInput,
    OnboardingStorage.gender,
    OnboardingStorage.heightMm,
    OnboardingStorage.weightGrams,
    OnboardingStorage.createdAtUnixMs,
    OnboardingStorage.timezoneID,
    OnboardingStorage.onboardingComplete,
    OnboardingStorage.onboardingRedoRequested,
    OnboardingStorage.persistedState,
  ]

  override func setUp() {
    super.setUp()
    resetStorage()
  }

  override func tearDown() {
    resetStorage()
    super.tearDown()
  }

  // MARK: - Helpers

  private func resetStorage() {
    keychainDelete()
    for key in profileKeys {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }

  private func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
    ]
  }

  @discardableResult
  private func keychainDelete() -> OSStatus {
    SecItemDelete(baseQuery() as CFDictionary)
  }

  private func keychainSeed(_ data: Data, accessible: CFString) {
    keychainDelete()
    var add = baseQuery()
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = accessible
    let status = SecItemAdd(add as CFDictionary, nil)
    XCTAssertEqual(status, errSecSuccess, "Keychain seed failed with \(status)")
  }

  private func keychainData() -> Data? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
      return nil
    }
    return result as? Data
  }

  private func keychainAccessibleAttribute() -> String? {
    var query = baseQuery()
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let attributes = result as? [String: Any] else {
      return nil
    }
    return attributes[kSecAttrAccessible as String] as? String
  }

  private func makeProfile(firstName: String, weightGrams: Int = 70_000) -> OnboardingProfileSnapshot {
    OnboardingProfileSnapshot(
      firstName: firstName,
      dateOfBirthString: "1990-01-01",
      unitSystemRaw: "metric",
      heightInput: "180",
      heightFeetInput: "5",
      heightInchesInput: "11",
      weightInput: "70",
      genderRaw: "female",
      heightMm: 1800,
      weightGrams: weightGrams,
      createdAtUnixMs: 1_700_000_000_000,
      timezoneID: "UTC"
    )
  }

  private func encodedState(firstName: String, complete: Bool = true) -> Data {
    let state = OnboardingPersistedState(
      version: 1,
      onboardingComplete: complete,
      profile: makeProfile(firstName: firstName)
    )
    return try! JSONEncoder().encode(state)
  }

  private func seedIndividualKeys(firstName: String) {
    makeProfile(firstName: firstName).write()
    UserDefaults.standard.set(true, forKey: OnboardingStorage.onboardingComplete)
  }

  private var blob: Data? {
    UserDefaults.standard.data(forKey: OnboardingStorage.persistedState)
  }

  // MARK: - 1. Keychain-first

  func testKeychainIsAuthoritativeWhenSecureStateExists() {
    keychainSeed(encodedState(firstName: "Secure"), accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    UserDefaults.standard.set(encodedState(firstName: "Legacy"), forKey: OnboardingStorage.persistedState)

    let state = OnboardingProfilePersistence.loadState()

    XCTAssertEqual(state?.profile.firstName, "Secure", "Keychain must win over the legacy UserDefaults blob")
  }

  // MARK: - 2. Legacy blob migration

  func testLegacyBlobMigratesToKeychainThenBlobIsRemoved() {
    let legacy = encodedState(firstName: "Legacy")
    UserDefaults.standard.set(legacy, forKey: OnboardingStorage.persistedState)
    XCTAssertNil(keychainData(), "precondition: no secure copy yet")

    let state = OnboardingProfilePersistence.loadState()

    XCTAssertEqual(state?.profile.firstName, "Legacy", "migration must return the legacy state")
    XCTAssertEqual(keychainData(), legacy, "Keychain must hold the migrated bytes")
    XCTAssertNil(blob, "legacy blob must be removed only after the Keychain holds it")
  }

  // MARK: - 3. Fail-safe: blob survives unless the Keychain was verified

  /// The blob is removed only on the migration path, immediately after a
  /// verified read-back. When the Keychain already holds different state the
  /// migration path is never entered and the blob is left untouched.
  ///
  /// Note: forcing `SecItemAdd`/`SecItemUpdate` to fail is not reachable from a
  /// test without adding a seam to production code, so the write-failure branch
  /// of `removePersistedStateDefaultsIfKeychainHolds` is covered by inspection
  /// rather than execution.
  func testBlobIsPreservedWhenMigrationPathIsNotTaken() {
    keychainSeed(encodedState(firstName: "Secure"), accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    let legacy = encodedState(firstName: "Legacy")
    UserDefaults.standard.set(legacy, forKey: OnboardingStorage.persistedState)

    _ = OnboardingProfilePersistence.loadState()

    XCTAssertEqual(blob, legacy, "blob must not be deleted when the migration path was not taken")
  }

  // MARK: - 4. Accessibility class re-asserted on update

  func testSaveReassertsAccessibilityClassOnExistingItem() {
    keychainSeed(encodedState(firstName: "Old"), accessible: kSecAttrAccessibleWhenUnlocked)
    XCTAssertEqual(
      keychainAccessibleAttribute(),
      kSecAttrAccessibleWhenUnlocked as String,
      "precondition: item starts with the weaker class"
    )

    OnboardingProfilePersistence.saveProfile(makeProfile(firstName: "New"), onboardingComplete: true)

    XCTAssertEqual(
      keychainAccessibleAttribute(),
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
      "update path must re-assert AfterFirstUnlockThisDeviceOnly"
    )
  }

  // MARK: - 5. Individual-key fallback

  func testIndividualKeyFallbackReconstructsProfile() {
    seedIndividualKeys(firstName: "Fallback")
    XCTAssertNil(keychainData(), "precondition: no secure copy")
    XCTAssertNil(blob, "precondition: no legacy blob")

    let state = OnboardingProfilePersistence.loadState()

    XCTAssertEqual(state?.profile.firstName, "Fallback", "must reconstruct from individual keys")
    XCTAssertNotNil(keychainData(), "reconstruction must persist into the Keychain")
    XCTAssertNil(blob, "reconstruction must not recreate the legacy blob")
  }

  // MARK: - 6. save() writes securely and clears the duplicate

  func testSaveWritesKeychainAndRemovesDuplicateBlob() {
    UserDefaults.standard.set(encodedState(firstName: "Stale"), forKey: OnboardingStorage.persistedState)

    OnboardingProfilePersistence.saveProfile(makeProfile(firstName: "Saved"), onboardingComplete: false)

    let stored = keychainData()
    XCTAssertNotNil(stored, "save must write the Keychain")
    let decoded = try? JSONDecoder().decode(OnboardingPersistedState.self, from: stored ?? Data())
    XCTAssertEqual(decoded?.profile.firstName, "Saved")
    XCTAssertEqual(decoded?.onboardingComplete, false)
    XCTAssertNil(blob, "duplicate blob must be cleared once the Keychain holds the state")
  }

  // MARK: - 7. Fresh state

  func testFreshStateReturnsNilAndWritesNothing() {
    XCTAssertNil(OnboardingProfilePersistence.loadState(), "no stored profile must yield nil")
    XCTAssertNil(keychainData(), "must not create a Keychain item from nothing")
    XCTAssertNil(blob, "must not create a blob from nothing")
  }

  // MARK: - 8. Idempotence

  func testMigrationIsIdempotentAcrossRepeatedCycles() {
    let legacy = encodedState(firstName: "Repeat")
    UserDefaults.standard.set(legacy, forKey: OnboardingStorage.persistedState)

    for iteration in 0..<5 {
      let state = OnboardingProfilePersistence.loadState()
      XCTAssertEqual(state?.profile.firstName, "Repeat", "iteration \(iteration): state must stay stable")
      XCTAssertEqual(state?.profile.weightGrams, 70_000, "iteration \(iteration): profile must stay stable")
      XCTAssertEqual(state?.onboardingComplete, true, "iteration \(iteration): completion flag must stay stable")

      // Compare decoded state rather than raw bytes: JSONEncoder gives no
      // ordering guarantee across separate encodings of identical values, so
      // byte equality would be testing the encoder, not the migration.
      let stored = keychainData()
      XCTAssertNotNil(stored, "iteration \(iteration): Keychain must hold the state")
      let decoded = stored.flatMap { try? JSONDecoder().decode(OnboardingPersistedState.self, from: $0) }
      XCTAssertEqual(decoded?.profile.firstName, "Repeat", "iteration \(iteration): Keychain content must stay stable")
      XCTAssertNil(blob, "iteration \(iteration): blob must stay removed")

      OnboardingProfilePersistence.saveProfile(makeProfile(firstName: "Repeat"), onboardingComplete: true)
      XCTAssertNil(blob, "iteration \(iteration): save must not resurrect the blob")
    }
  }

  // MARK: - Downgrade safety

  func testIndividualProfileKeysSurviveMigration() {
    seedIndividualKeys(firstName: "Downgrade")
    UserDefaults.standard.set(encodedState(firstName: "Downgrade"), forKey: OnboardingStorage.persistedState)

    _ = OnboardingProfilePersistence.loadState()

    XCTAssertEqual(
      UserDefaults.standard.string(forKey: OnboardingStorage.firstName),
      "Downgrade",
      "individual keys back @AppStorage and downgrade; they must not be removed"
    )
    XCTAssertEqual(UserDefaults.standard.integer(forKey: OnboardingStorage.heightMm), 1800)
  }
}
