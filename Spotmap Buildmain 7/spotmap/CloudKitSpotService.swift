import Foundation
import CloudKit
import CoreLocation
#if canImport(Security)
import Security
import CoreFoundation
import Darwin
#endif

protocol SpotService {
    func save(spot: Spot) async throws -> Spot
    func fetchSpot(by id: CKRecord.ID) async throws -> Spot
    func fetchNearby(center: CLLocation, radiusMeters: Double, limit: Int) async throws -> [Spot]
    func deleteSpot(by id: CKRecord.ID) async throws
}

final class CloudKitSpotService: SpotService {

    enum ServiceError: LocalizedError {
        case cloudKitNotAvailable(String)
        case recordDecodeFailed

        var errorDescription: String? {
            switch self {
            case .cloudKitNotAvailable(let msg): return msg
            case .recordDecodeFailed: return "Kon CloudKit record niet omzetten naar Spot."
            }
        }
    }

    private let containerIdentifier: String?

    private var _container: CKContainer?
    private var _db: CKDatabase?

    private var cachedAccountStatus: CKAccountStatus?
    private var cachedAccountStatusAt: Date?
    private let accountStatusTTL: TimeInterval = 60

    init(containerIdentifier: String? = nil) {
        self.containerIdentifier = containerIdentifier
    }

    // MARK: - Entitlements / availability

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

    private func container() throws -> CKContainer {
        if let c = _container { return c }

        // Important: avoid touching CKContainer.default() if the entitlement is missing
        guard Self.hasCloudKitEntitlement() else {
            throw ServiceError.cloudKitNotAvailable(
                "CloudKit entitlement ontbreekt. Zet iCloud → CloudKit aan in Signing & Capabilities en kies een container."
            )
        }

        let c: CKContainer
        if let id = containerIdentifier {
            c = CKContainer(identifier: id)
        } else {
            c = CKContainer.default()
        }

        _container = c
        return c
    }

    private func db() throws -> CKDatabase {
        if let d = _db { return d }
        let d = try container().publicCloudDatabase
        _db = d
        return d
    }

    private func assertCloudKitWorks() async throws {
        // 1) Entitlement check (fast, local)
        guard Self.hasCloudKitEntitlement() else {
            throw ServiceError.cloudKitNotAvailable(
                "CloudKit entitlement ontbreekt. Zet iCloud → CloudKit aan in Signing & Capabilities."
            )
        }

        // 2) Account status check (can be relatively expensive) — cache it
        if let cachedAt = cachedAccountStatusAt,
           let status = cachedAccountStatus,
           Date().timeIntervalSince(cachedAt) < accountStatusTTL {
            try ensureAccountStatusOK(status)
            return
        }

        let status = try await container().accountStatus()
        cachedAccountStatus = status
        cachedAccountStatusAt = Date()
        try ensureAccountStatusOK(status)
    }

    private func ensureAccountStatusOK(_ status: CKAccountStatus) throws {
        switch status {
        case .available:
            return
        case .noAccount:
            throw ServiceError.cloudKitNotAvailable("Geen iCloud account ingelogd op dit apparaat.")
        case .restricted:
            throw ServiceError.cloudKitNotAvailable("iCloud is restricted op dit apparaat.")
        case .temporarilyUnavailable:
            throw ServiceError.cloudKitNotAvailable("iCloud is tijdelijk niet beschikbaar.")
        case .couldNotDetermine:
            throw ServiceError.cloudKitNotAvailable("Kon iCloud status niet bepalen. Check iCloud/CloudKit instellingen.")
        @unknown default:
            throw ServiceError.cloudKitNotAvailable("Onbekende iCloud status. Check iCloud/CloudKit instellingen.")
        }
    }

    // MARK: - SpotService

    func save(spot: Spot) async throws -> Spot {
        try await assertCloudKitWorks()
        let (record, tempAssetURL) = spot.toRecordWithTempAssetURL()
        defer {
            if let tempAssetURL {
                try? FileManager.default.removeItem(at: tempAssetURL)
            }
        }
        let saved = try await db().save(record)
        guard let decoded = Spot(record: saved) else { throw ServiceError.recordDecodeFailed }
        return decoded
    }

    func fetchSpot(by id: CKRecord.ID) async throws -> Spot {
        try await assertCloudKitWorks()
        let record = try await db().fetchRecord(withID: id)
        guard let decoded = Spot(record: record) else { throw ServiceError.recordDecodeFailed }
        return decoded
    }

    func fetchNearby(center: CLLocation, radiusMeters: Double, limit: Int) async throws -> [Spot] {
        try await assertCloudKitWorks()

        // CloudKit supports distance predicates for CLLocation fields.
        let predicate = NSPredicate(
            format: "distanceToLocation:fromLocation:(location, %@) < %f",
            center,
            radiusMeters
        )

        let query = CKQuery(recordType: Spot.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        // Reduce payload: only request what we need.
        let desiredKeys = ["title", "note", "location", "createdAt"]

        let (matchResults, _) = try await db().records(
            matching: query,
            resultsLimit: limit,
            desiredKeys: desiredKeys
        )

        // If the task was cancelled mid-flight, propagate quickly.
        try Task.checkCancellation()

        return matchResults.compactMap { _, result in
            guard case .success(let record) = result else { return nil }
            return Spot(record: record)
        }
    }

    func deleteSpot(by id: CKRecord.ID) async throws {
        try await assertCloudKitWorks()
        _ = try await db().deleteRecord(withID: id)
    }
}

private extension CKDatabase {
    func fetchRecord(withID id: CKRecord.ID) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { cont in
            fetch(withRecordID: id) { record, error in
                if let error { cont.resume(throwing: error); return }
                if let record { cont.resume(returning: record); return }
                cont.resume(throwing: CKError(.unknownItem))
            }
        }
    }

    func save(_ record: CKRecord) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { cont in
            save(record) { saved, error in
                if let error { cont.resume(throwing: error); return }
                if let saved { cont.resume(returning: saved); return }
                cont.resume(throwing: CKError(.internalError))
            }
        }
    }

    func deleteRecord(withID id: CKRecord.ID) async throws -> CKRecord.ID {
        try await withCheckedThrowingContinuation { cont in
            delete(withRecordID: id) { deletedID, error in
                if let error { cont.resume(throwing: error); return }
                if let deletedID { cont.resume(returning: deletedID); return }
                cont.resume(throwing: CKError(.internalError))
            }
        }
    }

    func records(
        matching query: CKQuery,
        resultsLimit: Int,
        desiredKeys: [String]?
    ) async throws -> ([CKRecord.ID: Result<CKRecord, Error>], CKQueryOperation.Cursor?) {
        try await withCheckedThrowingContinuation { cont in
            let op = CKQueryOperation(query: query)
            op.resultsLimit = resultsLimit
            op.desiredKeys = desiredKeys
            op.qualityOfService = .userInitiated

            var results: [CKRecord.ID: Result<CKRecord, Error>] = [:]

            op.recordMatchedBlock = { recordID, result in
                results[recordID] = result
            }

            op.queryResultBlock = { result in
                switch result {
                case .success(let cursor):
                    cont.resume(returning: (results, cursor))
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }

            add(op)
        }
    }
}
