#!/usr/bin/env swift
// Manages the Ed25519 key that signs BrumlikAI updates.
//
//   swift scripts/update-keys.swift generate [key-file]     create a key pair, print the public key
//   swift scripts/update-keys.swift public [key-file]       print the public key (Info.plist → BrumlikUpdatePublicKey)
//   swift scripts/update-keys.swift sign <file> [key-file]  print the base64 signature of <file>
//
// The default key file is ~/.brumlikai/update-signing-key. Keep a backup: without it no update can be
// published that existing installations will accept.
import Foundation
import CryptoKit

let arguments = Array(CommandLine.arguments.dropFirst())
let defaultKeyPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".brumlikai/update-signing-key").path

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
        fail("✗ Can't read the private key at \(path)")
    }
    return key
}

switch arguments.first {
case "generate":
    let path = arguments.count > 1 ? arguments[1] : defaultKeyPath
    guard !FileManager.default.fileExists(atPath: path) else {
        fail("✗ \(path) already exists — refusing to overwrite it.")
    }
    let directory = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let key = Curve25519.Signing.PrivateKey()
    guard FileManager.default.createFile(
        atPath: path,
        contents: Data(key.rawRepresentation.base64EncodedString().utf8),
        attributes: [.posixPermissions: 0o600]
    ) else { fail("✗ Can't write \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "public":
    print(loadKey(arguments.count > 1 ? arguments[1] : defaultKeyPath).publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard arguments.count > 1, let data = FileManager.default.contents(atPath: arguments[1]) else {
        fail("usage: swift scripts/update-keys.swift sign <file> [key-file]")
    }
    let key = loadKey(arguments.count > 2 ? arguments[2] : defaultKeyPath)
    print(try key.signature(for: data).base64EncodedString())

default:
    fail("usage: swift scripts/update-keys.swift generate|public|sign <file> [key-file]")
}
