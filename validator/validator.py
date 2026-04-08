#!/usr/bin/env python3
"""Phase 1 stub validator -- accepts all registrations, no iptables yet."""
import json
from http.server import HTTPServer, BaseHTTPRequestHandler


class ValidatorHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == '/register':
            length = int(self.headers.get('Content-Length', 0))
            self.rfile.read(length)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
        else:
            self.send_response(404)
            self.end_headers()

    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'OK')
        elif self.path.startswith('/validate'):
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"valid":true}')
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass


if __name__ == '__main__':
    port = 8088
    server = HTTPServer(('0.0.0.0', port), ValidatorHandler)
    print(f'Validator HTTP server listening on :{port}')
    server.serve_forever()
