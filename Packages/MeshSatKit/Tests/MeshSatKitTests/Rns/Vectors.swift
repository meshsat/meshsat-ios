// The wire vectors of Fixtures/lxmf (see its README): golden.properties, written by Python RNS
// and LXMF for MeshSat Android, and go-vectors.properties, written by the Bridge's Go code for
// the same keys. One loader for both, in the shape of the Kotlin golden tests' helpers.
import Foundation
import MeshSatWire
import XCTest

struct Vectors {
    let values: [String: String]
    let file: String

    static func load(_ name: String) throws -> Vectors {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "properties", subdirectory: "Fixtures/lxmf"),
            "\(name).properties missing from Fixtures/lxmf")
        var values: [String: String] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        return Vectors(values: values, file: name)
    }

    static func golden() throws -> Vectors { try load("golden") }
    static func go() throws -> Vectors { try load("go-vectors") }

    func str(_ key: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try XCTUnwrap(values[key], "no vector \(key) in \(self.file).properties", file: file, line: line)
    }

    func hex(_ key: String, file: StaticString = #filePath, line: UInt = #line) throws -> [UInt8] {
        try XCTUnwrap(Hex.decode(try str(key, file: file, line: line)), "vector \(key) is not hex", file: file, line: line)
    }

    func int(_ key: String, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        try XCTUnwrap(Int(try str(key, file: file, line: line)), "vector \(key) is not an integer", file: file, line: line)
    }

    func double(_ key: String, file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        try XCTUnwrap(Double(try str(key, file: file, line: line)), "vector \(key) is not a number", file: file, line: line)
    }
}
