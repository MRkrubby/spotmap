import Foundation
import CoreLocation
import Combine
import CloudKit

/// Location manager used by the app.
///
/// Important: Do NOT mark this class `@MainActor`.
/// CoreLocation delegate callbacks can arrive on a non-main thread and Swift's
/// actor isolation checks may terminate the app at launch if a `@MainActor`-isolated
/// delegate is called off the main actor.
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published var lastLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.pausesLocationUpdatesAutomatically = true
    }

    /// Switch between low-power and high-accuracy tracking.
    ///
    /// Used by Explore mode so the 20m reveal radius feels responsive.
    func setHighAccuracy(_ enabled: Bool) {
        if enabled {
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 8
        } else {
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 50
        }
    }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    func start() {
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.authorizationStatus = status
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                self.start()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let loc = locations.last
        DispatchQueue.main.async { [weak self] in
            self?.lastLocation = loc
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Don't crash the app on location errors; just keep the last known location.
        // You can inspect this in the UI via repo.lastErrorMessage if needed.
    }
}


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
        me.lastJourneyZlib = JourneySerialization.encode(points: journey.decodedPoints())
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
            setLastError(AppErrorMapper.message(for: error))
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
            let records = try await fetchFriendRecords(from: db, recordIDs: recordIDs)
            let loaded = records.map { Self.decode($0) }
            let sorted = loaded.sorted(by: { $0.displayName < $1.displayName })
            setFriends(sorted)
        } catch {
            setLastError(AppErrorMapper.message(for: error))
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

    private func fetchFriendRecords(from db: CKDatabase, recordIDs: [CKRecord.ID]) async throws -> [CKRecord] {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchRecordsOperation(recordIDs: recordIDs)
            let lock = NSLock()
            var records: [CKRecord] = []

            operation.perRecordResultBlock = { _, result in
                guard case .success(let record) = result else { return }
                lock.lock()
                records.append(record)
                lock.unlock()
            }

            operation.fetchRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: records)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            db.add(operation)
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

private extension CKDatabase {
    func record(for id: CKRecord.ID) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { cont in
            fetch(withRecordID: id) { record, error in
                if let error { cont.resume(throwing: error); return }
                if let record { cont.resume(returning: record); return }
                cont.resume(throwing: NSError(domain: "FriendProfile", code: -1, userInfo: [NSLocalizedDescriptionKey: "Record not found"]))
            }
        }
    }
}

private extension CKContainer {
    func accountStatus() async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { cont in
            accountStatus { status, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: status)
            }
        }
    }
}
