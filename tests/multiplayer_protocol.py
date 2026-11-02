#!/usr/bin/env python3
"""Exercise the real relay with real RFC6455 clients. Requires websocket-client.

Run against the native test fixture or server/relay.js:
  python3 tests/multiplayer_protocol.py ws://127.0.0.1:18808/net
"""
import json
import struct
import sys
import time
from urllib.parse import urlencode

import websocket

endpoint = sys.argv[1] if len(sys.argv) > 1 else "ws://127.0.0.1:18808/net"
nodes = ["020000000001", "020000000002", "020000000003"]
clients = []


def connect(node, room="protocol-test"):
    client = websocket.create_connection(endpoint + "?" + urlencode(dict(room=room, node=node)), timeout=2)
    clients.append(client)
    return client


def binary(client):
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        op, value = client.recv_data(control_frame=True)
        if op == websocket.ABNF.OPCODE_BINARY:
            return value
    raise AssertionError("no binary game packet received")


def drain(client):
    client.settimeout(.08)
    try:
        while True:
            client.recv()
    except websocket.WebSocketTimeoutException:
        pass
    finally:
        client.settimeout(2)


results = []
try:
    a, b, isolated = connect(nodes[0]), connect(nodes[1]), connect(nodes[2], "different-room")
    for client in clients:
        drain(client)
    payload = b"original-ipx-packet\x00\x80\xff"
    a.send_binary(b"\xff" * 6 + payload)
    assert binary(b) == bytes.fromhex(nodes[0]) + payload
    results.append("broadcast forwards payload and rewrites source node")
    isolated.settimeout(.15)
    try:
        isolated.recv()
        raise AssertionError("packet crossed room boundary")
    except websocket.WebSocketTimeoutException:
        results.append("room isolation")
    isolated.settimeout(2)
    a.settimeout(.15)
    try:
        a.recv()
        raise AssertionError("broadcast echoed to sender")
    except websocket.WebSocketTimeoutException:
        results.append("broadcast does not echo to sender")
    a.settimeout(2)
    b.send_binary(bytes.fromhex(nodes[0]) + b"unicast-reply")
    assert binary(a) == bytes.fromhex(nodes[1]) + b"unicast-reply"
    results.append("unicast replies")
    a.ping(b"latency-probe")
    op, pong = a.recv_data(control_frame=True)
    assert op == websocket.ABNF.OPCODE_PONG and pong == b"latency-probe"
    results.append("WebSocket ping/pong")
    first = websocket.ABNF.create_frame(b"\xff" * 6 + b"fragment-", websocket.ABNF.OPCODE_BINARY, fin=0)
    last = websocket.ABNF.create_frame(b"tail", websocket.ABNF.OPCODE_CONT, fin=1)
    a.send_frame(first); a.send_frame(last)
    assert binary(b) == bytes.fromhex(nodes[0]) + b"fragment-tail"
    results.append("fragmented binary messages")
    oversize = connect("020000000004")
    drain(oversize)
    oversize.send_binary(b"x" * 4097)
    op, close = oversize.recv_data(control_frame=True)
    assert op == websocket.ABNF.OPCODE_CLOSE and struct.unpack("!H", close[:2])[0] == 1009
    results.append("oversized messages close with code1009")
    replacement = connect(nodes[1])
    drain(replacement)
    try:
        b.settimeout(1)
        b.recv()
    except (websocket.WebSocketConnectionClosedException, ConnectionResetError, OSError):
        pass
    a.send_binary(bytes.fromhex(nodes[1]) + b"new-peer")
    assert binary(replacement) == bytes.fromhex(nodes[0]) + b"new-peer"
    results.append("duplicate node replaces old connection")
    print(json.dumps(dict(endpoint=endpoint, passed=True, checks=results), indent=2))
finally:
    for client in clients:
        try:
            client.close(timeout=.2)
        except Exception:
            pass
