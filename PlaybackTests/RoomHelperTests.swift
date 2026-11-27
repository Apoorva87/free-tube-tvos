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

    func testSelfSignedLeafRequiresExactFingerprint() throws {
        // Public DER of a disposable self-signed test certificate.
        let der = try XCTUnwrap(Data(base64Encoded: "MIICKzCCAdACCQCxUFDjw5jFujAKBggqhkjOPQQDAjAjMSEwHwYDVQQDDBhyb29tLWhlbHBlci10ZXN0LWZpeHR1cmUwHhcNMjYxMTI3MDAyNzE0WhcNMjYxMTI4MDAyNzE0WjAjMSEwHwYDVQQDDBhyb29tLWhlbHBlci10ZXN0LWZpeHR1cmUwggFLMIIBAwYHKoZIzj0CATCB9wIBATAsBgcqhkjOPQEBAiEA/////wAAAAEAAAAAAAAAAAAAAAD///////////////8wWwQg/////wAAAAEAAAAAAAAAAAAAAAD///////////////wEIFrGNdiqOpPns+u9VXaYhrxlHQawzFOw9jvOPD4n0mBLAxUAxJ02CIbnBJNqZnjhE50mt4GffpAEQQRrF9Hy4SxCR/i85uVjpEDydwN9gS3rM6D0oTlF2JjClk/jQuL+Gn+bjufrSnwPnhYrzjNXazFezsu2QGg3v1H1AiEA/////wAAAAD//////////7zm+q2nF56E87nKwvxjJVECAQEDQgAE6yYOC7T4e6XaZwQj8Ve0ZDBo0m636ESIT7erG5I4ywORvOYjLGZYHkH8V/2CYoYR/sYw+ThGNUDT5NA5TkGebDAKBggqhkjOPQQDAgNJADBGAiEAj8hiZxTVgwy/Ww/yZTPQgRPOJhEmi+OR6ocmsFcwyCUCIQCsIup9fYgcw8PK6rhF9mt/6K6AhIRRfXHodawtHGgztw=="))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust), errSecSuccess)
        let presented = try XCTUnwrap(trust)
        XCTAssertTrue(RoomHelperTransport.accepts(presented, fingerprint: RoomHelperTransport.fingerprint(of: der)))
        XCTAssertFalse(RoomHelperTransport.accepts(presented, fingerprint: String(repeating: "0", count: 64)))
    }

    func testFixedLengthResponseCanBeSplitAtAnyByte() throws {
        let payload = Data(#"{"detail":"字幕"}"#.utf8)
        let wire = Data("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\n\r\n".utf8) + payload
        for boundary in 0..<wire.count {
            var response = RoomHelperHTTPResponse()
            XCTAssertNil(try response.receive(Data(wire.prefix(boundary)), end: false, limit: payload.count))
            XCTAssertEqual(try response.receive(Data(wire.dropFirst(boundary)), end: true, limit: payload.count), payload)
        }
    }

    func testRefusesRedirectsAmbiguousFramingOversizedAndTruncatedData() {
        let cases = [
            "HTTP/1.1 302 Found\r\nLocation: https://example.com/\r\nContent-Length: 0\r\n\r\n",
            "HTTP/1.0 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 2\r\n\r\n{}",
            "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n{}",
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n{}",
            "HTTP/1.1 200 OK\r\nContent-Length: 5000000\r\n\r\n",
            "HTTP/1.1 200 OK\r\n\r\n{}",
            String(repeating: "x", count: 8193)
        ]
        for wire in cases {
            var response = RoomHelperHTTPResponse()
            XCTAssertThrowsError(try response.receive(Data(wire.utf8), end: true, limit: 32))
        }
    }

    func testPropagatesAuthenticatedHelperStatus() {
        let body = #"{"error":"signed_out","detail":"Sign in on the laptop."}"#
        let wire = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        var response = RoomHelperHTTPResponse()
        XCTAssertThrowsError(try response.receive(Data(wire.utf8), end: true, limit: 256)) { error in
            guard case RoomHelperError.http(503, "signed_out", "Sign in on the laptop.") = error else {
                XCTFail("Expected the helper's status and detail.")
                return
            }
        }
    }

    func testCertificateFingerprintUsesExactDERBytes() {
        XCTAssertEqual(RoomHelperTransport.fingerprint(of: Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
