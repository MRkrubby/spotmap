import Foundation
import Combine
import CoreLocation
import CloudKit

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
    @Published private(set) var me: FriendProfile
    @Published private(set) var friends: [FriendProfile] = []
    @Published var isEnabled: Bool = true
    @Published var lastError: String? = nil

    private let meKey = "Friends.me.v1"
    private let followingKey = "Friends.following.v1"
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
        me.lastJourneyZlib = zipped
        me.updatedAt = Date()
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
        if let data = try? JSONEncoder().encode(me) {
            UserDefaults.standard.set(data, forKey: meKey)
        }
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
        // Create container lazily. If the capability isn't configured, calls below
        // will throw, but we won't crash at app launch.
        if container == nil {
            container = CKContainer.default()
        }
        guard let container else {
            throw NSError(domain: "FriendsStore", code: -11, userInfo: [NSLocalizedDescriptionKey: "CloudKit container unavailable"])
        }

        let status = try await container.accountStatus()
        guard status == .available else {
            throw NSError(domain: "FriendsStore", code: -12, userInfo: [NSLocalizedDescriptionKey: "iCloud is not available (status: \(status.rawValue))"])
        }
    }

    @MainActor
    private func disableIfEntitlementOrAccountIssue(_ error: Error) {
        // If CloudKit isn't configured or the user isn't signed in, keep the app stable
        // by disabling the feature and stopping background refresh.
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
}
