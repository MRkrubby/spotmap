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

    func loadPhotoData(filename: String) -> Data? {
        let url = directoryURL.appendingPathComponent(filename)
        return try? Data(contentsOf: url)
    }

    func savePhotoData(_ data: Data, filename: String) {
        ensureDirectoryExists()
        let url = directoryURL.appendingPathComponent(filename)
        try? data.write(to: url, options: [.atomic])
    }

    func deletePhoto(filename: String) {
        let url = directoryURL.appendingPathComponent(filename)
        try? fileManager.removeItem(at: url)
    }

    private func ensureDirectoryExists() {
        guard !fileManager.fileExists(atPath: directoryURL.path) else { return }
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
}
