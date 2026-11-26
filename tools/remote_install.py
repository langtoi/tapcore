"""Install a locally built TapCore .deb on a device that already runs the daemon (TapCore or the
older ghost-atd), through the daemon's own HTTP API - no SSH needed.

Usage:  python tools/remote_install.py <iphone-ip> [path/to/package.deb]

How it works: the .deb is uploaded into the Screenshots folder, then a small Lua script starts
a one-shot launchd job that runs `dpkg -i`. The job is independent of the daemon, so the
package scripts can stop and restart the daemon safely. The tool then waits for the new
daemon version to answer and prints the dpkg log.
"""
import glob
import json
import os
import sys
import time
import urllib.error
import urllib.request

PORTS = (8080, 8088)   # 8088: daemons before 1.1.2 that fell back when 8080 was busy
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEB_NAME = '_tapcore_install.deb'
LUA_NAME = '_tapcore_install.lua'

INSTALLER_LUA = r'''
local deb = rootDir() .. "/Screenshots/_tapcore_install.deb"
local plist = [[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.tapcore.installer</string>
<key>UserName</key><string>root</string>
<key>RunAtLoad</key><true/>
<key>ProgramArguments</key><array>
<string>/var/jb/bin/sh</string><string>-c</string>
<string>export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin; sleep 1; dpkg -i /tmp/_tapcore_install.deb &gt; /tmp/tapcore-install.log 2&gt;&amp;1; echo "EXIT=$?" &gt;&gt; /tmp/tapcore-install.log; rm -f /tmp/_tapcore_install.deb /tmp/com.tapcore.installer.plist; launchctl bootout system/com.tapcore.installer</string>
</array></dict></plist>]]
local f = assert(io.open("/tmp/com.tapcore.installer.plist", "w"))
f:write(plist)
f:close()
print(execute("mv '" .. deb .. "' /tmp/_tapcore_install.deb && rm -f /tmp/tapcore-install.log; " ..
  "launchctl bootout system/com.tapcore.installer >/dev/null 2>&1; " ..
  "launchctl bootstrap system /tmp/com.tapcore.installer.plist 2>&1; echo installer_started=$?"))
'''

READ_LOG_LUA = 'print(execute("cat /tmp/tapcore-install.log 2>&1"))'


def request(base, method, path, body=None, timeout=15):
    data = body.encode('utf-8') if isinstance(body, str) else body
    req = urllib.request.Request(base + path, data=data, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def find_daemon(host, timeout=3):
    for port in PORTS:
        base = f'http://{host}:{port}'
        try:
            st, body = request(base, 'GET', '/api/status', timeout=timeout)
            if st == 200:
                return base, json.loads(body)
        except OSError:
            pass
    return None, None


def run_lua(base, name, code, wait_s=2.0):
    """Upload + run a Lua snippet, return the lines it printed to the live log."""
    _, lb = request(base, 'GET', '/api/logs?since=0')
    last = max([e['id'] for e in json.loads(lb).get('logs', [])] or [0])
    request(base, 'POST', f'/api/script?path={name}', code)
    request(base, 'POST', f'/api/run?path={name}')
    time.sleep(wait_s)
    _, lb = request(base, 'GET', f'/api/logs?since={last}')
    request(base, 'DELETE', f'/api/script?path={name}')
    return [e['msg'] for e in json.loads(lb).get('logs', []) if e.get('tag') == 'LUA']


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    host = sys.argv[1]
    if len(sys.argv) > 2:
        deb = sys.argv[2]
    else:
        debs = sorted(glob.glob(os.path.join(ROOT, 'build', 'com.tapcore_*_iphoneos-arm64.deb')))
        if not debs:
            sys.exit('No .deb in build/ - run build.sh first')
        deb = debs[-1]
    version = os.path.basename(deb).split('_')[1]

    base, status = find_daemon(host)
    if not base:
        sys.exit(f'No TapCore daemon answering on {host} ports {PORTS}')
    print(f'Daemon at {base}: version={status.get("version", "legacy")} running={status.get("running")} '
          f'script={status.get("script") or "-"}')

    if status.get('running'):
        request(base, 'POST', '/api/stop')

    with open(deb, 'rb') as f:
        st, body = request(base, 'POST', f'/api/screenshot/upload?name={DEB_NAME}', f.read(), timeout=60)
    if st != 200:
        sys.exit(f'Upload failed: {st} {body[:200]!r}')
    print(f'Uploaded {os.path.basename(deb)} ({os.path.getsize(deb)} bytes)')

    out = run_lua(base, LUA_NAME, INSTALLER_LUA, wait_s=1.5)
    print('Installer:', ' | '.join(o.strip() for o in out) or '(no output)')

    print(f'Waiting for TapCore {version} ...')
    prev_started = status.get('daemon_started')
    deadline = time.time() + 90
    new_base = new_status = None
    restarted = False
    while time.time() < deadline:
        time.sleep(1)
        new_base, new_status = find_daemon(host, timeout=2)
        restarted = bool(new_status) and new_status.get('version') == version and             new_status.get('daemon_started') != prev_started
        if restarted:
            break
    if not restarted:
        sys.exit('New daemon did not come up within 90 s; check /tmp/tapcore-install.log on the device')

    print(f'TapCore {version} is up at {new_base} (screen {new_status.get("screen_w")}x{new_status.get("screen_h")}, '
          f'scripts {new_status.get("scripts_dir")})')
    log = run_lua(new_base, '_tapcore_readlog.lua', READ_LOG_LUA, wait_s=1.0)
    print('--- dpkg log ---')
    print('\n'.join(log).strip())


if __name__ == '__main__':
    main()
