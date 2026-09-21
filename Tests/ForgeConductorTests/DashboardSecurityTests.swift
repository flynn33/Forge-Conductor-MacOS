// DashboardSecurityTests.swift
// Probes the loopback HTTP boundary with malformed, oversized, and untrusted requests.
// The cases preserve parser limits and host/origin protections before routing is reached.

import XCTest
import Darwin
@testable import ForgeConductorCore

final class DashboardSecurityTests: XCTestCase {
    func testDashboardMutationAuthorizerRequiresAnExactBoundedToken() {
        let token = String(repeating: "a", count: DashboardMutationAuthorizer.tokenCharacterCount)
        let authorizer = DashboardMutationAuthorizer(token: token)

        XCTAssertFalse(authorizer.authorizes(nil))
        XCTAssertFalse(authorizer.authorizes(String(token.dropLast())))
        XCTAssertFalse(authorizer.authorizes(token + "a"))
        XCTAssertFalse(authorizer.authorizes(String(repeating: "b", count: token.count)))
        XCTAssertTrue(authorizer.authorizes(token))
        for path in [
            "/api/manager/settings",
            "/api/manager/start",
            "/api/manager/stop",
            "/api/manager/restart",
            "/api/manager/shutdown",
        ] {
            XCTAssertTrue(
                DashboardMutationAuthorizer.allowsManagerControl(method: "POST", path: path),
                path
            )
        }
        XCTAssertFalse(
            DashboardMutationAuthorizer.allowsManagerControl(
                method: "POST",
                path: "/api/manager/projects/remove"
            )
        )
        XCTAssertFalse(
            DashboardMutationAuthorizer.allowsManagerControl(
                method: "PUT",
                path: "/api/manager/settings"
            )
        )
    }

    func testManagerControlCredentialIsStableOwnerOnlyAndComparedExactly() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-manager-credential-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try paths.ensureLayout()

        let first = try ManagerControlCredentialStore(paths: paths).bearerToken()
        let second = try ManagerControlCredentialStore(paths: paths).bearerToken()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, ManagerControlCredentialStore.tokenCharacterCount)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit && !$0.isUppercase })

        let attributes = try FileManager.default.attributesOfItem(
            atPath: paths.managerControlCredential.path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.uint32Value, geteuid())

        let authorizer = ManagerMutationAuthorizer(
            credentials: ManagerControlCredentialStore(paths: paths)
        )
        XCTAssertFalse(authorizer.authorizes(nil))
        XCTAssertFalse(authorizer.authorizes("Bearer wrong"))
        XCTAssertFalse(authorizer.authorizes("bearer \(first)"))
        XCTAssertTrue(authorizer.authorizes("Bearer \(first)"))

        let config = try String(contentsOf: paths.configJSON, encoding: .utf8)
        XCTAssertFalse(config.contains(first))
    }

    func testEveryManagerMutationExceptReadOnlyStatusRequiresAuthorization() {
        for path in [
            "/api/manager/start",
            "/api/manager/stop",
            "/api/manager/restart",
            "/api/manager/shutdown",
            "/api/manager/settings",
            "/api/manager/projects/register",
            "/api/manager/projects/relink",
            "/api/manager/projects/bind",
            "/api/manager/projects/reset-generation",
            "/api/manager/projects/tool-permissions/status",
            "/api/manager/runs/prepare",
            "/api/manager/runs/start",
            "/api/manager/runs/control",
            "/api/manager/runs/delete",
            "/api/manager/runtime-jobs/cancel",
            "/api/manager/provider/probe",
            "/api/manager/provider/prepare",
            "/api/manager/stjornarvald/notices/pending",
            "/api/manager/future-mutation",
        ] {
            XCTAssertTrue(
                ManagerMutationAuthorizer.requiresAuthorization(method: "POST", path: path),
                path
            )
        }
        XCTAssertTrue(
            ManagerMutationAuthorizer.requiresAuthorization(
                method: "PUT",
                path: "/api/manager/settings"
            )
        )
        XCTAssertTrue(
            ManagerMutationAuthorizer.requiresAuthorization(
                method: "PUT",
                path: "/api/manager/projects/tool-permissions"
            )
        )
        XCTAssertFalse(
            ManagerMutationAuthorizer.requiresAuthorization(
                method: "GET",
                path: "/api/manager/status"
            )
        )
        for path in [
            "/api/manager/settings",
            "/api/manager/operator/snapshot",
            "/api/manager/autonomy/status",
        ] {
            XCTAssertFalse(
                ManagerMutationAuthorizer.requiresAuthorization(method: "GET", path: path),
                path
            )
        }
        XCTAssertFalse(
            ManagerMutationAuthorizer.requiresAuthorization(
                method: "POST",
                path: "/api/manager/projects/status"
            )
        )
        XCTAssertFalse(
            ManagerMutationAuthorizer.requiresAuthorization(
                method: "POST",
                path: "/api/manager/runs/status"
            )
        )
        XCTAssertTrue(
            ManagerMutationAuthorizer.requiresAuthorization(
                method: "GET",
                path: "/api/manager/future-mutation"
            )
        )
        XCTAssertTrue(
            ManagerMutationAuthorizer.requiresAuthorization(
                method: "POST",
                path: "/api/manager/status"
            )
        )
    }

    func testManagerControlCredentialFailsClosedWhenStoragePermissionsAreBroadened() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-manager-credential-mode-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try paths.ensureLayout()

        let store = ManagerControlCredentialStore(paths: paths)
        let token = try store.bearerToken()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: paths.managerControlCredential.path
        )

        XCTAssertThrowsError(try store.bearerToken()) { error in
            guard case ManagerMutationCredentialError.invalidStorage = error else {
                return XCTFail("Expected invalid protected storage, received \(error)")
            }
        }
        XCTAssertFalse(
            ManagerMutationAuthorizer(credentials: store).authorizes("Bearer \(token)")
        )
    }

    func testParserRejectsMalformedAndOversizedLengths() {
        let malformed = Data("POST / HTTP/1.1\r\nHost: 127.0.0.1:7788\r\nContent-Length:\r\n\r\n".utf8)
        XCTAssertEqual(
            DashboardHTTPRequestParser.parse(malformed, streamComplete: true),
            .rejected(status: 400, message: "Invalid Content-Length")
        )

        let oversized = Data(
            "POST / HTTP/1.1\r\nHost: 127.0.0.1:7788\r\nContent-Length: \(DashboardHTTPRequestParser.maximumBodyBytes + 1)\r\n\r\n".utf8
        )
        XCTAssertEqual(
            DashboardHTTPRequestParser.parse(oversized, streamComplete: false),
            .rejected(status: 413, message: "Request body too large")
        )
    }

    func testPolicyRejectsCrossOriginAndNonJSONMutations() {
        let crossOrigin = DashboardHTTPRequest(
            method: "POST",
            target: "/api/sessions/prune",
            headers: [
                "host": "127.0.0.1:7788",
                "content-type": "application/json",
                "origin": "https://attacker.example",
            ],
            body: Data("{}".utf8)
        )
        XCTAssertEqual(
            DashboardRequestPolicy.rejection(for: crossOrigin, serverPort: 7788)?.status,
            403
        )

        let formPost = DashboardHTTPRequest(
            method: "POST",
            target: "/api/sessions/prune",
            headers: [
                "host": "127.0.0.1:7788",
                "content-type": "application/x-www-form-urlencoded",
            ],
            body: Data()
        )
        XCTAssertEqual(
            DashboardRequestPolicy.rejection(for: formPost, serverPort: 7788)?.status,
            415
        )
    }

    func testDashboardCannotInvokePrivilegedTools() throws {
        let fixture = try DashboardFixture()
        defer { fixture.stop() }

        var request = URLRequest(url: fixture.url.appendingPathComponent("api/tools/call"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(fixture.origin, forHTTPHeaderField: "Origin")
        request.httpBody = Data(#"{"name":"shell_exec","arguments":{"command":"true"}}"#.utf8)

        let (_, response) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(response.statusCode, 404)
        XCTAssertNil(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin"))
    }

    func testDashboardRejectsCrossOriginStateChange() throws {
        let fixture = try DashboardFixture()
        defer { fixture.stop() }

        var request = URLRequest(url: fixture.url.appendingPathComponent("api/sessions/prune"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://attacker.example", forHTTPHeaderField: "Origin")
        request.httpBody = Data("{}".utf8)

        let (_, response) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(response.statusCode, 403)
    }

    func testControlDocumentInjectsEphemeralTokenAndRejectsEveryHTTPError() throws {
        let first = try DashboardFixture()
        defer { first.stop() }
        let second = try DashboardFixture()
        defer { second.stop() }

        let (firstData, firstResponse) = try HTTPTestHelpers.fetch(
            first.url.appendingPathComponent("control")
        )
        XCTAssertEqual(firstResponse.statusCode, 200)
        let firstDocument = try XCTUnwrap(String(data: firstData, encoding: .utf8))
        let firstToken = try extractMutationToken(from: firstDocument)
        XCTAssertFalse(firstDocument.contains(DashboardHTML.mutationTokenPlaceholder))
        XCTAssertTrue(firstDocument.contains("'X-Forge-Dashboard-Token': mutationToken"))
        XCTAssertTrue(firstDocument.contains("if (!r.ok)"))
        XCTAssertFalse(firstDocument.contains("if (!r.ok && r.status >= 500)"))
        XCTAssertFalse(firstDocument.contains("onclick=\"closeSession"))
        XCTAssertTrue(firstDocument.contains("button.addEventListener('click'"))

        let (secondData, _) = try HTTPTestHelpers.fetch(
            second.url.appendingPathComponent("control")
        )
        let secondDocument = try XCTUnwrap(String(data: secondData, encoding: .utf8))
        XCTAssertNotEqual(firstToken, try extractMutationToken(from: secondDocument))
    }

    func testSessionMutationsRequireAndAcceptInjectedControlToken() throws {
        let fixture = try DashboardFixture()
        defer { fixture.stop() }
        let token = try fixture.controlMutationToken()

        var request = fixture.mutationRequest(path: "api/sessions/prune")
        let (_, missing) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(missing.statusCode, 401)

        request.setValue(String(repeating: "0", count: token.count), forHTTPHeaderField: "X-Forge-Dashboard-Token")
        let (_, wrong) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(wrong.statusCode, 401)

        request.setValue(token, forHTTPHeaderField: "X-Forge-Dashboard-Token")
        let (_, accepted) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(accepted.statusCode, 200)

        request.setValue(nil, forHTTPHeaderField: "X-Forge-Dashboard-Token")
        let bearer = try ManagerControlCredentialStore(paths: fixture.app.paths).bearerToken()
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (_, nativeAccepted) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(nativeAccepted.statusCode, 200)
    }

    func testInjectedControlTokenAuthorizesManagerRouteWithoutExposingDurableBearer() throws {
        let fixture = try DashboardFixture(includeManager: true)
        defer { fixture.stop() }
        let document = try fixture.controlDocument()
        let token = try extractMutationToken(from: document)
        let durableBearer = try ManagerControlCredentialStore(paths: fixture.app.paths).bearerToken()
        XCTAssertFalse(document.contains(durableBearer))

        var request = fixture.mutationRequest(path: "api/manager/unknown")
        let (_, missing) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(missing.statusCode, 401)

        request.setValue(token, forHTTPHeaderField: "X-Forge-Dashboard-Token")
        let (_, authorized) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(authorized.statusCode, 401)

        request = fixture.mutationRequest(path: "api/manager/start-unknown")
        request.setValue(token, forHTTPHeaderField: "X-Forge-Dashboard-Token")
        let (_, scoped) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(scoped.statusCode, 401)

        request = fixture.mutationRequest(path: "api/manager/settings")
        request.setValue(token, forHTTPHeaderField: "X-Forge-Dashboard-Token")
        let (_, accepted) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(accepted.statusCode, 200)
    }

    private func extractMutationToken(from document: String) throws -> String {
        let expression = try NSRegularExpression(
            pattern: #"const mutationToken = '([0-9a-f]{64})';"#
        )
        let range = NSRange(document.startIndex..<document.endIndex, in: document)
        let match = try XCTUnwrap(expression.firstMatch(in: document, range: range))
        let tokenRange = try XCTUnwrap(Range(match.range(at: 1), in: document))
        return String(document[tokenRange])
    }
}

private final class DashboardFixture {
    let app: ForgeApp
    let server: DashboardServer
    let manager: ManagerNode?
    let url: URL
    let origin: String
    private let home: URL

    init(includeManager: Bool = false) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-dashboard-security-\(UUID().uuidString)", isDirectory: true)
        app = try ForgeApp.bootstrap(home: home)
        manager = includeManager ? ManagerNode(app: app) : nil
        let port = UInt16.random(in: 29_000...39_000)
        server = DashboardServer(app: app, host: "127.0.0.1", port: port)
        server.manager = manager
        url = URL(string: "http://127.0.0.1:\(port)/")!
        origin = "http://127.0.0.1:\(port)"
        try server.start()
        Thread.sleep(forTimeInterval: 0.1)
    }

    func controlDocument() throws -> String {
        let (data, response) = try HTTPTestHelpers.fetch(url.appendingPathComponent("control"))
        XCTAssertEqual(response.statusCode, 200)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    func controlMutationToken() throws -> String {
        let document = try controlDocument()
        let expression = try NSRegularExpression(
            pattern: #"const mutationToken = '([0-9a-f]{64})';"#
        )
        let range = NSRange(document.startIndex..<document.endIndex, in: document)
        let match = try XCTUnwrap(expression.firstMatch(in: document, range: range))
        let tokenRange = try XCTUnwrap(Range(match.range(at: 1), in: document))
        return String(document[tokenRange])
    }

    func mutationRequest(path: String) -> URLRequest {
        var request = URLRequest(url: url.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.httpBody = Data("{}".utf8)
        return request
    }

    func stop() {
        server.stop()
        app.shutdown()
        try? FileManager.default.removeItem(at: home)
    }
}
