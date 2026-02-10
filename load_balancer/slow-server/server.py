from http.server import BaseHTTPRequestHandler, HTTPServer
import time

class SlowHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(5)  # simulate slow processing
        self.send_response(200)
        self.send_header("Content-type", "text/plain")
        self.end_headers()
        self.wfile.write(b"Response from SLOW SERVER (5s delay)")

HTTPServer(("0.0.0.0", 80), SlowHandler).serve_forever()
