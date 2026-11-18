"""Unit and loopback tests for tools/mcp_probe.py (standard library only)."""

from __future__ import annotations

import http.server
import json
import os
import sys
import threading
import unittest
import urllib.parse

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import mcp_probe as probe  # noqa: E402


class ToolValidationTests(unittest.TestCase):
    def test_gateway_protocol_error_is_classified(self):
        body = json.dumps({"jsonrpc": "2.0", "id": 101, "error": {
            "code": -32602, "message": "Invalid arguments for tool core_list_projects: top violates maximum.",
            "data": {"tool": "core_list_projects", "violations": [{"field": "top", "rule": "maximum"}]}}})
        resp = probe.Response(200, {"Content-Type": "application/json", "x-mcp-gateway-validation": "rejected"}, body)
        outcome = probe.classify_tool_response(resp, 101)
        self.assertTrue(outcome["gateway_rejected"])
        self.assertEqual((outcome["kind"], outcome["code"], outcome["fields"], outcome["rules"]),
                         ("protocol-error", -32602, ["top"], ["maximum"]))
        self.assertIn("gateway JSON-RPC error -32602 [top:maximum]", probe.describe_tool_outcome(outcome))

    def test_tool_error_from_server_is_not_a_gateway_rejection(self):
        body = ('event: message\ndata: {"result":{"content":[{"type":"text","text":"bad id"}],"isError":true},'
                '"id":102,"jsonrpc":"2.0"}\n\n')
        outcome = probe.classify_tool_response(probe.Response(200, {"Content-Type": "text/event-stream"}, body), 102)
        self.assertEqual((outcome["kind"], outcome["gateway_rejected"]), ("tool-error", False))

    def test_other_ids_and_http_errors_yield_no_outcome(self):
        body = '{"jsonrpc":"2.0","id":5,"result":{"content":[]}}'
        self.assertEqual(probe.classify_tool_response(probe.Response(200, {"Content-Type": "application/json"}, body),
                                                      6)["kind"], "none")
        self.assertEqual(probe.classify_tool_response(probe.Response(500, {}, "oops"), 6)["kind"], "none")


class ParsingTests(unittest.TestCase):
    def test_resource_metadata_from_challenge(self):
        header = 'Bearer error="invalid_token", resource_metadata="https://gw.example/.well-known/oauth-protected-resource/x"'
        self.assertEqual(probe.parse_resource_metadata(header), "https://gw.example/.well-known/oauth-protected-resource/x")
        self.assertIsNone(probe.parse_resource_metadata("Bearer realm=x"))
        self.assertIsNone(probe.parse_resource_metadata(None))

    def test_sse_body_skips_other_messages(self):
        body = ('event: message\ndata: {"jsonrpc":"2.0","method":"notifications/progress"}\n\n'
                'event: message\ndata: {"jsonrpc":"2.0","id":7,"result":{"ok":true}}\n\n')
        message = probe.parse_jsonrpc(body, "text/event-stream", 7)
        self.assertEqual(message["result"], {"ok": True})

    def test_json_body(self):
        self.assertIsNone(probe.parse_jsonrpc('{"jsonrpc":"2.0","id":1}', "application/json", 2))
        self.assertEqual(probe.parse_jsonrpc('{"jsonrpc":"2.0","id":2,"result":{}}', "application/json", 2)["id"], 2)

    def test_metadata_urls_use_path_insertion(self):
        self.assertEqual(
            probe.authorization_metadata_urls("https://login.microsoftonline.com/t/v2.0")[:2],
            ["https://login.microsoftonline.com/.well-known/oauth-authorization-server/t/v2.0",
             "https://login.microsoftonline.com/.well-known/openid-configuration/t/v2.0"])
        self.assertEqual(probe.authorization_metadata_urls("https://gw.example")[0],
                         "https://gw.example/.well-known/oauth-authorization-server")

    def test_prm_resource_comparison_normalizes(self):
        self.assertTrue(probe.prm_matches({"resource": "HTTPS://GW.example/api/"}, "https://gw.example/api"))
        self.assertFalse(probe.prm_matches({"resource": "https://mcp.dev.azure.com"}, "https://gw.example/api"))

    def test_classify_entra_rejection(self):
        location = ("http://localhost/?error=invalid_target&error_description=AADSTS9010010%3a+The+resource+"
                    "parameter+provided+in+the+request+doesn%27t+match")
        resp = probe.Response(302, {"Location": location}, "")
        self.assertEqual(probe.classify_authorize_response(resp), ("rejected", "invalid_target AADSTS9010010"))
        self.assertEqual(probe.classify_authorize_response(probe.Response(200, {}, "<html>"))[0], "accepted")

    def test_authorize_url_includes_resource_only_when_given(self):
        url = probe.build_authorize_url("https://as/authorize", client_id="c", redirect_uri="http://localhost",
                                        scopes=["s1", "s2"], resource=None, code_challenge="x", state="y")
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
        self.assertNotIn("resource", query)
        self.assertEqual(query["scope"], ["s1 s2"])
        self.assertEqual(query["code_challenge_method"], ["S256"])

    def test_tool_errors_are_flagged(self):
        self.assertTrue(probe.ADO_ERROR.search("VS30063: You are not authorized"))
        self.assertTrue(probe.shorten("VS30063: denied").startswith("[VS30063]"))

    def test_expected_failures_are_not_regressions(self):
        xfail = probe.Check("t", "client: Entra authorize request", False, "", expected_failure=True)
        xpass = probe.Check("t", "client: Entra authorize request", True, "", expected_failure=True)
        fail = probe.Check("t", "mcp: initialize", False, "")
        self.assertEqual((xfail.label, xfail.unexpected), ("XFAIL", False))
        self.assertEqual((xpass.label, xpass.unexpected), ("XPASS", True))
        self.assertEqual((fail.label, fail.unexpected), ("FAIL", True))


class FakeMcpServer(http.server.BaseHTTPRequestHandler):
    """Minimal Streamable HTTP MCP server protected by a bearer token."""

    token = "test-token"
    base = ""

    def log_message(self, *args):
        return

    def _send(self, status, body=b"", headers=None):
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        if self.path == "/.well-known/oauth-protected-resource/mcp":
            prm = {"resource": f"{self.base}/mcp", "authorization_servers": [self.base],
                   "scopes_supported": ["api://x/.default"]}
            return self._send(200, json.dumps(prm).encode(), {"Content-Type": "application/json"})
        self._send(404)

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        message = json.loads(self.rfile.read(length) or b"{}")
        if self.headers.get("Authorization") != f"Bearer {self.token}":
            challenge = f'Bearer resource_metadata="{self.base}/.well-known/oauth-protected-resource/mcp"'
            return self._send(401, headers={"WWW-Authenticate": challenge})
        if "id" not in message:
            return self._send(202)
        results = {
            "initialize": {"protocolVersion": "2025-06-18", "serverInfo": {"name": "fake", "version": "1"},
                           "capabilities": {"tools": {}}},
            "tools/list": {"tools": [{"name": "core_list_projects", "inputSchema": {"type": "object"}}]},
            "tools/call": {"content": [{"type": "text", "text": "[{\"name\":\"demo\"}]"}], "isError": False},
        }
        payload = json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": results[message["method"]]})
        if message["method"] == "initialize":
            body = f"event: message\ndata: {payload}\n\n".encode()
            return self._send(200, body, {"Content-Type": "text/event-stream", "Mcp-Session-Id": "s1"})
        self._send(200, payload.encode(), {"Content-Type": "application/json"})


class LoopbackTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.HTTPServer(("127.0.0.1", 0), FakeMcpServer)
        FakeMcpServer.base = f"http://127.0.0.1:{cls.server.server_port}"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_discovery_and_authenticated_flow(self):
        url = f"{FakeMcpServer.base}/mcp"
        run = probe.Probe("run", "0" * 32, "test-token", {"name": "core_list_projects"}, "client")
        prm = run.discovery("fake", url)
        self.assertEqual(prm["resource"], url)
        run.mcp("fake", url)
        results = {c.step: c.ok for c in run.checks}
        self.assertTrue(all(results.values()), run.checks)
        self.assertIn("mcp: tools/call core_list_projects", results)

    def test_wrong_token_fails_initialize(self):
        url = f"{FakeMcpServer.base}/mcp"
        run = probe.Probe("run", "0" * 32, "wrong", {"name": "core_list_projects"}, "client")
        run.mcp("fake", url)
        self.assertEqual([(c.step, c.ok) for c in run.checks], [("mcp: initialize", False)])


if __name__ == "__main__":
    unittest.main()
