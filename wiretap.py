#!/usr/bin/env python3
"""Wiretap proxy: logs every request Roo sends to the gateway, then forwards it.
Listens on 4001 -> forwards to 4000. Log: /tmp/roo_wiretap.log"""
import http.server
import urllib.request
import urllib.error
import time
import json

TARGET = "http://127.0.0.1:4000"
LOG = "/tmp/roo_wiretap.log"

def log(msg):
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    with open(LOG, "a") as f:
        f.write(line + "\n")
        f.flush()


class Tap(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _proxy(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else b""
        safe_headers = {
            k: v for k, v in self.headers.items()
            if k.lower() in ("content-type", "accept")
        }
        log(f">>> {self.command} {self.path} | body {length}B | headers: {safe_headers}")
        if body:
            try:
                j = json.loads(body)
                tools = j.get("tools")
                log(f"    model={j.get('model')} stream={j.get('stream')} max_tokens={j.get('max_tokens')} n_msgs={len(j.get('messages', []))} n_tools={len(tools) if tools else 0} other_keys={sorted(set(j.keys()) - {'model','stream','max_tokens','messages','tools'})}")
                total = sum(len(str(m.get('content', ''))) for m in j.get("messages", []))
                log(f"    total message chars: {total}")
            except Exception as e:
                log(f"    body not json: {str(e)[:80]}")
        t0 = time.time()
        req = urllib.request.Request(TARGET + self.path, data=body if body else None, method=self.command)
        for k, v in self.headers.items():
            if k.lower() not in ("host", "content-length", "transfer-encoding", "connection"):
                req.add_header(k, v)
        try:
            resp = urllib.request.urlopen(req, timeout=300)
            log(f"<<< upstream status {resp.status} headers after {time.time()-t0:.1f}s")
            self.send_response(resp.status)
            for k, v in resp.getheaders():
                if k.lower() not in ("transfer-encoding", "connection", "content-length"):
                    self.send_header(k, v)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            first = True
            while True:
                chunk = resp.read(2048)
                if not chunk:
                    break
                if first:
                    log(f"<<< first response chunk after {time.time()-t0:.1f}s ({len(chunk)}B)")
                    first = False
                self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            log(f"<<< stream complete at {time.time()-t0:.1f}s")
        except urllib.error.HTTPError as e:
            err = e.read()[:300].decode("utf-8", "replace")
            log(f"<<< HTTPError {e.code} after {time.time()-t0:.1f}s")
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(err.encode())
        except Exception as e:
            log(f"<<< UPGRADE FAIL after {time.time()-t0:.1f}s: {type(e).__name__}: {str(e)[:200]}")
            self.send_response(502)
            self.end_headers()

    do_GET = do_POST = _proxy

    def log_message(self, *a):
        pass

log("=== wiretap started, forwarding to :4000 ===")
http.server.ThreadingHTTPServer(("127.0.0.1", 4001), Tap).serve_forever()
