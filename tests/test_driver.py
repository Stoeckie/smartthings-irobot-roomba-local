"""Run the Edge driver (src/init.lua) with a mocked SmartThings runtime against a fake Roomba:
password fetch while HOME is "held", MQTT login, state from shadow updates, commands, wrong password.

    pip install lupa pytest
    python -m pytest tests
"""
import json
import pathlib
import socket
import threading
import time

import pytest
from lupa import lua53

HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE.parent / "src"
BLID = "ABCDEF0123456789"
PW = ":1:1234567890:TestPasswordXyz"


def mqtt_read(conn):
    first = conn.recv(1)
    if not first:
        return None, None
    mult, length = 1, 0
    while True:
        b = conn.recv(1)[0]
        length += (b & 0x7F) * mult
        if not b & 0x80:
            break
        mult *= 128
    body = b""
    while len(body) < length:
        chunk = conn.recv(length - len(body))
        if not chunk:
            return None, None
        body += chunk
    return first[0], body


def mqtt_str(b, pos):
    n = (b[pos] << 8) | b[pos + 1]
    return b[pos + 2:pos + 2 + n].decode(), pos + 2 + n


def publish(topic, payload, qos=1, pid=7):
    t = topic.encode()
    body = len(t).to_bytes(2, "big") + t + (pid.to_bytes(2, "big") if qos else b"") + payload.encode()
    return bytes([0x30 | (qos << 1)]) + varlen(len(body)) + body


def varlen(n):
    out = b""
    while True:
        b = n % 128
        n //= 128
        out += bytes([b | (0x80 if n else 0)])
        if not n:
            return out


class FakeRoomba:
    def __init__(self):
        self.srv = socket.socket()
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(5)
        self.port = self.srv.getsockname()[1]
        self.listening = False   # HOME held
        self.password = PW
        self.commands = []
        self.payloads = []
        self.last_command = {"command": "start", "initiator": "rmtApp", "time": 1, "ordered": 1, "pmap_id": "PMAP1",
                             "regions": [{"region_id": "5", "type": "rid"}], "user_pmapv_id": "V1"}
        self.logins = []
        self.phase = "charge"
        self.conn = None
        threading.Thread(target=self.serve, daemon=True).start()

    def state(self):
        cycle = "none" if self.phase in ("charge",) else "clean"
        return json.dumps({"state": {"reported": {"batPct": 87, "bin": {"present": True, "full": False},
                                                   "lastCommand": self.last_command, "pmaps": [{"PMAP1": "V2"}],
                                                   "cleanMissionStatus": {"cycle": cycle, "phase": self.phase,
                                                                          "error": 0, "mssnM": 3}}}})

    def serve(self):
        while True:
            conn, _ = self.srv.accept()
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def handle(self, conn):
        try:
            first = conn.recv(1, socket.MSG_PEEK)
            if first == b"\xf0":
                req = conn.recv(7)
                assert req == bytes.fromhex("f005efcc3b2900")
                if self.listening:
                    rest = bytes.fromhex("efcc3b2900") + self.password.encode() + b"\x00"
                    conn.sendall(b"\xf0" + bytes([len(rest)]) + rest)
                else:
                    time.sleep(0.5)
                conn.close()
                return
            t, body = mqtt_read(conn)
            assert t == 0x10
            pos = 10
            cid, pos = mqtt_str(body, pos)
            user, pos = mqtt_str(body, pos)
            pw, pos = mqtt_str(body, pos)
            self.logins.append((cid, user, pw))
            if user != BLID or pw != self.password:
                conn.sendall(bytes([0x20, 2, 0, 4]))
                conn.close()
                return
            conn.sendall(bytes([0x20, 2, 0, 0]))
            self.conn = conn
            while True:
                t, body = mqtt_read(conn)
                if t is None:
                    return
                kind = t >> 4
                if kind == 8:  # SUBSCRIBE
                    conn.sendall(bytes([0x90, 3]) + body[:2] + b"\x00")
                    conn.sendall(publish(f"$aws/things/{BLID}/shadow/update",
                                         json.dumps({"state": {"reported": {"name": "Nounou", "sku": "s955840"}}})))
                    conn.sendall(publish(f"$aws/things/{BLID}/shadow/update", self.state()))
                elif kind == 3:
                    topic, p = mqtt_str(body, 0)
                    cmd = json.loads(body[p:])
                    self.commands.append(cmd["command"])
                    self.payloads.append(cmd)
                    self.last_command = {k: v for k, v in cmd.items() if k != "time"}
                    self.phase = {"start": "run", "resume": "run", "pause": "stop", "dock": "hmUsrDock",
                                  "stop": "stop"}.get(cmd["command"], self.phase)
                    conn.sendall(publish(f"$aws/things/{BLID}/shadow/update", self.state(), qos=0))
                elif kind == 12:
                    conn.sendall(bytes([0xD0, 0]))
                elif kind == 4:
                    pass
        except (OSError, AssertionError, IndexError):
            conn.close()


HARNESS = r'''
local function capmock(path)
  return setmetatable({}, {
    __index = function(t, k)
      if k == "NAME" then return path:match("([^.]+)$") end
      local v = capmock(path .. "." .. k); rawset(t, k, v); return v end,
    __call = function(_, a) return { path = path, arg = a } end })
end
local caps = capmock("cap")
for _, id in ipairs({ "refresh", "switch", "robotCleanerMovement", "momentary", "battery", "mode" }) do caps[id].ID = id end
package.loaded["st.capabilities"] = caps
package.loaded["st.driver"] = function(name, tmpl) DRIVER = tmpl; return { run = function() end } end
LOG = {}
local function L(p) return function(m) LOG[#LOG + 1] = p .. m; print(p .. m) end end
package.loaded["log"] = { info = L("I "), warn = L("W "), error = L("E "), debug = function() end }
package.loaded["st.json"] = require "st_json"
TASKS = {}
package.loaded["cosock"] = { spawn = function(fn) TASKS[#TASKS + 1] = coroutine.create(fn) end,
  socket = { gettime = function() return py_time() end } }

local function wrap(ps)
  local w = {}
  function w:settimeout(t) ps.settimeout(t) end
  function w:send(d, i) local n, e = ps.send(d, i or 1); if n then return n end; return nil, e end
  function w:receive(n)
    local d, e = ps.receive(n)
    if d then return d end
    if e == "timeout" then coroutine.yield(); e = "wantread" end -- luasec on the hub says wantread
    return nil, e, ""
  end
  function w:close() ps.close() end
  return w
end
package.loaded["transport"] = {
  PORT = 8883,
  connect_tls = function(ip, port, timeout)
    local ps, err = py_connect(ip)
    if not ps then return nil, err end
    return wrap(ps)
  end,
  discover = function(prefix, window)
    return { { ip = "127.0.0.1", data = py_discovery() } }
  end,
  sleep = function() coroutine.yield() end,
  http_get = function(ip, port, path, timeout) return py_http_get(ip, port, path) end,
  now = function() return py_time() end,
}
function STEP()
  for _, co in ipairs(TASKS) do
    if coroutine.status(co) == "suspended" then
      local ok, err = coroutine.resume(co)
      if not ok then print("task error " .. tostring(err)) end
    end
  end
end

DEVICES = {}
function NEW_DEVICE(info)
  local d = { id = info.id or ("dev" .. (#DEVICES + 1)), fields = {}, preferences = info.preferences or {},
              device_network_id = info.device_network_id, label = info.label, events = {}, state = "?",
              profile = { components = { main = { id = "main" }, favorites = { id = "favorites" } } } }
  function d:get_field(k) return self.fields[k] end
  function d:set_field(k, v) self.fields[k] = v end
  function d:emit_event(e) self.events[#self.events + 1] = e end
  function d:emit_component_event(c, e) self.events[#self.events + 1] = { path = c.id .. ":" .. e.path, arg = e.arg } end
  DELAYED = DELAYED or {}
  d.thread = { call_with_delay = function(_, secs, fn) DELAYED[#DELAYED + 1] = fn end,
               call_on_schedule = function() end }
  function d:online() self.state = "online" end
  function d:offline() self.state = "offline" end
  DEVICES[#DEVICES + 1] = d
  return d
end
DRIVER_OBJ = { get_devices = function() return DEVICES end,
  try_create_device = function(self, info) NEW_DEVICE(info) end, environment_info = { hub_ipv4 = "127.0.0.1" } }
'''


class PySock:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.t = 5

    def settimeout(self, t):
        self.t = t
        self.s.settimeout(0.2 if t is None else min(t, 0.2))

    def send(self, d, i):
        data = d[int(i) - 1:]
        self.s.sendall(data)
        return len(d), None

    def receive(self, n):
        try:
            d = self.s.recv(int(n))
        except socket.timeout:
            return None, "timeout"
        except OSError as e:
            return None, str(e)
        if not d:
            return None, "closed"
        return d, None

    def close(self):
        self.s.close()


@pytest.fixture
def env():
    robot = FakeRoomba()
    lua = lua53.LuaRuntime(unpack_returned_tuples=True, encoding=None)
    g = lua.globals()
    g.py_time = time.time
    g.py_http_get = lambda ip, port, path: (None, "no bridge")
    g.py_connect = lambda ip: (PySock(robot.port), None)
    g.py_discovery = lambda: json.dumps({"hostname": f"iRobot-{BLID}", "ip": "127.0.0.1", "robotname": "Nounou",
                                         "sku": "s955840", "proto": "mqtt", "ver": "3"}).encode()
    lua.execute(f'package.path = "{SRC}/?.lua;{HERE}/?.lua;" .. package.path'.encode())
    lua.execute(HARNESS.encode())
    lua.execute(f'dofile("{SRC}/init.lua")'.encode())
    return robot, lua


def run_until(lua, cond, secs=8):
    end = time.time() + secs
    while time.time() < end:
        lua.execute(b"STEP()")
        if cond():
            return True
        time.sleep(0.02)
    return False


def events(lua, dev):
    out = {}
    for i in range(1, len(dev.events) + 1):
        e = dev.events[i]
        out[e.path] = e.arg
    return out


def test_password_login_state_commands(env):
    robot, lua = env
    lua.execute(b"DRIVER.discovery(DRIVER_OBJ, {}, function() return true end)")
    dev = lua.eval(b"DEVICES[1]")
    assert dev is not None and dev.label == b"Nounou"
    lua.execute(b"DRIVER.lifecycle_handlers.added(DRIVER_OBJ, DEVICES[1])")
    assert dev.fields[b"blid"] == BLID.encode() and dev.fields[b"ip"] == b"127.0.0.1"
    # no password yet: the driver keeps asking, robot stays quiet
    run_until(lua, lambda: False, 1)
    assert dev.fields[b"pw"] is None
    assert any(b"hold HOME" in (lua.eval(b"LOG")[i] or b"") for i in range(1, len(lua.eval(b"LOG")) + 1))
    robot.listening = True
    assert run_until(lua, lambda: dev.state == b"online")
    assert dev.fields[b"pw"] == PW.encode()
    assert robot.logins[-1] == (BLID, BLID, PW)
    assert run_until(lua, lambda: b"cap.battery.battery" in events(lua, dev))
    assert events(lua, dev)[b"cap.battery.battery"] == 87
    paths = {dev.events[i].path for i in range(1, len(dev.events) + 1)}
    assert b"cap.robotCleanerMovement.robotCleanerMovement.charging" in paths
    assert b"cap.switch.switch.off" in paths

    lua.execute(b'DRIVER.capability_handlers.switch.on(DRIVER_OBJ, DEVICES[1])')
    assert run_until(lua, lambda: "start" in robot.commands)
    assert run_until(lua, lambda: b"cap.robotCleanerMovement.robotCleanerMovement.cleaning" in
                     {dev.events[i].path for i in range(1, len(dev.events) + 1)})
    lua.execute(b'DRIVER.capability_handlers.switch.off(DRIVER_OBJ, DEVICES[1])')
    assert run_until(lua, lambda: robot.commands[-2:] == ["pause", "dock"], 10)
    lua.execute(b'DRIVER.capability_handlers.momentary.push(DRIVER_OBJ, DEVICES[1], {component="emptyBin"})')
    assert run_until(lua, lambda: robot.commands[-1] == "evac")
    lua.execute(b'DRIVER.capability_handlers.robotCleanerMovement.setRobotCleanerMovement('
                b'DRIVER_OBJ, DEVICES[1], {args={mode="cleaning"}})')
    assert run_until(lua, lambda: robot.commands[-1] in ("start", "resume"))


def test_wrong_stored_password_is_dropped(env):
    robot, lua = env
    lua.execute(b"DRIVER.discovery(DRIVER_OBJ, {}, function() return true end)")
    lua.execute(b'DEVICES[1].fields.pw = "wrong"')
    lua.execute(b"DRIVER.lifecycle_handlers.added(DRIVER_OBJ, DEVICES[1])")
    dev = lua.eval(b"DEVICES[1]")
    assert run_until(lua, lambda: dev.fields[b"pw"] is None)
    robot.listening = True
    assert run_until(lua, lambda: dev.state == b"online")
    assert dev.fields[b"pw"] == PW.encode()


def test_model_mapping():
    lua = lua53.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(f'package.path = "{SRC}/?.lua;" .. package.path')
    m = lua.eval('require("roomba_model")')
    cases = [({"phase": "run", "cycle": "clean"}, "cleaning", True),
             ({"phase": "stop", "cycle": "clean"}, "pause", True),
             ({"phase": "stop", "cycle": "none"}, "idle", False),
             ({"phase": "hmUsrDock", "cycle": "clean"}, "homing", True),
             ({"phase": "charge", "cycle": "none"}, "charging", False),
             ({"phase": "evac", "cycle": "evac"}, "charging", False),
             ({"phase": "stuck", "cycle": "clean", "error": 17}, "alarm", True)]
    for cms, movement, active in cases:
        t = lua.table_from({"cleanMissionStatus": lua.table_from(cms)})
        v = m.view(t)
        assert (v.movement, v.active) == (movement, active), cms
    assert m.view(lua.table_from({"cleanMissionStatus": lua.table_from({"phase": "stuck", "error": 17})})).error_text == "Path blocked"


def test_favorites_learned_named_and_started(env):
    robot, lua = env
    lua.execute(b"DRIVER.discovery(DRIVER_OBJ, {}, function() return true end)")
    lua.execute(b'DEVICES[1].preferences.favoriteNames = "Kamer, Hele keuken"')
    lua.execute(b"DRIVER.lifecycle_handlers.added(DRIVER_OBJ, DEVICES[1])")
    dev = lua.eval(b"DEVICES[1]")
    robot.listening = True
    assert run_until(lua, lambda: dev.fields[b"programs"] is not None)
    progs = json.loads(dev.fields[b"programs"])
    assert len(progs) == 1 and progs[0]["pmap_id"] == "PMAP1" and progs[0]["regions"][0]["region_id"] == "5"

    def last(path):
        val = None
        for i in range(1, len(dev.events) + 1):
            if dev.events[i].path == path:
                val = dev.events[i].arg
        return val
    assert run_until(lua, lambda: last(b"favorites:cap.mode.supportedModes") is not None)
    modes = list(last(b"favorites:cap.mode.supportedModes").values())
    assert modes == [b"Idle", b"Whole home", b"Kamer"]
    # charging, not active -> Idle
    assert last(b"favorites:cap.mode.mode") == b"Idle"
    lua.execute(b'DRIVER.capability_handlers.mode.setMode(DRIVER_OBJ, DEVICES[1], {component="favorites", args={mode="Kamer"}})')
    assert run_until(lua, lambda: robot.payloads and robot.payloads[-1].get("regions"))
    pl = robot.payloads[-1]
    assert pl["command"] == "start" and pl["pmap_id"] == "PMAP1" and pl["user_pmapv_id"] == "V1"  # as learned
    assert pl["regions"] == [{"region_id": "5", "type": "rid"}] and pl["initiator"] == "localApp"
    assert run_until(lua, lambda: last(b"favorites:cap.mode.mode") == b"Kamer")
    # a plain start is not a favorite and must not merge with the old regions
    lua.execute(b'DRIVER.capability_handlers.mode.setMode(DRIVER_OBJ, DEVICES[1], {component="favorites", args={mode="Whole home"}})')
    assert run_until(lua, lambda: last(b"favorites:cap.mode.mode") == b"Whole home")
    assert len(json.loads(dev.fields[b"programs"])) == 1


def test_favorites_from_bridge(env):
    robot, lua = env
    calls = []

    def http_get(ip, port, path):
        path = path.decode() if isinstance(path, bytes) else path
        calls.append(path)
        if path == "/stbridge/info":
            return json.dumps({"service": "stoeckie-bridge", "id": "b1"}).encode(), None
        if path.startswith("/stbridge/irobot/" + BLID):
            return json.dumps({"name": "Nounou", "updated": 1, "favorites": [
                {"name": "Kamer", "command": "start",
                 "params": {"pmap_id": "PMAP1", "ordered": 1, "regions": [{"region_id": "5", "type": "rid"}]}},
                {"name": "Hele keuken", "command": "start",
                 "params": {"pmap_id": "PMAP1", "ordered": 1, "regions": [{"region_id": "7", "type": "rid"}]}},
            ]}).encode(), None
        return None, "HTTP 404"
    lua.globals().py_http_get = http_get
    lua.execute(b"DRIVER.discovery(DRIVER_OBJ, {}, function() return true end)")
    lua.execute(b'DEVICES[1].preferences.bridgeAddress = "127.0.0.1"')
    lua.execute(b"DRIVER.lifecycle_handlers.added(DRIVER_OBJ, DEVICES[1])")
    dev = lua.eval(b"DEVICES[1]")
    robot.listening = True
    assert run_until(lua, lambda: dev.state == b"online")
    lua.execute(b"for _, fn in ipairs(DELAYED) do fn() end; DELAYED = {}")  # the 10 s timer
    assert run_until(lua, lambda: dev.fields[b"cloud_favs"] is not None)

    def last(path):
        val = None
        for i in range(1, len(dev.events) + 1):
            if dev.events[i].path == path:
                val = dev.events[i].arg
        return val
    assert run_until(lua, lambda: last(b"favorites:cap.mode.supportedModes") is not None and
                     list(last(b"favorites:cap.mode.supportedModes").values()) == [b"Idle", b"Whole home", b"Kamer", b"Hele keuken"])
    lua.execute(b'DRIVER.capability_handlers.mode.setMode(DRIVER_OBJ, DEVICES[1], {component="favorites", args={mode="Hele keuken"}})')
    assert run_until(lua, lambda: robot.payloads and robot.payloads[-1].get("regions") == [{"region_id": "7", "type": "rid"}])
    assert "user_pmapv_id" not in robot.payloads[-1] or robot.payloads[-1]["user_pmapv_id"] == "V2"
    assert run_until(lua, lambda: last(b"favorites:cap.mode.mode") == b"Hele keuken")
    # Refresh asks the bridge to fetch again
    lua.execute(b"DRIVER.capability_handlers.refresh.refresh(DRIVER_OBJ, DEVICES[1])")
    assert run_until(lua, lambda: any("refresh=1" in c for c in calls))
