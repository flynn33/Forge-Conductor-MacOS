import XCTest
@testable import ForgeConductorCore

final class BudgetRawJSONTests: XCTestCase {
    func testRawPolicyCountsRejectFractionsBeyondDecimalPrecisionAtEveryBoundary() throws {
        let update = BudgetPolicyUpdate(scope: .globalDefault, expectedRevision: 1, expectedGlobalRevision: 1,
                                        operation: .set, policy: .default)
        let fixtures: [(Data, (Data) throws -> Void)] = [
            (try JSONEncoder().encode(BudgetPolicy.default), { _ = try BudgetPolicy.decode(data: $0) }),
            (try JSONEncoder().encode(BudgetPolicyState.default), { _ = try BudgetPolicyState.decode(data: $0) }),
            (try JSONEncoder().encode(update), { _ = try BudgetPolicyUpdate.decode(data: $0) }),
        ]
        let invalid = [
            "8.0000000000000000000000000000000000000001", "80.000000000000000000000000000000000000001e-1",
            "8e-10000", "8e10000", "9223372036854775808", "true", "\"8\"",
        ]
        for (data, decode) in fixtures {
            for token in invalid {
                let malformed = try replacingCount(in: data, with: token)
                XCTAssertThrowsError(try decode(malformed), token) { error in
                    XCTAssertEqual((error as? ManagerSettingsValidationError)?.reason, "expected_exact_integer")
                }
            }
        }

        let rawUpdate = try replacingCount(in: JSONEncoder().encode(update), with: invalid[0])
        let envelope = Data(("{\"settings\":{\"budget_update\":" + String(decoding: rawUpdate, as: UTF8.self) + "}}").utf8)
        XCTAssertThrowsError(try BudgetPolicyUpdate.validateSettingsJSON(envelope))

        let rawState = try replacingCount(in: JSONEncoder().encode(BudgetPolicyState.default), with: invalid[0])
        let config = Data(("{\"budget_policy\":" + String(decoding: rawState, as: UTF8.self) + ",\"unrelated\":true}").utf8)
        XCTAssertThrowsError(try BudgetPolicyState.validateConfigurationJSON(config))
    }

    func testIntegralExponentCountsNormalizeWithoutChangingThresholdsOrUnrelatedBytes() throws {
        let data = try JSONEncoder().encode(BudgetPolicy.default)
        for token in ["8.0", "80e-1", "0.8e1", "8e+0", "80000000000000000000000000000000000000000e-40"] {
            XCTAssertEqual(try BudgetPolicy.decode(data: replacingCount(in: data, with: token)), .default)
        }
        let raw = Data("{\"budget_policy\":{\"global_revision\":10e-1}, \"unrelated\": 1.234567890123456789}".utf8)
        let normalized = try BudgetPolicyState.validateConfigurationJSON(raw)
        XCTAssertEqual(String(decoding: normalized, as: UTF8.self),
                       "{\"budget_policy\":{\"global_revision\":1}, \"unrelated\": 1.234567890123456789}")
    }

    func testEscapedAndDuplicateBudgetKeysCannotHideFractionalTokens() throws {
        let fractional = "8.0000000000000000000000000000000000000001"
        let escaped = Data(("{\"settings\":{\"budget_update\":{\"policy\":{\"tools\":{\"calls_per_\\u0074urn\":" + fractional + "}}}}}").utf8)
        XCTAssertThrowsError(try BudgetPolicyUpdate.validateSettingsJSON(escaped))
        let duplicate = Data(("{\"budget_update\":{\"policy\":{\"tools\":{\"calls_per_turn\":" + fractional + ",\"calls_per_turn\":8}}}}").utf8)
        XCTAssertThrowsError(try BudgetPolicyUpdate.validateSettingsJSON(duplicate))
    }

    func testCompetingValidAndEscapedDuplicateKeysAreRejectedBeforeDecoding() throws {
        for duplicateKey in ["global_revision", "global_\\u0072evision"] {
            let config = Data(("{\"budget_policy\":{\"global_revision\":1,\"" + duplicateKey + "\":2}}").utf8)
            XCTAssertThrowsError(try BudgetPolicyState.validateConfigurationJSON(config)) { error in
                XCTAssertEqual((error as? ManagerSettingsValidationError)?.field, "budget_policy.global_revision")
                XCTAssertEqual((error as? ManagerSettingsValidationError)?.reason, "duplicate_field")
            }
        }
        let envelope = Data("{\"settings\":{\"budget_update\":{\"expected_revision\":1,\"expected_\\u0072evision\":2}}}".utf8)
        XCTAssertThrowsError(try BudgetPolicyUpdate.validateSettingsJSON(envelope)) { error in
            XCTAssertEqual((error as? ManagerSettingsValidationError)?.reason, "duplicate_field")
        }
        // Equal names in different objects remain independent fields.
        let distinct = Data("{\"first\":{\"revision\":1},\"second\":{\"revision\":2}}".utf8)
        XCTAssertEqual(try BudgetPolicyState.validateConfigurationJSON(distinct), distinct)
    }

    func testLegacyIntegerStringsRemainValidAndLongFractionsDoNotRound() throws {
        let string = Data("{\"settings\":{\"shell\":{\"default_timeout_sec\":\"41\"}}}".utf8)
        XCTAssertEqual(try BudgetPolicyUpdate.validateSettingsJSON(string), string)
        let fractional = Data("{\"shell\":{\"default_timeout_sec\":41.000000000000000000000000000000000000001}}".utf8)
        XCTAssertThrowsError(try BudgetPolicyUpdate.validateSettingsJSON(fractional))
    }

    func testRawIntegerValidationHasBoundedTokenBodyAndNestingLimits() throws {
        let longToken = Data(("{\"budget_update\":{\"expected_revision\":1." + String(repeating: "0", count: 60_000) + "1}}").utf8)
        XCTAssertLessThan(longToken.count, 65_536)
        XCTAssertThrowsError(try BudgetPolicyUpdate.validateSettingsJSON(longToken)) { error in
            XCTAssertEqual((error as? ManagerSettingsValidationError)?.reason, "numeric_token_too_long")
        }
        let tooLarge = Data(repeating: 32, count: 65_537)
        XCTAssertThrowsError(try BudgetPolicyUpdate.validateSettingsJSON(tooLarge))
        let deep = Data((String(repeating: "[", count: 66) + "0" + String(repeating: "]", count: 66)).utf8)
        XCTAssertThrowsError(try BudgetPolicyUpdate.validateSettingsJSON(deep)) { error in
            XCTAssertEqual((error as? ManagerSettingsValidationError)?.reason, "json_structure_too_large")
        }
    }

    func testLegacyPatchesRejectUnknownBudgetKeysInsideObjectsAndArrays() throws {
        let patches: [[String: Any]] = [
            ["manager": ["budget_policy": ["unexpected": 1]]],
            ["shell": ["context_budget": 1]],
            ["unknown": [["tool_BUDGET": 1]]],
        ]
        for patch in patches {
            XCTAssertThrowsError(try ManagerSettingsNormalizer.validateLegacyBudgetKeys(patch))
            XCTAssertThrowsError(try ManagerSettingsNormalizer.validated(patch)) { error in
                XCTAssertEqual((error as? ManagerSettingsValidationError)?.reason, "unknown_budget_field")
            }
        }
        XCTAssertNoThrow(try ManagerSettingsNormalizer.validateLegacyBudgetKeys([
            "unrelated_extension": ["arbitrary_field": [1, 2, 3]], "log_level": "debug",
        ]))
    }

    private func replacingCount(in data: Data, with token: String) throws -> Data {
        let text = String(decoding: data, as: UTF8.self)
        let needle = "\"calls_per_turn\":8"
        XCTAssertTrue(text.contains(needle))
        return Data(text.replacingOccurrences(of: needle, with: "\"calls_per_turn\":" + token).utf8)
    }
}
