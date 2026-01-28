import CloudKit
import Foundation

extension CKDatabase {
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

extension CKContainer {
    func accountStatus() async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { cont in
            accountStatus { status, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: status)
            }
        }
    }
}
