import Foundation
import XCTest
@testable import SentientComputerUseCore

final class ProtocolTests: XCTestCase {
    func testRequestRoundTripsWithoutLosingIdentifierOrArguments() throws {
        let request = ServiceRequest(id: "r1", operation: .click,
            arguments: ["app": .string("TextEdit"), "element_index": .int(7)])
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ServiceRequest.self, from: data), request)
    }

    func testErrorResponseCarriesStableCode() throws {
        let response = ServiceResponse.failure(id: "r2",
            ServiceError(code: .permissionDeniedAccessibility, message: "Accessibility is required"))
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ServiceResponse.self, from: data), response)
    }

    func testIntegralDoubleRoundTripsAsDouble() throws {
        let value = JSONValue.double(7.0)
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }

    func testResponseRejectsResultAndErrorTogether() {
        let data = Data(#"{"id":"r3","result":null,"error":{"code":"internal_error","message":"Unexpected"}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ServiceResponse.self, from: data))
    }
}
