import Foundation

/// The pure half of the built-in proxy: request-head parsing, request classification,
/// Basic-auth verification, canned responses, and gost-shaped session lines.
/// No sockets here — everything is unit-tested byte-in/byte-out.

struct HTTPHeader: Equatable {
    let name: String
    let value: String
}

struct HTTPRequestHead: Equatable {
    let method: String
    let target: String
    let version: String
    let headers: [HTTPHeader]

    func firstValue(of name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// End of an HTTP request head on the wire.
let httpHeadTerminator = Data("\r\n\r\n".utf8)
/// Cap for an accumulated head — over this the connection is answered 400 and closed.
let httpMaxHeadBytes = 65_536

/// Parse a request head (bytes BEFORE the terminator). nil for anything that is not
/// `METHOD SP TARGET SP HTTP/x.y` followed by `Name: value` lines — TLS bytes, SOCKS
/// greetings and garbage all fail closed here.
func parseHTTPRequestHead(_ head: Data) -> HTTPRequestHead? {
    guard let text = String(data: head, encoding: .utf8) else { return nil }
    var lines = text.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    lines.removeFirst()
    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, parts[2].hasPrefix("HTTP/") else { return nil }
    var headers: [HTTPHeader] = []
    for line in lines where !line.isEmpty {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        headers.append(HTTPHeader(name: name, value: value))
    }
    return HTTPRequestHead(method: parts[0], target: parts[1], version: parts[2], headers: headers)
}

enum ProxyRequestKind: Equatable {
    case connect(host: String, port: Int)
    /// `rewrittenHead` is origin-form with `Proxy-*` headers dropped, terminator included —
    /// ready to send to the origin verbatim, followed by whatever came after the client's head.
    case absoluteForm(host: String, port: Int, rewrittenHead: Data)
    case bad
}

func classifyProxyRequest(_ head: HTTPRequestHead) -> ProxyRequestKind {
    if head.method == "CONNECT" {
        // "host:port", IPv6 bracketed — same split as proxyClientIP.
        guard let colon = head.target.lastIndex(of: ":"),
              let port = Int(head.target[head.target.index(after: colon)...]), port > 0 else { return .bad }
        var host = String(head.target[head.target.startIndex..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty ? .bad : .connect(host: host, port: port)
    }
    // Absolute-form plain HTTP: `GET http://host[:port]/path HTTP/1.1`. https:// never arrives
    // here (clients CONNECT for TLS), and origin-form has no destination — both are .bad.
    guard let url = URL(string: head.target), url.scheme == "http", let host = url.host, !host.isEmpty
    else { return .bad }
    let port = url.port ?? 80
    var path = url.path.isEmpty ? "/" : url.path
    if let query = url.query { path += "?\(query)" }
    var rewritten = "\(head.method) \(path) \(head.version)\r\n"
    for header in head.headers where !header.name.lowercased().hasPrefix("proxy-") {
        rewritten += "\(header.name): \(header.value)\r\n"
    }
    rewritten += "\r\n"
    return .absoluteForm(host: host, port: port, rewrittenHead: Data(rewritten.utf8))
}

/// `Proxy-Authorization: Basic base64(user:pass)` against the expected pair. The split is at the
/// FIRST colon — a password may contain colons, a username may not (RFC 7617).
func proxyAuthorized(_ head: HTTPRequestHead, username: String, password: String) -> Bool {
    guard let value = head.firstValue(of: "Proxy-Authorization") else { return false }
    let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
    guard parts.count == 2, parts[0].caseInsensitiveCompare("Basic") == .orderedSame,
          let decoded = Data(base64Encoded: parts[1]),
          let pair = String(data: decoded, encoding: .utf8),
          let colon = pair.firstIndex(of: ":") else { return false }
    return String(pair[pair.startIndex..<colon]) == username
        && String(pair[pair.index(after: colon)...]) == password
}

func proxyResponse200() -> Data { Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8) }
func proxyResponse407() -> Data {
    Data("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"DevDeck\"\r\nConnection: close\r\n\r\n".utf8)
}
func proxyResponse400() -> Data { Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".utf8) }
func proxyResponse502() -> Data { Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8) }

/// One session event in the exact shape `parseGostLogLine` reads (`client`/`sid`/`msg` with the
/// spaced ` <> ` / ` >< ` markers) — the built-in engine feeds the SAME client monitor and LogView.
func builtInSessionLine(open: Bool, client: String, sid: String, port: Int) -> String {
    let object: [String: String] = [
        "client": client,
        "sid": sid,
        "msg": "\(client) \(open ? "<>" : "><") :\(port)",
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        return ""   // unreachable for a [String:String]; parseGostLogLine drops "" harmlessly
    }
    return String(decoding: data, as: UTF8.self)
}
