#!/usr/bin/env python3
"""wptserve.py - serve a web-platform-tests checkout as wptrun does.

    tools/ref/wptserve.py [-p port] wptroot

For looking at tests by hand (boxdiff.py, compare.py, a browser):
XHTML served as XHTML, ?pipe=status(N) honoured.
"""
import argparse, functools, os, socketserver, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wptrun

ap = argparse.ArgumentParser()
ap.add_argument('-p', type=int, default=8790)
ap.add_argument('root')
a = ap.parse_args()
socketserver.ThreadingTCPServer.allow_reuse_address = True
srv = socketserver.ThreadingTCPServer(('127.0.0.1', a.p), functools.partial(wptrun.Quiet, directory=os.path.abspath(a.root)))
srv.daemon_threads = True
print('serving %s on http://127.0.0.1:%d/' % (a.root, a.p), file=sys.stderr)
srv.serve_forever()
