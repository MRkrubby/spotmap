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
    var liveJourneyZlib: Data?   // short rolling live trace
    var isDriving: Bool = false
    var lastSpeedMps: Double?
    var lastHeadingDegrees: Double?
    var totalDistanceKm: Double?
    var level: Int?
    var visitedCitiesCount: Int?
    var visitedTilesCount: Int?

    var coordinate: CLLocationCoordinate2D? {
        guard let lastLat, let lastLon else { return nil }
        return .init(latitude: lastLat, longitude: lastLon)
    }

    var statusText: String {
        if isDriving {
            if let speed = lastSpeedMps {
                return String(format: "Rijdt • %.0f km/u", max(0, speed * 3.6))
            }
            return "Rijdt nu"
        }
        return "Niet aan het rijden"
    }

    var mapLabel: String {
        if isDriving, let speed = lastSpeedMps {
            return "\(displayName) • \(Int((speed * 3.6).rounded())) km/u"
        }
        return displayName
    }

    init(code: String,
         displayName: String,
         lastLat: Double?,
         lastLon: Double?,
         updatedAt: Date?,
         lastJourneyZlib: Data?,
         liveJourneyZlib: Data?,
         isDriving: Bool,
         lastSpeedMps: Double?,
         lastHeadingDegrees: Double?,
         totalDistanceKm: Double?,
         level: Int?,
         visitedCitiesCount: Int?,
         visitedTilesCount: Int?) {
        self.code = code
        self.displayName = displayName
        self.lastLat = lastLat
        self.lastLon = lastLon
        self.updatedAt = updatedAt
        self.lastJourneyZlib = lastJourneyZlib
        self.liveJourneyZlib = liveJourneyZlib
        self.isDriving = isDriving
        self.lastSpeedMps = lastSpeedMps
        self.lastHeadingDegrees = lastHeadingDegrees
        self.totalDistanceKm = totalDistanceKm
        self.level = level
        self.visitedCitiesCount = visitedCitiesCount
        self.visitedTilesCount = visitedTilesCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        displayName = try container.decode(String.self, forKey: .displayName)
        lastLat = try container.decodeIfPresent(Double.self, forKey: .lastLat)
        lastLon = try container.decodeIfPresent(Double.self, forKey: .lastLon)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        lastJourneyZlib = try container.decodeIfPresent(Data.self, forKey: .lastJourneyZlib)
        liveJourneyZlib = try container.decodeIfPresent(Data.self, forKey: .liveJourneyZlib)
        isDriving = try container.decodeIfPresent(Bool.self, forKey: .isDriving) ?? false
        lastSpeedMps = try container.decodeIfPresent(Double.self, forKey: .lastSpeedMps)
        lastHeadingDegrees = try container.decodeIfPresent(Double.self, forKey: .lastHeadingDegrees)
        totalDistanceKm = try container.decodeIfPresent(Double.self, forKey: .totalDistanceKm)
        level = try container.decodeIfPresent(Int.self, forKey: .level)
        visitedCitiesCount = try container.decodeIfPresent(Int.self, forKey: .visitedCitiesCount)
        visitedTilesCount = try container.decodeIfPresent(Int.self, forKey: .visitedTilesCount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(lastLat, forKey: .lastLat)
        try container.encodeIfPresent(lastLon, forKey: .lastLon)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastJourneyZlib, forKey: .lastJourneyZlib)
        try container.encodeIfPresent(liveJourneyZlib, forKey: .liveJourneyZlib)
        try container.encode(isDriving, forKey: .isDriving)
        try container.encodeIfPresent(lastSpeedMps, forKey: .lastSpeedMps)
        try container.encodeIfPresent(lastHeadingDegrees, forKey: .lastHeadingDegrees)
        try container.encodeIfPresent(totalDistanceKm, forKey: .totalDistanceKm)
        try container.encodeIfPresent(level, forKey: .level)
        try container.encodeIfPresent(visitedCitiesCount, forKey: .visitedCitiesCount)
        try container.encodeIfPresent(visitedTilesCount, forKey: .visitedTilesCount)
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case displayName
        case lastLat
        case lastLon
        case updatedAt
        case lastJourneyZlib
        case liveJourneyZlib
        case isDriving
        case lastSpeedMps
        case lastHeadingDegrees
        case totalDistanceKm
        case level
        case visitedCitiesCount
        case visitedTilesCount
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
    @Published var lastFriendAddWarning: String? = nil

    static let liveJourneyMaxAge: TimeInterval = 3 * 60

    private let meKey = "Friends.me.v1"
    private let followingKey = "Friends.following.v1"
    private let abuseKey = "Friends.abuse.v1"
    private let lastJourneyDirectoryName = "Friends"
    private var lastSavedJourneyZlib: Data? = nil
    private var lastSavedLiveJourneyZlib: Data? = nil
    private var refreshTask: Task<Void, Never>? = nil
    private var lastLivePublishAt: Date? = nil

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
            let code = Self.generateCode()
            self.me = FriendProfile(
                code: code,
                displayName: "Ik",
                lastLat: nil,
                lastLon: nil,
                updatedAt: nil,
                lastJourneyZlib: nil,
                liveJourneyZlib: nil,
                isDriving: false,
                lastSpeedMps: nil,
                lastHeadingDegrees: nil,
                totalDistanceKm: nil,
                level: nil,
                visitedCitiesCount: nil,
                visitedTilesCount: nil
            )
            persistMe()
        }
        loadLastJourneyZlib()
        loadLiveJourneyZlib()
        loadFollowing()
    }

    func liveJourneyZlib(for friend: FriendProfile, referenceDate: Date = Date()) -> Data? {
        guard let updatedAt = friend.updatedAt,
              referenceDate.timeIntervalSince(updatedAt) <= Self.liveJourneyMaxAge else {
            return nil
        }
        return friend.liveJourneyZlib
    }

    func setDisplayName(_ name: String) {
        me.displayName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Ik" : name
        persistMe()
        // Caller decides whether to publish (prevents unintended CloudKit calls on launch).
    }

    func myCode() -> String { me.code }

    func follow(code: String) {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        lastFriendAddWarning = nil
        guard Self.isValidFriendCode(c) else {
            lastFriendAddWarning = "Code ongeldig. Gebruik 6-10 tekens (A-Z/0-9)."
            return
        }
        var set = Set(followingCodes().map { $0.uppercased() })
        if set.contains(c) {
            return
        }
        switch followGate(for: c) {
        case .ok:
            break
        case .tooSoon:
            lastFriendAddWarning = "Te snel achter elkaar. Probeer over 1 minuut opnieuw."
            return
        case .dailyLimit:
            lastFriendAddWarning = "Daglimiet bereikt (25 toevoegingen)."
            return
        }
        guard c != me.code else {
            lastFriendAddWarning = "Je kunt jezelf niet toevoegen."
            return
        }
        guard set.count < 120 else {
            lastFriendAddWarning = "Limiet bereikt (120 vrienden)."
            return
        }
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
        me.lastHeadingDegrees = location.course >= 0 ? location.course : me.lastHeadingDegrees
        me.lastSpeedMps = location.speed >= 0 ? location.speed : me.lastSpeedMps
        me.isDriving = (me.lastSpeedMps ?? 0) > 2.5
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

    func updateMyLiveJourney(points: [JourneyPoint], speedMps: Double) {
        guard !points.isEmpty else { return }
        guard shouldPublishLiveJourney() else { return }
        let now = Date()
        let journeyPoints = pruneLiveJourneyPoints(points)
        let zipped = JourneySerialization.encode(points: journeyPoints)
        guard me.liveJourneyZlib != zipped else { return }
        me.liveJourneyZlib = zipped
        me.isDriving = speedMps > 2.5
        me.lastSpeedMps = max(0, speedMps)
        me.updatedAt = now
        persistLiveJourneyZlib()
        persistMe()
    }

    func clearLiveJourney() {
        guard me.liveJourneyZlib != nil else { return }
        me.liveJourneyZlib = nil
        me.isDriving = false
        me.updatedAt = Date()
        persistMe()
    }

    func updateMyStats(totalDistanceKm: Double, level: Int, visitedCitiesCount: Int, visitedTilesCount: Int) {
        me.totalDistanceKm = totalDistanceKm
        me.level = level
        me.visitedCitiesCount = visitedCitiesCount
        me.visitedTilesCount = visitedTilesCount
        persistMe()
    }

    private func pruneLiveJourneyPoints(_ points: [JourneyPoint]) -> [JourneyPoint] {
        let maxPoints = 300
        guard points.count > maxPoints else { return points }
        let strideSize = Int(ceil(Double(points.count) / Double(maxPoints)))
        guard strideSize > 1 else { return Array(points.suffix(maxPoints)) }

        var downsampled: [JourneyPoint] = []
        downsampled.reserveCapacity(maxPoints)
        for index in stride(from: 0, to: points.count, by: strideSize) {
            downsampled.append(points[index])
        }
        if let last = points.last, downsampled.last?.ts != last.ts {
            downsampled.append(last)
        }
        if downsampled.count > maxPoints {
            downsampled = Array(downsampled.suffix(maxPoints))
        }
        return downsampled
    }

    func regenerateMyCode() async -> Bool {
        lastFriendAddWarning = nil
        guard canRotateCode() else {
            lastFriendAddWarning = "Je kunt maximaal 2x per dag een nieuwe code maken."
            return false
        }
        let newCode = await generateUniqueCode()
        guard newCode != me.code else { return false }
        me.code = newCode
        persistMe()
        resetFollowingOnCodeRotate()
        return true
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
            if let data = me.liveJourneyZlib {
                record["liveJourneyZlib"] = data as CKRecordValue
            }
            record["isDriving"] = me.isDriving as CKRecordValue
            if let speed = me.lastSpeedMps {
                record["lastSpeedMps"] = speed as CKRecordValue
            }
            if let heading = me.lastHeadingDegrees {
                record["lastHeading"] = heading as CKRecordValue
            }
            if let totalKm = me.totalDistanceKm {
                record["totalDistanceKm"] = totalKm as CKRecordValue
            }
            if let level = me.level {
                record["level"] = level as CKRecordValue
            }
            if let cities = me.visitedCitiesCount {
                record["visitedCitiesCount"] = cities as CKRecordValue
            }
            if let tiles = me.visitedTilesCount {
                record["visitedTilesCount"] = tiles as CKRecordValue
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
        snapshot.liveJourneyZlib = nil
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

    private func loadLiveJourneyZlib() {
        guard let url = lastLiveJourneyURL(for: me.code) else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        me.liveJourneyZlib = data
        lastSavedLiveJourneyZlib = data
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
        let live = record["liveJourneyZlib"] as? Data
        let isDriving = (record["isDriving"] as? Bool) ?? false
        let lastSpeedMps = record["lastSpeedMps"] as? Double
        let lastHeading = record["lastHeading"] as? Double
        let totalKm = record["totalDistanceKm"] as? Double
        let level = record["level"] as? Int
        let cities = record["visitedCitiesCount"] as? Int
        let tiles = record["visitedTilesCount"] as? Int
        return FriendProfile(code: code, displayName: name,
                             lastLat: loc?.coordinate.latitude, lastLon: loc?.coordinate.longitude,
                             updatedAt: updatedAt,
                             lastJourneyZlib: data,
                             liveJourneyZlib: live,
                             isDriving: isDriving,
                             lastSpeedMps: lastSpeedMps,
                             lastHeadingDegrees: lastHeading,
                             totalDistanceKm: totalKm,
                             level: level,
                             visitedCitiesCount: cities,
                             visitedTilesCount: tiles)
    }

    private func shouldPublishLiveJourney() -> Bool {
        let now = Date()
        if let lastLivePublishAt, now.timeIntervalSince(lastLivePublishAt) < 12 {
            return false
        }
        lastLivePublishAt = now
        return true
    }

    private func persistLiveJourneyZlib() {
        guard let url = lastLiveJourneyURL(for: me.code) else { return }
        guard let data = me.liveJourneyZlib else { return }
        guard data != lastSavedLiveJourneyZlib else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try data.write(to: url, options: [.atomic])
            lastSavedLiveJourneyZlib = data
        } catch {
            // Ignore persistence failures; keep in-memory copy.
        }
    }

    private func lastLiveJourneyURL(for code: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent(lastJourneyDirectoryName, isDirectory: true)
        return directory.appendingPathComponent("live-journey-\(code).zlib")
    }

    private enum FollowGate {
        case ok
        case tooSoon
        case dailyLimit
    }

    private func followGate(for code: String) -> FollowGate {
        var state = loadAbuseState()
        let now = Date()
        state.prune(now: now)
        let key = code.uppercased()
        if let last = state.lastFollowAttemptByCode[key], now.timeIntervalSince(last) < 60 {
            saveAbuseState(state)
            return .tooSoon
        }
        state.lastFollowAttemptByCode[key] = now
        state.followAttemptsToday += 1
        saveAbuseState(state)
        return state.followAttemptsToday > 25 ? .dailyLimit : .ok
    }

    private func canRotateCode() -> Bool {
        var state = loadAbuseState()
        let now = Date()
        state.prune(now: now)
        let allowed = state.codeRotationsToday < 2
        if allowed {
            state.codeRotationsToday += 1
            saveAbuseState(state)
        }
        return allowed
    }

    private func resetFollowingOnCodeRotate() {
        saveFollowing([])
        friends.removeAll()
    }

    private func loadAbuseState() -> AbuseState {
        guard let data = UserDefaults.standard.data(forKey: abuseKey),
              let state = try? JSONDecoder().decode(AbuseState.self, from: data) else {
            return AbuseState()
        }
        return state
    }

    private func saveAbuseState(_ state: AbuseState) {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: abuseKey)
        }
    }

    private struct AbuseState: Codable {
        var dayStamp: String = Self.dayStamp(for: Date())
        var followAttemptsToday: Int = 0
        var codeRotationsToday: Int = 0
        var lastFollowAttemptByCode: [String: Date] = [:]

        mutating func prune(now: Date) {
            let currentStamp = Self.dayStamp(for: now)
            if currentStamp != dayStamp {
                dayStamp = currentStamp
                followAttemptsToday = 0
                codeRotationsToday = 0
                lastFollowAttemptByCode = [:]
            }
            lastFollowAttemptByCode = lastFollowAttemptByCode.filter { now.timeIntervalSince($0.value) < 3600 }
        }

        private static func dayStamp(for date: Date) -> String {
            let cal = Calendar.current
            let comps = cal.dateComponents([.year, .month, .day], from: date)
            return "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
        }
    }

    static func isValidFriendCode(_ code: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return (6...10).contains(code.count) && code.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func generateCode(length: Int = 8) -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var out = ""
        for _ in 0..<length {
            out.append(chars.randomElement() ?? "A")
        }
        return out
    }

    private func generateUniqueCode() async -> String {
        for _ in 0..<6 {
            let candidate = Self.generateCode()
            if await isCodeAvailable(candidate) {
                return candidate
            }
        }
        return Self.generateCode()
    }

    private func isCodeAvailable(_ code: String) async -> Bool {
        guard isEnabled else { return true }
        do {
            try await ensureCloudKitAvailable()
            guard let db else { return true }
            let recordID = CKRecord.ID(recordName: "friend-\(code)")
            _ = try await fetchRecord(recordID, from: db)
            return false
        } catch {
            return true
        }
    }

    private func fetchRecord(_ id: CKRecord.ID, from database: CKDatabase) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { cont in
            database.fetch(withRecordID: id) { record, error in
                if let error { cont.resume(throwing: error); return }
                if let record { cont.resume(returning: record); return }
                cont.resume(throwing: CKError(.unknownItem))
            }
        }
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
