import Foundation
import CryptoKit

// Verify the actual update archive against the public key embedded in the app.
let args = CommandLine.arguments
guard args.count == 4,
      let keyData = Data(base64Encoded: args[1]),
      let signature = Data(base64Encoded: args[2]) else {
    fatalError("Expected public key, signature, and DMG path")
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
let archive = try Data(contentsOf: URL(fileURLWithPath: args[3]))
guard key.isValidSignature(signature, for: archive) else {
    fatalError("Sparkle signature does not match the app's public key")
}
print("Sparkle DMG signature verified against the app's public key.")
