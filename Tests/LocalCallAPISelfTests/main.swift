import Foundation
import Network

func expect(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}

func request(_ method: String = "POST", _ path: String = "/api/calls/dial",
             body: String = "{\"number\":\"+86 (138) 0000-0000\"}",
             headers: String = "", token: String = "test-token", port: UInt16 = 17576) -> Data {
    Data("\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\(headers)\r\n\(body)".utf8)
}

func decode(_ data: Data) throws -> LocalCallAPICommand? {
    try LocalCallAPIProtocol.decode(data, token: "test-token", port: 17576)
}

func rejected(_ data: Data, _ status: Int) {
    do {
        _ = try decode(data)
        fatalError("Accepted invalid request (expected \(status))")
    } catch let error as LocalCallAPIHTTPError {
        expect(error.status == status, "Expected \(status), got \(error.status): \(error.message)")
    } catch { fatalError("Unexpected error: \(error)") }
}

@main
struct LocalCallAPITests {
    @MainActor static func main() async throws {
        let dial = request()
        for split in 0..<dial.count {
            expect(try decode(Data(dial.prefix(split))) == nil, "Partial request executed at \(split)")
        }
        expect(try decode(dial) == .dial("+8613800000000"), "Dial normalization")
        expect(try decode(request("GET", "/api/calls/status", body: "")) == .status, "Status route")
        expect(try decode(request("POST", "/api/calls/answer", body: "{}")) == .answer, "Answer route")
        expect(try decode(request("POST", "/api/calls/hangup", body: "{}")) == .hangUp, "Hangup route")
        rejected(request(token: "wrong"), 401)
        rejected(request(headers: "Origin: https://example.com\r\n"), 403)
        rejected(request(headers: "Origin: null\r\n"), 403)
        rejected(request(port: 1234), 403)
        rejected(request("GET"), 405)
        rejected(request("POST", "/api/at"), 404)
        rejected(request("POST", "/api/calls/dial?number=123"), 404)
        rejected(request(headers: "Authorization: Bearer test-token\r\n"), 400)
        rejected(request(headers: "Content-Length: 1\r\n"), 400)
        rejected(request(headers: "Transfer-Encoding: chunked\r\n"), 400)
        rejected(request(headers: "Expect: 100-continue\r\n"), 400)
        rejected(request(body: "[]"), 400)
        rejected(request(body: "{"), 400)
        rejected(request(body: "{\"number\":123}"), 400)
        rejected(request(body: "{\"number\":\"123;ATH\"}"), 400)
        rejected(request(body: "{\"number\":\"123\\r\\nATH\"}"), 400)
        rejected(request(body: "{\"number\":\"\"}"), 400)
        rejected(request(body: "{\"number\":\"" + String(repeating: "1", count: 33) + "\"}"), 400)
        rejected(request(body: "{\"number\":\"123\",\"module\":\"other\"}"), 400)
        rejected(request("POST", "/api/calls/answer", body: "{\"number\":\"123\"}"), 400)
        rejected(request(body: String(repeating: "x", count: 4097)), 413)
        rejected(Data(String(repeating: "x", count: 8193).utf8), 413)
        rejected(request(headers: "X-Large: " + String(repeating: "x", count: 8192) + "\r\n"), 413)
        rejected(dial + dial, 400)
        let plain = Data(String(decoding: dial, as: UTF8.self)
            .replacingOccurrences(of: "application/json", with: "text/plain").utf8)
        rejected(plain, 415)

        // Real loopback HTTP traffic, with a fake action handler: no modem or call.
        let port = UInt16.random(in: 20000...60000)
        var commands: [LocalCallAPICommand] = []
        let server = LocalCallAPIServer(token: "test-token", port: port) { command, complete in
            expect(Thread.isMainThread, "Call handler must run on the main queue")
            commands.append(command)
            if command == .hangUp { complete(.error(409, "No active call")) }
            else { complete(.json(["accepted": true])) }
        }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            var finished = false
            try! server.start { error in
                guard !finished else { return }
                finished = true
                if let error { ready.resume(throwing: NSError(domain: error, code: 1)) }
                else { ready.resume() }
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        func perform(_ path: String, method: String = "POST", body: String? = "{}",
                     token: String = "test-token", origin: String? = nil) async throws -> Int {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.httpBody = body.map { Data($0.utf8) }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(origin, forHTTPHeaderField: "Origin")
            let (_, response) = try await session.data(for: request)
            return (response as! HTTPURLResponse).statusCode
        }
        expect(try await perform("/api/calls/dial", body: "{\"number\":\"123\"}", token: "bad") == 401, "HTTP auth")
        expect(try await perform("/api/calls/dial", body: "{\"number\":\"123\"}", origin: "null") == 403, "HTTP origin")
        expect(commands.isEmpty, "Rejected traffic reached the call handler")
        expect(try await perform("/api/calls/dial", body: "{\"number\":\"123\"}") == 200, "HTTP dial")
        expect(try await perform("/api/calls/status", method: "GET", body: nil) == 200, "HTTP status")
        expect(try await perform("/api/calls/answer") == 200, "HTTP answer")
        expect(try await perform("/api/calls/hangup") == 409, "HTTP action failure")
        expect(commands == [.dial("123"), .status, .answer, .hangUp], "Exactly one dispatch per request")
        server.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        do {
            _ = try await perform("/api/calls/status", method: "GET", body: nil)
            fatalError("Listener remained open after stop")
        } catch { /* Connection refused is expected. */ }
        session.invalidateAndCancel()
        print("Local call API protocol and loopback integration tests passed")
    }
}
