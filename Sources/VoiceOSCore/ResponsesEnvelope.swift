import Foundation

/// Shared strict Responses envelope; payload validators remain purpose-specific.
struct ResponsesEnvelope {
    let status: ModelResponse.Status
    let text: String?
    let inputTokens: Int?
    let outputTokens: Int?
    var failureSummary: String? = nil
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
            if status != "completed" {
                let summary=terminalFailureSummary(root, status: status)
                if status == "incomplete" { return ResponsesEnvelope(status: .incomplete, text: nil, inputTokens: input, outputTokens: output, failureSummary: summary) }
                throw ModelPortFailure.rejected(summary)
            }
            guard let items = root["output"] as? [[String: Any]] else { throw ModelPortFailure.rejected("响应已完成但 output 缺失或格式无效（status=completed）") }
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
    private static func terminalFailureSummary(_ root: [String:Any], status: String) -> String {
        let knownStatuses=["failed","incomplete","cancelled","in_progress","queued"]
        var details=["status="+(knownStatuses.contains(status) ? status : "unknown")]
        if let error=root["error"] as? [String:Any] {
            let code=error["code"] as? String ?? "unknown"
            let knownCodes=["server_error","rate_limit_exceeded","invalid_prompt","context_length_exceeded","insufficient_quota","model_not_found","invalid_api_key"]
            details.append("error.code="+(knownCodes.contains(code) ? code : "unknown"))
        }
        if status == "incomplete" {
            let reason=(root["incomplete_details"] as? [String:Any])?["reason"] as? String ?? "unknown"
            details.append("incomplete_details.reason="+(["max_output_tokens","content_filter"].contains(reason) ? reason : "unknown"))
        }
        return "响应未完成（"+details.joined(separator:"；")+"）；未接纳部分结果"
    }
}
