local json = dofile("_json_tmp.lua")
local f = io.open("E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/Mods/PBZFog/pbz_pporig.json","rb")
local raw = f:read("a"); f:close()
print(string.format("文件 %.0f KB", #raw/1024))
local t0=os.clock(); local d = json.decode(raw); local t1=os.clock()
print(string.format("decode  %.2f ms", (t1-t0)*1000))
local t2=os.clock(); local out = json.encode(d); local t3=os.clock()
print(string.format("encode  %.2f ms  -> %.0f KB", (t3-t2)*1000, #out/1024))
local s=0
for i=1,10 do local a=os.clock(); json.encode(d); s=s+(os.clock()-a) end
print(string.format("encode 均值 %.2f ms", s/10*1000))