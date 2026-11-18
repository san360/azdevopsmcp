"""End-to-end probe for an MCP server behind Azure API Management.

Runs the same checks against every configured target (typically the hosted
Azure DevOps MCP origin and one or more APIM gateway URLs) and prints PASS/FAIL
plus the identifiers needed to find each request in Application Insights /
Log Analytics.

Checks per target:
  discovery  unauthenticated initialize -> 401 + WWW-Authenticate resource_metadata,
             then fetch the advertised protected-resource metadata (PRM).
  client     emulate an MCP client the way VS Code does it: accept PRM only if its
             "resource" equals the server URL (RFC 9728 s3.3, falling back like VS
             Code), load authorization-server metadata, use dynamic client
             registration when offered, then send the authorization request with
             resource + scope (RFC 8707) and report any AADSTS error. Gateway
             redirects to Entra are followed one hop; no sign-in happens.
  mcp        with a bearer token: initialize, notifications/initialized,
             tools/list and one read-only tools/call.
  validation targets with "toolValidation": "enforced" must reject the invalid
             "validationCases" at the gateway (x-mcp-gateway-validation: rejected,
             JSON-RPC -32602, or isError for MCP 2025-11-25) and pass the valid ones;
             "none" targets only record what the server did with the same input.

Targets may list "expectFailures" (step prefixes). Those are reported as XFAIL
and the exit code is non-zero only for unexpected results.

Standard library only. Tokens are held in memory and never printed or written.
"""

from __future__ import annotations

import argparse
import base64
import dataclasses
import hashlib
import http.server
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid
import webbrowser
from typing import Any

PROTOCOL_VERSION = "2025-06-18"
MAX_BODY = 256 * 1024
DEFAULT_SCOPE = "https://mcp.dev.azure.com/.default"
VSCODE_REDIRECT = "http://127.0.0.1:33418/"
AZURE_CLI_CLIENT_ID = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"
CLIENT_INFO = {"name": "apim-mcp-probe", "version": "1.0"}
AADSTS = re.compile(r"AADSTS\d+")
ADO_ERROR = re.compile(r"\b(?:VS|TF)\d{5,6}\b")


# --------------------------------------------------------------------- helpers


@dataclasses.dataclass
class Response:
    status: int
    headers: dict[str, str]
    body: str

    def header(self, name: str) -> str | None:
        for key, value in self.headers.items():
            if key.lower() == name.lower():
                return value
        return None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args: Any, **kwargs: Any) -> None:
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def http_request(
    url: str,
    *,
    method: str = "GET",
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
    timeout: float = 60,
) -> Response:
    request = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with _OPENER.open(request, timeout=timeout) as resp:
            return Response(resp.status, dict(resp.headers.items()), resp.read(MAX_BODY).decode("utf-8", "replace"))
    except urllib.error.HTTPError as err:
        return Response(err.code, dict(err.headers.items()), err.read(MAX_BODY).decode("utf-8", "replace"))


def parse_resource_metadata(www_authenticate: str | None) -> str | None:
    if not www_authenticate:
        return None
    match = re.search(r'resource_metadata="?([^",\s]+)"?', www_authenticate)
    return match.group(1) if match else None


def parse_jsonrpc(body: str, content_type: str | None, request_id: Any) -> dict[str, Any] | None:
    """Return the JSON-RPC message matching request_id from a JSON or SSE body."""
    if content_type and "text/event-stream" in content_type.lower():
        data_lines: list[str] = []
        messages: list[str] = []
        for line in body.splitlines() + [""]:
            if line.startswith("data:"):
                data_lines.append(line[5:].lstrip())
            elif line == "" and data_lines:
                messages.append("\n".join(data_lines))
                data_lines = []
        candidates = messages
    else:
        candidates = [body]
    for raw in candidates:
        try:
            message = json.loads(raw)
        except (ValueError, TypeError):
            continue
        if isinstance(message, dict) and message.get("id") == request_id:
            return message
    return None


def normalize_url(url: str) -> str:
    parts = urllib.parse.urlsplit(url)
    path = parts.path.rstrip("/")
    return urllib.parse.urlunsplit((parts.scheme.lower(), parts.netloc.lower(), path, "", ""))


def authorization_metadata_urls(issuer: str) -> list[str]:
    """Candidate metadata URLs for an issuer (RFC 8414 path insertion and OIDC)."""
    parts = urllib.parse.urlsplit(issuer)
    base = f"{parts.scheme}://{parts.netloc}"
    path = parts.path.rstrip("/")
    if not path:
        return [f"{base}/.well-known/oauth-authorization-server", f"{base}/.well-known/openid-configuration"]
    return [
        f"{base}/.well-known/oauth-authorization-server{path}",
        f"{base}/.well-known/openid-configuration{path}",
        f"{base}{path}/.well-known/openid-configuration",
    ]


def pkce_pair() -> tuple[str, str]:
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    return verifier, challenge


def build_authorize_url(
    endpoint: str,
    *,
    client_id: str,
    redirect_uri: str,
    scopes: list[str],
    resource: str | None,
    code_challenge: str,
    state: str,
) -> str:
    params = {
        "client_id": client_id,
        "response_type": "code",
        "redirect_uri": redirect_uri,
        "scope": " ".join(scopes),
        "code_challenge": code_challenge,
        "code_challenge_method": "S256",
        "state": state,
    }
    if resource:
        params["resource"] = resource
    return endpoint + ("&" if "?" in endpoint else "?") + urllib.parse.urlencode(params)


def classify_authorize_response(resp: Response) -> tuple[str, str]:
    """Return (outcome, detail) for an authorization request sent without following redirects."""
    location = resp.header("Location") or ""
    text = urllib.parse.unquote_plus(location) + " " + resp.body
    codes = sorted(set(AADSTS.findall(text)))
    if codes:
        error = urllib.parse.parse_qs(urllib.parse.urlsplit(location).query).get("error", [""])[0]
        return "rejected", f"{error or 'error'} {','.join(codes)}".strip()
    if resp.status == 200:
        return "accepted", "sign-in page served"
    if resp.status in (301, 302, 303, 307, 308):
        return "redirect", urllib.parse.urlsplit(location).netloc or "relative"
    return "unknown", f"HTTP {resp.status}"


def traceparent(trace_id: str) -> str:
    return f"00-{trace_id}-{secrets.token_hex(8)}-01"


def _json(text: str) -> Any:
    try:
        return json.loads(text)
    except (ValueError, TypeError):
        return None


def prm_matches(prm: Any, expected: str) -> bool:
    return isinstance(prm, dict) and normalize_url(str(prm.get("resource", ""))) == normalize_url(expected)


def discover_prm_like_vscode(url: str, advertised: dict[str, Any] | None) -> tuple[dict[str, Any] | None, str]:
    """Mirror VS Code's fetchResourceMetadata: header URL, path-appended, then root.

    Each candidate is accepted only if its "resource" equals the expected URL
    (RFC 9728 s3.3). Returns (prm, description).
    """
    if advertised is not None and prm_matches(advertised, url):
        return advertised, "advertised PRM"
    reasons = []
    if advertised is not None:
        reasons.append(f"advertised resource {advertised.get('resource')} != {url}")
    parts = urllib.parse.urlsplit(url)
    origin = f"{parts.scheme}://{parts.netloc}"
    root = f"{origin}/.well-known/oauth-protected-resource"
    candidates = []
    if parts.path not in ("", "/"):
        candidates.append((root + parts.path.rstrip("/"), url))
    candidates.append((root, origin))
    for candidate, expected in candidates:
        resp = http_request(candidate, headers={"Accept": "application/json"})
        prm = _json(resp.body) if resp.status == 200 else None
        if prm_matches(prm, expected):
            return prm, f"well-known {candidate}"
        reasons.append(f"{candidate} -> HTTP {resp.status}")
    return None, "; ".join(reasons)


def fetch_authorization_metadata(issuer: str) -> dict[str, Any] | None:
    for candidate in authorization_metadata_urls(issuer):
        resp = http_request(candidate, headers={"Accept": "application/json"})
        meta = _json(resp.body) if resp.status == 200 else None
        if isinstance(meta, dict) and meta.get("authorization_endpoint"):
            return meta
    return None


OAUTH_ENDPOINT_KEYS = ("issuer", "authorization_endpoint", "token_endpoint", "registration_endpoint")
ENTRA_HOSTS = ("login.microsoftonline.com",)


def foreign_host_urls(mcp_url: str, urls: list[Any]) -> list[str]:
    """URLs on neither the MCP URL's host nor Microsoft Entra.

    Behind a reverse proxy (Application Gateway) every URL the gateway advertises must use the
    host the client connected to; a backend host (for example *.azure-api.net) there means the
    proxy did not preserve the Host header and clients reject the metadata or cannot reach it.
    """
    host = urllib.parse.urlsplit(mcp_url).netloc.lower()
    return [u for u in urls if isinstance(u, str) and urllib.parse.urlsplit(u).netloc.lower() not in (host, *ENTRA_HOSTS)]


def oauth_isolation(mcp_url: str, meta: dict[str, Any]) -> tuple[bool | None, str]:
    """Whether gateway-hosted OAuth endpoints stay under the MCP URL's first path segment.

    Returns (None, reason) when the check does not apply: the MCP URL has no path, or the
    authorization server is on another host (for example Microsoft Entra).
    """
    parts = urllib.parse.urlsplit(mcp_url)
    segment = parts.path.strip("/").split("/")[0]
    if not segment:
        return None, "MCP URL has no path"
    prefix = f"/{segment}"
    same_host = {key: meta[key] for key in OAUTH_ENDPOINT_KEYS
                 if isinstance(meta.get(key), str) and urllib.parse.urlsplit(meta[key]).netloc.lower() == parts.netloc.lower()}
    if not same_host:
        return None, "authorization server on another host"
    outside = [f"{key}={value}" for key, value in same_host.items()
               if not (urllib.parse.urlsplit(value).path.rstrip("/") + "/").startswith(prefix + "/")]
    if outside:
        return False, "outside " + prefix + ": " + ", ".join(outside)
    return True, f"{len(same_host)} endpoints under {prefix}/"


# --------------------------------------------------------------------- results


@dataclasses.dataclass
class Check:
    target: str
    step: str
    ok: bool | None  # None = informational / skipped
    detail: str
    request_id: str | None = None
    expected_failure: bool = False

    @property
    def label(self) -> str:
        if self.expected_failure:
            return "XFAIL" if self.ok is False else "XPASS"
        return {True: "PASS", False: "FAIL", None: "INFO"}[self.ok]

    @property
    def unexpected(self) -> bool:
        """A regression: a failure not listed in expectFailures, or an expected failure that now passes."""
        return (self.ok is False) != self.expected_failure and self.ok is not None


class Probe:
    def __init__(self, run_id: str, trace_id: str, token: str | None, tool: dict[str, Any], client_id: str,
                 tenant: str | None = None):
        self.run_id = run_id
        self.trace_id = trace_id
        self.token = token
        self.tool = tool
        self.client_id = client_id
        self.tenant = tenant
        self.checks: list[Check] = []

    def _add(self, *args: Any, **kwargs: Any) -> Check:
        check = Check(*args, **kwargs)
        self.checks.append(check)
        return check

    def _headers(self, extra: dict[str, str] | None = None) -> dict[str, str]:
        headers = {
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
            "MCP-Protocol-Version": PROTOCOL_VERSION,
            "traceparent": traceparent(self.trace_id),
            "x-mcp-test-run": self.run_id,
        }
        headers.update(extra or {})
        return headers

    def _post(self, url: str, payload: Any, extra: dict[str, str] | None = None) -> Response:
        return http_request(url, method="POST", body=json.dumps(payload).encode(), headers=self._headers(extra))

    # ---------------------------------------------------------------- discovery

    def discovery(self, name: str, url: str) -> dict[str, Any] | None:
        """Unauthenticated initialize and the advertised PRM document. Returns the PRM or None."""
        init = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {"protocolVersion": PROTOCOL_VERSION, "capabilities": {}, "clientInfo": CLIENT_INFO}}
        resp = self._post(url, init)
        rid = resp.header("x-apim-request-id")
        metadata_url = parse_resource_metadata(resp.header("WWW-Authenticate"))
        if resp.status != 401 or not metadata_url:
            self._add(name, "discovery: 401 challenge", False,
                      f"HTTP {resp.status}, resource_metadata={'present' if metadata_url else 'missing'}", rid)
            return None
        self._add(name, "discovery: 401 challenge", True, f"resource_metadata={metadata_url}", rid)

        # Some clients (OpenAI Codex) probe the MCP URL with a body-less GET before discovery.
        # The spec allows 401 or 405; a 5xx aborts their sign-in.
        get = http_request(url, headers={"Accept": "text/event-stream", "x-mcp-test-run": self.run_id})
        self._add(name, "discovery: GET without token is not 5xx", get.status < 500,
                  f"HTTP {get.status}", get.header("x-apim-request-id"))

        prm_resp = http_request(metadata_url, headers={"Accept": "application/json"})
        prm = _json(prm_resp.body) if prm_resp.status == 200 else None
        if not isinstance(prm, dict):
            self._add(name, "discovery: advertised PRM", False,
                      f"GET {metadata_url} -> HTTP {prm_resp.status}", prm_resp.header("x-apim-request-id"))
            return None
        self._add(name, "discovery: advertised PRM", True,
                  f"resource={prm.get('resource')} scopes={prm.get('scopes_supported')} "
                  f"as={prm.get('authorization_servers')}")
        foreign = foreign_host_urls(url, [metadata_url, prm.get("resource"), *(prm.get("authorization_servers") or [])])
        self._add(name, "discovery: URLs on the client's host", not foreign,
                  "other host: " + ", ".join(foreign) if foreign else f"all on {urllib.parse.urlsplit(url).netloc}")
        return prm

    def client_auth(self, name: str, url: str, advertised_prm: dict[str, Any] | None) -> None:
        """Emulate an MCP client (VS Code algorithm) up to the Entra authorization request."""
        prm, how = discover_prm_like_vscode(url, advertised_prm)
        if prm:
            self._add(name, "client: PRM accepted (resource == server URL)", True, how)
            issuer = (prm.get("authorization_servers") or [None])[0]
            resource = prm.get("resource")
        else:
            # VS Code falls back to the 2025-03-26 behaviour: the server origin is the authorization server.
            self._add(name, "client: PRM accepted (resource == server URL)", False,
                      f"{how}; falling back to server origin as authorization server")
            parts = urllib.parse.urlsplit(url)
            issuer, resource = f"{parts.scheme}://{parts.netloc}", None
        meta = fetch_authorization_metadata(issuer) if issuer else None
        if not meta or not meta.get("authorization_endpoint"):
            self._add(name, "client: authorization server metadata", False, f"none found for {issuer}")
            return
        scopes = (prm or {}).get("scopes_supported") or meta.get("scopes_supported") or []
        client_id, how_client = self.client_id, "configured client ID"
        if meta.get("registration_endpoint"):
            reg = http_request(meta["registration_endpoint"], method="POST", headers={"Content-Type": "application/json"},
                               body=json.dumps({"client_name": CLIENT_INFO["name"], "redirect_uris": [VSCODE_REDIRECT],
                                                "grant_types": ["authorization_code", "refresh_token"],
                                                "response_types": ["code"], "token_endpoint_auth_method": "none"}).encode())
            registered = _json(reg.body) if reg.status in (200, 201) else None
            if isinstance(registered, dict) and registered.get("client_id"):
                client_id, how_client = registered["client_id"], "dynamic client registration"
        self._add(name, "client: authorization server metadata", True,
                  f"issuer={meta.get('issuer')} client_id via {how_client}")
        foreign = foreign_host_urls(url, [meta.get(key) for key in OAUTH_ENDPOINT_KEYS])
        if foreign:
            self._add(name, "client: OAuth endpoints on the client's host", False, "other host: " + ", ".join(foreign))
        isolated, why = oauth_isolation(url, meta)
        if isolated is not None:
            # Gateway-hosted OAuth must not claim routes outside this setup's dedicated path.
            self._add(name, "client: OAuth endpoints under the MCP path (isolation)", isolated, why)

        _, challenge = pkce_pair()
        authorize = build_authorize_url(meta["authorization_endpoint"], client_id=client_id,
                                        redirect_uri=VSCODE_REDIRECT, scopes=scopes, resource=resource,
                                        code_challenge=challenge, state=secrets.token_urlsafe(8))
        resp = http_request(authorize)
        hop = ""
        location = resp.header("Location") or ""
        if resp.status in (301, 302, 303, 307, 308) and "login.microsoftonline.com" in location and not AADSTS.search(
                urllib.parse.unquote_plus(location)):
            hop = " (via gateway redirect)"
            authorize = location
            resp = http_request(location)
        tenant_note = ""
        if self.tenant and re.search(r"login\.microsoftonline\.com/(organizations|common)/", authorize):
            # Entra checks resource/scope only after it knows the home tenant; evaluate with it directly.
            authorize = re.sub(r"(login\.microsoftonline\.com/)(organizations|common)/", rf"\g<1>{self.tenant}/", authorize)
            resp = http_request(authorize)
            tenant_note = f" [evaluated with tenant authority]"
        sent = urllib.parse.parse_qs(urllib.parse.urlsplit(authorize).query)
        outcome, detail = classify_authorize_response(resp)
        self._add(name, "client: Entra authorize request", outcome == "accepted",
                  f"{detail}{hop}{tenant_note}; resource={sent.get('resource', ['(none)'])[0]} "
                  f"scope={sent.get('scope', [''])[0]}")

    # ---------------------------------------------------------------- MCP calls

    def mcp(self, name: str, url: str, extra_headers: dict[str, str] | None = None,
            tool_arguments: dict[str, Any] | None = None) -> None:
        if not self.token:
            self._add(name, "mcp: authenticated calls", None, "skipped (no token)")
            return
        auth = {"Authorization": f"Bearer {self.token}", **(extra_headers or {})}
        init = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {"protocolVersion": PROTOCOL_VERSION, "capabilities": {}, "clientInfo": CLIENT_INFO}}
        resp = self._post(url, init, auth)
        rid = resp.header("x-apim-request-id")
        message = parse_jsonrpc(resp.body, resp.header("Content-Type"), 1) if resp.status == 200 else None
        if not message or "result" not in message:
            self._add(name, "mcp: initialize", False, f"HTTP {resp.status} {summarize_error(resp, message)}", rid)
            return
        result = message["result"]
        server = result.get("serverInfo", {})
        self._add(name, "mcp: initialize", True,
                  f"{server.get('name')} {server.get('version', '')} protocol={result.get('protocolVersion')}", rid)
        session = resp.header("Mcp-Session-Id")
        if session:
            auth["Mcp-Session-Id"] = session
        auth["MCP-Protocol-Version"] = result.get("protocolVersion", PROTOCOL_VERSION)

        note = self._post(url, {"jsonrpc": "2.0", "method": "notifications/initialized"}, auth)
        self._add(name, "mcp: notifications/initialized", note.status in (200, 202),
                  f"HTTP {note.status}", note.header("x-apim-request-id"))

        resp = self._post(url, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, auth)
        message = parse_jsonrpc(resp.body, resp.header("Content-Type"), 2) if resp.status == 200 else None
        tools = (message or {}).get("result", {}).get("tools") if message else None
        if tools is None:
            self._add(name, "mcp: tools/list", False, f"HTTP {resp.status} {summarize_error(resp, message)}",
                      resp.header("x-apim-request-id"))
            return
        names = [t.get("name") for t in tools]
        self._add(name, "mcp: tools/list", bool(tools),
                  f"{len(tools)} tools; {self.tool['name']} {'present' if self.tool['name'] in names else 'MISSING'}",
                  resp.header("x-apim-request-id"))

        call = {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                "params": {"name": self.tool["name"], "arguments": {**self.tool.get("arguments", {}),
                                                                    **(tool_arguments or {})}}}
        resp = self._post(url, call, auth)
        message = parse_jsonrpc(resp.body, resp.header("Content-Type"), 3) if resp.status == 200 else None
        result = (message or {}).get("result")
        if not result:
            self._add(name, f"mcp: tools/call {self.tool['name']}", False,
                      f"HTTP {resp.status} {summarize_error(resp, message)}", resp.header("x-apim-request-id"))
            return
        text = " ".join(c.get("text", "") for c in result.get("content", []) if isinstance(c, dict))
        failed = bool(result.get("isError")) or bool(ADO_ERROR.search(text))
        detail = shorten(text)
        self._add(name, f"mcp: tools/call {self.tool['name']}", not failed,
                  f"isError={bool(result.get('isError'))} {detail}", resp.header("x-apim-request-id"))

    # ---------------------------------------------------------------- tool-argument validation

    def tool_validation(self, name: str, url: str, cases: list[dict[str, Any]], enforced: bool,
                        extra_headers: dict[str, str] | None = None) -> None:
        """Send vetted tools/call cases; on enforcing targets invalid ones must be rejected by the gateway."""
        if not self.token:
            self._add(name, "validation: cases", None, "skipped (no token)")
            return
        auth = {"Authorization": f"Bearer {self.token}", **(extra_headers or {})}
        init = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {"protocolVersion": PROTOCOL_VERSION, "capabilities": {}, "clientInfo": CLIENT_INFO}}
        resp = self._post(url, init, auth)
        if resp.status != 200:
            self._add(name, "validation: initialize", False, f"HTTP {resp.status}", resp.header("x-apim-request-id"))
            return
        if resp.header("Mcp-Session-Id"):
            auth["Mcp-Session-Id"] = resp.header("Mcp-Session-Id")
        self._post(url, {"jsonrpc": "2.0", "method": "notifications/initialized"}, auth)

        for number, case in enumerate(cases, start=100):
            headers = dict(auth)
            headers["MCP-Protocol-Version"] = case.get("protocolVersion", PROTOCOL_VERSION)
            call = {"jsonrpc": "2.0", "id": number, "method": "tools/call",
                    "params": {"name": case["tool"], "arguments": case.get("arguments", {})}}
            batch = bool(case.get("batch"))
            resp = self._post(url, [call] if batch else call, headers)
            outcome = classify_tool_response(resp, None if batch else number)
            step = f"validation: {case['name']}"
            rid = resp.header("x-apim-request-id")
            summary = describe_tool_outcome(outcome)
            if case.get("expect") == "pass":
                ok = outcome["kind"] == "result" and not outcome["gateway_rejected"]
                self._add(name, step, ok, summary, rid)
            elif enforced:
                expected_field = case.get("field")
                ok = (outcome["gateway_rejected"]
                      and outcome["kind"] in ("protocol-error", "tool-error")
                      and (outcome["kind"] == "tool-error" or outcome["code"] == -32602)
                      and (not expected_field or expected_field in outcome["fields"]
                           or expected_field in outcome["text"]))
                self._add(name, step, ok, summary, rid)
            else:
                # Targets without gateway validation: record what the server did with the invalid input.
                self._add(name, step, None, f"not validated at the gateway; server answered {summary}", rid)


def classify_tool_response(resp: Response, request_id: Any) -> dict[str, Any]:
    """Classify a tools/call response: gateway rejection, protocol error, tool error or result."""
    message = parse_jsonrpc(resp.body, resp.header("Content-Type"), request_id) if resp.status == 200 else None
    outcome: dict[str, Any] = {
        "status": resp.status,
        "gateway_rejected": (resp.header("x-mcp-gateway-validation") or "") in ("rejected", "denied"),
        "kind": "none", "code": None, "fields": [], "rules": [], "text": "",
    }
    if not message:
        return outcome
    if "error" in message:
        error = message["error"] or {}
        violations = ((error.get("data") or {}).get("violations")) or []
        outcome.update(kind="protocol-error", code=error.get("code"), text=str(error.get("message", "")),
                       fields=[v.get("field") for v in violations if isinstance(v, dict)],
                       rules=[v.get("rule") for v in violations if isinstance(v, dict)])
    elif "result" in message:
        result = message["result"] or {}
        text = " ".join(c.get("text", "") for c in result.get("content", []) if isinstance(c, dict))
        outcome.update(kind="tool-error" if result.get("isError") else "result", text=text)
    return outcome


def describe_tool_outcome(outcome: dict[str, Any]) -> str:
    who = "gateway" if outcome["gateway_rejected"] else "server"
    if outcome["kind"] == "protocol-error":
        pairs = ", ".join(f"{f}:{r}" for f, r in zip(outcome["fields"], outcome["rules"]))
        return f"{who} JSON-RPC error {outcome['code']} [{pairs}]"
    if outcome["kind"] == "tool-error":
        return f"{who} tool error isError=true: {shorten(outcome['text'], 110)}"
    if outcome["kind"] == "result":
        return f"{who} result: {shorten(outcome['text'], 60)}"
    return f"HTTP {outcome['status']} (no JSON-RPC response)"


def shorten(text: str, limit: int = 160) -> str:
    text = " ".join(text.split())
    codes = ADO_ERROR.findall(text)
    prefix = f"[{','.join(sorted(set(codes)))}] " if codes else ""
    return prefix + (text if len(text) <= limit else text[:limit] + "...")


def summarize_error(resp: Response, message: dict[str, Any] | None) -> str:
    if message and "error" in message:
        err = message["error"]
        return f"jsonrpc error {err.get('code')}: {shorten(str(err.get('message', '')))}"
    return shorten(resp.body) if resp.body else ""


# --------------------------------------------------------------------- tokens


def token_from_azure_cli(scope: str, tenant: str | None) -> str:
    az = shutil.which("az") or shutil.which("az.cmd")
    if not az:
        raise SystemExit("Azure CLI not found")
    cmd = [az, "account", "get-access-token", "--scope", scope, "--query", "accessToken", "-o", "tsv"]
    if tenant:
        cmd += ["--tenant", tenant]
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip()


def token_from_browser(tenant: str, client_id: str, scope: str, timeout: float = 300) -> str:
    """OAuth 2.0 authorization code + PKCE with a loopback redirect (public client)."""
    verifier, challenge = pkce_pair()
    state = secrets.token_urlsafe(16)
    captured: dict[str, str] = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            captured.update({k: v[0] for k, v in query.items()})
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"Sign-in complete. You can close this tab.")

        def log_message(self, *args: Any) -> None:
            return

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    redirect_uri = f"http://localhost:{server.server_port}"
    authority = f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0"
    url = build_authorize_url(f"{authority}/authorize", client_id=client_id, redirect_uri=redirect_uri,
                              scopes=[scope], resource=None, code_challenge=challenge, state=state)
    thread = threading.Thread(target=server.handle_request, daemon=True)
    server.timeout = timeout
    thread.start()
    print("Opening the browser for Microsoft Entra sign-in...", file=sys.stderr)
    if not webbrowser.open(url):
        print(f"Open this URL to sign in:\n{url}", file=sys.stderr)
    thread.join(timeout)
    server.server_close()
    if captured.get("state") != state or "code" not in captured:
        raise SystemExit(f"sign-in failed: {captured.get('error')} {captured.get('error_description', '')}")
    form = urllib.parse.urlencode({
        "client_id": client_id, "grant_type": "authorization_code", "code": captured["code"],
        "redirect_uri": redirect_uri, "code_verifier": verifier, "scope": scope,
    }).encode()
    resp = http_request(f"{authority}/token", method="POST", body=form,
                        headers={"Content-Type": "application/x-www-form-urlencoded"})
    payload = json.loads(resp.body or "{}")
    if "access_token" not in payload:
        raise SystemExit(f"token exchange failed: {payload.get('error')} {shorten(payload.get('error_description', ''))}")
    return payload["access_token"]


def token_claims(token: str) -> dict[str, Any]:
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except (IndexError, ValueError):
        return {}


# --------------------------------------------------------------------- CLI


def tool_for_target(tool: dict[str, Any], target: dict[str, Any]) -> dict[str, Any]:
    """The tool a target calls: the config tool, renamed when the target sets toolName.

    Gateways that federate MCP servers (for example Azure AI Gateway) publish tools with a
    namespace prefix, such as ado_core_list_projects."""
    return {**tool, "name": target["toolName"]} if target.get("toolName") else tool


def load_config(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as handle:
        config = json.load(handle)
    if not config.get("targets"):
        raise SystemExit("config needs a non-empty 'targets' list")
    return config


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", required=True, help="JSON config (see probe.example.json)")
    parser.add_argument("--token", choices=["none", "env", "az", "browser"], default="none",
                        help="env: MCP_ACCESS_TOKEN; az: Azure CLI; browser: auth code + PKCE with config clientId")
    parser.add_argument("--only", action="append", help="run only the named target(s)")
    parser.add_argument("--skip-auth", action="store_true", help="skip the client OAuth emulation checks")
    parser.add_argument("--skip-validation", action="store_true", help="skip the tool-argument validation cases")
    parser.add_argument("--json-out", help="write results (no secrets) to this file")
    args = parser.parse_args(argv)

    config = load_config(args.config)
    scope = config.get("scope", DEFAULT_SCOPE)
    tenant = config.get("tenantId")
    client_id = config.get("clientId") or AZURE_CLI_CLIENT_ID

    token = None
    if args.token == "env":
        token = os.environ.get("MCP_ACCESS_TOKEN") or None
        if not token:
            raise SystemExit("MCP_ACCESS_TOKEN is not set")
    elif args.token == "az":
        token = token_from_azure_cli(scope, tenant)
    elif args.token == "browser":
        if not (tenant and config.get("clientId")):
            raise SystemExit("--token browser needs tenantId and clientId in the config")
        token = token_from_browser(tenant, config["clientId"], scope)

    run_id = uuid.uuid4().hex[:12]
    trace_id = secrets.token_hex(16)
    probe = Probe(run_id, trace_id, token, config.get("tool", {"name": "core_list_projects", "arguments": {}}),
                  client_id, tenant)
    if token:
        claims = token_claims(token)
        print(f"token: aud={claims.get('aud')} azp={claims.get('azp') or claims.get('appid')} "
              f"scp={claims.get('scp')} tid={claims.get('tid')}")

    for target in config["targets"]:
        name, url = target["name"], target["url"]
        if args.only and name not in args.only:
            continue
        first = len(probe.checks)
        prm = probe.discovery(name, url)
        if not args.skip_auth:
            probe.client_auth(name, url, prm)
        default_tool, probe.tool = probe.tool, tool_for_target(probe.tool, target)
        probe.mcp(name, url, target.get("headers"), target.get("toolArguments"))
        probe.tool = default_tool
        mode = target.get("toolValidation")
        if mode in ("enforced", "none") and not args.skip_validation and config.get("validationCases"):
            probe.tool_validation(name, url, config["validationCases"], mode == "enforced", target.get("headers"))
        for check in probe.checks[first:]:
            check.expected_failure = any(check.step.startswith(p) for p in target.get("expectFailures", []))

    width = max(len(c.target) for c in probe.checks) if probe.checks else 10
    for check in probe.checks:
        rid = f"  [apim {check.request_id}]" if check.request_id else ""
        print(f"{check.label:<5}  {check.target:<{width}}  {check.step}: {check.detail}{rid}")
    regressions = [c for c in probe.checks if c.unexpected]
    print(f"\n{len(probe.checks)} checks, {sum(c.label == 'XFAIL' for c in probe.checks)} expected failures, "
          f"{len(regressions)} unexpected")
    print(f"run id (x-mcp-test-run): {run_id}\ntrace id (operation_Id / traceparent): {trace_id}")
    print("Find these requests: docs/kql/requests-by-run.kql (App Insights) or "
          "docs/kql/gateway-by-request-id.kql (Log Analytics).")

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as handle:
            json.dump({"runId": run_id, "traceId": trace_id,
                       "checks": [dataclasses.asdict(c) for c in probe.checks]}, handle, indent=2)
    return 1 if regressions else 0


if __name__ == "__main__":
    sys.exit(main())
