#!/usr/bin/env python3
"""Start a disposable real HTTP service, verify health, then remove all data."""
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request


def main():
    with tempfile.TemporaryDirectory(prefix='notihub-smoke-') as folder:
        root = Path(folder)
        for name in ('sync', 'proxy'):
            (root / name).write_text(secrets.token_urlsafe(48))
            (root / name).chmod(0o600)
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        env = dict(os.environ, NOTIFHUB_ID='demo', NOTIFHUB_URL='https://demo.example.invalid',
                   NOTIFHUB_DATABASE=str(root / 'cloud.sqlite'),
                   NOTIFHUB_SYNC_TOKEN_FILE=str(root / 'sync'), NOTIFHUB_PROXY_TOKEN_FILE=str(root / 'proxy'),
                   NOTIFHUB_BARK_URL='', NOTIFHUB_BARK_KEY_FILE='')
        process = subprocess.Popen([sys.executable, '-m', 'uvicorn', 'api:create_app', '--factory',
                                    '--host', '127.0.0.1', '--port', str(port)],
                                   cwd=Path(__file__).resolve().parent, env=env,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            request = urllib.request.Request(f'http://127.0.0.1:{port}/api/health',
                       headers={'Host': 'demo.example.invalid', 'X-Notifhub-Proxy': (root / 'proxy').read_text()})
            for _ in range(100):
                if process.poll() is not None: raise RuntimeError('server exited before health readback')
                try:
                    with urllib.request.urlopen(request, timeout=1) as response:
                        data = json.load(response)
                    assert data['ok'] is True, 'health response was not successful'
                    print(json.dumps({'ok': True, 'http': 200, 'instance': data.get('instance'),
                                      'records': data.get('records'), 'database': 'temporary synthetic database'}))
                    return
                except OSError:
                    time.sleep(.1)
            raise RuntimeError('server did not become ready within ten seconds')
        finally:
            process.terminate()
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: process.kill(); process.wait()


if __name__ == '__main__': main()
