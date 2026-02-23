#!/usr/bin/env python3
"""
Cluckers Central Gateway Proxy

Usage:
  1. pip install requests
  2. python3 gateway_proxy.py
  3. Launch the game normally (make sure .env file exists, see below)

Also create a file called ".env" next to cluckers-central.exe containing:
  API_BASE_URL=http://127.0.0.1:18080
"""
import http.server, json, sys
try:
    import requests
except ImportError:
    print("ERROR: Install 'requests' first: pip install requests")
    sys.exit(1)

TARGET = "https://gateway-dev.project-crown.com"
PORT = 18080
session = requests.Session()

class Proxy(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  self._proxy("GET")
    def do_POST(self): self._proxy("POST")
    def do_PUT(self):  self._proxy("PUT")
    def _proxy(self, method):
        url = TARGET + self.path
        cl = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(cl) if cl > 0 else None
        hdrs = {k: v for k, v in self.headers.items() if k.lower() not in ('host', 'transfer-encoding', 'connection')}
        hdrs['Host'] = 'gateway-dev.project-crown.com'
        try:
            r = session.request(method, url, headers=hdrs, data=body, timeout=30)
            self.send_response(r.status_code)
            for k, v in r.headers.items():
                if k.lower() not in ('transfer-encoding', 'connection', 'content-encoding', 'content-length'):
                    self.send_header(k, v)
            self.send_header('Content-Length', str(len(r.content)))
            self.end_headers()
            self.wfile.write(r.content)
        except Exception as e:
            b = json.dumps({"error": str(e)}).encode()
            self.send_response(502)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(b)))
            self.end_headers()
            self.wfile.write(b)
    def log_message(self, *a): pass

if __name__ == '__main__':
    print(f"Gateway proxy running on http://127.0.0.1:{PORT}")
    print(f"Forwarding to {TARGET}")
    print("Keep this running while playing. Ctrl+C to stop.\n")
    http.server.HTTPServer(('127.0.0.1', PORT), Proxy).serve_forever()
