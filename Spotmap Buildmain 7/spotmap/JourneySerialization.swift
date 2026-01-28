import Foundation

enum JourneySerialization {
    static func encode(points: [JourneyPoint]) -> Data {
        let raw = (try? JSONEncoder().encode(points)) ?? Data()
        return (try? JourneyCompression.compress(raw)) ?? raw
    }

    static func decodePoints(fromZlib data: Data) -> [JourneyPoint]? {
        do {
            let raw = try JourneyCompression.decompress(data)
            return try JSONDecoder().decode([JourneyPoint].self, from: raw)
        } catch {
            return nil
        }
    }
}
