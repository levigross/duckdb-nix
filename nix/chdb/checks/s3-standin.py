"""The part of S3 that the durable backend of chdb-rust uses, over HTTPS, in memory.

An object is read with GET (404 when it is absent, an ETag on the answer) and written with PUT,
which answers with an ETag and, when it carries `If-None-Match: *` or `If-Match: <etag>`, fails
with 412 if that does not hold: the compare-and-swap that keeps a writer's lease. Requests are
not signed-checked, only required to carry an Authorization header, which shows the program
meant to talk to a store. Every request, and every handshake that failed, is a line in the
access log.

    s3-standin.py <port> <cert> <key> <access log>
"""

import hashlib
import http.server
import socketserver
import ssl
import sys

port, cert, key, access_log = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
store = {}


def record(line):
    with open(access_log, "a") as log:
        log.write(line + "\n")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.request.do_handshake()

    def log_message(self, *args):
        pass

    def answer(self, status, body=b"", etag=None):
        self.send_response(status)
        if etag:
            self.send_header("ETag", etag)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        record(f"{self.command} {self.path} {status} auth={'yes' if self.headers.get('Authorization') else 'no'}")

    def do_GET(self):
        if self.path in store:
            data, etag = store[self.path]
            self.answer(200, data, etag)
        else:
            self.answer(404, b"<Error><Code>NoSuchKey</Code></Error>")

    def do_PUT(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        present = self.path in store
        if self.headers.get("If-None-Match") == "*" and present:
            return self.answer(412)
        wanted = self.headers.get("If-Match")
        if wanted is not None:
            if not present:
                return self.answer(404, b"<Error><Code>NoSuchKey</Code></Error>")
            if store[self.path][1] != wanted:
                return self.answer(412)
        etag = '"' + hashlib.md5(data).hexdigest() + '"'
        store[self.path] = (data, etag)
        self.answer(200, b"", etag)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

    def __init__(self, *args):
        super().__init__(*args)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        # the handshake happens in the thread of the connection, so a client that refuses
        # the certificate does not hold up the others
        self.socket = context.wrap_socket(self.socket, server_side=True, do_handshake_on_connect=False)

    def handle_error(self, request, client_address):
        record(f"handshake failed: {sys.exc_info()[1]}")


with open(access_log, "a"):
    pass
Server(("127.0.0.1", port), Handler).serve_forever()
