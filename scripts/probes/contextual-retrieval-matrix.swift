// Synthetic quality matrix, existing Apple assets only. Does not open a data library.
import Foundation
import NaturalLanguage

struct Document: Decodable { let id: String; let text: String }
struct Query: Decodable { let id: String; let split: String; let text: String; let relevant: [String] }
struct Fixture: Decodable { let synthetic: Bool; let documents: [Document]; let queries: [Query] }
enum ProbeError: Error { case invalidFixture, invalidVector }
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift contextual-retrieval-matrix.swift synthetic-fixture.json\n", stderr)
    exit(2)
}
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let fixture = try JSONDecoder().decode(Fixture.self, from: data)
guard fixture.synthetic, !fixture.documents.isEmpty, fixture.documents.count <= 1000,
      !fixture.queries.isEmpty, fixture.queries.count <= 100 else { throw ProbeError.invalidFixture }
guard let embedding = NLContextualEmbedding(language: .simplifiedChinese), embedding.hasAvailableAssets else {
    print("{\"status\":\"not_run\",\"reason\":\"Local Chinese contextual assets unavailable\"}")
    exit(0)
}
try embedding.load()
defer { embedding.unload() }
func vector(_ text: String) throws -> [Double] {
    let result = try embedding.embeddingResult(for: text, language: .simplifiedChinese)
    var values = Array(repeating: 0.0, count: embedding.dimension)
    result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { token, _ in
        for i in values.indices { values[i] += token[i] }
        return true
    }
    let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
    guard norm.isFinite, norm > 0, values.allSatisfy(\.isFinite) else { throw ProbeError.invalidVector }
    return values.map { $0 / norm }
}
let vectors = try fixture.documents.map { try vector($0.text) }
var rows: [[String: Any]] = []
for query in fixture.queries {
    let v = try vector(query.text)
    let distances = vectors.map { 1 - zip(v, $0).reduce(0) { $0 + $1.0 * $1.1 } }
    let indices = fixture.documents.indices.sorted { distances[$0] < distances[$1] }
    rows.append(["id": query.id, "split": query.split, "text": query.text, "relevant": query.relevant,
                 "ranked": indices.map { ["id": fixture.documents[$0].id, "distance": distances[$0]] as [String: Any] }])
}
let output: [String: Any] = ["model": embedding.modelIdentifier, "revision": embedding.revision,
                            "pooling": "mean-normalized", "rows": rows]
print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted]), encoding: .utf8)!)
