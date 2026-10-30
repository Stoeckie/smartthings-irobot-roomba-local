-- Minimal MQTT 3.1.1 client, enough to talk to the local broker on a Roomba.
-- Works on any socket object with send(data) and receive(n) -> data | nil, err, partial and settimeout(t).
local M = {}

local function u16(n) return string.char((n >> 8) & 0xff, n & 0xff) end
local function str(s) return u16(#s) .. s end

local function varlen(n)
  local out = {}
  repeat
    local b = n % 128
    n = n // 128
    if n > 0 then b = b | 0x80 end
    out[#out + 1] = string.char(b)
  until n == 0
  return table.concat(out)
end

local function packet(first, body)
  return string.char(first) .. varlen(#body) .. body
end

function M.connect_packet(client_id, username, password, keepalive)
  local flags = 0x02 -- clean session
  if username then flags = flags | 0x80 end
  if password then flags = flags | 0x40 end
  local body = str("MQTT") .. string.char(4, flags) .. u16(keepalive or 60) .. str(client_id)
  if username then body = body .. str(username) end
  if password then body = body .. str(password) end
  return packet(0x10, body)
end

function M.subscribe_packet(packet_id, topic, qos)
  return packet(0x82, u16(packet_id) .. str(topic) .. string.char(qos or 0))
end

function M.publish_packet(topic, payload, qos, packet_id)
  qos = qos or 0
  local body = str(topic)
  if qos > 0 then body = body .. u16(packet_id or 1) end
  return packet(0x30 | (qos << 1), body .. payload)
end

function M.puback_packet(packet_id) return packet(0x40, u16(packet_id)) end
M.PINGREQ = string.char(0xC0, 0x00)
M.DISCONNECT = string.char(0xE0, 0x00)

M.CONNACK_ERRORS = {
  [1] = "unacceptable protocol version", [2] = "identifier rejected", [3] = "server unavailable",
  [4] = "bad username or password", [5] = "not authorised",
}

--- Parse one packet body. Returns a table {type=..., ...}.
function M.parse(first, body)
  local ptype = first >> 4
  if ptype == 2 then -- CONNACK
    return { type = "connack", rc = body:byte(2) or 255 }
  elseif ptype == 3 then -- PUBLISH
    local qos = (first >> 1) & 3
    local tlen = (body:byte(1) << 8) | body:byte(2)
    local topic = body:sub(3, 2 + tlen)
    local pos = 3 + tlen
    local pid
    if qos > 0 then
      pid = (body:byte(pos) << 8) | body:byte(pos + 1)
      pos = pos + 2
    end
    return { type = "publish", topic = topic, payload = body:sub(pos), qos = qos, packet_id = pid }
  elseif ptype == 9 then
    return { type = "suback" }
  elseif ptype == 13 then
    return { type = "pingresp" }
  elseif ptype == 4 then
    return { type = "puback" }
  end
  return { type = "other", code = ptype }
end

local Session = {}
Session.__index = Session

function M.new(sock) return setmetatable({ sock = sock, next_id = 1 }, Session) end

function Session:send(data)
  local i = 1
  while i <= #data do
    local n, err, last = self.sock:send(data, i)
    if not n then
      if (err == "timeout" or err == "wantwrite" or err == "wantread") and last and last >= i then
        i = last + 1
      else
        return nil, err
      end
    else
      i = n + 1
    end
  end
  return true
end

function Session:_exact(n, timeout)
  self.sock:settimeout(timeout)
  local buf = {}
  local got = 0
  while got < n do
    local data, err, partial = self.sock:receive(n - got)
    local chunk = data or partial
    if chunk and #chunk > 0 then
      buf[#buf + 1] = chunk
      got = got + #chunk
    end
    if not data then
      -- luasec reports an expired timeout on a TLS socket as "wantread" / "wantwrite"
      if err == "wantread" or err == "wantwrite" then err = "timeout" end
      if err ~= "timeout" or got == 0 then return nil, err end
      -- partial packet: keep reading
    end
  end
  return table.concat(buf)
end

--- Read one packet. `first_timeout` applies to the first byte only (nil = block); the rest of the
--- packet must arrive within `body_timeout`. Returns packet table, or nil, "timeout" / error.
function Session:read(first_timeout, body_timeout)
  local first, err = self:_exact(1, first_timeout)
  if not first then return nil, err end
  local mult, len = 1, 0
  for _ = 1, 4 do
    local b, e = self:_exact(1, body_timeout or 10)
    if not b then return nil, e end
    b = b:byte()
    len = len + (b & 0x7f) * mult
    if b & 0x80 == 0 then break end
    mult = mult * 128
  end
  local body = ""
  if len > 0 then
    body, err = self:_exact(len, body_timeout or 10)
    if not body then return nil, err end
  end
  return M.parse(first:byte(), body)
end

--- CONNECT and wait for CONNACK. Returns true or nil, err, rc.
function Session:connect(client_id, username, password, keepalive, timeout)
  local ok, err = self:send(M.connect_packet(client_id, username, password, keepalive))
  if not ok then return nil, err end
  local p, rerr = self:read(timeout or 10, timeout or 10)
  if not p then return nil, "no CONNACK: " .. tostring(rerr) end
  if p.type ~= "connack" then return nil, "expected CONNACK" end
  if p.rc ~= 0 then return nil, M.CONNACK_ERRORS[p.rc] or ("CONNACK " .. p.rc), p.rc end
  return true
end

function Session:subscribe(topic)
  local id = self.next_id
  self.next_id = id % 65535 + 1
  return self:send(M.subscribe_packet(id, topic, 0))
end

function Session:publish(topic, payload)
  return self:send(M.publish_packet(topic, payload, 0))
end

function Session:ping() return self:send(M.PINGREQ) end

function Session:ack(p)
  if p.type == "publish" and p.qos == 1 and p.packet_id then
    return self:send(M.puback_packet(p.packet_id))
  end
  return true
end

function Session:close()
  pcall(function() self.sock:send(M.DISCONNECT) end)
  pcall(function() self.sock:close() end)
end

return M
