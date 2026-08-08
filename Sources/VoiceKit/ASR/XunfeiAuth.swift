import Foundation
import CryptoKit

/// 讯飞开放平台 WebAPI 握手鉴权（hmac-sha256 签名 URL）。
/// 纯函数实现，便于单元测试（测试向量取自官方文档）。
enum XunfeiAuth {
    /// RFC1123 GMT 时间戳，如 "Wed, 10 Jul 2019 07:35:43 GMT"。
    /// 服务端允许 ±300s 时钟偏移。
    static func rfc1123GMT(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return fmt.string(from: date)
    }

    /// signature = base64(hmac-sha256(signature_origin, apiSecret))，
    /// signature_origin = "host: $host\ndate: $date\nGET $path HTTP/1.1"。
    static func signature(apiSecret: String, date: String, host: String, path: String) -> String {
        let origin = "host: \(host)\ndate: \(date)\nGET \(path) HTTP/1.1"
        let key = SymmetricKey(data: Data(apiSecret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(origin.utf8), using: key)
        return Data(mac).base64EncodedString()
    }

    /// 组装带鉴权参数的握手 URL：
    /// wss://$host$path?authorization=...&date=...&host=...
    static func signedURL(host: String, path: String, apiKey: String, apiSecret: String, date: Date = Date()) -> URL? {
        let dateStr = rfc1123GMT(date)
        let sig = signature(apiSecret: apiSecret, date: dateStr, host: host, path: path)
        let authOrigin = "api_key=\"\(apiKey)\", algorithm=\"hmac-sha256\", headers=\"host date request-line\", signature=\"\(sig)\""
        let authorization = Data(authOrigin.utf8).base64EncodedString()
        var comps = URLComponents()
        comps.scheme = "wss"
        comps.host = host
        comps.path = path
        comps.queryItems = [
            URLQueryItem(name: "authorization", value: authorization),
            URLQueryItem(name: "date", value: dateStr),
            URLQueryItem(name: "host", value: host)
        ]
        return comps.url
    }
}
