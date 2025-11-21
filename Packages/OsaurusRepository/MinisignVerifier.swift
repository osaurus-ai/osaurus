import Foundation
import CryptoKit

public enum MinisignVerifyError: Error {
    case invalidPublicKey
    case invalidSignature
}

public enum MinisignVerifier {
    public static func verify(publicKey: String, signature: String, data: Data) throws -> Bool {
        let pubKeyRaw = try decodePublicKey(publicKey)
        let sigRaw = try decodeSignature(signature)
        guard pubKeyRaw.count == 32, sigRaw.count == 64 else {
            throw MinisignVerifyError.invalidSignature
        }
        let pk = try Curve25519.Signing.PublicKey(rawRepresentation: pubKeyRaw)
        return pk.isValidSignature(sigRaw, for: data)
    }

    private static func decodePublicKey(_ s: String) throws -> Data {
        if let d = Data(base64Encoded: s), d.count == 32 {
            return d
        }
        if let base64Line = extractBase64Line(from: s), let d = Data(base64Encoded: base64Line) {
            if d.count >= 32 {
                return d.suffix(32)
            }
        }
        throw MinisignVerifyError.invalidPublicKey
    }

    private static func decodeSignature(_ s: String) throws -> Data {
        if let d = Data(base64Encoded: s), d.count == 64 {
            return d
        }
        if let base64Line = extractBase64Line(from: s), let d = Data(base64Encoded: base64Line) {
            if d.count >= 64 {
                return d.suffix(64)
            }
        }
        throw MinisignVerifyError.invalidSignature
    }

    private static func extractBase64Line(from ascii: String) -> String? {
        let lines = ascii.split(whereSeparator: \.isNewline).map(String.init)
        for line in lines {
            if line.count >= 3, line.hasPrefix("RW"), Data(base64Encoded: line) != nil {
                return line
            }
        }
        for line in lines {
            if Data(base64Encoded: line) != nil {
                return line
            }
        }
        return nil
    }
}
