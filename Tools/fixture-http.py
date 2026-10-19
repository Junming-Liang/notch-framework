#!/usr/bin/env python3
"""Loopback-only development fixture transport. Never exposed to a public interface."""
import argparse, functools, http.server, pathlib
p=argparse.ArgumentParser();p.add_argument('directory',type=pathlib.Path);p.add_argument('--port',type=int,default=0);args=p.parse_args()
class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*args): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',args.port),functools.partial(Handler,directory=str(args.directory)))
print(server.server_address[1],flush=True)
server.serve_forever()
