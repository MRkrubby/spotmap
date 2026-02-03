import Foundation
import Combine
import CoreLocation
import CloudKit
#if canImport(Security)
import Security
import CoreFoundation
import Darwin
#endif

// MARK: - Friends (Life360-style, CloudKit prototype)

struct FriendProfile: Identifiable, Hashable, Codable {
    var id: String { code }
    var code: String
    var displayName: String
    var lastLat: Double?
    var lastLon: Double?
    var updatedAt: Date?
    var lastJourneyZlib: Data?   // compressed polyline points (JourneyPoint array)

    var coordinate: CLLocationCoordinate2D? {
        guard let lastLat, let lastLon else { return nil }
        return .init(latitude: lastLat, longitude: lastLon)
    }
}

/// Friends data store (Life360-style, CloudKit prototype).
///
/// Named `FriendsStore` (instead of `FriendsRepository`) to avoid symbol clashes
/// if a project or dependency also defines a `FriendsRepository` type.
final class FriendsStore: ObservableObject {
    enum FriendsStoreError: LocalizedError {
        case cloudKitNotAvailable(String)

        var errorDescription: String? {
            switch self {
            case .cloudKitNotAvailable(let message):
                return message
            }
        }
    }

    @Published private(set) var me: FriendProfile
    @Published private(set) var friends: [FriendProfile] = []
    @Published var isEnabled: Bool = true
    @Published var lastError: String? = nil

    private let meKey = "Friends.me.v1"
    private let followingKey = "Friends.following.v1"
    private let lastJourneyDirectoryName = "Friends"
    private var lastSavedJourneyZlib: Data? = nil
    private var refreshTask: Task<Void, Never>? = nil

    // Lazily created. This avoids touching CloudKit at app launch on setups
    // where the iCloud/CloudKit capability isn't configured yet.
    private var container: CKContainer? = nil
    private var db: CKDatabase? { container?.publicCloudDatabase }

    init() {
        // Load or create profile
        if let data = UserDefaults.standard.data(forKey: meKey),
           let saved = try? JSONDecoder().decode(FriendProfile.self, from: data) {
            self.me = saved
        } else {
            let code = String(UUID().uuidString.prefix(8)).uppercased()
            self.me = FriendProfile(code: code, displayName: "Ik", lastLat: nil, lastLon: nil, updatedAt: nil, lastJourneyZlib: nil)
            persistMe()
        }
        loadLastJourneyZlib()
        loadFollowing()
    }

    func setDisplayName(_ name: String) {
        me.displayName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Ik" : name
        persistMe()
        // Caller decides whether to publish (prevents unintended CloudKit calls on launch).
    }

    func myCode() -> String { me.code }

    func follow(code: String) {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard c.count >= 6 else { return }
        var set = followingCodes()
        set.insert(c)
        saveFollowing(set)
        Task { await refreshFriends() }
    }

    func unfollow(code: String) {
        var set = followingCodes()
        set.remove(code.uppercased())
        saveFollowing(set)
        friends.removeAll { $0.code.uppercased() == code.uppercased() }
    }

    func updateMyLocation(_ location: CLLocation) {
        me.lastLat = location.coordinate.latitude
        me.lastLon = location.coordinate.longitude
        me.updatedAt = Date()
        persistMe()
    }

    func updateMyLastJourney(_ journey: JourneyRecord?) {
        guard let journey else { return }
        // Store compressed points so friends can render your last route
        let raw = (try? JSONEncoder().encode(journey.decodedPoints())) ?? Data()
        let zipped = (try? JourneyCompression.compress(raw)) ?? raw
        guard me.lastJourneyZlib != zipped else { return }
        me.lastJourneyZlib = zipped
        me.updatedAt = Date()
        persistLastJourneyZlib()
        persistMe()
    }

    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshFriends()
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func publish() async {
        guard isEnabled else { return }
        do {
            setLastError(nil)
            try await ensureCloudKitAvailable()

            guard let db else {
                throw NSError(domain: "FriendsStore", code: -10, userInfo: [NSLocalizedDescriptionKey: "CloudKit database unavailable"])
            }

            let recordID = CKRecord.ID(recordName: "friend-\(me.code)")
            let record = CKRecord(recordType: "FriendProfile", recordID: recordID)
            record["code"] = me.code as CKRecordValue
            record["displayName"] = me.displayName as CKRecordValue
            if let lat = me.lastLat, let lon = me.lastLon {
                record["location"] = CLLocation(latitude: lat, longitude: lon) as CKRecordValue
            }
            if let updatedAt = me.updatedAt {
                record["updatedAt"] = updatedAt as CKRecordValue
            }
            if let data = me.lastJourneyZlib {
                record["lastJourneyZlib"] = data as CKRecordValue
            }
            _ = try await db.save(record)
        } catch {
            setLastError(error.localizedDescription)
            disableIfEntitlementOrAccountIssue(error)
        }
    }

    func refreshFriends() async {
        guard isEnabled else { return }
        do {
            setLastError(nil)
            try await ensureCloudKitAvailable()

            guard let db else {
                throw NSError(domain: "FriendsStore", code: -10, userInfo: [NSLocalizedDescriptionKey: "CloudKit database unavailable"])
            }

            let codes = Array(followingCodes())
            guard !codes.isEmpty else {
                setFriends([])
                return
            }

            let recordIDs = codes.map { CKRecord.ID(recordName: "friend-\($0)") }
            let existingByCode = Dictionary(uniqueKeysWithValues: friends.map { ($0.code.uppercased(), $0) })
            let fetchResult = try await fetchFriendRecords(recordIDs, from: db)
            var loadedByCode: [String: FriendProfile] = [:]
            for record in fetchResult.records.values {
                let profile = Self.decode(record)
                loadedByCode[profile.code.uppercased()] = profile
            }
            if !fetchResult.failures.isEmpty {
                setLastError("Some friends could not be refreshed.")
            }

            var merged: [FriendProfile] = []
            for code in codes.map({ $0.uppercased() }) {
                if let updated = loadedByCode[code] {
                    merged.append(updated)
                } else if let existing = existingByCode[code] {
                    merged.append(existing)
                }
            }
            let sorted = merged.sorted(by: { $0.displayName < $1.displayName })
            setFriends(sorted)
        } catch {
            setLastError(error.localizedDescription)
            disableIfEntitlementOrAccountIssue(error)
        }
    }

    private func loadFollowing() {
        // ensure stored format
        _ = followingCodes()
    }

    private func followingCodes() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: followingKey),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }

    private func saveFollowing(_ set: Set<String>) {
        let arr = Array(set)
        if let data = try? JSONEncoder().encode(arr) {
            UserDefaults.standard.set(data, forKey: followingKey)
        }
    }

    private func persistMe() {
        var snapshot = me
        snapshot.lastJourneyZlib = nil
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: meKey)
        }
    }

    private func loadLastJourneyZlib() {
        guard let url = lastJourneyURL(for: me.code) else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        me.lastJourneyZlib = data
        lastSavedJourneyZlib = data
    }

    private func persistLastJourneyZlib() {
        guard let url = lastJourneyURL(for: me.code) else { return }
        guard let data = me.lastJourneyZlib else { return }
        guard data != lastSavedJourneyZlib else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try data.write(to: url, options: [.atomic])
            lastSavedJourneyZlib = data
        } catch {
            // Ignore persistence failures; keep in-memory copy.
        }
    }

    private func lastJourneyURL(for code: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent(lastJourneyDirectoryName, isDirectory: true)
        return directory.appendingPathComponent("last-journey-\(code).zlib")
    }

    @MainActor
    private func setLastError(_ message: String?) {
        lastError = message
    }

    @MainActor
    private func setFriends(_ values: [FriendProfile]) {
        friends = values
    }

    private func ensureCloudKitAvailable() async throws {
        // 1) Entitlement check (fast, local)
        guard Self.hasCloudKitEntitlement() else {
            throw FriendsStoreError.cloudKitNotAvailable(
                "CloudKit entitlement ontbreekt. Zet iCloud → CloudKit aan in Signing & Capabilities."
            )
        }

        // Create container lazily. If the capability isn't configured, calls below
        // will throw, but we won't crash at app launch.
        if container == nil {
            container = CKContainer.default()
        }
        guard let container else {
            throw FriendsStoreError.cloudKitNotAvailable("CloudKit container unavailable.")
        }

        let status = try await container.accountStatus()
        try ensureAccountStatusOK(status)
    }

    @MainActor
    private func disableIfEntitlementOrAccountIssue(_ error: Error) {
        // If CloudKit isn't configured or the user isn't signed in, keep the app stable
        // by disabling the feature and stopping background refresh.
        if error is FriendsStoreError {
            isEnabled = false
            stopAutoRefresh()
            return
        }
        if let ck = error as? CKError {
            switch ck.code {
            case .notAuthenticated, .permissionFailure:
                isEnabled = false
                stopAutoRefresh()
            default:
                break
            }
        }
    }

    private func fetchFriendRecords(
        _ recordIDs: [CKRecord.ID],
        from database: CKDatabase
    ) async throws -> (records: [CKRecord.ID: CKRecord], failures: [CKRecord.ID: Error]) {
        try await withCheckedThrowingContinuation { continuation in
            var recordsByID: [CKRecord.ID: CKRecord] = [:]
            var failures: [CKRecord.ID: Error] = [:]
            let operation = CKFetchRecordsOperation(recordIDs: recordIDs)
            operation.perRecordResultBlock = { recordID, result in
                switch result {
                case .success(let record):
                    recordsByID[recordID] = record
                case .failure(let error):
                    failures[recordID] = error
                }
            }
            operation.fetchRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: (recordsByID, failures))
                case .failure(let error):
                    if let ckError = error as? CKError, ckError.code == .partialFailure {
                        if let partialErrors = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [CKRecord.ID: Error] {
                            for (recordID, partialError) in partialErrors {
                                failures[recordID] = partialError
                            }
                        }
                        continuation.resume(returning: (recordsByID, failures))
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
            database.add(operation)
        }
    }

    private static func decode(_ record: CKRecord) -> FriendProfile {
        let code = (record["code"] as? String) ?? record.recordID.recordName.replacingOccurrences(of: "friend-", with: "")
        let name = (record["displayName"] as? String) ?? "Friend"
        let loc = record["location"] as? CLLocation
        let updatedAt = record["updatedAt"] as? Date
        let data = record["lastJourneyZlib"] as? Data
        return FriendProfile(code: code, displayName: name,
                             lastLat: loc?.coordinate.latitude, lastLon: loc?.coordinate.longitude,
                             updatedAt: updatedAt, lastJourneyZlib: data)
    }

    private static func hasCloudKitEntitlement() -> Bool {
#if canImport(Security)
        // Dynamically look up SecTask symbols to avoid compile-time dependency on platforms where they're unavailable.
        // If unavailable at runtime, return false and let account status gating handle UX.
        typealias SecTaskRef = CFTypeRef
        typealias SecTaskCreateFromSelfFn = @convention(c) (CFAllocator?) -> SecTaskRef?
        typealias SecTaskCopyValueForEntitlementFn = @convention(c) (SecTaskRef, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> CFTypeRef?

        // Resolve symbols using dlsym to prevent hard references on unsupported platforms.
        guard let handle = dlopen(nil, RTLD_NOW) else { return false }
        defer { dlclose(handle) }

        guard let createSym = dlsym(handle, "SecTaskCreateFromSelf"),
              let copySym = dlsym(handle, "SecTaskCopyValueForEntitlement") else {
            return false
        }
        let SecTaskCreateFromSelf = unsafeBitCast(createSym, to: SecTaskCreateFromSelfFn.self)
        let SecTaskCopyValueForEntitlement = unsafeBitCast(copySym, to: SecTaskCopyValueForEntitlementFn.self)

        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else { return false }
        let key: CFString = "com.apple.developer.icloud-services" as CFString
        let value: CFTypeRef? = SecTaskCopyValueForEntitlement(task, key, nil)
        guard let value else { return false }

        // Handle both array and string representations defensively.
        if CFGetTypeID(value) == CFArrayGetTypeID(),
           let arr = value as? [Any] {
            return arr.contains { item in
                guard let s = item as? String else { return false }
                return s == "CloudKit" || s == "CloudKit-Anonymous"
            }
        }

        if let s = value as? String {
            return s == "CloudKit" || s == "CloudKit-Anonymous"
        }

        return false
#else
        // If Security framework isn't available (e.g., certain platforms),
        // fall back to assuming CloudKit entitlement might be present. The
        // subsequent CloudKit account status check will still gate usage.
        return true
#endif
    }

    private func ensureAccountStatusOK(_ status: CKAccountStatus) throws {
        switch status {
        case .available:
            return
        case .noAccount:
            throw FriendsStoreError.cloudKitNotAvailable("Geen iCloud account ingelogd op dit apparaat.")
        case .restricted:
            throw FriendsStoreError.cloudKitNotAvailable("iCloud is restricted op dit apparaat.")
        case .temporarilyUnavailable:
            throw FriendsStoreError.cloudKitNotAvailable("iCloud is tijdelijk niet beschikbaar.")
        case .couldNotDetermine:
            throw FriendsStoreError.cloudKitNotAvailable("Kon iCloud status niet bepalen. Check iCloud/CloudKit instellingen.")
        @unknown default:
            throw FriendsStoreError.cloudKitNotAvailable("Onbekende iCloud status. Check iCloud/CloudKit instellingen.")
        }
    }
}
