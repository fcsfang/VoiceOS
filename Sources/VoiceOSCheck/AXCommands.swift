import Foundation
import VoiceOSCore
import VoiceOSPlatform

enum AXCommands {
    static func run(_ args: [String]) throws {
        switch try AXCommand.parse(args) {
        case let .dump(pid, identifierPrefix, json):
            let snapshot = try AXDriver(pid: pid).snapshot(identifierPrefix: identifierPrefix)
            if json {
                print(try encode(snapshot))
            } else {
                for record in snapshot.elements { print(line(record)) }
                if snapshot.truncated { print("结果已截断：达到 \(snapshot.elements.count) 个元素的遍历上限") }
            }
        case let .click(pid, identifier):
            let record = try AXDriver(pid: pid).press(identifier: identifier)
            print(try encode(Receipt(action: "press", identifier: identifier, role: record.role, pages: nil)))
        case let .setValue(pid, identifier, value):
            let record = try AXDriver(pid: pid).setValue(identifier: identifier, value: value)
            print(try encode(Receipt(action: "setValue", identifier: identifier, role: record.role, pages: nil)))
        case let .wait(pid, identifier, timeout):
            let record = try AXDriver(pid: pid).wait(identifier: identifier, timeout: timeout)
            print(try encode(Receipt(action: "found", identifier: identifier, role: record.role, pages: nil)))
        case let .scrollTo(pid, identifier, maxPages):
            let result = try AXDriver(pid: pid).scrollTo(identifier: identifier, maxPages: maxPages)
            print(try encode(Receipt(action: "scrolled", identifier: identifier, role: result.record.role, pages: result.pages)))
        }
    }

    private struct Receipt: Codable {
        let action: String
        let identifier: String
        let role: String
        let pages: Int?
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func line(_ record: AXElementRecord) -> String {
        var parts = ["role=" + (record.role.isEmpty ? "-" : record.role), "identifier=" + (record.identifier ?? "-")]
        if let title = record.title, !title.isEmpty { parts.append("title=" + title) }
        if let value = record.value, !value.isEmpty { parts.append("value=" + value) }
        if let frame = record.frame {
            parts.append("frame=" + [frame.x, frame.y, frame.w, frame.h].map { String(format: "%.1f", $0) }.joined(separator: ","))
        }
        parts.append("actions=" + (record.actions.isEmpty ? "-" : record.actions.joined(separator: ",")))
        return parts.joined(separator: " ")
    }
}
