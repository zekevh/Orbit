import Foundation
import MCP
import Network

private struct ContactToolPayload: Codable {
    let items: [[String: String]]
}

actor OrbitMCPServer {
    static let port: UInt16 = 7475

    private let database: OrbitDatabase
    private let transport = StatefulHTTPServerTransport()
    private let server: Server
    private var listener: NWListener?

    init(database: OrbitDatabase) {
        self.database = database
        self.server = Server(
            name: "Orbit",
            version: "0.1.0",
            instructions: """
                Orbit exposes a local professional contact memory system. \
                Use list_contacts for discovery, get_contact for full context, \
                append_context_entry to write raw notes or facts, \
                create_follow_up to set reminders, and complete_follow_up to close them.
                """,
            capabilities: Server.Capabilities(tools: .init(listChanged: false))
        )
    }

    func start() async throws {
        await registerHandlers()
        Task { [server, transport] in
            try await server.start(transport: transport)
        }
        try startListener()
    }

    private func registerHandlers() async {
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: Self.tools)
        }

        let database = database
        await server.withMethodHandler(CallTool.self) { params in
            do {
                switch params.name {
                case "list_contacts":
                    let search = params.arguments?["query"]?.stringValue ?? ""
                    let items = try database.fetchContacts(filter: .allContacts, search: search)
                    let payload = items.map { item in
                        [
                            "id": String(item.id),
                            "display_name": item.displayName,
                            "subtitle": item.secondaryLine
                        ]
                    }
                    return CallTool.Result(
                        content: [.text(text: Self.encode(payload), annotations: nil, _meta: nil)]
                    )

                case "get_contact":
                    guard let contactIDText = params.arguments?["contact_id"]?.stringValue,
                          let contactID = Int64(contactIDText),
                          let payload = try database.contactPayload(contactID: contactID) else {
                        return CallTool.Result(
                            content: [.text(text: "Missing or unknown contact_id", annotations: nil, _meta: nil)],
                            isError: true
                        )
                    }
                    return CallTool.Result(
                        content: [.text(text: Self.encode(payload), annotations: nil, _meta: nil)]
                    )

                case "append_context_entry":
                    guard let contactIDText = params.arguments?["contact_id"]?.stringValue,
                          let contactID = Int64(contactIDText),
                          let body = params.arguments?["body"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !body.isEmpty else {
                        return CallTool.Result(
                            content: [.text(text: "contact_id and body are required", annotations: nil, _meta: nil)],
                            isError: true
                        )
                    }
                    let title = params.arguments?["title"]?.stringValue ?? ""
                    let kind = ContextEntryKind(rawValue: params.arguments?["kind"]?.stringValue ?? "") ?? .note
                    try database.addContextEntry(
                        contactID: contactID,
                        kind: kind,
                        title: title,
                        body: body,
                        provenance: .agentWritten
                    )
                    return CallTool.Result(
                        content: [.text(text: "Added context entry to contact \(contactID)", annotations: nil, _meta: nil)]
                    )

                case "create_follow_up":
                    guard let contactIDText = params.arguments?["contact_id"]?.stringValue,
                          let contactID = Int64(contactIDText),
                          let title = params.arguments?["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !title.isEmpty else {
                        return CallTool.Result(
                            content: [.text(text: "contact_id and title are required", annotations: nil, _meta: nil)],
                            isError: true
                        )
                    }
                    let note = params.arguments?["note"]?.stringValue ?? ""
                    let dueAt = params.arguments?["due_at"]?.stringValue.flatMap(ISO8601DateFormatter().date(from:))
                    try database.addFollowUp(contactID: contactID, title: title, note: note, dueAt: dueAt)
                    return CallTool.Result(
                        content: [.text(text: "Created follow-up for contact \(contactID)", annotations: nil, _meta: nil)]
                    )

                case "complete_follow_up":
                    guard let followUpIDText = params.arguments?["follow_up_id"]?.stringValue,
                          let followUpID = Int64(followUpIDText) else {
                        return CallTool.Result(
                            content: [.text(text: "follow_up_id is required", annotations: nil, _meta: nil)],
                            isError: true
                        )
                    }
                    try database.completeFollowUp(id: followUpID)
                    return CallTool.Result(
                        content: [.text(text: "Completed follow-up \(followUpID)", annotations: nil, _meta: nil)]
                    )

                default:
                    throw MCPError.methodNotFound("Unknown tool: \(params.name)")
                }
            } catch {
                return CallTool.Result(
                    content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                    isError: true
                )
            }
        }
    }

    private static let tools: [Tool] = [
        Tool(
            name: "list_contacts",
            description: "Search Orbit contacts by name, company, title, or context text",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Optional search text")
                    ])
                ])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "get_contact",
            description: "Fetch one contact with full Orbit context timeline and follow-ups",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "contact_id": .object([
                        "type": .string("string"),
                        "description": .string("Orbit contact ID returned by list_contacts")
                    ])
                ]),
                "required": .array([.string("contact_id")])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "append_context_entry",
            description: "Append a raw note or fact to a contact without overwriting prior context",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "contact_id": .object([
                        "type": .string("string"),
                        "description": .string("Orbit contact ID")
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Optional short title")
                    ]),
                    "body": .object([
                        "type": .string("string"),
                        "description": .string("Raw context body")
                    ]),
                    "kind": .object([
                        "type": .string("string"),
                        "description": .string("note, fact, meeting, preference, or imported")
                    ])
                ]),
                "required": .array([.string("contact_id"), .string("body")])
            ]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
        ),
        Tool(
            name: "create_follow_up",
            description: "Create a follow-up reminder for a contact",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "contact_id": .object([
                        "type": .string("string"),
                        "description": .string("Orbit contact ID")
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Short follow-up title")
                    ]),
                    "note": .object([
                        "type": .string("string"),
                        "description": .string("Optional follow-up note")
                    ]),
                    "due_at": .object([
                        "type": .string("string"),
                        "description": .string("Optional ISO8601 due date")
                    ])
                ]),
                "required": .array([.string("contact_id"), .string("title")])
            ]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
        ),
        Tool(
            name: "complete_follow_up",
            description: "Mark a follow-up as completed",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "follow_up_id": .object([
                        "type": .string("string"),
                        "description": .string("Orbit follow-up ID")
                    ])
                ]),
                "required": .array([.string("follow_up_id")])
            ]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        )
    ]

    private static func encode(_ payload: Any) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private func startListener() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        let listener = try NWListener(using: parameters, on: port)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleConnection(connection) }
        }
        listener.start(queue: .main)
    }

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .main)
        guard let request = await readRequest(from: connection) else {
            connection.cancel()
            return
        }
        let response = await transport.handleRequest(request)
        switch response {
        case .stream(let stream, let headers):
            await writeHead(statusCode: 200, headers: headers, to: connection)
            do {
                for try await chunk in stream {
                    guard await write(chunk, to: connection) else { break }
                }
            } catch {}
        default:
            let body = response.bodyData ?? Data()
            var headers = response.headers
            headers["Content-Length"] = "\(body.count)"
            await writeHead(statusCode: response.statusCode, headers: headers, to: connection)
            _ = await write(body, to: connection)
        }
        connection.cancel()
    }

    private func readRequest(from connection: NWConnection) async -> HTTPRequest? {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)

        while true {
            guard let chunk = await receive(from: connection) else { return nil }
            buffer.append(chunk)
            guard let split = buffer.range(of: separator) else { continue }

            let headerData = buffer[..<split.lowerBound]
            guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
            let lines = headerString.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { return nil }
            let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return nil }

            var headers: [String: String] = [:]
            for line in lines.dropFirst() where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }

            let contentLength = Int(headers["Content-Length"] ?? headers["content-length"] ?? "") ?? 0
            var body = Data(buffer[split.upperBound...])
            while body.count < contentLength {
                guard let more = await receive(from: connection) else { return nil }
                body.append(more)
            }

            return HTTPRequest(
                method: parts[0],
                headers: headers,
                body: contentLength > 0 ? Data(body.prefix(contentLength)) : nil,
                path: parts[1]
            )
        }
    }

    private func receive(from connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                continuation.resume(returning: data.flatMap { $0.isEmpty ? nil : Optional($0) })
            }
        }
    }

    private func writeHead(statusCode: Int, headers: [String: String], to connection: NWConnection) async {
        let phrase: String
        switch statusCode {
        case 200: phrase = "OK"
        case 202: phrase = "Accepted"
        case 400: phrase = "Bad Request"
        case 404: phrase = "Not Found"
        case 405: phrase = "Method Not Allowed"
        default: phrase = "Error"
        }
        var response = "HTTP/1.1 \(statusCode) \(phrase)\r\n"
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"
        _ = await write(Data(response.utf8), to: connection)
    }

    @discardableResult
    private func write(_ data: Data, to connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }
}
