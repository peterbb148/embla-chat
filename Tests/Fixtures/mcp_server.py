"""Loopback-only synthetic MCP 2026 HTTP fixture; never a production server or live data source."""

import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock


class Handler(BaseHTTPRequestHandler):
    """Return deterministic protocol scenarios for the native client's transport tests."""

    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        """Keep fixture input and credentials out of test logs."""

    def do_GET(self):
        """Expose method counts only, never credentials or request bodies."""
        if self.path == "/request-counts":
            with self.server.count_lock:
                counts = {path: dict(values) for path, values in self.server.counts.items()}
            self.respond(200, counts)
        else:
            self.respond(404, {"error": "unknown fixture route"})

    def do_POST(self):
        """Serve discovery, echo, SSE, cancellation and actual error responses."""
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with self.server.count_lock:
            counts = self.server.counts.setdefault(self.path, {})
            method = request.get("method", "")
            counts[method] = counts.get(method, 0) + 1
        params = request.get("params", {})
        metadata = params.get("_meta", {})
        if (
            self.headers.get("MCP-Protocol-Version") != "2026-07-28"
            or metadata.get("io.modelcontextprotocol/protocolVersion") != "2026-07-28"
            or metadata.get("io.modelcontextprotocol/clientCapabilities") != {}
            or self.headers.get("Mcp-Method") != request["method"]
        ):
            self.respond(400, {"error": "fixture metadata validation failed"})
            return
        if self.path == "/bearer" and self.headers.get("Authorization") != "Bearer synthetic-key":
            self.respond(401, {"error": "synthetic bearer key required"})
            return
        if self.path == "/auth":
            self.respond(401, {"error": "fixture authentication required"})
            return
        if self.path == "/redirect":
            self.send_response(307)
            self.send_header("Location", "/must-not-follow")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path in {"/rpc-error", "/rpc-error-http"}:
            status = 400 if self.path == "/rpc-error-http" else 200
            self.respond(status, {"jsonrpc": "2.0", "id": request["id"], "error": {
                "code": -32602, "message": "Synthetic invalid timezone",
                "data": {"field": "timezone", "reason": "Fixture detail"},
            }})
            return
        if self.path == "/paged-discovery":
            time.sleep(0.08)
        if (self.path == "/delayed-tool" and request["method"] == "tools/call") or (
            self.path == "/delayed-discovery" and request["method"] == "server/discover"
        ):
            time.sleep(0.4)
        if request["method"] == "server/discover":
            result = {"capabilities": {"tools": {}}, "resultType": "complete"}
        elif self.path in {
            "/routing-time", "/routing-search", "/routing-oversized", "/routing-profile",
        }:
            result = self.routing_result(request["method"], params)
        elif request["method"] == "tools/list":
            result = {
                "resultType": "complete",
                "tools": [{"name": "echo", "description": "Synthetic fixture echo", "inputSchema": {
                    "type": "object", "properties": {"text": {"type": "string", "x-mcp-header": "Text"}},
                    "required": ["text"],
                }}],
            }
        elif request["method"] == "tools/call":
            if self.headers.get("Mcp-Name") != params["name"]:
                self.respond(400, {"error": "fixture name-header validation failed"})
                return
            result = {"resultType": "complete", "isError": self.path == "/tool-error",
                      "content": [{"type": "text", "text": params["arguments"].get("text", "")}],
                      "structuredContent": {"header": self.headers.get("Mcp-Param-Text")}}
        else:
            self.respond(404, {"jsonrpc": "2.0", "id": request["id"],
                               "error": {"code": -32601, "message": "Fixture method not found"}})
            return
        if request["method"] == "tools/call":
            if self.path == "/missing-content":
                result.pop("content")
            elif self.path == "/bad-content":
                result["content"] = "not content blocks"
            elif self.path == "/bad-text":
                result["content"] = [{"type": "text", "text": 42}]
            elif self.path == "/bad-error-flag":
                result["isError"] = "true"
            elif self.path == "/numeric-overflow":
                result["structuredContent"]["number"] = "fixture-excess-precision"
            elif self.path in {"/large-json", "/large-sse", "/over-limit-json", "/over-limit-sse"}:
                size = (1024 if self.path.startswith("/over-limit-") else 192) * 1024
                result["content"][0]["text"] = "x" * size
        if request["method"] == "tools/list":
            if self.path == "/oversized-catalogue-body":
                result["tools"][0]["description"] = "x" * (128 * 1024)
            elif self.path == "/too-many-tools":
                template = result["tools"][0]
                result["tools"] = [dict(template, name=f"echo-{i}") for i in range(65)]
        if self.path == "/paged-discovery" and request["method"] == "tools/list":
            if params.get("cursor") is None:
                result["nextCursor"] = "second-page"
            else:
                result["tools"][0]["name"] = "echo-second-page"
        response = {"jsonrpc": "2.0", "id": request["id"], "result": result}
        if self.path == "/wrong-id":
            response["id"] = "not-the-request-id"
        if self.path in {"/sse", "/sse-cr", "/sse-bom", "/slow", "/invalid-utf8"} or (
            self.path in {"/progress-tool", "/large-sse", "/over-limit-sse"}
            and request["method"] == "tools/call"
        ):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            try:
                if self.path == "/sse-bom":
                    self.wfile.write(b"\xef\xbb\xbf")
                else:
                    self.wfile.write(b": fixture keep-alive\r\n\r\n")
                self.wfile.flush()
                if self.path == "/progress-tool":
                    for _ in range(50):
                        self.wfile.write(b": research still running\n\n")
                        self.wfile.flush()
                        time.sleep(0.02)
                if self.path == "/slow":
                    for _ in range(50):
                        self.wfile.write(b": waiting\n\n")
                        self.wfile.flush()
                        time.sleep(0.1)
                if self.path == "/invalid-utf8":
                    response["result"]["fixture_utf8"] = "fixture-bad-utf8"
                payload = json.dumps(response).encode()
                if self.path == "/invalid-utf8":
                    payload = payload.replace(b'"fixture-bad-utf8"', b'"\xff"')
                ending = b"\r\r" if self.path == "/sse-cr" else b"\r\n\r\n"
                self.wfile.write(b"data: " + payload + ending)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                with self.server.count_lock:
                    counts = self.server.counts.setdefault(self.path, {})
                    counts["disconnected"] = counts.get("disconnected", 0) + 1
        else:
            self.respond(200, response)

    def routing_result(self, method, params):
        """Provide deterministic local catalogues and distinguishable routing evidence."""
        if self.path == "/routing-time":
            definitions = [
                ("get_current_time", "Get the current time in an IANA timezone.", "timezone"),
                ("list_timezones", "List IANA timezone names matching a location.", "query"),
                ("lookup_ip_time", "Look up local time for an IP address.", "ip"),
            ]
        else:
            definitions = [
                ("tavily_search", "Search the web for current sources and links.", "query"),
                ("tavily_research", "Perform extensive multi-step web research.", "input"),
            ]
        if method == "tools/list" and self.path == "/routing-oversized":
            padding = [{
                "name": f"warehouse_inventory_{index:02d}",
                "description": "Look up a warehouse stock movement for its stored inventory record.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        f"warehouse_inventory_reference_{field:03d}": {"type": "string"}
                        for field in range(75)
                    },
                    "required": ["warehouse_inventory_reference_000"],
                    "additionalProperties": False,
                },
            } for index in range(16)]
            return {"resultType": "complete", "tools": padding + [{
                "name": "tavily_search",
                "description": "Search the web for current sources and links.",
                "inputSchema": {
                    "type": "object", "properties": {"query": {"type": "string"}},
                    "required": ["query"], "additionalProperties": False,
                },
            }]}
        if method == "tools/list":
            return {"resultType": "complete", "tools": [
                {"name": name, "description": description, "inputSchema": {
                    "type": "object", "properties": {arg: {"type": "string"}},
                    "required": [arg], "additionalProperties": False,
                }} for name, description, arg in definitions
            ]}
        name = params["name"]
        args = params["arguments"]
        if name == "get_current_time":
            zone = args["timezone"]
            value = {"timezone": zone, "local_time": {
                "Asia/Hong_Kong": "14:37", "Asia/Tokyo": "15:37",
            }.get(zone, "00:09")}
        elif name == "list_timezones":
            value = {"timezones": ["Asia/Hong_Kong", "Asia/Tokyo"]}
        elif name == "tavily_search":
            value = {"url": "https://example.com/blue-penguin"}
            if self.path == "/routing-profile":
                value = {
                    "url": "https://example.com/cedar-reference",
                    "product": "Cedar Finch",
                    "details": [
                        "The synthetic Cedar Finch reference model is intended for offline use.",
                        "The entire model stays on the device during inference.",
                        "The original checkpoint is 5.62 GB and has ten billion parameters.",
                        "The model activates a billion parameters for each generated token.",
                        "The 8192-token context includes instructions, conversation, and generation.",
                        "A separate worker selects tools so their schemas stay out of the main chat.",
                        "Chat summaries keep older information available during long conversations.",
                        "Optional network tools can search, while ordinary offline chat is local.",
                        "Raw tool responses are available for inspection through the tool record.",
                        "The synthetic benchmark name is Midnight Orchard.",
                    ],
                }
        else:
            value = {"message": "Unexpected routing fixture method", "method": name}
        return {"resultType": "complete", "structuredContent": value,
                "content": [{"type": "text", "text": json.dumps(value)}]}

    def respond(self, status, value):
        """Write a complete JSON response, closing each synthetic request."""
        data = json.dumps(value).encode()
        if self.path == "/numeric-overflow":
            data = data.replace(b'"fixture-excess-precision"',
                                b'0.1234567890123456789012345678901234567890123456789012345')
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server.count_lock = Lock()
    server.counts = {}
    print(server.server_address[1], flush=True)
    server.serve_forever()
