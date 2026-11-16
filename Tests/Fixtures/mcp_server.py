"""Loopback-only synthetic MCP 2026 HTTP fixture; never a production server or live data source."""

import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    """Return deterministic protocol scenarios for the native client's transport tests."""

    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        """Keep fixture input and credentials out of test logs."""

    def do_POST(self):
        """Serve discovery, echo, SSE, cancellation and actual error responses."""
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
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
        if request["method"] == "server/discover":
            result = {"capabilities": {"tools": {}}, "resultType": "complete"}
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
        response = {"jsonrpc": "2.0", "id": request["id"], "result": result}
        if self.path == "/wrong-id":
            response["id"] = "not-the-request-id"
        if self.path in {"/sse", "/slow"}:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            try:
                self.wfile.write(b": fixture keep-alive\r\n\r\n")
                self.wfile.flush()
                if self.path == "/slow":
                    for _ in range(50):
                        self.wfile.write(b": waiting\n\n")
                        self.wfile.flush()
                        time.sleep(0.1)
                self.wfile.write(("data: " + json.dumps(response) + "\r\n\r\n").encode())
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass  # Expected native request cancellation, not a fabricated result.
        else:
            self.respond(200, response)

    def respond(self, status, value):
        """Write a complete JSON response, closing each synthetic request."""
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    print(server.server_address[1], flush=True)
    server.serve_forever()
