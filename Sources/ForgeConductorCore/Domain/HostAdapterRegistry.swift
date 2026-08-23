// HostAdapterRegistry.swift
// What: Describes and registers compile-time session-host plugins.
// How: A locked factory registry exposes stable manifests without loading unsigned bundles.
// Why: Continuity selects only adapters that explicitly advertise the required capabilities.

import Foundation

public struct HostPluginManifest: Sendable, Equatable {
    public var identifier: String
    public var version: String
    public var minimumContractVersion: Int
    public var hostType: String
    public var capabilities: HostCapabilities
    public var configurationKeys: [String]
    public var privacyRequirements: [String]
    public var migrationVersion: Int

    public init(
        identifier: String, version: String, minimumContractVersion: Int,
        hostType: String, capabilities: HostCapabilities,
        configurationKeys: [String], privacyRequirements: [String], migrationVersion: Int
    ) {
        self.identifier = identifier
        self.version = version
        self.minimumContractVersion = minimumContractVersion
        self.hostType = hostType
        self.capabilities = capabilities
        self.configurationKeys = configurationKeys
        self.privacyRequirements = privacyRequirements
        self.migrationVersion = migrationVersion
    }

    public func asDictionary() -> [String: Any] {
        [
            "identifier": identifier, "version": version,
            "minimum_contract_version": minimumContractVersion, "host_type": hostType,
            "capabilities": [
                "create": capabilities.create, "bootstrap": capabilities.bootstrap,
                "usage_reporting": capabilities.usageReporting, "resume": capabilities.resume,
                "idempotency": capabilities.idempotency,
                "query_by_idempotency_key": capabilities.queryByIdempotencyKey,
            ],
            "configuration_keys": configurationKeys,
            "privacy_requirements": privacyRequirements,
            "migration_version": migrationVersion,
        ]
    }
}

public final class HostAdapterRegistry: @unchecked Sendable {
    public static let shared = HostAdapterRegistry()
    public typealias Factory = @Sendable (URL) throws -> any SessionHostAdapter

    private struct Registration {
        var manifest: HostPluginManifest
        var factory: Factory
    }

    private let lock = NSLock()
    private var registrations: [String: Registration] = [:]

    public init() {}

    public func register(manifest: HostPluginManifest, factory: @escaping Factory) {
        lock.lock()
        registrations[manifest.identifier] = Registration(manifest: manifest, factory: factory)
        lock.unlock()
    }

    public func adapter(identifier: String, storageDirectory: URL) throws -> any SessionHostAdapter {
        lock.lock()
        let factory = registrations[identifier]?.factory
        lock.unlock()
        guard let factory else { throw ContinuityRunError.hostCapabilityUnavailable }
        return try factory(storageDirectory)
    }

    public var manifests: [HostPluginManifest] {
        lock.lock(); defer { lock.unlock() }
        return registrations.values.map(\.manifest).sorted { $0.identifier < $1.identifier }
    }
}
