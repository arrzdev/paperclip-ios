import Testing
@testable import PaperclipIOS

@MainActor
struct PresentationSlotTests {
    @Test func aLateCompletionFromAnEarlierSessionDoesNotEndTheNewerOne() {
        let slot = PresentationSlot()
        var ended: [String] = []
        let first = slot.begin { ended.append("first") }
        let second = slot.begin { ended.append("second") }
        // Starting the second presentation ended the first one.
        #expect(ended == ["first"])

        // The first session's completion handler fires late.
        #expect(slot.end(first) == false)
        #expect(ended == ["first"])

        #expect(slot.end(second) == true)
        #expect(ended == ["first", "second"])
    }

    @Test func eachPresentationEndsOnce() {
        let slot = PresentationSlot()
        var count = 0
        let id = slot.begin { count += 1 }

        slot.endCurrent()
        #expect(slot.end(id) == false)
        slot.endCurrent()

        #expect(count == 1)
    }
}
