import XCTest

final class XunfeiAuthTests: XCTestCase {
    /// 官方文档给出的签名测试向量：
    /// APISecret = "secretxxxxxxxx2df7900c09xxxxxxxx"，
    /// date = "Wed, 10 Jul 2019 07:35:43 GMT"，host/path 为听写默认值。
    func testSignatureMatchesOfficialDocVector() {
        let sig = XunfeiAuth.signature(
            apiSecret: "secretxxxxxxxx2df7900c09xxxxxxxx",
            date: "Wed, 10 Jul 2019 07:35:43 GMT",
            host: "iat-api.xfyun.cn",
            path: "/v2/iat"
        )
        XCTAssertEqual(sig, "Hp3Ty4ZkSBmL8jKyOLpQiv9Sr5nvmeYEH7WsL/ZO2Jg=")
    }

    func testRFC1123GMTFormat() {
        // 2019-07-10 07:35:43 UTC
        var comps = DateComponents()
        comps.year = 2019; comps.month = 7; comps.day = 10
        comps.hour = 7; comps.minute = 35; comps.second = 43
        comps.timeZone = TimeZone(identifier: "GMT")
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        XCTAssertEqual(XunfeiAuth.rfc1123GMT(date), "Wed, 10 Jul 2019 07:35:43 GMT")
    }

    func testRFC1123GMTIgnoresLocalTimeZone() {
        // 不同本地时区下格式化结果必须一致（固定 GMT 输出）
        var comps = DateComponents()
        comps.year = 2026; comps.month = 1; comps.day = 2
        comps.hour = 3; comps.minute = 4; comps.second = 5
        comps.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        XCTAssertEqual(XunfeiAuth.rfc1123GMT(date), "Thu, 01 Jan 2026 19:04:05 GMT")
    }

    func testSignedURLContainsAuthQueryItems() throws {
        let url = try XCTUnwrap(XunfeiAuth.signedURL(
            host: "iat-api.xfyun.cn", path: "/v2/iat",
            apiKey: "key123", apiSecret: "secret456"
        ))
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "iat-api.xfyun.cn")
        XCTAssertEqual(url.path, "/v2/iat")

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(Set(byName.keys), ["authorization", "date", "host"])
        XCTAssertEqual(byName["host"], "iat-api.xfyun.cn")

        // authorization = base64("api_key=..., signature=...")
        let authOrigin = String(data: Data(base64Encoded: byName["authorization"]!)!, encoding: .utf8)!
        XCTAssertTrue(authOrigin.contains("api_key=\"key123\""))
        XCTAssertTrue(authOrigin.contains("algorithm=\"hmac-sha256\""))
        XCTAssertTrue(authOrigin.contains("headers=\"host date request-line\""))

        // date 参数与签名所用时间一致，可复算出同一 signature
        let expectedSig = XunfeiAuth.signature(
            apiSecret: "secret456", date: byName["date"]!,
            host: "iat-api.xfyun.cn", path: "/v2/iat"
        )
        XCTAssertTrue(authOrigin.contains("signature=\"\(expectedSig)\""))
    }
}
