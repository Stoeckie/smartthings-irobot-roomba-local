-- Network access for the driver, in one place so the tests can replace it.
local cosock = require "cosock"
local socket = cosock.socket

local M = {}
M.PORT = 8883
M.DISCOVERY_PORT = 5678

--- TLS connection to the robot (self-signed certificate, so no verification; LAN only).
function M.connect_tls(ip, port, timeout, secret)
  local ssl = require "cosock.ssl"
  local sock, err = socket.tcp()
  if not sock then return nil, "tcp: " .. tostring(err) end
  sock:settimeout(timeout or 10)
  local ok, cerr = sock:connect(ip, port or M.PORT)
  if not ok then
    sock:close()
    return nil, "connect: " .. tostring(cerr)
  end
  local tls, werr = ssl.wrap(sock, { mode = "client", protocol = "any", verify = "none", options = "all" })
  if not tls then
    sock:close()
    return nil, "tls: " .. tostring(werr)
  end
  local hs, herr = tls:dohandshake()
  if not hs then
    tls:close()
    return nil, "tls handshake: " .. tostring(herr)
  end
  local okp, perr = require("certpin").check(tls, ip, secret)
  if not okp then tls:close(); return nil, perr end
  return tls
end

--- Send "irobotmcs" to the broadcast address and every host of `prefix` (e.g. "192.168.2."),
--- collect replies for `window` seconds. Returns a list of {ip=..., data=...}.
function M.discover(prefix, window)
  local udp = socket.udp()
  udp:setsockname("*", 0)
  pcall(function() udp:setoption("broadcast", true) end)
  local msg = "irobotmcs"
  pcall(function() udp:sendto(msg, "255.255.255.255", M.DISCOVERY_PORT) end)
  if prefix then
    pcall(function() udp:sendto(msg, prefix .. "255", M.DISCOVERY_PORT) end)
    for i = 1, 254 do pcall(function() udp:sendto(msg, prefix .. i, M.DISCOVERY_PORT) end) end
  end
  local out = {}
  local deadline = socket.gettime() + (window or 4)
  while socket.gettime() < deadline do
    udp:settimeout(math.max(0.1, deadline - socket.gettime()))
    local data, ip = udp:receivefrom()
    if data and data ~= msg then out[#out + 1] = { ip = ip, data = data } end
  end
  udp:close()
  return out
end

--- Plain HTTP GET on the LAN (for a Stoeckie Bridge). Returns body or nil, err.
function M.http_get(ip, port, path, timeout)
  local http = cosock.asyncify "socket.http"
  local ltn12 = require "ltn12"
  local chunks = {}
  http.TIMEOUT = timeout or 5
  local ok, code = http.request({ url = string.format("http://%s:%d%s", ip, port, path),
                                  sink = ltn12.sink.table(chunks) })
  if not ok then return nil, tostring(code) end
  if code ~= 200 then return nil, "HTTP " .. tostring(code) end
  return table.concat(chunks)
end

function M.sleep(s) socket.sleep(s) end
function M.now() return socket.gettime() end

return M
