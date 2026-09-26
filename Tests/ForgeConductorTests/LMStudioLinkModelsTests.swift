import Foundation
import XCTest

#if SWIFT_PACKAGE
@testable import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

final class LMStudioLinkModelsTests: XCTestCase {
    private let nodeID = LMStudioLinkNodeID(
        rawValue: UUID(uuidString: "4b11b1c7-8378-4c18-a3bd-aa1e1a854a16")!
    )

    func testEndpointModeHasCanonicalVersionedShapeAndRejectsAmbiguousLocalNode() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            String(data: try encoder.encode(LMStudioEndpointMode.local), encoding: .utf8),
            #"{"mode":"local"}"#
        )
        XCTAssertEqual(
            String(data: try encoder.encode(LMStudioEndpointMode.linked(nodeID: nodeID)), encoding: .utf8),
            #"{"mode":"linked","node_id":"4b11b1c7-8378-4c18-a3bd-aa1e1a854a16"}"#
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                LMStudioEndpointMode.self,
                from: Data(#"{"mode":"local","node_id":"4b11b1c7-8378-4c18-a3bd-aa1e1a854a16"}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                LMStudioEndpointMode.self,
                from: Data(#"{"mode":"future"}"#.utf8)
            )
        )
    }

    func testHealthFieldsRejectStatesFromAnotherHealthDomain() throws {
        let invalidConnectorState = Data(#"""
        {
          "schema_version":"forge-link/1",
          "link_instance_id":"4b11b1c7-8378-4c18-a3bd-aa1e1a854a16",
          "connector":"stopped",
          "lmstudio":"ready",
          "registration":"ready"
        }
        """#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(LMStudioLinkHealth.self, from: invalidConnectorState)
        )

        let validHealth = try LMStudioLinkHealth(
            linkInstanceID: nodeID,
            connector: .ready,
            lmstudio: .stopped,
            registration: .absent
        )
        XCTAssertNoThrow(try JSONEncoder().encode(validHealth))
    }

    func testLegacyProviderConfigurationAndSnapshotDecodeAsLocal() throws {
        let legacyConfiguration = Data(#"""
        {
          "revision":"0",
          "base_url":"http:\/\/127.0.0.1:1234",
          "model_key":"fixture\/tool-model"
        }
        """#.utf8)
        let configuration = try JSONDecoder().decode(
            LMStudioProviderConfiguration.self,
            from: legacyConfiguration
        )
        XCTAssertEqual(configuration.endpointMode, .local)
        XCTAssertEqual(configuration.baseURL.absoluteString, "http://127.0.0.1:1234")
        XCTAssertNoThrow(try configuration.validated())
        XCTAssertEqual(
            try JSONDecoder().decode(
                LMStudioProviderConfiguration.self,
                from: JSONEncoder().encode(configuration)
            ),
            configuration
        )

        let legacySnapshot = Data(#"""
        {
          "revision":"0",
          "endpoint":"http:\/\/127.0.0.1:1234",
          "modelKey":null,
          "credentialConfigured":false,
          "saved":false
        }
        """#.utf8)
        let snapshot = try JSONDecoder().decode(
            ProviderConfigurationSnapshot.self,
            from: legacySnapshot
        )
        XCTAssertEqual(snapshot.endpointMode, .local)
        XCTAssertFalse(snapshot.credentialCleanupPending)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ProviderConfigurationSnapshot.self,
                from: JSONEncoder().encode(snapshot)
            ),
            snapshot
        )
    }

    func testLinkedProviderRequiresHTTPSWithoutWeakeningLegacyRemoteHTTPS() throws {
        XCTAssertThrowsError(
            try LMStudioProviderConfiguration(
                endpointMode: .linked(nodeID: nodeID),
                baseURL: URL(string: "http://127.0.0.1:57400")!
            ).validated()
        )
        XCTAssertNoThrow(
            try LMStudioProviderConfiguration(
                endpointMode: .linked(nodeID: nodeID),
                baseURL: URL(string: "https://gb10.fixture:57400")!
            ).validated()
        )
        XCTAssertNoThrow(
            try LMStudioProviderConfiguration(
                baseURL: URL(string: "https://existing-remote.fixture")!
            ).validated()
        )
    }

    func testDiscoveryFixtureBoundsUnknownFieldsAndMalformedUUID() throws {
        let fixture = try fixture(named: "discovery")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(LMStudioLinkDiscoveryRecord.self, from: fixture)
        XCTAssertNoThrow(try record.validate())
        XCTAssertEqual(record.id, nodeID)
        XCTAssertEqual(record.port, 57_400)

        let malformed = String(decoding: fixture, as: UTF8.self)
            .replacingOccurrences(of: nodeID.description, with: "not-a-uuid")
        XCTAssertThrowsError(
            try decoder.decode(LMStudioLinkDiscoveryRecord.self, from: Data(malformed.utf8))
        )
        XCTAssertThrowsError(
            try LMStudioLinkDiscoveryRecord(
                id: nodeID,
                host: String(repeating: "h", count: 256),
                port: 57_400,
                spkiSHA256: String(repeating: "a", count: 64),
                capabilities: ["proxy"],
                lastSeen: Date()
            )
        )
    }

    func testPublicNodeAndPairingReceiptCannotEncodeBearerMaterial() throws {
        let token = "bearer-secret-that-must-never-enter-public-json"
        let node = try makeNode()
        let receipt = try LMStudioLinkPairingReceipt(
            challengeID: UUID(),
            nodeID: node.id,
            peerID: UUID(),
            grantedScopes: [.proxyModelsRead, .proxyInference],
            generation: 1,
            completedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode([node.spkiSHA256, String(data: encoder.encode(receipt), encoding: .utf8)!])
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains(token))
        XCTAssertFalse(text.lowercased().contains("bearer"))
        XCTAssertFalse(text.contains("token"))

        let issued = try LMStudioLinkIssuedCredential(
            peerID: UUID(),
            token: token + String(repeating: "x", count: 43),
            grantedScopes: [.proxyInference],
            generation: 1
        )
        XCTAssertTrue(issued.token.hasPrefix(token))
    }

    func testRolePathsAreImmutableAndCapabilitiesAreBounded() throws {
        XCTAssertEqual(LMStudioLinkMCPRole.allCases.map(\.route), [
            "/mcp/primary", "/mcp/fallback", "/mcp/clu",
        ])
        XCTAssertThrowsError(
            try LMStudioLinkRoleEndpoint(
                role: .clu,
                path: "/mcp/primary",
                credentialReference: "role-clu"
            )
        )
        XCTAssertThrowsError(
            try LMStudioLinkCapabilities(
                proxyPaths: [],
                controlActions: ["server_start"],
                mcpVersions: ["2025-11-25"],
                architecture: "aarch64"
            )
        )

        let decoder = JSONDecoder()
        let capabilities = try decoder.decode(
            LMStudioLinkCapabilities.self,
            from: fixture(named: "capabilities")
        )
        XCTAssertEqual(capabilities.architecture, "aarch64")
        let pairingDecoder = JSONDecoder()
        pairingDecoder.dateDecodingStrategy = .iso8601
        let receipt = try pairingDecoder.decode(
            LMStudioLinkPairingReceipt.self,
            from: fixture(named: "pairing-receipt")
        )
        XCTAssertEqual(receipt.nodeID, nodeID)
        XCTAssertEqual(receipt.grantedScopes, [.proxyModelsRead, .proxyInference])

        let evidence = try pairingDecoder.decode(
            LMStudioLinkPairingEvidence.self,
            from: fixture(named: "pairing-evidence")
        )
        XCTAssertTrue(evidence.fingerprintConfirmed)
        XCTAssertEqual(evidence.linkInstanceID, nodeID)
        XCTAssertEqual(evidence.postPairHealth, .ready)
    }

    func testControlAndErrorContractsAreBoundedAndFailClosed() throws {
        XCTAssertThrowsError(
            try LMStudioLinkControlRequest(
                nodeID: nodeID,
                action: .modelLoad,
                idempotencyKey: UUID()
            )
        )
        XCTAssertNoThrow(
            try LMStudioLinkControlRequest(
                nodeID: nodeID,
                action: .serverRestart,
                idempotencyKey: UUID()
            )
        )
        XCTAssertThrowsError(
            try LMStudioLinkErrorDetail(
                code: .authenticationFailed,
                message: "Authentication failed.",
                retryAfterMilliseconds: 100
            )
        )
        let detail = try LMStudioLinkErrorDetail(
            code: .overloaded,
            message: "The connector is busy.",
            retryAfterMilliseconds: 500
        )
        let envelope = LMStudioLinkErrorEnvelope(requestID: UUID(), error: detail)
        let data = try JSONEncoder().encode(envelope)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("token"))
    }

    func testCanonicalFixturesRoundTripDeterministically() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let discovery = try decoder.decode(
            LMStudioLinkDiscoveryRecord.self,
            from: fixture(named: "discovery")
        )
        let capabilities = try decoder.decode(
            LMStudioLinkCapabilities.self,
            from: fixture(named: "capabilities")
        )
        let evidence = try decoder.decode(
            LMStudioLinkPairingEvidence.self,
            from: fixture(named: "pairing-evidence")
        )
        XCTAssertEqual(
            try encoder.encode(discovery),
            try canonicalFixture(named: "discovery", removing: ["additive_future_field"])
        )
        XCTAssertEqual(
            try encoder.encode(capabilities),
            try canonicalFixture(named: "capabilities")
        )
        XCTAssertEqual(
            try encoder.encode(evidence),
            try canonicalFixture(named: "pairing-evidence")
        )

        let unconfirmed = String(decoding: try fixture(named: "pairing-evidence"), as: UTF8.self)
            .replacingOccurrences(of: #""fingerprint_confirmed": true"#, with: #""fingerprint_confirmed": false"#)
        XCTAssertThrowsError(
            try decoder.decode(LMStudioLinkPairingEvidence.self, from: Data(unconfirmed.utf8))
        )
    }

    private func fixture(named name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/LMStudioLink/\(name).json")
        return try Data(contentsOf: url)
    }

    private func canonicalFixture(named name: String, removing keys: [String] = []) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixture(named: name)) as? [String: Any]
        )
        for key in keys { object.removeValue(forKey: key) }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func makeNode(state: LMStudioLinkNodeState = .active) throws -> LMStudioLinkNodeSnapshot {
        try LMStudioLinkNodeSnapshot(
            id: nodeID,
            displayName: "Dell Pro Max GB10",
            origin: URL(string: "https://gb10.fixture:57400")!,
            serviceName: "gb10._forge-lms-link._tcp.local",
            spkiSHA256: String(repeating: "a", count: 64),
            credentialReference: "lmstudio-link-\(nodeID)",
            capabilities: ["proxy", "control", "mcp-relay"],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            state: state
        )
    }
}
