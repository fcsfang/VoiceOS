import Foundation

/// Retries the same wire request. Attempts that change the payload or resume
/// later from a durable receipt remain the calling operation's responsibility.
enum ResponsesRetry {
    enum Scope {
        case httpStatus
        case httpStatusAndConnection
    }

    private static let delays: [Duration] = [.seconds(5), .seconds(15)]
    static let maximumAttempts = delays.count + 1

    static func delay(forHTTPStatus status: Int, afterAttempt attempt: Int) -> Duration? {
        guard [429, 502, 503, 504].contains(status) else { return nil }
        return delay(afterAttempt: attempt)
    }

    static func isTransientConnection(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    static func send(_ request: URLRequest, using transport: any ModelHTTPTransport, scope: Scope,
                     wait: @Sendable (Duration) async throws -> Void) async throws -> ModelHTTPReply {
        var attempt = 1
        while true {
            let reply: ModelHTTPReply
            do {
                reply = try await transport.send(request)
            } catch let error as URLError where scope == .httpStatusAndConnection {
                try Task.checkCancellation()
                guard isTransientConnection(error.code), let delay = delay(afterAttempt: attempt) else {
                    throw error
                }
                try await wait(delay)
                attempt += 1
                continue
            }
            let delay = delay(forHTTPStatus: reply.status, afterAttempt: attempt)
            if scope == .httpStatusAndConnection, reply.status == 200 || delay != nil {
                try Task.checkCancellation()
            }
            guard let delay else { return reply }
            try await wait(delay)
            attempt += 1
        }
    }

    private static func delay(afterAttempt attempt: Int) -> Duration? {
        let index = attempt - 1
        return delays.indices.contains(index) ? delays[index] : nil
    }
}
