import Foundation

/// Shared strict Responses envelope; payload validators remain purpose-specific.
struct ResponsesEnvelope {
    let status: ModelResponse.Status
    let text: String?
    let inputTokens: Int?
    let outputTokens: Int?
    static func parse(_ data: Data, maxResponseBytes: Int = 262144) throws -> ResponsesEnvelope {
        var knownInput: Int?, knownOutput: Int?
        do {
            guard data.count <= maxResponseBytes else { throw ModelPortFailure.rejected("响应超过 \(maxResponseBytes) 字节限制") }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = root["status"] as? String else { throw ModelPortFailure.rejected("响应外层格式无效") }
            let usage = root["usage"] as? [String: Any]
            func token(_ field: String) throws -> Int? {
                guard let value = usage?[field], !(value is NSNull) else { return nil }
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue >= 0, number.doubleValue < Double(Int.max),
                      number.doubleValue.rounded(.towardZero) == number.doubleValue else { throw ModelPortFailure.rejected("响应用量格式无效") }
                return number.intValue
            }
            var invalidUsage=false
            do { knownInput=try token("input_tokens") } catch { invalidUsage=true }
            do { knownOutput=try token("output_tokens") } catch { invalidUsage=true }
            guard !invalidUsage else { throw ModelPortFailure.rejected("响应用量格式无效") }
            let input=knownInput,output=knownOutput
            if status == "incomplete" { return ResponsesEnvelope(status: .incomplete, text: nil, inputTokens: input, outputTokens: output) }
            guard status == "completed", let items = root["output"] as? [[String: Any]] else { throw ModelPortFailure.rejected("响应未处于可接纳的完成状态") }
            var texts: [String] = []; var refused = false
            for item in items {
                if item["type"] as? String == "reasoning" { continue }
                guard item["type"] as? String == "message", item["role"] as? String == "assistant",
                      item["status"] as? String == "completed", let content = item["content"] as? [[String: Any]] else { throw ModelPortFailure.rejected("响应包含不支持的输出项") }
                for part in content {
                    if part["type"] as? String == "refusal" { refused = true }
                    else if part["type"] as? String == "output_text", let text = part["text"] as? String { texts.append(text) }
                    else { throw ModelPortFailure.rejected("响应包含不支持的内容项") }
                }
            }
            if refused { return ResponsesEnvelope(status: .refused, text: nil, inputTokens: input, outputTokens: output) }
            guard texts.count == 1 else { throw ModelPortFailure.rejected("响应必须含一个结构化文本") }
            return ResponsesEnvelope(status: .completed, text: texts[0], inputTokens: input, outputTokens: output)
        } catch ModelPortFailure.rejected(let reason, _, _) {
            throw ModelPortFailure.rejected(reason, inputTokens: knownInput, outputTokens: knownOutput)
        } catch { throw ModelPortFailure.rejected("模型响应无法解析", inputTokens: knownInput, outputTokens: knownOutput) }
    }
}
