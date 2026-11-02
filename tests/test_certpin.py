"""certpin: remember the certificate with the secret, refuse a changed one, trust again after a new secret."""
import pathlib
from lupa import lua53

SRC = str(pathlib.Path(__file__).resolve().parents[1] / "src")


def test_certpin():
    L = lua53.LuaRuntime()
    L.execute('package.path="' + SRC + '/?.lua;"..package.path')
    L.execute('''package.loaded["log"]={info=function() end, error=function() end}
pin=require "certpin"
DEV={fields={},label="GW"}
function DEV:get_field(k) return self.fields[k] end
function DEV:set_field(k,v) self.fields[k]=v end
pin.lookup=function(h) if h=="10.0.0.1" then return DEV end end
function TLS(fp) return {getpeercertificate=function() return {digest=function(_,a) return fp end} end} end
local fpa=string.rep("a",64); local fpb=string.rep("b",64)
R1=pin.check(TLS(fpa),"10.0.0.1","secret1")
R2=pin.check(TLS(fpa),"10.0.0.1","secret1")
R3=pin.check(TLS(fpb),"10.0.0.1","secret1")
R4=pin.check(TLS(fpb),"10.0.0.1","secret2")
R5=pin.check({getpeercertificate=function() error("no") end},"10.0.0.1","secret2")
''')
    g = L.globals()
    assert [g.R1, g.R2, g.R3, g.R4, g.R5] == [True, True, None, True, True]
