import Foundation

func decodeWithPath<T: Decodable>(_ type: T.Type, from data: Data, label: String) throws -> T {
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch let error as DecodingError {
        let keys: [any CodingKey]
        switch error {
        case .keyNotFound(let key, let context): keys = context.codingPath + [key]
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context): keys = context.codingPath
        @unknown default: keys = []
        }
        throw VoiceOSError("\(label)解码失败：\(codingPath(keys))")
    }
}

private func codingPath(_ keys: [any CodingKey]) -> String {
    let path = keys.reduce(into: "") { path, key in
        if let index = key.intValue {
            path += "[\(index)]"
        } else {
            path += path.isEmpty ? key.stringValue : "." + key.stringValue
        }
    }
    return path.isEmpty ? "$" : path
}
