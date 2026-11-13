import XCTest
import CryptoKit
@testable import BrumlikAI

final class UpdateTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isVersion("0.2.0", newerThan: "0.1.9"))
        XCTAssertTrue(UpdateChecker.isVersion("1.0", newerThan: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isVersion("0.10.0", newerThan: "0.9.0"))
        XCTAssertTrue(UpdateChecker.isVersion("1.2.1", newerThan: "1.2"))
        XCTAssertFalse(UpdateChecker.isVersion("1.2.0", newerThan: "1.2"))
        XCTAssertFalse(UpdateChecker.isVersion("0.1.0", newerThan: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isVersion("0.1.0", newerThan: "0.2.0"))
    }

    func testAcceptsArchiveSignedWithTheMatchingKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let archive = Data("BrumlikAI.app contents".utf8)
        let signatureFile = Data((try key.signature(for: archive).base64EncodedString() + "\n").utf8)
        XCTAssertTrue(UpdateChecker.isValidSignature(signatureFile, for: archive, publicKey: key.publicKey))
    }

    func testRejectsTamperedArchive() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signatureFile = Data(try key.signature(for: Data("original".utf8)).base64EncodedString().utf8)
        XCTAssertFalse(UpdateChecker.isValidSignature(signatureFile, for: Data("tampered".utf8), publicKey: key.publicKey))
    }

    func testRejectsSignatureFromAnotherKey() throws {
        let archive = Data("archive".utf8)
        let signatureFile = Data(try Curve25519.Signing.PrivateKey().signature(for: archive).base64EncodedString().utf8)
        XCTAssertFalse(UpdateChecker.isValidSignature(signatureFile, for: archive, publicKey: Curve25519.Signing.PrivateKey().publicKey))
    }

    func testRejectsGarbageSignature() {
        let key = Curve25519.Signing.PrivateKey()
        XCTAssertFalse(UpdateChecker.isValidSignature(Data("not base64 !!".utf8), for: Data("archive".utf8), publicKey: key.publicKey))
    }
}
