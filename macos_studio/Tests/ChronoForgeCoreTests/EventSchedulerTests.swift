// EventSchedulerTests.swift — multi-object preview with CT call levels.
import XCTest
@testable import ChronoForgeCore

final class EventSchedulerTests: XCTestCase {
    private func scenes(_ sources: [String: String]) throws -> [String: EventScene] {
        try sources.mapValues { try EventDSL.parse($0) }
    }
    private func lines(_ r: EventScheduler.Result) -> [String] {
        r.entries.map { "f\($0.frame) \($0.scene) L\($0.level) \($0.action)" }
    }

    func testWaitCallBlocksUntilTheTargetEnds() throws {
        let r = try EventScheduler.run(scenes: scenes([
            "hero": "obj 1 {\n func 0 {\n  call_obj \"npc\"#1 wait level 3\n  set_flag done\n }\n}\n",
            "npc": "obj 2 {\n func 1 {\n  text greet\n  wait 10\n  nop\n }\n}\n",
        ]), entryScene: "hero", dialogue: ["greet": "Hi"])
        XCTAssertEqual(lines(r), [
            "f0 hero L7 call_obj \"npc\"#1 wait level 3",
            "f0 npc L3 text \"greet\"",
            "f0 npc L3 wait 10",
            "f10 npc L3 nop",
            "f11 hero L7 set_flag \"done\"",
        ])
        XCTAssertEqual(r.entries[0].detail, "npc starts func 1 at level 3")
        XCTAssertEqual(r.entries[1].detail, "Hi")
        XCTAssertEqual(r.stopReason, "All objects idle")
        XCTAssertEqual(r.flags, ["done"])
        XCTAssertEqual(r.elapsedFrames, 11)
        XCTAssertTrue(r.objects.allSatisfy { $0.level == 7 && $0.function == nil && $0.status == "idle" })
    }

    func testPreemptionSavesAndResumesTheInterruptedFunction() throws {
        let r = try EventScheduler.run(scenes: scenes([
            "boss": "obj 0 {\n func 0 {\n  call_obj \"npc\"#1 start level 4\n  wait 2\n  call_obj \"npc\"#2 start level 2\n }\n}\n",
            "npc": "obj 2 {\n func 1 {\n  wait 5\n  nop\n }\n func 2 {\n  set_flag urgent\n }\n}\n",
        ]), entryScene: "boss")
        XCTAssertEqual(lines(r), [
            "f0 boss L7 call_obj \"npc\"#1 start level 4",
            "f0 boss L7 wait 2",
            "f0 npc L4 wait 5",
            "f2 boss L7 call_obj \"npc\"#2 start level 2",
            "f2 npc L2 set_flag \"urgent\"",
            "f5 npc L4 nop",
        ])
        XCTAssertEqual(r.entries[3].detail, "npc starts func 2 at level 2")
    }

    func testLessUrgentCallsQueueAndSameLevelCallsDoNothing() throws {
        let r = try EventScheduler.run(scenes: scenes([
            "a": "obj 0 {\n func 0 {\n  call_obj b#1 start level 2\n  call_obj b#2 start level 5\n  call_obj b#3 start level 5\n  call_obj b#1 start level 2\n }\n}\n",
            "b": "obj 1 {\n func 1 {\n  wait 3\n }\n func 2 {\n  set_flag second\n }\n func 3 {\n  set_flag third\n }\n}\n",
        ]), entryScene: "a")
        let details = r.entries.prefix(4).map(\.detail)
        XCTAssertEqual(details, ["b starts func 1 at level 2", "b is busy at level 2: func 2 queued at level 5",
                                 "level 5 of b is taken: not queued", "b is already at level 2: nothing happens"])
        XCTAssertEqual(lines(r).suffix(2), ["f0 b L2 wait 3", "f3 b L5 set_flag \"second\""])
        XCTAssertEqual(r.flags, ["second"])
    }

    func testRetryWaitsForTheLevelToFree() throws {
        let r = try EventScheduler.run(scenes: scenes([
            "a": "obj 0 {\n func 0 {\n  call_obj b#1 start level 1\n  call_obj b#2 retry level 3\n  set_flag after\n }\n}\n",
            "b": "obj 1 {\n func 1 {\n  wait 4\n }\n func 2 {\n  nop\n }\n}\n",
        ]), entryScene: "a")
        XCTAssertEqual(lines(r), [
            "f0 a L7 call_obj \"b\"#1 start level 1",
            "f0 a L7 call_obj \"b\"#2 retry level 3",
            "f0 b L1 wait 4",
            "f5 a L7 call_obj \"b\"#2 retry level 3",
            "f5 a L7 set_flag \"after\"",
            "f5 b L3 nop",
        ])
        XCTAssertEqual(r.entries[1].detail, "b busy at level 1: retrying each frame")
        XCTAssertEqual(r.entries[3].detail, "b starts func 2 at level 3")
    }

    func testPreemptedWaitKeepsWaitingAndDeadlocksAreReported() throws {
        // a waits on b (level 6); b's function then retries a, which a's own call put at level 1.
        let r = try EventScheduler.run(scenes: scenes([
            "a": "obj 0 {\n func 0 {\n  call_obj b#9 start level 1\n }\n func 1 {\n  call_obj b#1 wait level 6\n }\n}\n",
            "b": "obj 1 {\n func 9 {\n  call_obj a#1 start level 1\n }\n func 1 {\n  call_obj a#2 retry level 3\n }\n}\n",
        ]).merging(["c": try EventDSL.parse("obj 2 {\n func 0 {\n  nop\n }\n}\n")]) { $1 }, entryScene: "a")
        XCTAssertEqual(r.stopReason, "Blocked: every running object waits on another")
        let a = r.objects.first { $0.scene == "a" }!, b = r.objects.first { $0.scene == "b" }!
        XCTAssertEqual(a.level, 1); XCTAssertEqual(a.status, "waiting for b")
        XCTAssertEqual(b.level, 6); XCTAssertEqual(b.status, "retrying a")
    }

    func testPartyCallsNeedSlotsAndMapCallsStop() throws {
        let sources = [
            "hero": "obj 1 {\n func 0 {\n  call_pc 0#1 start level 4\n  call map#2\n  nop\n }\n}\n",
            "lucca": "obj 3 {\n func 1 {\n  set_flag lucca\n }\n}\n",
        ]
        let without = try EventScheduler.run(scenes: scenes(sources), entryScene: "hero")
        XCTAssertTrue(without.entries[0].detail.contains("not simulated"))
        XCTAssertTrue(without.stopReason.hasPrefix("Stopped at external call map#2"))
        // The map call stops the preview in frame 0, before slot 3 runs.
        let with = try EventScheduler.run(scenes: scenes(sources), entryScene: "hero", party: [3, 1, 2])
        XCTAssertEqual(with.entries[0].detail, "lucca starts func 1 at level 4")
        XCTAssertEqual(with.flags, [])
        let noMap = sources.merging(["hero": "obj 1 {\n func 0 {\n  call_pc 0#1 start level 4\n }\n}\n"]) { $1 }
        XCTAssertEqual(try EventScheduler.run(scenes: scenes(noMap), entryScene: "hero", party: [3, 1, 2]).flags, ["lucca"])
    }

    func testPartySlotsAndDuplicateObjectsAreRejected() throws {
        XCTAssertNil(try EventScheduler.parsePartySlots("  "))
        XCTAssertEqual(try EventScheduler.parsePartySlots("3, 1, 2"), [3, 1, 2])
        for text in ["1,,2", "1,", ",1", "oops", "1,no,2", "1,2,3,4", "16", "-1", "1,1"] {
            XCTAssertThrowsError(try EventScheduler.parsePartySlots(text), text)
        }
        let unique = try scenes(["a": "obj 0 { func 0 { nop } }"])
        for slots in [[], [16], [0, 0], [0, 1, 2, 3]] {
            XCTAssertThrowsError(try EventScheduler.run(scenes: unique, entryScene: "a", party: slots))
        }
        let duplicate = try scenes(["a": "obj 0 { func 0 { nop } }", "b": "obj 0 { func 1 { nop } }"])
        XCTAssertThrowsError(try EventScheduler.run(scenes: duplicate, entryScene: "a")) { error in
            XCTAssertTrue(String(describing: error).contains("slot 0 is shared"))
        }
    }

    func testLimitsAndErrors() throws {
        let loop = try scenes(["l": "obj 0 {\n func 0 {\n  nop\n  jump func0\n }\n}\n"])
        XCTAssertTrue(try EventScheduler.run(scenes: loop, entryScene: "l", stepLimit: 12).stopReason.hasPrefix("Step limit"))
        let slow = try scenes(["s": "obj 0 {\n func 0 {\n  wait 60000\n }\n}\n"])
        XCTAssertEqual(try EventScheduler.run(scenes: slow, entryScene: "s", frameLimit: 100).stopReason, "Frame limit reached")
        XCTAssertThrowsError(try EventScheduler.run(scenes: loop, entryScene: "x"))
        XCTAssertThrowsError(try EventScheduler.run(scenes: loop, entryScene: "l", entry: 3))
        // Five statements per object per frame (Field_Unk68).
        let many = try scenes(["m": "obj 0 {\n func 0 {\n" + String(repeating: "  nop\n", count: 12) + " }\n}\n"])
        XCTAssertEqual(try EventScheduler.run(scenes: many, entryScene: "m").entries.map(\.frame), [0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 2])
    }
}
