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
        var loadedPhoto: Data? = nil
        if let url = asset?.fileURL {
            loadedPhoto = try? Data(contentsOf: url)
        }
        self.photoData = loadedPhoto
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
            let tempFilename = "spot-photo-\(id.recordName)-\(UUID().uuidString).jpg"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(tempFilename)
            do {
                try photoData.write(to: url, options: [.atomic])
                record["photo"] = CKAsset(fileURL: url)
                return (record, url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                record["photo"] = nil
                return (record, nil)
            }
        } else {
            record["photo"] = nil
            return (record, nil)
        }
    }
}
