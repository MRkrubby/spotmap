import Foundation

final class SpotPhotoStore {
    static let shared = SpotPhotoStore()

    private let fileManager: FileManager
    private let directoryURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.directoryURL = baseURL.appendingPathComponent("SpotPhotos", isDirectory: true)
    }

    func filename(for recordName: String) -> String {
        "spot-\(recordName).jpg"
    }

    func uniqueFilename(for recordName: String) -> String {
        "spot-\(recordName)-\(UUID().uuidString).jpg"
    }

    func url(for filename: String) -> URL {
        directoryURL.appendingPathComponent(filename)
    }

    func loadPhotoData(filename: String) -> Data? {
        let url = url(for: filename)
        return try? Data(contentsOf: url)
    }

    func savePhotoData(_ data: Data, filename: String) {
        ensureDirectoryExists()
        let url = url(for: filename)
        try? data.write(to: url, options: [.atomic])
    }

    func deletePhoto(filename: String) {
        let url = url(for: filename)
        try? fileManager.removeItem(at: url)
    }

    private func ensureDirectoryExists() {
        guard !fileManager.fileExists(atPath: directoryURL.path) else { return }
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
}
