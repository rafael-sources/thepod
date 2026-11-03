"""
thePod · una sola app.

El host manda thepod.castmedia.space a este proceso. Además de la landing, los docs y la cuenta,
aquí se reparten las otras apps bajo un camino, para que todo viva en un solo dominio (y la PWA
los abarque):

    /pre/…   → prePod   (5001)
    /prod/…  → prodPod  (5002)
    /ama/…   → amaPod   (5004)
    /post/…  → postPod  (5000)

Cada petición se reenvía tal cual (método, cabeceras, cuerpo en streaming) con X-Forwarded-Prefix,
y cada app, con ProxyFix(x_prefix=1), arma sus URLs con ese prefijo. La respuesta vuelve también en
streaming, sin guardarla entera en memoria. Los subdominios siguen vivos: esto no los reemplaza.

Los puertos se leen de la configuración compartida (gateway_ports) y, si no están, son los de siempre.
"""
from __future__ import annotations

import http.client
import os
from urllib.parse import quote

from flask import Flask, Response, request, stream_with_context

DEFAULT_PORTS = {"pre": 5001, "prod": 5002, "ama": 5004, "post": 5000}

# Cabeceras que no se reenvían entre saltos
_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers",
        "transfer-encoding", "upgrade", "content-length", "host"}


def _ports(cfg: dict) -> dict:
    out = dict(DEFAULT_PORTS)
    for k, v in (cfg.get("gateway_ports") or {}).items():
        try:
            out[k] = int(v)
        except (TypeError, ValueError):
            pass
    # Para probar en local: THEPOD_GATEWAY_PORTS="pre=5091,ama=5094"
    for part in (os.environ.get("THEPOD_GATEWAY_PORTS") or "").split(","):
        if "=" in part:
            k, v = part.split("=", 1)
            try:
                out[k.strip()] = int(v)
            except ValueError:
                pass
    return out


def _forward(port: int, prefix: str, tail: str):
    """Reenvía la petición actual a 127.0.0.1:<port>/<tail> y devuelve la respuesta en streaming."""
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

    # Sin cuerpo (304, 204, HEAD): cerrar ya
    if upstream.status in (204, 304) or request.method == "HEAD":
        conn.close()
        return Response(b"", status=upstream.status, headers=resp_headers)
    return Response(stream_with_context(body_iter()), status=upstream.status, headers=resp_headers, direct_passthrough=True)


def install(app: Flask, cfg: dict) -> None:
    ports = _ports(cfg)
    methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"]

    for key, port in ports.items():
        prefix = "/" + key

        # /pre → /pre/ (el service worker y las rutas relativas quedan bien)
        def _root(key=key):
            qs = ("?" + request.query_string.decode("latin-1")) if request.query_string else ""
            return Response(status=301, headers={"Location": f"/{key}/{qs}"})

        def _any(tail="", port=port, prefix=prefix):
            return _forward(port, prefix, tail)

        app.add_url_rule(prefix, f"gw_{key}_root", _root, methods=["GET", "HEAD"], strict_slashes=False)
        app.add_url_rule(prefix + "/", f"gw_{key}_index", _any, methods=methods, defaults={"tail": ""})
        app.add_url_rule(prefix + "/<path:tail>", f"gw_{key}", _any, methods=methods)
