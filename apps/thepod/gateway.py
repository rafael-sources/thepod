"""
thePod · a single app.

The host routes thepod.castmedia.space to this process. Besides the landing page, the docs and the account,
the other apps are dispatched here under a path, so everything lives on a single domain (and the PWA
covers them all):

    /pre/…   → prePod   (5001)
    /prod/…  → prodPod  (5002)
    /ama/…   → amaPod   (5004)
    /post/…  → postPod  (5000)

Each request is forwarded as-is (method, headers, streamed body) with X-Forwarded-Prefix,
and each app, with ProxyFix(x_prefix=1), builds its URLs with that prefix. The response also comes back
streamed, without holding it all in memory. The subdomains are still live: this does not replace them.

Ports are read from the shared config (gateway_ports) and, if absent, are the usual ones.
"""
from __future__ import annotations

import http.client
import os
from urllib.parse import quote

from flask import Flask, Response, request, stream_with_context

DEFAULT_PORTS = {"pre": 5001, "prod": 5002, "ama": 5004, "post": 5000}

# Hop-by-hop headers that are not forwarded
_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers",
        "transfer-encoding", "upgrade", "content-length", "host"}


def _ports(cfg: dict) -> dict:
    out = dict(DEFAULT_PORTS)
    for k, v in (cfg.get("gateway_ports") or {}).items():
        try:
            out[k] = int(v)
        except (TypeError, ValueError):
            pass
    # For local testing: THEPOD_GATEWAY_PORTS="pre=5091,ama=5094"
    for part in (os.environ.get("THEPOD_GATEWAY_PORTS") or "").split(","):
        if "=" in part:
            k, v = part.split("=", 1)
            try:
                out[k.strip()] = int(v)
            except ValueError:
                pass
    return out


def _forward(port: int, prefix: str, tail: str):
    """Forwards the current request to 127.0.0.1:<port>/<tail> and returns the response streamed."""
    path = "/" + quote(tail, safe="/%:@&=+$,;~!*'()") if tail else "/"
    if request.query_string:
        path += "?" + request.query_string.decode("latin-1")

    headers = {k: v for k, v in request.headers.items() if k.lower() not in _HOP}
    headers["Host"] = request.host
    headers["X-Forwarded-Prefix"] = prefix
    headers["X-Forwarded-Host"] = request.host
    headers["X-Forwarded-Proto"] = request.headers.get("X-Forwarded-Proto") or request.scheme
    fwd = request.headers.get("X-Forwarded-For")
    headers["X-Forwarded-For"] = f"{fwd}, {request.remote_addr}" if fwd else (request.remote_addr or "")
    if request.content_length is not None:
        headers["Content-Length"] = str(request.content_length)

    body = request.stream if request.content_length else None
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=600)
    try:
        conn.request(request.method, path, body=body, headers=headers)
        upstream = conn.getresponse()
    except OSError:
        conn.close()
        return Response("La app no responde ahora mismo. Intenta en un momento.", status=502, mimetype="text/plain")

    resp_headers = [(k, v) for k, v in upstream.getheaders() if k.lower() not in _HOP or k.lower() == "content-length"]

    def body_iter():
        try:
            while True:
                chunk = upstream.read(64 * 1024)
                if not chunk:
                    break
                yield chunk
        finally:
            conn.close()

    # No body (304, 204, HEAD): close now
    if upstream.status in (204, 304) or request.method == "HEAD":
        conn.close()
        return Response(b"", status=upstream.status, headers=resp_headers)
    return Response(stream_with_context(body_iter()), status=upstream.status, headers=resp_headers, direct_passthrough=True)


def install(app: Flask, cfg: dict) -> None:
    ports = _ports(cfg)
    methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"]

    for key, port in ports.items():
        prefix = "/" + key

        # /pre → /pre/ (so the service worker and relative paths work)
        def _root(key=key):
            qs = ("?" + request.query_string.decode("latin-1")) if request.query_string else ""
            return Response(status=301, headers={"Location": f"/{key}/{qs}"})

        def _any(tail="", port=port, prefix=prefix):
            return _forward(port, prefix, tail)

        app.add_url_rule(prefix, f"gw_{key}_root", _root, methods=["GET", "HEAD"], strict_slashes=False)
        app.add_url_rule(prefix + "/", f"gw_{key}_index", _any, methods=methods, defaults={"tail": ""})
        app.add_url_rule(prefix + "/<path:tail>", f"gw_{key}", _any, methods=methods)
