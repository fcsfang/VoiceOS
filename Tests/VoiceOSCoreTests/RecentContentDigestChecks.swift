import XCTest
@testable import VoiceOSCore

final class RecentContentDigestChecks: XCTestCase {
    private func makeThoughts(_ entries: [(String, RecentThoughtKind)]) -> [RecentContentThought] {
        entries.enumerated().map { RecentContentThought(claimID: "claim-\($0.offset)", statement: $0.element.0, kind: $0.element.1) }
    }

    func testPrefixesAndBookkeepingAreParsedAway() {
        XCTAssertEqual(RecentContentIndex.parse("【观点】完成比完美更重要")?.kind, .insight)
        XCTAssertEqual(RecentContentIndex.parse("【长期目标】每周复盘工作")?.kind, .goal)
        XCTAssertEqual(RecentContentIndex.parse("随手记下的想法")?.kind, .note)
        XCTAssertEqual(RecentContentIndex.parse("【观点】完成比完美更重要")?.statement, "完成比完美更重要")
        XCTAssertEqual(RecentContentIndex.parse("晚饭后散步；说明：这是补充")?.statement, "晚饭后散步")
        XCTAssertNil(RecentContentIndex.parse("整理录音文件（待核对）"))
        XCTAssertNil(RecentContentIndex.parse("【录音中活动】整理录音文件"))
        XCTAssertEqual(RecentContentIndex.thoughtStatement("【长期目标】坚持写作"), "坚持写作")
    }

    func testEveryThoughtLandsInExactlyOneThread() {
        let thoughts = makeThoughts([
            ("过去对父亲的了解有偏差", .insight),
            ("实习项目需要先交付再打磨", .insight),
            ("GPT 和代码能力还要练", .note),
            ("自卑让我长期不敢表达", .insight),
            ("AirPods 进水后还能用", .note),
            ("返沪后从下周恢复正常实习", .note),
        ])
        let digest = RecentContentDigest.build(thoughts: thoughts, duration: 600)
        let landed = digest.threads.flatMap(\.thoughts)
        XCTAssertEqual(digest.threads.map(\.id), ["family", "work", "career", "self", "life"])
        XCTAssertEqual(digest.threads.map(\.thoughts.count).reduce(0, +), thoughts.count)
        XCTAssertEqual(landed.count, thoughts.count)
        XCTAssertEqual(Set(landed.map(\.id)), Set(thoughts.map(\.id)))
        XCTAssertEqual(digest.thoughtCount, thoughts.count)
    }

    func testLeadPrefersReflectionOverConcreteFacts() {
        let thoughts = makeThoughts([
            ("第二个实习项目是给老系统补功能", .insight),
            ("完成比完美更重要，先把成果交付出去", .insight),
        ])
        let digest = RecentContentDigest.build(thoughts: thoughts, duration: 0)
        XCTAssertEqual(digest.threads.first?.lead?.statement, "完成比完美更重要，先把成果交付出去")
    }

    func testFamilyLeadIsTheReflectiveStatement() {
        let thoughts = makeThoughts([
            ("与父母长谈很愉快", .insight),
            ("过去对父亲的了解有偏差", .insight),
        ])
        let digest = RecentContentDigest.build(thoughts: thoughts, duration: 0)
        XCTAssertEqual(digest.threads.first?.id, "family")
        XCTAssertEqual(digest.threads.first?.lead?.statement, "过去对父亲的了解有偏差")
    }

    func testLifeSignalsOutrankWorkAndFamilyComesFirst() {
        let thoughts = makeThoughts([
            ("实习恢复正常后，让播客、视频录制和个人学习回到正轨", .goal),
            ("AirPods 进水后恢复使用", .note),
            ("写下交流收获", .note),
            ("学习通用网关隧道服务的实现方法", .note),
        ])
        let digest = RecentContentDigest.build(thoughts: thoughts, duration: 0)
        let byID = Dictionary(uniqueKeysWithValues: digest.threads.map { ($0.id, $0.thoughts.map(\.statement)) })
        XCTAssertEqual(byID["life"], ["实习恢复正常后，让播客、视频录制和个人学习回到正轨", "AirPods 进水后恢复使用"])
        XCTAssertEqual(byID["family"], ["写下交流收获"])
        XCTAssertEqual(byID["career"], ["学习通用网关隧道服务的实现方法"])
    }

    func testSupportingGoalsAndRemainingPartitionTheThread() {
        let thoughts = makeThoughts([
            ("完成比完美更重要", .insight),
            ("交付前要主动汇报进度", .insight),
            ("把项目拆成小步再打磨", .insight),
            ("每周整理一次汇报材料", .insight),
            ("慢慢做到先交付再完善", .goal),
            ("把汇报频率提高到每周", .goal),
        ])
        let digest = RecentContentDigest.build(thoughts: thoughts, duration: 0)
        guard let thread = digest.threads.first(where: { $0.id == "work" }) else { return XCTFail("work thread missing") }
        XCTAssertEqual(thread.lead?.statement, "交付前要主动汇报进度")
        XCTAssertEqual(thread.supporting.map(\.statement), ["完成比完美更重要", "每周整理一次汇报材料"])
        XCTAssertEqual(thread.goals.map(\.statement), ["慢慢做到先交付再完善", "把汇报频率提高到每周"])
        XCTAssertEqual(thread.remaining.map(\.statement), ["把项目拆成小步再打磨"])
        XCTAssertEqual(thread.hiddenCount, 1)
        let shown = Set(([thread.lead].compactMap { $0 } + thread.supporting + Array(thread.goals.prefix(2))).map(\.id))
        let remaining = Set(thread.remaining.map(\.id))
        XCTAssertTrue(shown.isDisjoint(with: remaining))
        XCTAssertEqual(shown.union(remaining), Set(thread.thoughts.map(\.id)))
        XCTAssertTrue(shown.union(remaining).isSuperset(of: Set(thoughts.map(\.id))))
    }

    func testTaskOrderingPutsDatedTitlesFirst() {
        let tasks = [
            RecentContentTask(id: "a", title: "整理桌面"),
            RecentContentTask(id: "b", title: "下周一提交开题"),
            RecentContentTask(id: "c", title: "打磨汇报"),
            RecentContentTask(id: "d", title: "周四复盘"),
            RecentContentTask(id: "e", title: "买耳机"),
        ]
        XCTAssertEqual(RecentContentDigest.orderedTasks(tasks).map(\.id), ["b", "d", "a", "c", "e"])
        XCTAssertEqual(RecentContentDigest.build(thoughts: [], duration: 0, tasks: tasks).tasks.map(\.id), ["b", "d", "a", "c", "e"])
    }

    func testDurationLabel() {
        XCTAssertEqual(RecentContentDigest.durationLabel(0), "")
        XCTAssertEqual(RecentContentDigest.durationLabel(30), "不到 1 分钟")
        XCTAssertEqual(RecentContentDigest.durationLabel(600), "10 分钟")
        XCTAssertEqual(RecentContentDigest.durationLabel(6068.7773125), "1 小时 41 分")
        XCTAssertEqual(RecentContentDigest.durationLabel(3600), "1 小时 0 分")
    }

    func testThreadTitlesAndLeadScore() {
        XCTAssertEqual(RecentContentDigest.threadTitle("work"), "实习与交付")
        XCTAssertEqual(RecentContentDigest.threadID(for: "这周录了一期播客"), "life")
        XCTAssertGreaterThan(RecentContentDigest.leadScore("完成比完美更重要"), RecentContentDigest.leadScore("第二个项目是补功能"))
    }
}
