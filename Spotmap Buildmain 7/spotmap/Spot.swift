import Foundation
import CoreLocation
import CloudKit

public struct Spot: Identifiable, Equatable, Hashable {
    public let id: CKRecord.ID
    public var title: String
    public var note: String
    public var location: CLLocation
    public var createdAt: Date
    public var photoData: Data?
    public let photoAssetURL: URL?

    public var latitude: Double { location.coordinate.latitude }
    public var longitude: Double { location.coordinate.longitude }

    // MARK: - CloudKit
    public static let recordType = "Spot"

    public init(id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString),
                title: String,
                note: String,
                location: CLLocation,
                createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.note = note
        self.location = location
        self.createdAt = createdAt
        self.photoData = nil
        self.photoAssetURL = nil
    }

    public init?(record: CKRecord) {
        guard record.recordType == Self.recordType else { return nil }
        guard let title = record["title"] as? String,
              let note = record["note"] as? String,
              let location = record["location"] as? CLLocation,
              let createdAt = record["createdAt"] as? Date
        else { return nil }

        self.id = record.recordID
        self.title = title
        self.note = note
        self.location = location
        self.createdAt = createdAt
        let asset = record["photo"] as? CKAsset
        self.photoData = nil
        self.photoAssetURL = asset?.fileURL
    }

    public func loadPhotoData() async -> Data? {
        if let photoData {
            return photoData
        }
        guard let url = photoAssetURL else { return nil }
        return await Task.detached(priority: .utility) {
            try? Data(contentsOf: url)
        }.value
    }

    public func toRecord(existing: CKRecord? = nil) -> CKRecord {
        toRecordWithTempAssetURL(existing: existing).record
    }

    public func toRecordWithTempAssetURL(existing: CKRecord? = nil) -> (record: CKRecord, tempAssetURL: URL?) {
        let record = existing ?? CKRecord(recordType: Self.recordType, recordID: id)
        record["title"] = title as CKRecordValue
        record["note"] = note as CKRecordValue
        record["location"] = location as CKRecordValue
        record["createdAt"] = createdAt as CKRecordValue

        if let photoData {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("spot-photo-\(id.recordName).jpg")
            try? photoData.write(to: url, options: [.atomic])
            record["photo"] = CKAsset(fileURL: url)
            return (record, url)
        } else {
            record["photo"] = nil
            return (record, nil)
        }
    }
}
