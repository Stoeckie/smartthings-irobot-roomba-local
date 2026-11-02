-- Certificate pinning for LAN devices with a self-signed certificate (trust on first use).
-- The first connection that carries a secret (token, API key, password) remembers the certificate's SHA-256
-- fingerprint on the SmartThings device. Later, a different certificate means another device answers on that
-- address (or someone in between): the connection is refused before the secret is sent. Entering a new secret
-- trusts the certificate that answers next (for a replaced gateway or console).
local log = require "log"

local M = {}
M.lookup = nil -- function(host) -> SmartThings device that owns this host (set by init.lua)

local unsupported_logged = false

local function fnv(s)
  local h = 2166136261
  for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xffffffff end
  return string.format("%08x", h)
end

function M.fingerprint(tls)
  local ok, fp = pcall(function()
    local cert = tls:getpeercertificate()
    return cert and cert:digest("sha256")
  end)
  if ok and type(fp) == "string" and #fp >= 32 then return fp:lower() end
  return nil
end

--- true when the connection may carry `secret`, else nil, reason. Without a secret nothing is checked.
function M.check(tls, host, secret)
  if not secret or secret == "" then return true end
  local dev = M.lookup and M.lookup(host)
  if not dev then return true end
  local fp = M.fingerprint(tls)
  if not fp then
    if not unsupported_logged then
      unsupported_logged = true
      log.info("[pin] certificate fingerprints are not available on this hub, pinning is off")
    end
    return true
  end
  local sid = fnv(secret)
  local pin = dev:get_field("cert_pin")
  if type(pin) ~= "table" or pin.s ~= sid then
    dev:set_field("cert_pin", { fp = fp, s = sid }, { persist = true })
    log.info("[pin] " .. tostring(dev.label) .. ": certificate of " .. host .. " remembered (" .. fp:sub(1, 16) .. "...)")
    return true
  end
  if pin.fp == fp then return true end
  log.error("[pin] " .. tostring(dev.label) .. ": certificate of " .. host .. " changed, secret NOT sent. "
    .. "Replaced the device? Enter the key/token again to trust the new certificate.")
  return nil, "certificate of " .. host .. " changed (secret not sent)"
end

return M
