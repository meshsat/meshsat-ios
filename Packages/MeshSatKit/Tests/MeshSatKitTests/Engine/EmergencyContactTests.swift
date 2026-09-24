// Mirrors EmergencyContactAddingTest.kt (the contacts-app picker cases are Android's own):
// emergency contacts come from the phone's own contacts, and a contacts app hands numbers over
// as people wrote them.
import MeshSatEngine
import XCTest

final class EmergencyContactTests: XCTestCase {
    private let anna = EmergencyContact(name: "Anna", phone: "+31612345678")

    func testANumberAsAContactsAppWritesItIsTaken() {
        guard case .ok(let list) = EmergencyContact.adding([], name: "Anna de Vries", rawPhone: "+31 6 1234-5678") else {
            return XCTFail("refused")
        }
        XCTAssertEqual(list, [EmergencyContact(name: "Anna de Vries", phone: "+31612345678")])
        guard case .ok(let national) = EmergencyContact.adding([], name: "Huisarts", rawPhone: "(020) 555 01 00") else {
            return XCTFail("refused")
        }
        XCTAssertEqual(national.first?.phone, "0205550100")
    }

    func testTheSamePersonPickedTwiceIsSaidNotDoubled() {
        XCTAssertEqual(
            EmergencyContact.adding([anna], name: "Anna again", rawPhone: "+31 6 12345678"),
            .no("That number is already on the list."))
    }

    func testAContactWithNoNumberOrNotANumberIsRefusedInWords() {
        XCTAssertEqual(EmergencyContact.adding([], name: "Bo", rawPhone: ""), .no("That contact has no phone number."))
        XCTAssertEqual(EmergencyContact.adding([], name: "Bo", rawPhone: "bo@example.org"), .no("That is not a phone number."))
    }

    func testTheListStopsAtItsLimit() {
        let full = (1...EmergencyContact.max).map { EmergencyContact(name: "c\($0)", phone: "+3161000000\($0)") }
        guard case .no = EmergencyContact.adding(full, name: "One more", rawPhone: "+31699999999") else {
            return XCTFail("took an eleventh")
        }
    }

    func testANameCannotBreakTheStoredList() {
        guard case .ok(let list) = EmergencyContact.adding([], name: "Anna\tde\nVries", rawPhone: "+31612345678") else {
            return XCTFail("refused")
        }
        XCTAssertEqual(list, EmergencyContact.decode(EmergencyContact.encode(list)))
        XCTAssertEqual(list.first?.name, "Anna de Vries")
    }

    func testDecodeSkipsBrokenLinesAndStopsAtTheLimit() {
        let text = "Anna\t+31612345678\nno tab here\nBo\tnot a number\nCid\t0612345678"
        XCTAssertEqual(
            EmergencyContact.decode(text),
            [EmergencyContact(name: "Anna", phone: "+31612345678"), EmergencyContact(name: "Cid", phone: "0612345678")])
        let many = (1...12).map { "c\($0)\t+316100000\(String(format: "%02d", $0))" }.joined(separator: "\n")
        XCTAssertEqual(EmergencyContact.decode(many).count, EmergencyContact.max)
    }
}
