import Foundation
import Security

enum OnboardingStorage {
  static let onboardingComplete = "goose.swift.onboardingComplete"
  static let onboardingRedoRequested = "goose.swift.onboardingRedoRequested"
  static let firstName = "goose.swift.profile.firstName"
  static let dateOfBirth = "goose.swift.profile.dateOfBirth"
  static let unitSystem = "goose.swift.profile.unitSystem"
  static let heightInput = "goose.swift.profile.heightInput"
  static let heightFeetInput = "goose.swift.profile.heightFeetInput"
  static let heightInchesInput = "goose.swift.profile.heightInchesInput"
  static let weightInput = "goose.swift.profile.weightInput"
  static let gender = "goose.swift.profile.gender"
  static let heightMm = "goose.swift.profile.heightMm"
  static let weightGrams = "goose.swift.profile.weightGrams"
  static let createdAtUnixMs = "goose.swift.profile.createdAtUnixMs"
  static let timezoneID = "goose.swift.profile.timezoneID"
  static let healthKitPermissionHandled = "goose.swift.permissions.healthKitHandled"
  static let locationPermissionHandled = "goose.swift.permissions.locationHandled"
  static let notificationPermissionHandled = "goose.swift.permissions.notificationHandled"
  static let persistedState = "goose.swift.onboarding.persistedState"
}

struct OnboardingProfileSnapshot: Codable {
  var firstName: String
  var dateOfBirthString: String
  var unitSystemRaw: String
  var heightInput: String
  var heightFeetInput: String
  var heightInchesInput: String
  var weightInput: String
  var genderRaw: String
  var heightMm: Int
  var weightGrams: Int
  var createdAtUnixMs: Int
  var timezoneID: String

  init(
    firstName: String,
    dateOfBirthString: String,
    unitSystemRaw: String,
    heightInput: String,
    heightFeetInput: String,
    heightInchesInput: String,
    weightInput: String,
    genderRaw: String,
    heightMm: Int,
    weightGrams: Int,
    createdAtUnixMs: Int,
    timezoneID: String
  ) {
    self.firstName = firstName
    self.dateOfBirthString = dateOfBirthString
    self.unitSystemRaw = unitSystemRaw
    self.heightInput = heightInput
    self.heightFeetInput = heightFeetInput
    self.heightInchesInput = heightInchesInput
    self.weightInput = weightInput
    self.genderRaw = genderRaw
    self.heightMm = heightMm
    self.weightGrams = weightGrams
    self.createdAtUnixMs = createdAtUnixMs
    self.timezoneID = timezoneID
  }

  init(defaults: UserDefaults = .standard) {
    firstName = defaults.string(forKey: OnboardingStorage.firstName) ?? ""
    dateOfBirthString = defaults.string(forKey: OnboardingStorage.dateOfBirth) ?? ""
    unitSystemRaw = defaults.string(forKey: OnboardingStorage.unitSystem) ?? "imperial"
    heightInput = defaults.string(forKey: OnboardingStorage.heightInput) ?? ""
    heightFeetInput = defaults.string(forKey: OnboardingStorage.heightFeetInput) ?? ""
    heightInchesInput = defaults.string(forKey: OnboardingStorage.heightInchesInput) ?? ""
    weightInput = defaults.string(forKey: OnboardingStorage.weightInput) ?? ""
    genderRaw = defaults.string(forKey: OnboardingStorage.gender) ?? ""
    heightMm = defaults.integer(forKey: OnboardingStorage.heightMm)
    weightGrams = defaults.integer(forKey: OnboardingStorage.weightGrams)
    createdAtUnixMs = defaults.integer(forKey: OnboardingStorage.createdAtUnixMs)
    timezoneID = defaults.string(forKey: OnboardingStorage.timezoneID) ?? ""
  }

  var hasRequiredDetails: Bool {
    !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !dateOfBirthString.isEmpty
      && !genderRaw.isEmpty
      && heightMm > 0
      && weightGrams > 0
  }

  func write(to defaults: UserDefaults = .standard) {
    defaults.set(firstName, forKey: OnboardingStorage.firstName)
    defaults.set(dateOfBirthString, forKey: OnboardingStorage.dateOfBirth)
    defaults.set(unitSystemRaw, forKey: OnboardingStorage.unitSystem)
    defaults.set(heightInput, forKey: OnboardingStorage.heightInput)
    defaults.set(heightFeetInput, forKey: OnboardingStorage.heightFeetInput)
    defaults.set(heightInchesInput, forKey: OnboardingStorage.heightInchesInput)
    defaults.set(weightInput, forKey: OnboardingStorage.weightInput)
    defaults.set(genderRaw, forKey: OnboardingStorage.gender)
    defaults.set(heightMm, forKey: OnboardingStorage.heightMm)
    defaults.set(weightGrams, forKey: OnboardingStorage.weightGrams)
    defaults.set(createdAtUnixMs, forKey: OnboardingStorage.createdAtUnixMs)
    defaults.set(timezoneID, forKey: OnboardingStorage.timezoneID)
  }
}

struct OnboardingPersistedState: Codable {
  var version: Int
  var onboardingComplete: Bool
  var profile: OnboardingProfileSnapshot
}

enum OnboardingProfilePersistence {
  private static let keychainService = "com.goose.swift.onboarding"
  private static let keychainAccount = "profile"

  /// Keychain is authoritative. The Keychain item is
  /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so unlike the previous
  /// UserDefaults blob it does not ride a device backup onto a new device.
  ///
  /// The individual `goose.swift.profile.*` keys are deliberately left in
  /// UserDefaults: they back the `@AppStorage` bindings used by onboarding and
  /// profile editing, and they keep a downgrade to an older build working.
  static func loadState() -> OnboardingPersistedState? {
    if let data = readKeychainData(),
       let state = try? JSONDecoder().decode(OnboardingPersistedState.self, from: data) {
      return state
    }
    // Migrate a blob written by an earlier build: copy it into the Keychain
    // first, confirm it reads back, and only then drop the duplicate.
    if let data = UserDefaults.standard.data(forKey: OnboardingStorage.persistedState),
       let state = try? JSONDecoder().decode(OnboardingPersistedState.self, from: data) {
      writeKeychainData(data)
      removePersistedStateDefaultsIfKeychainHolds(data)
      return state
    }
    return legacyStateFromDefaults()
  }

  @discardableResult
  static func restoreIntoDefaultsIfAvailable(restoreCompletion: Bool) -> OnboardingPersistedState? {
    guard let state = loadState(), state.profile.hasRequiredDetails else {
      return nil
    }
    state.profile.write()
    if restoreCompletion, state.onboardingComplete {
      UserDefaults.standard.set(true, forKey: OnboardingStorage.onboardingComplete)
      UserDefaults.standard.set(false, forKey: OnboardingStorage.onboardingRedoRequested)
    }
    return state
  }

  static func saveProfile(_ profile: OnboardingProfileSnapshot, onboardingComplete: Bool) {
    profile.write()
    save(
      OnboardingPersistedState(
        version: 1,
        onboardingComplete: onboardingComplete,
        profile: profile
      )
    )
  }

  static func saveProfileFromDefaults(onboardingComplete: Bool) {
    let profile = OnboardingProfileSnapshot()
    guard profile.hasRequiredDetails else {
      return
    }
    saveProfile(profile, onboardingComplete: onboardingComplete)
  }

  static func markCompleteFromDefaults() {
    UserDefaults.standard.set(true, forKey: OnboardingStorage.onboardingComplete)
    UserDefaults.standard.set(false, forKey: OnboardingStorage.onboardingRedoRequested)
    saveProfileFromDefaults(onboardingComplete: true)
  }

  static func requestRedoFromDefaults() {
    UserDefaults.standard.set(false, forKey: OnboardingStorage.onboardingComplete)
    UserDefaults.standard.set(true, forKey: OnboardingStorage.onboardingRedoRequested)
    let profile = OnboardingProfileSnapshot()
    if profile.hasRequiredDetails {
      saveProfile(profile, onboardingComplete: false)
    }
  }

  private static func save(_ state: OnboardingPersistedState) {
    guard let data = try? JSONEncoder().encode(state) else {
      return
    }
    writeKeychainData(data)
    removePersistedStateDefaultsIfKeychainHolds(data)
  }

  /// Drops the legacy UserDefaults blob only once the Keychain is confirmed to
  /// hold the same bytes. If the Keychain write failed the duplicate is kept,
  /// so no path can delete the only copy of the profile.
  private static func removePersistedStateDefaultsIfKeychainHolds(_ data: Data) {
    guard readKeychainData() == data else {
      return
    }
    UserDefaults.standard.removeObject(forKey: OnboardingStorage.persistedState)
  }

  private static func legacyStateFromDefaults() -> OnboardingPersistedState? {
    let profile = OnboardingProfileSnapshot()
    guard profile.hasRequiredDetails else {
      return nil
    }
    let state = OnboardingPersistedState(
      version: 1,
      onboardingComplete: UserDefaults.standard.bool(forKey: OnboardingStorage.onboardingComplete),
      profile: profile
    )
    save(state)
    return state
  }

  private static func keychainQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
    ]
  }

  private static func readKeychainData() -> Data? {
    var query = keychainQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else {
      return nil
    }
    return result as? Data
  }

  private static func writeKeychainData(_ data: Data) {
    let query = keychainQuery()
    // Re-assert the accessibility class on update so an item created by an
    // older build cannot retain a weaker class.
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var addQuery = query
      addQuery[kSecValueData as String] = data
      addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      SecItemAdd(addQuery as CFDictionary, nil)
    }
  }
}
