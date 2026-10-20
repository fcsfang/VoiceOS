import Foundation

/// Timing and byte counts only. No URL, headers, credentials or content.
public struct ModelHTTPDiagnostic: Codable, Sendable {
    public let deadlineSeconds: Double
    public let requestBytes: Int
    public let headersSeconds: Double?
    public let firstBodyByteSeconds: Double?
    public let totalSeconds: Double
    public let responseBytes: Int
    public let httpStatus: Int?
    public let result: String
    public let urlErrorCode: Int?
}
public actor ModelHTTPDiagnostics {
    private var values: [ModelHTTPDiagnostic]=[]
    public init() {}
    func append(_ value: ModelHTTPDiagnostic) { values.append(value) }
    public func records() -> [ModelHTTPDiagnostic] { values }
}
