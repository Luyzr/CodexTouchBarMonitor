#!/usr/bin/env python3
"""Offline stdio or Unix-proxy WebSocket protocol fixture. Never executes a command."""
import base64
import hashlib
import json
import struct
import sys

websocket = 'proxy' in sys.argv
stream = sys.stdin.buffer
out = sys.stdout.buffer
replies = 0
starts = 0
interrupts = 0
turns = {}
reject_control = False
drop_start = False

def frame(data, opcode=1, final=True):
    size = len(data)
    header = bytes([(0x80 if final else 0) | opcode])
    header += bytes([size]) if size < 126 else b'\x7e' + struct.pack('!H', size) if size < 65536 else b'\x7f' + struct.pack('!Q', size)
    out.write(header + data)
    out.flush()

def send(value):
    data = json.dumps(value, ensure_ascii=False).encode()
    if websocket:
        # Every JSON message exercises continuation frames and ping interleaving.
        half = len(data) // 2
        frame(data[:half], final=False)
        frame(b'fixture', opcode=9)
        frame(data[half:], opcode=0)
    else:
        out.write(data + b'\n')
        out.flush()

def exact(size):
    data = b''
    while len(data) < size:
        chunk = stream.read(size - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    return data

def receive():
    if not websocket:
        line = stream.readline()
        if not line:
            raise EOFError
        return json.loads(line)
    while True:
        first, second = exact(2)
        assert first & 0x80 and second & 0x80
        size = second & 127
        if size == 126:
            size = struct.unpack('!H', exact(2))[0]
        elif size == 127:
            size = struct.unpack('!Q', exact(8))[0]
        assert size <= 8 * 1024 * 1024
        mask = exact(4)
        data = bytes(b ^ mask[i % 4] for i, b in enumerate(exact(size)))
        if first & 15 == 10:
            continue
        return json.loads(data)

if websocket:
    headers = {}
    request = stream.readline()
    assert request.startswith(b'GET / HTTP/1.1')
    while True:
        line = stream.readline().strip()
        if not line:
            break
        k, v = line.split(b':', 1)
        headers[k.lower()] = v.strip()
    digest = base64.b64encode(hashlib.sha1(headers[b'sec-websocket-key'] + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
    out.write(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + digest + b'\r\n\r\n')
    out.flush()

try:
    while True:
        message = receive()
        method = message.get('method')
        params = message.get('params', {})
        result = None
        if method == 'initialize':
            result = {}
        elif method == 'thread/loaded/list':
            ids = ['fixture-' + str(i) for i in range(12)]
            result = {'data': ids[:6] if not params.get('cursor') else ids[6:], 'nextCursor': 'second' if not params.get('cursor') else None}
        elif method in ('thread/resume', 'thread/read'):
            result = {'thread': {'id': params['threadId'], 'name': 'Fixture ' + params['threadId'], 'cwd': '/fixture/project', 'status': {'type': 'active'}, 'turns': []}}
        elif method == 'thread/turns/list':
            if params.get('cursor'):
                result = {'data': [{'id': 'old', 'status': 'completed', 'startedAt': 100, 'completedAt': 200}], 'nextCursor': None}
            else:
                result = {'data': [turns.get(params['threadId'], {'id': 'turn', 'status': 'inProgress', 'startedAt': 100})], 'nextCursor': 'older'}
        elif method == 'fixture/request':
            send({'id': 'approval-7', 'method': 'item/commandExecution/requestApproval', 'params': {'threadId': 'thread', 'turnId': 'turn', 'command': 'echo fixture'}})
            result = {'ready': True}
        elif method == 'fixture/decision':
            send({'id': 'live-fixture', 'method': 'item/tool/requestUserInput', 'params': {'threadId': 'fixture-0', 'turnId': 'turn', 'questions': [{'id': 'q', 'question': 'Fixture only', 'isSecret': True}]}})
            result = {}
        elif method == 'fixture/error':
            send({'id': message['id'], 'error': {'code': -32601, 'message': 'fixture'}})
        elif method == 'fixture/exit':
            sys.exit(0)
        elif method == 'fixture/timeout':
            pass
        elif method == 'fixture/stats':
            result = {'replies': replies, 'starts': starts, 'interrupts': interrupts}
        elif method == 'fixture/control':
            reject_control = params.get('reject', False)
            drop_start = params.get('dropStart', False)
            result = {}
        elif method == 'fixture/advance':
            turns[params['threadId']] = {'id': 'external', 'status': 'inProgress'}
            result = {}
        elif method in ('turn/interrupt', 'turn/start') and reject_control:
            reject_control = False
            send({'id': message['id'], 'error': {'code': -32600, 'message': 'fixture rejection'}})
        elif method == 'turn/start':
            assert len(params['input']) == 1 and params['input'][0]['type'] == 'text'
            starts += 1
            turn = {'id': 'continued-' + str(starts), 'status': 'inProgress'}
            turns[params['threadId']] = turn
            if not drop_start:
                send({'method': 'turn/started', 'params': {'threadId': params['threadId'], 'turn': turn}})
                result = {'turn': turn}
            drop_start = False
        elif method == 'turn/interrupt':
            interrupts += 1
            turns[params['threadId']] = {'id': params['turnId'], 'status': 'interrupted'}
            send({'method': 'turn/completed', 'params': {'threadId': params['threadId'], 'turn': {'id': params['turnId'], 'status': 'interrupted'}}})
            result = {}
        elif 'result' in message:
            replies += 1
            thread = 'fixture-0' if message['id'] == 'live-fixture' else 'thread'
            send({'method': 'serverRequest/resolved', 'params': {'threadId': thread, 'requestId': message['id']}})
            send({'method': 'fixture/received', 'params': {'decision': message['result'].get('decision')}})
        if result is not None:
            send({'id': message['id'], 'result': result})
except (EOFError, BrokenPipeError):
    pass
