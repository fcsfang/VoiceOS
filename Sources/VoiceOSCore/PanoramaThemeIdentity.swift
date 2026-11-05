import Foundation

struct PanoramaThemeMatch: Sendable, Equatable {
    enum Kind: String, Sendable { case exact, matched, new }
    let themeID: String
    let rawRegionID: String
    let regionTitle: String
    let questionTitles: [String]
    let claimIDs: [String]
    let sourceIDs: [String]
    let quoteKeys: [String]
    let kind: Kind
    let score: Double?
}

struct PanoramaThemeMap: Sendable {
    struct Reference: Sendable {
        let id: String
        let title: String
        let questionTitles: [String]
        let claimIDs: Set<String>
        let sourceIDs: Set<String>
        let quoteKeys: Set<String>
    }
    let references: [Reference]

    init(references: [Reference]) { self.references = references }

    static func isEligible(_ snapshot: PanoramaSnapshot, attemptState: String) -> Bool {
        guard !snapshot.proposal.regions.isEmpty else { return false }
        if let workflow = snapshot.workflow {
            if workflow.isComplete { return true }
            return workflow.receipts.contains { $0.stage == "draft.synthesize" }
        }
        return attemptState == "completed"
    }

    static func make(snapshot: PanoramaSnapshot) -> PanoramaThemeMap { make(proposal: snapshot.proposal) }

    static func make(proposal: PanoramaProposal) -> PanoramaThemeMap {
        let questions = Dictionary(grouping: proposal.questions, by: \.regionID)
        return .init(references: proposal.regions.map { region in
            PanoramaThemeIdentity.reference(id: region.id, title: region.title, questions: questions[region.id] ?? [])
        })
    }

    init(proposal: PanoramaProposal, attemptID: String, phase: PanoramaPhase) { self = .make(proposal: proposal) }
}

enum PanoramaThemeIdentity {
    private struct Signals {
        let title: Set<String>
        let questions: Set<String>
        let claims: Set<String>
        let sources: Set<String>
        let quotes: Set<String>
        init(_ reference: PanoramaThemeMap.Reference) {
            title = bigrams(reference.title)
            questions = reference.questionTitles.reduce(into: Set<String>()) { $0.formUnion(bigrams($1)) }
            claims = reference.claimIDs
            sources = reference.sourceIDs
            quotes = reference.quoteKeys
        }
    }

    private static let ignoredCharacters = Set<Character>("，。！？、；：,.!?;:()（）【】[]“”‘’…·-")

    static func quoteKey(sourceID: String, quote: String) -> String {
        let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        return VoiceOSStore.relevanceHash(Data((sourceID + "|" + trimmed).utf8))
    }

    static func reference(id: String, title: String, questions: [PanoramaQuestion]) -> PanoramaThemeMap.Reference {
        let evidence = questions.flatMap(\.evidence)
        return .init(id: id, title: title, questionTitles: questions.map(\.title),
                     claimIDs: Set(evidence.flatMap(\.claimIDs)), sourceIDs: Set(evidence.map(\.sourceID)),
                     quoteKeys: Set(evidence.map { quoteKey(sourceID: $0.sourceID, quote: $0.quote) }))
    }

    static func adoptableID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 128, !id.hasPrefix("unit["), !id.hasPrefix("part["),
              !id.contains("/"), !id.contains("|") else { return false }
        return id.unicodeScalars.allSatisfy {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
        }
    }

    static func mintedID(attemptID: String, rawRegionID: String) -> String {
        "theme-" + String(VoiceOSStore.relevanceHash(Data(("panorama-theme-v1|" + attemptID + "|" + rawRegionID).utf8)).prefix(32))
    }

    private static func normalized(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace && !ignoredCharacters.contains($0) }).lowercased()
    }

    private static func bigrams(_ text: String) -> Set<String> {
        let characters = Array(normalized(text))
        guard characters.count >= 2 else { return [] }
        var result = Set<String>()
        for index in 0..<(characters.count - 1) { result.insert(String(characters[index...index + 1])) }
        return result
    }

    private static func dice(_ left: Set<String>, _ right: Set<String>) -> Double {
        let total = left.count + right.count
        guard total > 0 else { return 0 }
        return 2 * Double(left.intersection(right).count) / Double(total)
    }

    private static func containment(_ left: Set<String>, _ right: Set<String>) -> Double {
        let smaller = min(left.count, right.count)
        guard smaller > 0 else { return 0 }
        return Double(left.intersection(right).count) / Double(smaller)
    }

    private static func overlap(_ left: Set<String>, _ right: Set<String>) -> Double {
        let shared = left.intersection(right).count
        if shared == 0 { return 0 }
        if shared == 1 { return 0.5 }
        return Double(shared) / Double(min(left.count, right.count))
    }

    private static func similarity(_ left: Signals, _ right: Signals) -> (score: Double, eligible: Bool) {
        let title = dice(left.title, right.title)
        let questions = dice(left.questions, right.questions)
        let claims = overlap(left.claims, right.claims)
        let sources = containment(left.sources, right.sources)
        let quotes = overlap(left.quotes, right.quotes)
        let score = 0.35 * title + 0.20 * questions + 0.20 * claims + 0.15 * sources + 0.10 * quotes
        let evidence = claims > 0 || sources > 0
        let anchor = title >= 0.90 || questions >= 0.35 || claims >= 0.60 || quotes >= 0.50
        let veto = !left.claims.isEmpty && !right.claims.isEmpty && claims == 0 && sources < 0.50
        return (score, evidence && anchor && !veto)
    }

    private struct Best {
        let index: Int
        let score: Double
        let second: Double?
    }

    private static func best(of values: [(index: Int, score: Double)]) -> Best? {
        guard !values.isEmpty else { return nil }
        let ordered = values.sorted { $0.score > $1.score }
        guard ordered.count == 1 || ordered[0].score != ordered[1].score else { return nil }
        return .init(index: ordered[0].index, score: ordered[0].score, second: ordered.count > 1 ? ordered[1].score : nil)
    }

    static func rewrite(_ proposal: PanoramaProposal, attemptID: String,
                        current: PanoramaThemeMap?, prior: PanoramaThemeMap?) throws -> (proposal: PanoramaProposal, matches: [PanoramaThemeMatch]) {
        let questionsByRegion = Dictionary(grouping: proposal.questions, by: \.regionID)
        let rawIDs = proposal.regions.map(\.id)
        guard Set(rawIDs).count == rawIDs.count else { throw VoiceOSError("全景区域身份重复") }
        let knownRegions = Set(rawIDs)
        for question in proposal.questions where !knownRegions.contains(question.regionID) {
            throw VoiceOSError("全景问题缺少所属区域")
        }
        let currentReferences = current?.references ?? []
        let currentIDs = Set(currentReferences.map(\.id))
        var merged = currentReferences
        var mergedIDs = currentIDs
        if let prior {
            for reference in prior.references where mergedIDs.insert(reference.id).inserted { merged.append(reference) }
        }
        var mapped: [String: String] = [:]
        var kinds: [String: PanoramaThemeMatch.Kind] = [:]
        var scores: [String: Double] = [:]
        var used = Set<String>()
        for region in proposal.regions where currentIDs.contains(region.id) {
            mapped[region.id] = region.id
            kinds[region.id] = .exact
            used.insert(region.id)
        }
        let candidates = proposal.regions.filter { kinds[$0.id] == nil }
        let available = merged.filter { !used.contains($0.id) }
        let candidateSignals = candidates.map { Signals(reference(region: $0, questionsByRegion: questionsByRegion)) }
        let priorSignals = available.map { Signals($0) }
        var pairs: [(candidate: Int, prior: Int, score: Double)] = []
        var byCandidate: [[(index: Int, score: Double)]] = Array(repeating: [], count: candidates.count)
        var byPrior: [[(index: Int, score: Double)]] = Array(repeating: [], count: available.count)
        for candidate in candidates.indices {
            for prior in available.indices {
                let result = similarity(candidateSignals[candidate], priorSignals[prior])
                guard result.eligible, result.score >= 0.55 else { continue }
                byCandidate[candidate].append((prior, result.score))
                byPrior[prior].append((candidate, result.score))
                pairs.append((candidate: candidate, prior: prior, score: result.score))
            }
        }
        let candidateBest = byCandidate.map { best(of: $0) }
        let priorBest = byPrior.map { best(of: $0) }
        var accepted: [(candidate: Int, prior: Int, score: Double)] = []
        for pair in pairs {
            guard let candidateTop = candidateBest[pair.candidate], candidateTop.index == pair.prior,
                  let priorTop = priorBest[pair.prior], priorTop.index == pair.candidate else { continue }
            let candidateMargin = candidateTop.second.map { pair.score - $0 } ?? .infinity
            let priorMargin = priorTop.second.map { pair.score - $0 } ?? .infinity
            guard candidateMargin >= 0.12, priorMargin >= 0.12 else { continue }
            accepted.append((candidate: pair.candidate, prior: pair.prior, score: pair.score))
        }
        accepted.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.candidate != right.candidate { return left.candidate < right.candidate }
            return left.prior < right.prior
        }
        var usedCandidates = Set<Int>(), usedPriors = Set<Int>()
        for pair in accepted where !usedCandidates.contains(pair.candidate) && !usedPriors.contains(pair.prior) {
            usedCandidates.insert(pair.candidate)
            usedPriors.insert(pair.prior)
            let themeID = available[pair.prior].id
            mapped[candidates[pair.candidate].id] = adoptableID(themeID) ? themeID : mintedID(attemptID: attemptID, rawRegionID: candidates[pair.candidate].id)
            kinds[candidates[pair.candidate].id] = .matched
            scores[candidates[pair.candidate].id] = pair.score
        }
        for candidate in candidates.indices where !usedCandidates.contains(candidate) {
            let region = candidates[candidate]
            mapped[region.id] = mintedID(attemptID: attemptID, rawRegionID: region.id)
            kinds[region.id] = .new
        }
        let themeIDs = rawIDs.compactMap { mapped[$0] }
        guard themeIDs.count == rawIDs.count, Set(themeIDs).count == themeIDs.count else { throw VoiceOSError("全景主题身份重复") }
        let matches = proposal.regions.map { region -> PanoramaThemeMatch in
            let reference = reference(region: region, questionsByRegion: questionsByRegion)
            return .init(themeID: mapped[region.id]!, rawRegionID: region.id, regionTitle: reference.title,
                         questionTitles: reference.questionTitles, claimIDs: reference.claimIDs.sorted(),
                         sourceIDs: reference.sourceIDs.sorted(), quoteKeys: reference.quoteKeys.sorted(),
                         kind: kinds[region.id]!, score: scores[region.id])
        }
        let regions = proposal.regions.map { PanoramaRegion(id: mapped[$0.id]!, title: $0.title, summary: $0.summary) }
        let questions = proposal.questions.map { question in
            PanoramaQuestion(id: question.id, regionID: mapped[question.regionID]!, title: question.title,
                             summary: question.summary, evidence: question.evidence)
        }
        let areas = try proposal.areas.map { area -> PanoramaArea in
            for regionID in area.regionIDs where mapped[regionID] == nil { throw VoiceOSError("全景大区引用了未知区域") }
            return .init(id: area.id, title: area.title, summary: area.summary, regionIDs: area.regionIDs.map { mapped[$0]! })
        }
        if !areas.isEmpty {
            let covered = areas.flatMap(\.regionIDs)
            guard Set(covered) == Set(regions.map(\.id)), covered.count == regions.count else {
                throw VoiceOSError("全景大区没有恰好覆盖每个区域一次")
            }
        }
        return (.init(regions: regions, questions: questions, relations: proposal.relations,
                      unrepresentedSources: proposal.unrepresentedSources, unrepresentedClaims: proposal.unrepresentedClaims,
                      areas: areas), matches)
    }

    private static func reference(region: PanoramaRegion, questionsByRegion: [String: [PanoramaQuestion]]) -> PanoramaThemeMap.Reference {
        reference(id: region.id, title: region.title, questions: questionsByRegion[region.id] ?? [])
    }
}

struct PanoramaThemeBatch: Sendable {
    let attemptID: String
    let phase: PanoramaPhase
    let createdAt: String
    let matches: [PanoramaThemeMatch]
}

extension VoiceOSStore {
    func latestPanoramaThemeMap() throws -> PanoramaThemeMap? {
        let rows=try db.query("""
            SELECT b.attempt_id,b.phase,a.theme_id,a.region_title,a.question_titles_json,a.claim_ids_json,a.source_ids_json,a.quote_keys_json
            FROM panorama_theme_batches b
            JOIN panorama_attempts p ON p.id=b.attempt_id
            JOIN panorama_theme_appearances a ON a.attempt_id=b.attempt_id AND a.phase=b.phase
            ORDER BY p.rowid DESC,CASE b.phase WHEN 'completed' THEN 0 ELSE 1 END,a.rowid
            """)
        guard let first=rows.first,let attempt=first["attempt_id"],let phase=first["phase"] else { return nil }
        func strings(_ row: [String:String], _ key: String) -> [String] {
            guard let json=row[key] else { return [] }
            return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
        }
        let selected=rows.filter { $0["attempt_id"] == attempt && $0["phase"] == phase }
        return .init(references: selected.map { row in
            .init(id: row["theme_id"]!, title: row["region_title"]!, questionTitles: strings(row,"question_titles_json"),
                  claimIDs: Set(strings(row,"claim_ids_json")), sourceIDs: Set(strings(row,"source_ids_json")),
                  quoteKeys: Set(strings(row,"quote_keys_json")))
        })
    }

    func recordPanoramaThemeBatch(_ batch: PanoramaThemeBatch, replacing: Bool) throws {
        guard batch.phase == .synthesis || batch.phase == .completed else { throw VoiceOSError("全景主题批次阶段无效") }
        let phase=batch.phase.rawValue
        if replacing {
            try db.execute("DELETE FROM panorama_theme_appearances WHERE attempt_id=? AND phase=?", [batch.attemptID,phase])
            try db.execute("DELETE FROM panorama_theme_batches WHERE attempt_id=? AND phase=?", [batch.attemptID,phase])
        }
        try db.execute("INSERT INTO panorama_theme_batches(attempt_id,phase,theme_count,created_at) VALUES(?,?,?,?)",
                       [batch.attemptID,phase,String(batch.matches.count),batch.createdAt])
        for match in batch.matches {
            try db.execute("""
                INSERT INTO panorama_themes(id,title,created_at,last_seen_at) VALUES(?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET title=excluded.title,last_seen_at=excluded.last_seen_at
                """, [match.themeID,match.regionTitle,batch.createdAt,batch.createdAt])
            try db.execute("""
                INSERT INTO panorama_theme_appearances(attempt_id,phase,theme_id,raw_region_id,region_title,question_titles_json,claim_ids_json,source_ids_json,quote_keys_json,match_kind,match_score,created_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                """, [batch.attemptID,phase,match.themeID,match.rawRegionID,match.regionTitle,
                      try Self.relevanceJSON(match.questionTitles),try Self.relevanceJSON(match.claimIDs),
                      try Self.relevanceJSON(match.sourceIDs),try Self.relevanceJSON(match.quoteKeys),
                      match.kind.rawValue,match.score.map { String($0) },batch.createdAt])
        }
    }

    func backfillPanoramaThemeLedger() throws {
        let rows=try db.query("""
            SELECT id,state,snapshot_json FROM panorama_attempts
            WHERE snapshot_json IS NOT NULL AND id NOT IN (SELECT attempt_id FROM panorama_theme_batches)
            ORDER BY rowid
            """)
        guard !rows.isEmpty else { return }
        try db.transaction {
            for row in rows {
                guard let id=row["id"],let json=row["snapshot_json"],
                      let snapshot=try? JSONDecoder().decode(PanoramaSnapshot.self, from: Data(json.utf8)),
                      PanoramaThemeMap.isEligible(snapshot, attemptState: row["state"] ?? "") else { continue }
                let phase: PanoramaPhase = snapshot.workflow?.phase == .completed ? .completed : .synthesis
                let matches=PanoramaThemeMap.make(snapshot: snapshot).references.map { reference -> PanoramaThemeMatch in
                    let themeID=PanoramaThemeIdentity.adoptableID(reference.id) ? reference.id
                        : PanoramaThemeIdentity.mintedID(attemptID: id, rawRegionID: reference.id)
                    return .init(themeID: themeID, rawRegionID: reference.id, regionTitle: reference.title,
                                 questionTitles: reference.questionTitles, claimIDs: reference.claimIDs.sorted(),
                                 sourceIDs: reference.sourceIDs.sorted(), quoteKeys: reference.quoteKeys.sorted(),
                                 kind: .new, score: nil)
                }
                try recordPanoramaThemeBatch(.init(attemptID: id, phase: phase, createdAt: snapshot.createdAt, matches: matches), replacing: false)
            }
        }
    }

    func panoramaThemeHistory() throws -> [String: PanoramaThemeHistory] {
        var history: [String: PanoramaThemeHistory]=[:]
        for row in try db.query("""
            SELECT theme_id,COUNT(DISTINCT attempt_id) AS count,MIN(created_at) AS first_seen,MAX(created_at) AS last_seen
            FROM panorama_theme_appearances GROUP BY theme_id
            """) {
            guard let id=row["theme_id"],let count=row["count"].flatMap(Int.init),
                  let first=row["first_seen"],let last=row["last_seen"] else { continue }
            history[id] = .init(appearanceCount: count, firstSeenAt: first, lastSeenAt: last)
        }
        return history
    }
}
