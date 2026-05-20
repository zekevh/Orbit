import Foundation
import MCP
import Network

actor OrbitMCPServer {
    static let port: UInt16 = 7475

    private let database: OrbitDatabase
    private let transport = StatefulHTTPServerTransport()
    private let server: Server
    private var listener: NWListener?
    private var hasStarted = false

    init(database: OrbitDatabase) {
        self.database = database
        self.server = Server(
            name: "Orbit",
            version: "0.3.0",
            instructions: """
                Orbit exposes a local contact memory system for agents.
                Humans write append-only raw notes. Agents should read contact context,
                generate editable insights on top of those notes, and manage follow-ups.
                Raw notes must not be overwritten.
                """,
            capabilities: Server.Capabilities(tools: .init(listChanged: false))
        )
    }

    func start() async throws {
        guard !hasStarted else { return }
        await registerHandlers()
        Task { [server, transport] in
            try await server.start(transport: transport)
        }
        try startListener()
        hasStarted = true
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
                    let query = params.arguments?["query"]?.stringValue ?? ""
                    let items = try database.fetchContacts(filter: .allContacts, search: query)
                    return Self.success(items.map {
                        [
                            "id": String($0.id),
                            "display_name": $0.displayName,
                            "subtitle": $0.secondaryLine,
                            "open_follow_up_count": String($0.openFollowUpCount)
                        ]
                    })

                case "get_contact":
                    guard let contactID = Self.contactID(from: params.arguments),
                          let payload = try database.contactPayload(contactID: contactID) else {
                        return Self.error("Missing or unknown contact_id")
                    }
                    return Self.success(payload)

                case "list_pending_follow_ups":
                    return Self.success(try database.pendingFollowUpsPayload())

                case "append_note":
                    guard let contactID = Self.contactID(from: params.arguments),
                          let body = params.arguments?["body"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !body.isEmpty else {
                        return Self.error("contact_id and body are required")
                    }
                    let source = NoteSource(rawValue: params.arguments?["source"]?.stringValue ?? "") ?? .agent
                    try database.addNote(contactID: contactID, body: body, source: source)
                    return Self.message("Added note to contact \(contactID)")

                case "upsert_insight":
                    guard let contactID = Self.contactID(from: params.arguments),
                          let body = params.arguments?["body"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !body.isEmpty else {
                        return Self.error("contact_id and body are required")
                    }
                    let insightID = params.arguments?["insight_id"]?.stringValue.flatMap(Int64.init)
                    let kind = InsightKind(rawValue: params.arguments?["kind"]?.stringValue ?? "") ?? .general
                    let source = InsightSource(rawValue: params.arguments?["source"]?.stringValue ?? "") ?? .agent
                    try database.upsertInsight(contactID: contactID, insightID: insightID, body: body, kind: kind, source: source)
                    return Self.message(insightID == nil ? "Created insight for contact \(contactID)" : "Updated insight \(insightID!)")

                case "delete_insight":
                    guard let insightID = params.arguments?["insight_id"]?.stringValue.flatMap(Int64.init) else {
                        return Self.error("insight_id is required")
                    }
                    try database.deleteInsight(id: insightID)
                    return Self.message("Deleted insight \(insightID)")

                case "upsert_follow_up":
                    guard let contactID = Self.contactID(from: params.arguments),
                          let title = params.arguments?["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !title.isEmpty else {
                        return Self.error("contact_id and title are required")
                    }
                    let followUpID = params.arguments?["follow_up_id"]?.stringValue.flatMap(Int64.init)
                    let note = params.arguments?["note"]?.stringValue ?? ""
                    let dueAt = params.arguments?["due_at"]?.stringValue.flatMap(ISO8601DateFormatter().date(from:))
                    let source = FollowUpSource(rawValue: params.arguments?["source"]?.stringValue ?? "") ?? .agent
                    try database.upsertFollowUp(
                        contactID: contactID,
                        followUpID: followUpID,
                        title: title,
                        note: note,
                        dueAt: dueAt,
                        source: source
                    )
                    return Self.message(followUpID == nil ? "Created follow-up for contact \(contactID)" : "Updated follow-up \(followUpID!)")

                case "complete_follow_up":
                    guard let followUpID = params.arguments?["follow_up_id"]?.stringValue.flatMap(Int64.init) else {
                        return Self.error("follow_up_id is required")
                    }
                    try database.completeFollowUp(id: followUpID)
                    return Self.message("Completed follow-up \(followUpID)")

                default:
                    throw MCPError.methodNotFound("Unknown tool: \(params.name)")
                }
            } catch {
                return Self.error(error.localizedDescription)
            }
        }
    }

    private static let tools: [Tool] = [
        Tool(
            name: "list_contacts",
            description: "Search Orbit contacts by name, company, title, raw note text, or insight text",
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
            description: "Fetch one contact with profile, raw notes, editable insights, follow-ups, and today's timestamp",
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
            name: "list_pending_follow_ups",
            description: "List all open follow-ups across contacts",
            inputSchema: .object([
                "type": .string("object")
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "append_note",
            description: "Append a raw note to a contact without overwriting prior notes",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "contact_id": .object([
                        "type": .string("string"),
                        "description": .string("Orbit contact ID")
                    ]),
                    "body": .object([
                        "type": .string("string"),
                        "description": .string("Raw note body")
                    ]),
                    "source": .object([
                        "type": .string("string"),
                        "description": .string("agent, imported, or system")
                    ])
                ]),
                "required": .array([.string("contact_id"), .string("body")])
            ]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
        ),
        Tool(
            name: "upsert_insight",
            description: "Create or update an editable interpreted insight for a contact",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "contact_id": .object([
                        "type": .string("string"),
                        "description": .string("Orbit contact ID")
                    ]),
                    "insight_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional insight ID to update")
                    ]),
                    "body": .object([
                        "type": .string("string"),
                        "description": .string("Insight text")
                    ]),
                    "kind": .object([
                        "type": .string("string"),
                        "description": .string("general, summary, fact, preference, relationship, or priority")
                    ]),
                    "source": .object([
                        "type": .string("string"),
                        "description": .string("human, agent, imported, or system")
                    ])
                ]),
                "required": .array([.string("contact_id"), .string("body")])
            ]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
        ),
        Tool(
            name: "delete_insight",
            description: "Delete one editable insight",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "insight_id": .object([
                        "type": .string("string"),
                        "description": .string("Insight ID")
                    ])
                ]),
                "required": .array([.string("insight_id")])
            ]),
            annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "upsert_follow_up",
            description: "Create or update an agent-managed follow-up for a contact",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "contact_id": .object([
                        "type": .string("string"),
                        "description": .string("Orbit contact ID")
                    ]),
                    "follow_up_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional follow-up ID to update")
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
                    ]),
                    "source": .object([
                        "type": .string("string"),
                        "description": .string("agent, imported, or system")
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

    private static func contactID(from arguments: [String: Value]?) -> Int64? {
        arguments?["contact_id"]?.stringValue.flatMap(Int64.init)
    }

    private static func success(_ payload: Any) -> CallTool.Result {
        CallTool.Result(content: [.text(text: encode(payload), annotations: nil, _meta: nil)])
    }

    private static func message(_ text: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
    }

    private static func error(_ text: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: true)
    }

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
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch let error as NWError {
            throw OrbitMCPServerError.listenerStartupFailed(error)
        } catch {
            throw OrbitMCPServerError.genericStartupFailed(error.localizedDescription)
        }
        self.listener = listener
        listener.stateUpdateHandler = { newState in
            switch newState {
            case .failed(let error):
                NSLog("Orbit MCP listener failed: %@", String(describing: error))
            case .cancelled:
                NSLog("Orbit MCP listener cancelled")
            default:
                break
            }
        }
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
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else { return nil }

            let method = String(parts[0])
            let path = String(parts[1])
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colonIndex = line.firstIndex(of: ":") else { continue }
                let name = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }

            let bodyStart = split.upperBound
            let contentLength = Int(headers["Content-Length"] ?? "") ?? 0
            let remaining = buffer[bodyStart...]
            var body = Data(remaining)
            while body.count < contentLength {
                guard let chunk = await receive(from: connection) else { return nil }
                body.append(chunk)
            }
            if body.count > contentLength {
                body = body.prefix(contentLength)
            }

            return HTTPRequest(method: method, headers: headers, body: body, path: path)
        }
    }

    private func receive(from connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete || error != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func writeHead(statusCode: Int, headers: [String: String], to connection: NWConnection) async {
        var response = "HTTP/1.1 \(statusCode) \(Self.reasonPhrase(for: statusCode))\r\n"
        for (name, value) in headers {
            response += "\(name): \(value)\r\n"
        }
        response += "\r\n"
        _ = await write(Data(response.utf8), to: connection)
    }

    private func write(_ data: Data, to connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}

enum OrbitMCPServerError: LocalizedError {
    case listenerStartupFailed(NWError)
    case genericStartupFailed(String)

    var errorDescription: String? {
        switch self {
        case .listenerStartupFailed(let error):
            "Could not start local listener: \(error)"
        case .genericStartupFailed(let message):
            message
        }
    }

    var isPortInUse: Bool {
        switch self {
        case .listenerStartupFailed(let error):
            if case .posix(let posixError) = error {
                return posixError == .EADDRINUSE
            }
            return false
        case .genericStartupFailed:
            return false
        }
    }
}
