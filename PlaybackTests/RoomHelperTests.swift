import Security
import XCTest
@testable import ChannelRoom

final class RoomHelperTests: XCTestCase {
    func testPairingRequiresFullOutOfBandFingerprintAndASCIISecret() throws {
        let pin = String(repeating: "aF", count: 32)
        let good = try RoomPairingCode(" \(pin).00001234\n")
        XCTAssertEqual(good.fingerprint, pin.lowercased())
        XCTAssertEqual(good.secret, "00001234")
        for invalid in ["00001234", "\(pin.dropFirst()).00001234", "\(pin).", "\(pin).1234", "\(pin).٠١٢٣", "\(pin).1.2",
                        "\(pin).1234\r\nX-Test: secret", String(repeating: "g", count: 64) + ".1234"] {
            XCTAssertThrowsError(try RoomPairingCode(invalid))
        }
    }

    func testResolvedAddressesAreNumericPrivateOrLinkLocal() {
        for address in ["192.168.1.4", "10.1.2.3", "172.16.0.8", "172.31.255.254", "169.254.1.9",
                        "fd23::9", "fc00::1", "fe80::123%en0"] {
            XCTAssertTrue(RoomHelperDiscovery.isLANHost(address), address)
        }
        for address in ["example.com", "127.0.0.1", "0.0.0.0", "8.8.8.8", "172.15.255.255", "172.32.0.0",
                        "192.169.0.1", "::", "::1", "ff02::fb", "2001:db8::1", "::ffff:192.168.1.4"] {
            XCTAssertFalse(RoomHelperDiscovery.isLANHost(address), address)
        }
    }

    func testServerTrustRequiresBothTheSelectedHostAndItsPinnedLeaf() throws {
        // Public DER of a disposable self-signed test certificate.
        let der = try XCTUnwrap(Data(base64Encoded: "MIICKzCCAdACCQCxUFDjw5jFujAKBggqhkjOPQQDAjAjMSEwHwYDVQQDDBhyb29tLWhlbHBlci10ZXN0LWZpeHR1cmUwHhcNMjYxMTI3MDAyNzE0WhcNMjYxMTI4MDAyNzE0WjAjMSEwHwYDVQQDDBhyb29tLWhlbHBlci10ZXN0LWZpeHR1cmUwggFLMIIBAwYHKoZIzj0CATCB9wIBATAsBgcqhkjOPQEBAiEA/////wAAAAEAAAAAAAAAAAAAAAD///////////////8wWwQg/////wAAAAEAAAAAAAAAAAAAAAD///////////////wEIFrGNdiqOpPns+u9VXaYhrxlHQawzFOw9jvOPD4n0mBLAxUAxJ02CIbnBJNqZnjhE50mt4GffpAEQQRrF9Hy4SxCR/i85uVjpEDydwN9gS3rM6D0oTlF2JjClk/jQuL+Gn+bjufrSnwPnhYrzjNXazFezsu2QGg3v1H1AiEA/////wAAAAD//////////7zm+q2nF56E87nKwvxjJVECAQEDQgAE6yYOC7T4e6XaZwQj8Ve0ZDBo0m636ESIT7erG5I4ywORvOYjLGZYHkH8V/2CYoYR/sYw+ThGNUDT5NA5TkGebDAKBggqhkjOPQQDAgNJADBGAiEAj8hiZxTVgwy/Ww/yZTPQgRPOJhEmi+OR6ocmsFcwyCUCIQCsIup9fYgcw8PK6rhF9mt/6K6AhIRRfXHodawtHGgztw=="))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust), errSecSuccess)
        let host = "fe80::1%en0"
        let good = RoomHelperTrustDelegate(fingerprint: RoomHelperTransport.fingerprint(of: der), host: host)
        XCTAssertTrue(good.accepts(trust, from: "[fe80::1%25en0]"))
        XCTAssertFalse(good.accepts(trust, from: "192.168.1.9"))
        XCTAssertFalse(good.accepts(nil, from: host))
        let wrong = RoomHelperTrustDelegate(fingerprint: String(repeating: "0", count: 64), host: host)
        XCTAssertFalse(wrong.accepts(trust, from: host))
    }

    func testCertificateFingerprintUsesExactDERBytes() {
        XCTAssertEqual(RoomHelperTransport.fingerprint(of: Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
