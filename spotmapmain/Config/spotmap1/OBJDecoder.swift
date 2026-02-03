import Foundation

/// A lightweight stand-in decoder for `.obj` catalog files.
/// Currently delegates to JSONDecoder so `.obj` files containing JSON can be parsed.
/// Replace the implementation if your `.obj` format differs from JSON.
struct OBJDecoder {
    private let jsonDecoder: JSONDecoder

    init(configure: ((JSONDecoder) -> Void)? = nil) {
        let decoder = JSONDecoder()
        configure?(decoder)
        self.jsonDecoder = decoder
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        return try jsonDecoder.decode(T.self, from: data)
    }
}
