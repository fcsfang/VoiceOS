import SwiftUI
import VoiceOSCore

// MARK: - Cache identity

/// Everything the stage renders or positions, in comparable form. Deliberately
/// not keyed by the attempt id alone: that id survives partial publishes and
/// final synthesis, while region and question ids are replaced underneath it.
struct ConstellationContentKey: Hashable, Sendable {
    let snapshotID: String
    let regions: [String]
    let questions: [String]
    let regionPairCounts: [String]
    let evidenceSourceIDs: [String]
    let sourceStamps: [String]

    init(snapshot: PanoramaSnapshot) {
        snapshotID = snapshot.id
        regions = snapshot.proposal.regions.map { $0.id + "\u{1F}" + $0.title }.sorted()
        questions = snapshot.proposal.questions.map { $0.id + "\u{1F}" + $0.regionID }.sorted()
        let regionIDByQuestion = Dictionary(uniqueKeysWithValues: snapshot.proposal.questions.map { ($0.id, $0.regionID) })
        regionPairCounts = snapshot.proposal.relations.compactMap { relation -> String? in
            guard let from = regionIDByQuestion[relation.from], let to = regionIDByQuestion[relation.to], from != to else { return nil }
            let pair = ConstellationModel.Pair(from, to)
            return pair.a + "|" + pair.b + "|" + relation.id
        }.sorted()
        let cited = Set(snapshot.proposal.questions.flatMap { $0.evidence.map(\.sourceID) })
        evidenceSourceIDs = cited.sorted()
        sourceStamps = snapshot.input.sources.filter { cited.contains($0.id) }.map { $0.id + "\u{1F}" + $0.occurredAt }.sorted()
    }
}

// MARK: - Search matches

/// Region-level search state published to the toolbar. Counted from the same
/// derived `searchText` the dimming pass uses, so the number matches the canvas.
struct ConstellationSearchMatches: Equatable, Sendable {
    var count = 0
    var includesQuestionOrRelationText = false
}

// MARK: - Derived model

/// One derivation pass per content key. Recent flags, ordering, search text and
/// edge aggregation are all fixed here so no body evaluation re-parses dates.
struct ConstellationModel: Sendable {
    struct Region: Identifiable, Sendable {
        let id: String
        let title: String
        let summary: String
        let questionIDs: [String]
        let evidenceCount: Int
        let isRecent: Bool
        let searchText: String
    }

    /// Undirected region pair in canonical order, so one pair can never exist
    /// in two orders or be counted twice.
    struct Pair: Hashable, Comparable, Sendable {
        let a: String
        let b: String

        init(_ x: String, _ y: String) {
            if x < y { a = x; b = y } else { a = y; b = x }
        }

        static func < (lhs: Pair, rhs: Pair) -> Bool {
            lhs.a == rhs.a ? lhs.b < rhs.b : lhs.a < rhs.a
        }
    }

    struct WeightedPair: Sendable {
        let pair: Pair
        let weight: Int
    }

    struct RegionEdge: Identifiable, Sendable {
        let pair: Pair
        let relationIDs: [String]

        var id: String { pair.a + "|" + pair.b }
        var count: Int { relationIDs.count }
    }

    let regions: [Region]
    let regionByID: [String: Region]
    let edges: [RegionEdge]
    let affinityPairs: [WeightedPair]
    let questionByID: [String: PanoramaQuestion]
    let relationByID: [String: PanoramaRelation]

    init(snapshot: PanoramaSnapshot, now: Date) {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var sourceDate: [String: Date] = [:]
        for source in snapshot.input.sources {
            sourceDate[source.id] = plain.date(from: source.occurredAt) ?? fractional.date(from: source.occurredAt) ?? .distantPast
        }

        let questions = Dictionary(uniqueKeysWithValues: snapshot.proposal.questions.map { ($0.id, $0) })
        questionByID = questions
        relationByID = Dictionary(uniqueKeysWithValues: snapshot.proposal.relations.map { ($0.id, $0) })

        let cutoff = now.addingTimeInterval(-14 * 86_400)
        var latestDate: [String: Date] = [:]
        var recentFlag: [String: Bool] = [:]
        for question in snapshot.proposal.questions {
            var latest = Date.distantPast
            var recent = false
            for item in question.evidence {
                let date = sourceDate[item.sourceID] ?? .distantPast
                if date > latest { latest = date }
                if date >= cutoff { recent = true }
            }
            latestDate[question.id] = latest
            recentFlag[question.id] = recent
        }

        let questionOrder = Dictionary(uniqueKeysWithValues: snapshot.proposal.questions.enumerated().map { ($0.element.id, $0.offset) })
        var questionsByRegion: [String: [PanoramaQuestion]] = [:]
        for question in snapshot.proposal.questions {
            questionsByRegion[question.regionID, default: []].append(question)
        }
        for region in snapshot.proposal.regions {
            questionsByRegion[region.id]?.sort { lhs, rhs in
                let left = latestDate[lhs.id] ?? .distantPast
                let right = latestDate[rhs.id] ?? .distantPast
                return left == right ? (questionOrder[lhs.id] ?? 0) < (questionOrder[rhs.id] ?? 0) : left > right
            }
        }

        var regionLatest: [String: Date] = [:]
        var regionRecent: [String: Bool] = [:]
        var regionEvidence: [String: Int] = [:]
        var regionSources: [String: Set<String>] = [:]
        var searchParts: [String: [String]] = [:]
        for region in snapshot.proposal.regions {
            let regionQuestions = questionsByRegion[region.id] ?? []
            regionLatest[region.id] = regionQuestions.compactMap { latestDate[$0.id] }.max() ?? .distantPast
            regionRecent[region.id] = regionQuestions.contains { recentFlag[$0.id] == true }
            regionEvidence[region.id] = regionQuestions.reduce(0) { $0 + $1.evidence.count }
            var sources = Set<String>()
            var parts = [region.title, region.summary]
            for question in regionQuestions {
                sources.formUnion(question.evidence.map(\.sourceID))
                parts.append(question.title)
                parts.append(question.summary)
            }
            regionSources[region.id] = sources
            searchParts[region.id] = parts
        }

        var edgeMap: [Pair: [String]] = [:]
        for relation in snapshot.proposal.relations {
            guard let from = questions[relation.from]?.regionID, let to = questions[relation.to]?.regionID else { continue }
            searchParts[from]?.append(relation.label)
            searchParts[from]?.append(relation.explanation)
            if to != from {
                searchParts[to]?.append(relation.label)
                searchParts[to]?.append(relation.explanation)
                edgeMap[Pair(from, to), default: []].append(relation.id)
            }
        }

        let orderedRegions = snapshot.proposal.regions.enumerated().sorted { lhs, rhs in
            let left = regionLatest[lhs.element.id] ?? .distantPast
            let right = regionLatest[rhs.element.id] ?? .distantPast
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)

        regions = orderedRegions.map { region in
            let regionQuestions = questionsByRegion[region.id] ?? []
            return Region(
                id: region.id,
                title: region.title,
                summary: region.summary,
                questionIDs: regionQuestions.map(\.id),
                evidenceCount: regionEvidence[region.id] ?? 0,
                isRecent: regionRecent[region.id] ?? false,
                searchText: (searchParts[region.id] ?? []).joined(separator: "\n").lowercased()
            )
        }
        regionByID = Dictionary(uniqueKeysWithValues: regions.map { ($0.id, $0) })
        edges = edgeMap.keys.sorted().map { RegionEdge(pair: $0, relationIDs: edgeMap[$0] ?? []) }

        var affinity: [WeightedPair] = []
        let regionIDs = snapshot.proposal.regions.map(\.id).sorted()
        for i in 0..<regionIDs.count {
            for j in (i + 1)..<regionIDs.count {
                guard let left = regionSources[regionIDs[i]], let right = regionSources[regionIDs[j]] else { continue }
                let shared = left.intersection(right).count
                if shared > 0 { affinity.append(WeightedPair(pair: Pair(regionIDs[i], regionIDs[j]), weight: shared)) }
            }
        }
        affinityPairs = affinity.sorted { $0.pair < $1.pair }
    }
}

// MARK: - Layout (pure, deterministic, cached once per key)

struct ConstellationLayout: Equatable, Sendable {
    static let cardSize = CGSize(width: 150, height: 64)
    static let cardGap: CGFloat = 16
    static let layoutMargin: CGFloat = 24

    let centers: [String: CGPoint]
    let worldSize: CGSize

    /// Deterministic for (model, seeds): fixed iteration order over sorted ids,
    /// no RNG, no Hasher, serial arithmetic. Seeds are the previous layout for
    /// surviving ids so growth nudges the map instead of reshuffling it.
    static func compute(model: ConstellationModel, seeds: [String: CGPoint]) -> ConstellationLayout {
        let ids = model.regions.map(\.id).sorted()
        let count = ids.count
        guard count > 0 else {
            return ConstellationLayout(centers: [:], worldSize: CGSize(width: layoutMargin * 2, height: layoutMargin * 2))
        }
        var indexByID: [String: Int] = [:]
        for (index, id) in ids.enumerated() { indexByID[id] = index }

        var points = ids.enumerated().map { index, id -> CGPoint in
            seeds[id] ?? coldSeed(index: index, count: count)
        }

        let edgeSprings: [(a: Int, b: Int, weight: CGFloat)] = model.edges.compactMap { edge in
            guard let a = indexByID[edge.pair.a], let b = indexByID[edge.pair.b] else { return nil }
            return (a, b, CGFloat(min(edge.count, 3)))
        }
        let affinitySprings: [(a: Int, b: Int, weight: CGFloat)] = model.affinityPairs.compactMap { pair in
            guard let a = indexByID[pair.pair.a], let b = indexByID[pair.pair.b] else { return nil }
            return (a, b, CGFloat(min(pair.weight, 3)))
        }

        // Repulsion measures the gap between card extents, not point distance:
        // a point force expands the map to ~9000 units, and scaling that back
        // down to a fit-size world stacks the fixed 176×72 cards on each other.
        let packing: CGFloat = 8
        let relationTarget: CGFloat = 270
        let relationStrength: CGFloat = 0.02
        let affinityTarget: CGFloat = 360
        let affinityStrength: CGFloat = 0.004
        let centering: CGFloat = 0.006
        let anchoring: CGFloat = 0.10
        let iterations = 300

        var displacement = [CGVector](repeating: .zero, count: count)
        for iteration in 0..<iterations {
            let cooling = CGFloat(iterations - iteration) / CGFloat(iterations)
            let cap = 40 * cooling + 1
            for i in 0..<count { displacement[i] = .zero }

            for i in 0..<count {
                for j in (i + 1)..<count {
                    let dx = points[i].x - points[j].x
                    let dy = points[i].y - points[j].y
                    let overlapX = cardSize.width + cardGap - abs(dx)
                    let overlapY = cardSize.height + cardGap - abs(dy)
                    guard overlapX > 0, overlapY > 0 else { continue }
                    if overlapX < overlapY {
                        let direction: CGFloat = dx < 0 ? -1 : 1
                        let force = packing * overlapX * direction
                        displacement[i].dx += force
                        displacement[j].dx -= force
                    } else {
                        let direction: CGFloat = dy < 0 ? -1 : 1
                        let force = packing * overlapY * direction
                        displacement[i].dy += force
                        displacement[j].dy -= force
                    }
                }
            }

            for spring in edgeSprings {
                let dx = points[spring.b].x - points[spring.a].x
                let dy = points[spring.b].y - points[spring.a].y
                let distance = max(sqrt(dx * dx + dy * dy), 0.001)
                let force = (distance - relationTarget) * relationStrength * spring.weight
                let ux = dx / distance
                let uy = dy / distance
                displacement[spring.a].dx += ux * force
                displacement[spring.a].dy += uy * force
                displacement[spring.b].dx -= ux * force
                displacement[spring.b].dy -= uy * force
            }

            // Shared-source affinity is a weak positional pull only; it is never drawn.
            for spring in affinitySprings {
                let dx = points[spring.b].x - points[spring.a].x
                let dy = points[spring.b].y - points[spring.a].y
                let distance = max(sqrt(dx * dx + dy * dy), 0.001)
                let force = (distance - affinityTarget) * affinityStrength * spring.weight
                let ux = dx / distance
                let uy = dy / distance
                displacement[spring.a].dx += ux * force
                displacement[spring.a].dy += uy * force
                displacement[spring.b].dx -= ux * force
                displacement[spring.b].dy -= uy * force
            }

            for i in 0..<count {
                displacement[i].dx -= points[i].x * centering
                displacement[i].dy -= points[i].y * centering
                if let seed = seeds[ids[i]] {
                    displacement[i].dx += (seed.x - points[i].x) * anchoring * cooling
                    displacement[i].dy += (seed.y - points[i].y) * anchoring * cooling
                }
            }

            for i in 0..<count {
                let dx = displacement[i].dx
                let dy = displacement[i].dy
                let length = sqrt(dx * dx + dy * dy)
                if length > cap {
                    let scale = cap / length
                    points[i].x += dx * scale
                    points[i].y += dy * scale
                } else {
                    points[i].x += dx
                    points[i].y += dy
                }
            }
        }

        separateOverlaps(&points)
        return normalized(points, ids: ids)
    }

    private static func coldSeed(index: Int, count: Int) -> CGPoint {
        let angle = Double(index) * 2.39996322972865332
        let fraction = sqrt((Double(index) + 0.5) / Double(max(count, 1)))
        return CGPoint(x: cos(angle) * 620 * fraction, y: sin(angle) * 388 * fraction)
    }

    private static func separateOverlaps(_ points: inout [CGPoint]) {
        let minimumX = cardSize.width + cardGap
        let minimumY = cardSize.height + cardGap
        guard points.count > 1 else { return }
        for i in 0..<(points.count - 1) {
            for j in (i + 1)..<points.count {
                let dx = points[j].x - points[i].x
                let dy = points[j].y - points[i].y
                let overlapX = minimumX - abs(dx)
                let overlapY = minimumY - abs(dy)
                guard overlapX > 0, overlapY > 0 else { continue }
                if overlapX < overlapY {
                    let direction: CGFloat = dx < 0 ? -1 : 1
                    let push = overlapX / 2 * direction
                    points[i].x -= push
                    points[j].x += push
                } else {
                    let direction: CGFloat = dy < 0 ? -1 : 1
                    let push = overlapY / 2 * direction
                    points[i].y -= push
                    points[j].y += push
                }
            }
        }
    }

    private static func normalized(_ points: [CGPoint], ids: [String]) -> ConstellationLayout {
        let placed = points
        let box = boundingBox(placed)
        var centers: [String: CGPoint] = [:]
        for (index, point) in placed.enumerated() {
            centers[ids[index]] = CGPoint(x: point.x - box.minX + layoutMargin, y: point.y - box.minY + layoutMargin)
        }
        return ConstellationLayout(
            centers: centers,
            worldSize: CGSize(width: box.width + layoutMargin * 2, height: box.height + layoutMargin * 2)
        )
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for point in points {
            minX = min(minX, point.x - cardSize.width / 2)
            minY = min(minY, point.y - cardSize.height / 2)
            maxX = max(maxX, point.x + cardSize.width / 2)
            maxY = max(maxY, point.y + cardSize.height / 2)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

@MainActor
final class ConstellationLayoutStore {
    private var cachedKey: ConstellationContentKey?
    private var cachedLayout: ConstellationLayout?

    func layout(for model: ConstellationModel, key: ConstellationContentKey) -> ConstellationLayout {
        if key == cachedKey, let cachedLayout { return cachedLayout }
        let seeds = cachedLayout?.centers ?? [:]
        let next = ConstellationLayout.compute(model: model, seeds: seeds)
        cachedKey = key
        cachedLayout = next
        return next
    }
}

// MARK: - Camera

struct ConstellationCamera: Equatable, Sendable {
    enum Mode: Equatable, Sendable { case fit, free }
    static let zoomRange: ClosedRange<CGFloat> = 0.35...3.0
    static let initial = ConstellationCamera(zoom: 1, pan: .zero, mode: .fit)

    private(set) var zoom: CGFloat
    private(set) var pan: CGPoint
    private(set) var mode: Mode

    private init(zoom: CGFloat, pan: CGPoint, mode: Mode) {
        self.zoom = zoom
        self.pan = pan
        self.mode = mode
    }

    func project(_ world: CGPoint) -> CGPoint {
        CGPoint(x: pan.x + world.x * zoom, y: pan.y + world.y * zoom)
    }

    static func fitting(world: CGSize, canvas: CGSize, margin: CGFloat = 24) -> Self {
        guard world.width > 0, world.height > 0, canvas.width > 0, canvas.height > 0 else { return initial }
        let raw = min((canvas.width - margin * 2) / world.width, (canvas.height - margin * 2) / world.height)
        let zoom = min(max(raw, zoomRange.lowerBound), 1)
        return Self(
            zoom: zoom,
            pan: CGPoint(x: (canvas.width - world.width * zoom) / 2, y: (canvas.height - world.height * zoom) / 2),
            mode: .fit
        )
    }

    func fitted(to box: CGRect, canvas: CGSize, world: CGSize, margin: CGFloat = 24) -> Self {
        guard box.width > 0, box.height > 0, canvas.width > 0, canvas.height > 0 else { return self }
        let raw = min((canvas.width - margin * 2) / box.width, (canvas.height - margin * 2) / box.height)
        let zoom = min(max(raw, Self.zoomRange.lowerBound), 1)
        var next = Self(
            zoom: zoom,
            pan: CGPoint(x: canvas.width / 2 - box.midX * zoom, y: canvas.height / 2 - box.midY * zoom),
            mode: .free
        )
        next.clampPan(canvas: canvas, world: world)
        return next
    }

    func panned(by delta: CGSize, canvas: CGSize, world: CGSize) -> Self {
        var next = Self(zoom: zoom, pan: CGPoint(x: pan.x + delta.width, y: pan.y + delta.height), mode: .free)
        next.clampPan(canvas: canvas, world: world)
        return next
    }

    func centered(on point: CGPoint, canvas: CGSize, world: CGSize) -> Self {
        var next = Self(zoom: zoom, pan: CGPoint(x: canvas.width / 2 - point.x * zoom, y: canvas.height / 2 - point.y * zoom), mode: mode)
        next.clampPan(canvas: canvas, world: world)
        return next
    }

    func magnified(toZoom raw: CGFloat, anchor: CGPoint, canvas: CGSize, world: CGSize) -> Self {
        guard zoom > 0 else { return self }
        let target = min(max(raw, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let ratio = target / zoom
        var next = Self(
            zoom: target,
            pan: CGPoint(x: anchor.x - (anchor.x - pan.x) * ratio, y: anchor.y - (anchor.y - pan.y) * ratio),
            mode: .free
        )
        next.clampPan(canvas: canvas, world: world)
        return next
    }

    func clamped(canvas: CGSize, world: CGSize) -> Self {
        var next = self
        next.clampPan(canvas: canvas, world: world)
        return next
    }

    private mutating func clampPan(canvas: CGSize, world: CGSize) {
        guard canvas.width > 0, canvas.height > 0, world.width > 0, world.height > 0 else { return }
        let extent = CGSize(width: world.width * zoom, height: world.height * zoom)
        pan.x = Self.clampAxis(pan.x, canvasExtent: canvas.width, worldExtent: extent.width)
        pan.y = Self.clampAxis(pan.y, canvasExtent: canvas.height, worldExtent: extent.height)
    }

    private static func clampAxis(_ value: CGFloat, canvasExtent: CGFloat, worldExtent: CGFloat) -> CGFloat {
        let lower = 96 - worldExtent
        let upper = canvasExtent - 96
        guard lower <= upper else { return (canvasExtent - worldExtent) / 2 }
        return min(max(value, lower), upper)
    }
}

// MARK: - Stage view

struct PanoramaConstellationView: View {
    let snapshot: PanoramaSnapshot
    let query: String
    let recentOnly: Bool
    @Binding var selection: PanoramaSelection?
    @Binding var focusedRegionID: String?
    @Binding var searchMatches: ConstellationSearchMatches
    let recenterToken: Int

    @State private var stage: StageState?
    @State private var camera = ConstellationCamera.initial
    @State private var store = ConstellationLayoutStore()
    @State private var hoveredRegionID: String?
    @State private var suppressClick = false
    @State private var dragOrigin: ConstellationCamera?
    @State private var magnifyOrigin: (camera: ConstellationCamera, anchor: CGPoint)?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { _ in
                            selection = nil
                            focusedRegionID = nil
                        })
                    if let stage {
                        EdgeLayer(
                            stage: stage,
                            camera: camera,
                            highlightedPair: highlightedPair(in: stage),
                            hoveredRegionID: hoveredRegionID,
                            query: normalizedQuery
                        )
                        .allowsHitTesting(false)
                        worldLayer(stage: stage)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()
                if let stage {
                    VStack {
                        Spacer(minLength: 0)
                        HStack {
                            ConstellationLegend(
                                isPartial: snapshot.isPartial,
                                hasEdges: !stage.model.edges.isEmpty,
                                hasRecent: recentOnly && stage.model.regions.contains { $0.isRecent }
                            )
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                    }
                    .allowsHitTesting(false)
                    VStack {
                        HStack {
                            Spacer(minLength: 0)
                            zoomCluster(canvas: size, world: stage.layout.worldSize)
                        }
                        .padding(12)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .highPriorityGesture(dragGesture(canvas: size, world: stage?.layout.worldSize ?? .zero))
            .simultaneousGesture(magnifyGesture(canvas: size, world: stage?.layout.worldSize ?? .zero))
            .task(id: contentKey) {
                let model = ConstellationModel(snapshot: snapshot, now: .now)
                let layout = store.layout(for: model, key: contentKey)
                let survived = stage.map { previous in
                    previous.model.regionByID.keys.contains { model.regionByID[$0] != nil }
                } ?? false
                stage = StageState(key: contentKey, model: model, layout: layout)
                publishSearchMatches(for: model)
                if !survived || (camera.mode == .fit && focusedRegionID == nil) {
                    camera = .fitting(world: layout.worldSize, canvas: size)
                } else {
                    camera = camera.clamped(canvas: size, world: layout.worldSize)
                }
            }
            .onChange(of: normalizedQuery) { _, _ in
                if let stage {
                    publishSearchMatches(for: stage.model)
                } else {
                    searchMatches = ConstellationSearchMatches()
                }
            }
            .onChange(of: recenterToken) { _, _ in revealMatches(canvas: size) }
            .onChange(of: size) { oldSize, newSize in
                guard let stage else { return }
                let grew = newSize.width >= oldSize.width && newSize.height >= oldSize.height
                if camera.mode == .fit, grew {
                    camera = .fitting(world: stage.layout.worldSize, canvas: newSize)
                } else if camera.mode == .fit, newSize.width < oldSize.width,
                          let id = focusedRegionID, let center = stage.layout.centers[id] {
                    camera = camera.centered(on: center, canvas: newSize, world: stage.layout.worldSize)
                } else {
                    camera = camera.clamped(canvas: newSize, world: stage.layout.worldSize)
                }
            }
        }
    }

    private var contentKey: ConstellationContentKey { ConstellationContentKey(snapshot: snapshot) }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matchingRegionIDs(in model: ConstellationModel) -> [String] {
        let needle = normalizedQuery
        guard !needle.isEmpty else { return [] }
        return model.regions.filter { $0.searchText.contains(needle) }.map(\.id)
    }

    private func publishSearchMatches(for model: ConstellationModel) {
        let ids = matchingRegionIDs(in: model)
        let needle = normalizedQuery
        let includesQuestionOrRelationText = ids.contains { id in
            guard let region = model.regionByID[id] else { return false }
            return !(region.title + "\n" + region.summary).lowercased().contains(needle)
        }
        searchMatches = ConstellationSearchMatches(count: ids.count, includesQuestionOrRelationText: includesQuestionOrRelationText)
    }

    private func revealMatches(canvas: CGSize) {
        guard let stage else { return }
        let rects = matchingRegionIDs(in: stage.model).compactMap { id -> CGRect? in
            guard let center = stage.layout.centers[id] else { return nil }
            return CGRect(
                x: center.x - ConstellationLayout.cardSize.width / 2,
                y: center.y - ConstellationLayout.cardSize.height / 2,
                width: ConstellationLayout.cardSize.width,
                height: ConstellationLayout.cardSize.height
            )
        }
        guard let first = rects.first else { return }
        let box = rects.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -24, dy: -24)
        camera = camera.fitted(to: box, canvas: canvas, world: stage.layout.worldSize)
    }

    private func highlightedPair(in stage: StageState) -> ConstellationModel.Pair? {
        guard case .relation(let id)? = selection else { return nil }
        return stage.model.edges.first { $0.relationIDs.contains(id) }?.pair
    }

    private func worldLayer(stage: StageState) -> some View {
        let highlighted = highlightedPair(in: stage)
        let normalizedQuery = self.normalizedQuery
        return ZStack(alignment: .topLeading) {
            ForEach(stage.model.regions) { region in
                let center = stage.layout.centers[region.id] ?? .zero
                RegionCard(
                    region: region,
                    focused: focusedRegionID == region.id,
                    hovered: hoveredRegionID == region.id,
                    selected: highlighted.map { $0.a == region.id || $0.b == region.id } ?? false,
                    recent: recentOnly && region.isRecent,
                    compact: camera.zoom < 0.78,
                    dimmed: dimmedOpacity(region, query: normalizedQuery),
                    onOpen: { open(region.id) }
                )
                .onHover { inside in
                    if inside {
                        hoveredRegionID = region.id
                    } else if hoveredRegionID == region.id {
                        hoveredRegionID = nil
                    }
                }
                .position(x: center.x, y: center.y)
            }
        }
        .frame(width: stage.layout.worldSize.width, height: stage.layout.worldSize.height, alignment: .topLeading)
        .scaleEffect(camera.zoom, anchor: .topLeading)
        .offset(x: camera.pan.x, y: camera.pan.y)
    }

    private func dimmedOpacity(_ region: ConstellationModel.Region, query: String) -> Double {
        var opacity = 1.0
        if !query.isEmpty, !region.searchText.contains(query) { opacity = 0.25 }
        if recentOnly, !region.isRecent { opacity = min(opacity, 0.55) }
        return opacity
    }

    private func open(_ id: String) {
        guard !suppressClick else { return }
        focusedRegionID = id
        selection = nil
    }

    private func dragGesture(canvas: CGSize, world: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard world.width > 0, world.height > 0 else { return }
                if dragOrigin == nil { dragOrigin = camera }
                suppressClick = true
                guard let base = dragOrigin else { return }
                camera = base.panned(by: value.translation, canvas: canvas, world: world)
            }
            .onEnded { _ in
                dragOrigin = nil
                DispatchQueue.main.async { suppressClick = false }
            }
    }

    private func magnifyGesture(canvas: CGSize, world: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard world.width > 0, world.height > 0 else { return }
                if magnifyOrigin == nil {
                    magnifyOrigin = (camera, CGPoint(x: value.startAnchor.x * canvas.width, y: value.startAnchor.y * canvas.height))
                }
                guard let origin = magnifyOrigin else { return }
                camera = origin.camera.magnified(
                    toZoom: origin.camera.zoom * value.magnification,
                    anchor: origin.anchor,
                    canvas: canvas,
                    world: world
                )
            }
            .onEnded { _ in magnifyOrigin = nil }
    }

    private func zoomCluster(canvas: CGSize, world: CGSize) -> some View {
        ZoomCluster(
            onZoomOut: { zoom(by: 1 / 1.25, canvas: canvas, world: world) },
            onZoomIn: { zoom(by: 1.25, canvas: canvas, world: world) },
            onFit: { camera = .fitting(world: world, canvas: canvas) }
        )
    }

    private func zoom(by factor: CGFloat, canvas: CGSize, world: CGSize) {
        let anchor = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        camera = camera.magnified(toZoom: camera.zoom * factor, anchor: anchor, canvas: canvas, world: world)
    }
}

private struct StageState {
    let key: ConstellationContentKey
    let model: ConstellationModel
    let layout: ConstellationLayout
}

// MARK: - Canvas pieces

/// Screen-space Canvas: one bezier per aggregated region pair. Projecting here
/// keeps stroke widths constant at every zoom; edges never hit-test and are
/// never the only way to reach a relation.
private struct EdgeLayer: View {
    let stage: StageState
    let camera: ConstellationCamera
    let highlightedPair: ConstellationModel.Pair?
    let hoveredRegionID: String?
    let query: String

    var body: some View {
        Canvas { context, size in
            let viewport = CGRect(origin: .zero, size: size).insetBy(dx: -120, dy: -120)
            for edge in stage.model.edges {
                guard let startCenter = stage.layout.centers[edge.pair.a],
                      let endCenter = stage.layout.centers[edge.pair.b] else { continue }
                let start = camera.project(startCenter)
                let end = camera.project(endCenter)
                guard viewport.contains(start) || viewport.contains(end) else { continue }
                let dx = end.x - start.x
                let dy = end.y - start.y
                let length = max(sqrt(dx * dx + dy * dy), 1)
                let bulge = min(40, length * 0.12)
                let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                let control = CGPoint(x: mid.x - dy / length * bulge, y: mid.y + dx / length * bulge)
                var path = Path()
                path.move(to: start)
                path.addQuadCurve(to: end, control: control)

                let highlighted = edge.pair == highlightedPair
                    || hoveredRegionID.map { edge.pair.a == $0 || edge.pair.b == $0 } == true
                let dimmed = !query.isEmpty
                    && !(stage.model.regionByID[edge.pair.a]?.searchText.contains(query) ?? false)
                    && !(stage.model.regionByID[edge.pair.b]?.searchText.contains(query) ?? false)
                context.opacity = dimmed ? 0.25 : 1
                context.stroke(
                    path,
                    with: .color(highlighted ? Color.accentColor : Color.secondary.opacity(0.45)),
                    style: StrokeStyle(lineWidth: highlighted ? 2 : 1, dash: highlighted ? [6, 3] : [5, 4])
                )
            }
        }
        .accessibilityHidden(true)
    }
}

private struct RegionCard: View {
    @Environment(\.workspacePalette) private var palette
    let region: ConstellationModel.Region
    let focused: Bool
    let hovered: Bool
    let selected: Bool
    let recent: Bool
    let compact: Bool
    let dimmed: Double
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: compact ? 0 : 5) {
                if !compact {
                    HStack(spacing: 5) {
                        Text("\(region.questionIDs.count) 个问题").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if recent {
                            Circle().fill(palette.accent).frame(width: 5, height: 5).accessibilityLabel("近期更新的区域")
                        }
                    }
                }
                Text(region.title)
                    .font(.system(size: compact ? 14 : 13.5, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, compact ? 8 : 9)
            .frame(width: ConstellationLayout.cardSize.width, height: ConstellationLayout.cardSize.height, alignment: compact ? .leading : .topLeading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14).strokeBorder(borderColor, lineWidth: focused || selected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .opacity(dimmed)
        .help(region.title)
        .accessibilityLabel("探索区域：\(region.title)，\(region.questionIDs.count) 个问题")
        .accessibilityHint("打开区域摘要与问题")
    }

    private var borderColor: Color {
        if focused || selected { return palette.accent }
        if hovered { return palette.accent.opacity(0.55) }
        return palette.border
    }
}

private struct ZoomCluster: View {
    let onZoomOut: () -> Void
    let onZoomIn: () -> Void
    let onFit: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onZoomOut) {
                Image(systemName: "minus").frame(width: 24, height: 24)
            }
            .keyboardShortcut("-", modifiers: .command)
            .help("缩小")
            .accessibilityLabel("缩小")

            Button(action: onZoomIn) {
                Image(systemName: "plus").frame(width: 24, height: 24)
            }
            .keyboardShortcut("=", modifiers: .command)
            .help("放大")
            .accessibilityLabel("放大")

            Divider().frame(height: 14)

            Button(action: onFit) {
                Text("适配").font(.system(size: 11)).padding(.horizontal, 4).frame(height: 24)
            }
            .keyboardShortcut("0", modifiers: .command)
            .help("适配全部区域")
            .accessibilityLabel("适配全部区域")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct ConstellationLegend: View {
    let isPartial: Bool
    let hasEdges: Bool
    let hasRecent: Bool

    var body: some View {
        Text(copy)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .help("位置邻近仅表示引用过相同材料，不代表主题相似")
    }

    private var copy: String {
        let base: String
        if hasEdges {
            base = "虚线 · AI 候选联系，尚待核对"
        } else if isPartial {
            base = "跨材料联系尚未核对完成；当前仅显示已核对区域"
        } else {
            base = "当前没有已核对的跨区域候选联系"
        }
        return hasRecent ? base + " · 圆点为近期更新" : base
    }
}
