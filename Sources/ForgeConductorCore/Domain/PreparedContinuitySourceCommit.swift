import Foundation

/// The native request owner freezes these bytes before its durable commit intent.
/// This value carries no task authority; every read and commit still requires
/// the live control-plane authorization and exact native request admission.
struct PreparedContinuitySourceCommit: Sendable, Equatable {
    let canonicalPacketJSON: Data
    let packetSHA256: String
    let finalize: Bool
    let continuityID: String

    private init(packet: HandoffPacket, canonicalPacketJSON: Data) {
        self.canonicalPacketJSON = canonicalPacketJSON
        packetSHA256 = JSONSupport.sha256Hex(canonicalPacketJSON)
        finalize = packet.resumeReady
        continuityID = packet.id
    }

    static func preparing(_ packet: HandoffPacket) throws -> Self {
        try storedSnapshot(from: ForgeJSONCanonicalizationV1.data(from: packet.asDictionary()))
    }

    /// The persisted representation is the canonical packet itself. Decoding
    /// derives every metadata field and rejects dropped, altered or excess data.
    static func storedSnapshot(from data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= ContinuityIngressLimits.maximumPacketBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packet = HandoffPacket.fromDictionary(object),
              ContinuityIngressLimits.validHandoffID(packet.id),
              try ForgeJSONCanonicalizationV1.data(from: packet.asDictionary()) == data else {
            throw ContinuityIngressError.integrityFailure("prepared source packet differs")
        }
        try SQLiteStore.validateIngressPacketBounds(packet)
        return Self(packet: packet, canonicalPacketJSON: data)
    }

    func packet() throws -> HandoffPacket {
        let verified = try Self.storedSnapshot(from: canonicalPacketJSON)
        guard verified == self,
              let packet = HandoffPacket.fromDictionary(try JSONSupport.object(from: canonicalPacketJSON)) else {
            throw ContinuityIngressError.integrityFailure("prepared source identity differs")
        }
        return packet
    }
}
