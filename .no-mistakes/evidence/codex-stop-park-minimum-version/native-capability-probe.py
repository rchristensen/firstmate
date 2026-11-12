import http.server
import json
import os
from pathlib import Path
import queue
import shutil
import shlex
import subprocess
import sys
import threading
import time

root, lab, version = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
actual_version = subprocess.run(['codex', '--version'], capture_output=True, text=True, check=True).stdout.strip()
assert actual_version == 'codex-cli ' + version, (actual_version, version)
lab.mkdir()
wrapper = json.loads((root / '.codex/hooks.json').read_text())['hooks']['SessionStart'][0]['hooks'][0]['command']
primary = lab / 'primary'
primary.mkdir()
# The code under test, as it stands in this checkout, in a standalone primary
# repository: the wrapper resolves its scripts from the session's directory.
tracked = subprocess.run(['git', '-C', str(root), 'ls-files', '-z'], check=True,
                         capture_output=True).stdout.decode().split('\0')
for name in filter(None, tracked):
    source = root / name
    if source.is_file() and not source.is_symlink():
        target = primary / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
subprocess.run(['git', 'init', '-q', str(primary)], check=True)
(primary / 'config').mkdir(exist_ok=True)
(primary / 'state').mkdir(exist_ok=True)
(primary / 'config/codex-stop-park').touch()
probe = lab / 'capability.sh'
probe.write_text('#!/bin/bash\nunset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS FM_OMP_HARNESS\nbin/fm-lock.sh > ../lock.out 2>&1\nbin/fm-harness.sh > ../harness.out\nFM_CODEX_PARK_SESSION=synthetic-session bin/fm-codex-stop-park.sh --capable\nprintf \'%s\\n\' "$?" > ../capability.rc\n')
wrapper = shlex.join(['bash', str(probe)])
requests = []

class Responses(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        requests.append(self.rfile.read(int(self.headers.get('Content-Length', '0'))).decode('utf-8', 'replace'))
        message = {'id': 'msg_fixture', 'type': 'message', 'role': 'assistant',
                   'status': 'completed', 'phase': 'final_answer', 'content': [
                       {'type': 'output_text', 'text': 'fixture complete', 'annotations': []}]}
        events = [
            {'type': 'response.created', 'response': {'id': 'resp_fixture', 'status': 'in_progress', 'output': []}},
            {'type': 'response.output_item.added', 'output_index': 0,
             'item': {**message, 'status': 'in_progress', 'content': []}},
            {'type': 'response.output_item.done', 'output_index': 0, 'item': message},
            {'type': 'response.completed', 'response': {'id': 'resp_fixture', 'status': 'completed',
             'output': [message], 'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}},
        ]
        data = ''.join('event: ' + event['type'] + '\ndata: ' + json.dumps(event) + '\n\n'
                       for event in events).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Responses)
server_thread = threading.Thread(target=server.serve_forever, daemon=True)
server_thread.start()
fixture_home = lab / 'login'
fixture_home.mkdir()
(fixture_home / '.bash_profile').write_text(':\n')
codex_data = lab / 'codex'
codex_data.mkdir()
(codex_data / 'hooks.json').write_text(json.dumps({'hooks': {'SessionStart': [{'hooks': [
    {'type': 'command', 'command': wrapper, 'timeout': 180}]}]}}))
(codex_data / 'config.toml').write_text(f'''model="fixture"
model_provider="fixture"
[model_providers.fixture]
name="Loopback SessionStart fixture"
base_url="http://127.0.0.1:{server.server_port}/v1"
wire_api="responses"
requires_openai_auth=false
[features]
hooks=true
shell_snapshot=false
[analytics]
enabled=false
''')
# Keep the inherited PATH, but no operator config, tokens, fleet home, or
# Firstmate variables enter the child app-server or its hooks.
env = {key: os.environ[key] for key in ['PATH', 'LANG', 'LC_ALL', 'DISABLE_AUTOUPDATER'] if key in os.environ}
env.update({'HOME': str(fixture_home), 'CODEX_HOME': str(codex_data),
            'SHELL': '/bin/sh', 'TMPDIR': str(lab), 'OTEL_SDK_DISABLED': 'true'})
notifications = []
messages = queue.Queue()
deadline = time.monotonic() + 150
try:
    with (lab / 'stderr').open('w') as stderr:
        process = subprocess.Popen(['codex', 'app-server', '--stdio'], cwd=lab, env=env,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, text=True)
        def read_lines():
            for line in process.stdout:
                messages.put(json.loads(line))
            messages.put(None)
        reader = threading.Thread(target=read_lines, daemon=True)
        reader.start()
        def send(message):
            process.stdin.write(json.dumps(message) + '\n')
            process.stdin.flush()
        def receive():
            message = messages.get(timeout=max(0.1, deadline - time.monotonic()))
            assert message is not None, 'app-server exited before its SessionStart hook ran'
            notifications.append(message)
            return message
        def rpc(number, method, params):
            send({'id': number, 'method': method, 'params': params})
            while True:
                message = receive()
                if message.get('id') == number:
                    assert 'error' not in message, message
                    return message['result']
        try:
            rpc(1, 'initialize', {'clientInfo': {'name': 'isolated-sessionstart-test', 'version': '1'},
                                 'capabilities': {'experimentalApi': True}})
            send({'method': 'initialized'})
            listed = rpc(2, 'hooks/list', {'cwds': [str(primary)]})
            hooks = [hook for entry in listed['data'] for hook in entry['hooks']
                     if hook['sourcePath'] == str(codex_data / 'hooks.json')]
            assert len(hooks) == 1, listed
            hook = hooks[0]
            thread = rpc(3, 'thread/start', {'cwd': str(primary), 'model': 'fixture', 'modelProvider': 'fixture',
                'approvalPolicy': 'never', 'sandbox': 'read-only', 'ephemeral': True,
                'config': {'hooks.state': {hook['key']: {'trusted_hash': hook['currentHash']}}}})
            rpc(4, 'turn/start', {'threadId': thread['thread']['id'],
                                 'input': [{'type': 'text', 'text': 'fixture', 'text_elements': []}]})
            while receive().get('method') != 'turn/completed':
                pass
        finally:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            reader.join(timeout=1)
    runs = [message['params']['run'] for message in notifications
            if message.get('method') == 'hook/completed']
    assert [run['status'] for run in runs] == ['completed'], runs
    expected = '1' if version == '0.162.0' else '0'
    actual = (lab / 'capability.rc').read_text().strip()
    harness = (lab / 'harness.out').read_text().strip()
    assert harness == 'codex', harness
    assert actual == expected, (version, actual, expected, (lab / 'lock.out').read_text())
    print(f'Codex {version}: real native SessionStart hook -> harness={harness}; Stop-park --capable exit={actual} (expected {expected})')
    print((lab / 'lock.out').read_text().strip())

except Exception as error:
    raise SystemExit(f'not ok - codex {version}: SessionStart harness detection failed: {error!r}') from error
finally:
    server.shutdown()
    server.server_close()
    server_thread.join()