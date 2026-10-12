local sys = require("luci.sys")
local m, s, o

m = Map("wififusion", translate("WiFi 双频合一"),
	translate("将 2.4G 与 5G 两个无线网络合并为同一个 SSID，并通过 802.11k/v 协议让设备自动在两个频段间漫游（近走 5G 高速、远落 2.4G 稳连接）。"))

s = m:section(NamedSection, "config", "wififusion", translate("融合设置"))
s.addremove = false

o = s:option(Flag, "enabled", translate("启用双频合一"))
o.rmempty = false

o = s:option(Value, "ssid", translate("统一 SSID"))
o.datatype = "maxlength(32)"
o.placeholder = "Kwrt"

o = s:option(Value, "key", translate("统一密码"))
o.datatype = "wpakey"

o = s:option(ListValue, "encryption", translate("加密方式"))
o:value("psk2", "WPA2-PSK（兼容性最好）")
o:value("sae-mixed", "WPA2/WPA3 混合（推荐，新设备更安全）")
o:value("sae", "WPA3-SAE（仅新设备）")
o.default = "psk2"

m.on_after_commit = function()
	sys.call("/etc/init.d/wififusion restart >/dev/null 2>&1")
end

return m
