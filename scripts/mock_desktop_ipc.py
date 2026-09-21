#!/usr/bin/env python3
"""Offline Desktop IPC framing/route fixture. Never connects to the real app."""
import json, os, socket, struct, sys
path = sys.argv[1]
server = socket.socket(socket.AF_UNIX)
server.bind(path); server.listen(1)
try:
    conn, _ = server.accept()
    def read_exact(size):
        data = b''
        while len(data) < size:
            part = conn.recv(size-len(data))
            if not part: raise EOFError
            data += part
        return data
    def send(obj):
        payload = json.dumps(obj).encode(); frame = struct.pack('<I', len(payload)) + payload
        for i in range(0, len(frame), 3): conn.sendall(frame[i:i+3])
    broadcasts = []
    with conn:
        while True:
            try: obj = json.loads(read_exact(struct.unpack('<I', read_exact(4))[0]))
            except EOFError: break
            if obj.get('type') == 'broadcast':
                broadcasts.append(obj)
                continue
            if obj.get('type') != 'request': continue
            method = obj['method']
            if method == 'initialize': result = {'clientId':'fixture-monitor'}
            elif method == 'fixture/broadcasts':
                result = {'messages': broadcasts}
                broadcasts = []
            elif method == 'thread-follower-submit-user-input':
                assert obj['sourceClientId'] == 'fixture-monitor'
                assert obj['targetClientId'] == 'fixture-owner'
                assert obj['version'] == (2 if obj.get('hostId') == 'remote-ssh-discovered:fixture' else 1)
                assert obj['params']['conversationId'] == 'fixture-thread'
                assert obj['params']['requestId'] == 'input-1'
                assert obj['params']['response'] == {'answers': {'branch': {'answers': ['功能分支🚀']}}}
                result = {'ok': True}
            elif method == 'thread-follower-steer-turn':
                assert obj['targetClientId'] == 'fixture-owner' and obj['version'] == 1
                assert obj['params']['conversationId'] == 'fixture-thread'
                assert obj['params']['input'][0]['text'].startswith('<send_user_message_question_reply>')
                assert obj['params']['restoreMessage']['context']['turnTrigger'] == 'send_user_message_async_question'
                result = {'ok': True}
            else: result = {}
            send({'type':'response','requestId':obj['requestId'],'method':method,'resultType':'success','result':result,'handledByClientId':'fixture-owner'})
finally:
    server.close()
    if os.path.exists(path): os.unlink(path)
