-- Certificate pinning for LAN devices with a self-signed certificate (trust on first use).
-- The first connection that carries a secret (token, API key, password) remembers the certificate's SHA-256
-- fingerprint on the SmartThings device. Later, a different certificate means another device answers on that
-- address (or someone in between): the connection is refused before the secret is sent. Entering a new secret
-- trusts the certificate that answers next (for a replaced gateway or console).
local log = require "log"

local M = {}
M.lookup = nil -- function(host) -> SmartThings device that owns this host (set by init.lua)

local unsupported_logged = false
local ok_logged = {}

local function fnv(s)
  local h = 2166136261
  for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xffffffff end
  return string.format("%08x", h)
end

local why_off -- first reason fingerprints failed (for the log)

local function peer_cert(tls)
  for _, get in ipairs({
    function() return tls:getpeercertificate() end,
    function() return tls.inner_sock:getpeercertificate() end,
    function() return tls.sock:getpeercertificate() end,
  }) do
    local ok, cert = pcall(get)
    if ok and cert then return cert end
    if not ok and not why_off then why_off = tostring(cert) end
  end
end

function M.fingerprint(tls)
  local cert = peer_cert(tls)
  if not cert then return nil end
  local ok, fp = pcall(function() return cert:digest("sha256") end)
  if ok and type(fp) == "string" and #fp >= 32 then return fp:lower() end
  -- no digest(): hash the PEM text with the bundled SHA-512
  local okp, pem = pcall(function() return cert:pem() end)
  local oks, sha = pcall(require, "sha512")
  if okp and type(pem) == "string" and #pem > 100 and oks then
    return "sha512:" .. sha.hex(sha.sha512(pem)):sub(1, 64)
  end
  if not why_off then why_off = "digest: " .. tostring(fp) .. "; pem: " .. tostring(pem) end
  return nil
end

--- true when the connection may carry `secret`, else nil, reason. Without a secret nothing is checked.
function M.check(tls, host, secret, device)
  if not secret or secret == "" then return true end
  local okl, dev = true, device
  if not dev then okl, dev = pcall(function() return M.lookup and M.lookup(host) end) end
  if not okl or not dev then
    if not unsupported_logged then
      unsupported_logged = true
      log.info("[pin] no SmartThings device found for " .. tostring(host) .. ", not pinned (" .. tostring(dev) .. ")")
    end
    return true
  end
  local fp = M.fingerprint(tls)
  local pin = dev:get_field("cert_pin")
  if not fp then
    -- a certificate was pinned before: without a fingerprint now it cannot be checked, so the secret stays
    -- here (fail closed). Never pinned (this hub gives no fingerprints at all): nothing to compare with.
    if type(pin) == "table" and pin.fp then
      log.error("[pin] " .. tostring(dev.label) .. ": the certificate of " .. host .. " could not be read, secret NOT sent ("
        .. tostring(why_off) .. ")")
      return nil, "certificate of " .. host .. " could not be checked (secret not sent)"
    end
    if not unsupported_logged then
      unsupported_logged = true
      log.warn("[pin] certificate fingerprints are not available on this hub, the certificate is not pinned ("
        .. tostring(why_off) .. ")")
    end
    return true
  end
  local sid = fnv(secret)
  if type(pin) ~= "table" or pin.s ~= sid then
    dev:set_field("cert_pin", { fp = fp, s = sid }, { persist = true })
    log.info("[pin] " .. tostring(dev.label) .. ": certificate of " .. host .. " remembered (" .. fp:sub(1, 16) .. "...)")
    return true
  end
  if pin.fp == fp then
    if not ok_logged[dev.id or dev] then
      ok_logged[dev.id or dev] = true
      log.info("[pin] " .. tostring(dev.label) .. ": certificate of " .. host .. " matches (" .. fp:sub(1, 16) .. "...)")
    end
    return true
  end
  log.error("[pin] " .. tostring(dev.label) .. ": certificate of " .. host .. " changed, secret NOT sent. "
    .. "Replaced the device? Enter the key/token again to trust the new certificate.")
  return nil, "certificate of " .. host .. " changed (secret not sent)"
end

return M
