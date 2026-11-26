"""Install the freshly built TapCore .deb on a jailbroken iPhone over SSH, then smoke-test the daemon.

Usage (Windows, needs `pip install paramiko`):
    set TAPCORE_SSH_PASS=<mobile password>      (optional: asked interactively otherwise)
    python tools\\deploy_verify.py <iphone-ip> [ssh-user]

The same password is used for `sudo`. For normal installs use Sileo instead:
add the source https://langtoi.github.io/tapcore/ and install TapCore.
"""
import getpass
import glob
import json
import os
import sys
import time
import urllib.error
import urllib.request

import paramiko

if len(sys.argv) < 2:
    sys.exit(__doc__)

HOST = sys.argv[1]
USER = sys.argv[2] if len(sys.argv) > 2 else 'mobile'
PASS = os.environ.get('TAPCORE_SSH_PASS') or getpass.getpass(f'SSH/sudo password for {USER}@{HOST}: ')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

debs = sorted(glob.glob(os.path.join(ROOT, 'build', 'com.tapcore_*_iphoneos-arm64.deb')))
if not debs:
    sys.exit('No .deb in build/ - run build.sh first')
DEB = debs[-1]

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
print(f'Connecting to {USER}@{HOST}...')
c.connect(HOST, username=USER, password=PASS, timeout=8)

sftp = c.open_sftp()
sftp.put(DEB, '/tmp/tapcore.deb')
sftp.close()
print('Uploaded', os.path.basename(DEB))


def sudo(cmd):
    _, out, _ = c.exec_command(f'sudo -S -p "" /var/jb/bin/sh -c {json.dumps(cmd)} 2>&1')
    out.channel.sendall((PASS + '\n').encode())
    return out.read().decode('utf-8', 'replace')


print(sudo('export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin; dpkg -i /tmp/tapcore.deb; rm -f /tmp/tapcore.deb'))
time.sleep(1.5)

_, pout, _ = c.exec_command('cat /tmp/tapcore.port 2>/dev/null')
port = pout.read().decode().strip() or '8080'
base = f'http://{HOST}:{port}'
print(f'\n=== VERIFYING TAPCORE AT {base} ===')


def req(method, path, body=None, ctype='application/json'):
    data = body.encode('utf-8') if isinstance(body, str) else body
    r = urllib.request.Request(base + path, data=data, method=method)
    if data is not None:
        r.add_header('Content-Type', ctype)
    try:
        with urllib.request.urlopen(r, timeout=15) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


st, b = req('GET', '/api/status')
print('1. GET /api/status:', st, b.decode())

st, b = req('GET', '/')
print('2. GET / (Web Studio HTML):', st, len(b), 'bytes, TapCore title =', b'TapCore' in b)

req('POST', '/api/script?path=verify_tmp.lua', 'for i=1,50 do print("verify_tick_"..i); usleep(150000) end', 'text/plain')
st, b = req('POST', '/api/run?path=verify_tmp.lua')
print('3a. Play verify_tmp.lua:', st, b.decode())
time.sleep(0.55)
t0 = time.time()
st, b = req('POST', '/api/stop')
print(f'3b. Stop verify_tmp.lua ({(time.time() - t0) * 1000:.1f} ms):', st, b.decode())
st, lb = req('GET', '/api/logs?since=0')
print('3c. Recent logs:', [(x['tag'], x['msg']) for x in json.loads(lb)['logs'][-6:]])
req('DELETE', '/api/script?path=verify_tmp.lua')

st, b = req('GET', '/control/start_playing?path=/sv.lua')
print('4a. /control/start_playing?path=/sv.lua:', st, b.decode())
time.sleep(0.4)
try:
    body = b'{"action":"RUNLUA","data":"return 42"}'
    p3000 = urllib.request.Request(f'http://{HOST}:3000', data=body,
                                   headers={'Content-Type': 'application/json'}, method='POST')
    with urllib.request.urlopen(p3000, timeout=5) as r3:
        print('4b. Port 3000 sv.lua check:', r3.status, r3.read().decode())
except Exception as e:  # noqa: BLE001 - report any failure
    print('4b. Port 3000 error:', e)
st, b = req('GET', '/control/stop_playing')
print('4c. /control/stop_playing:', st, b.decode())

st, png = req('GET', '/api/capture')
print('5a. GET /api/capture:', st, len(png), 'bytes, PNG_HDR=', png[:4] == b'\x89PNG')
st, ob = req('POST', '/api/ocr', json.dumps({'languages': ['en-US']}))
od = json.loads(ob)
print('5b. POST /api/ocr:', st, 'items=', len(od.get('items', [])), 'ms=', od.get('elapsed_ms'))

_, uout, _ = c.exec_command('/var/jb/usr/bin/uiopen --bundleid com.tapcore.app 2>&1')
print('6. Launch TapCore.app:', uout.read().decode().strip() or 'launched')
c.close()
