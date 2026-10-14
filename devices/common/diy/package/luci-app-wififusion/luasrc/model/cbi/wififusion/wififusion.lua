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
o.placeholder = translate("留空 = 开放网络（不加密）")

o = s:option(ListValue, "encryption", translate("加密方式"))
o:value("psk2", "WPA2-PSK（兼容性最好）")
o:value("sae-mixed", "WPA2/WPA3 混合（推荐，新设备更安全）")
o:value("sae", "WPA3-SAE（仅新设备）")
o:value("none", "不加密（开放网络，密码留空时自动选择）")
o.default = "psk2"

m.on_after_commit = function()
	sys.call("/etc/init.d/wififusion restart >/dev/null 2>&1")
end


-- usteer 主动漫游（AP 端信号阈值引导，双击同一 SSID 下的终端主动调度频段）
s2 = m:section(NamedSection, "config", "wififusion", translate("主动漫游增强（usteer）"),
	translate("终端被动漫游之外的 AP 主动调度：持续监测每个终端信号，达标即引导上 5G，过弱则引导回 2.4G 或剔除重连。"))
s2.addremove = false

o = s2:option(Flag, "usteer_enabled", translate("启用主动漫游"))
o.rmempty = false

o = s2:option(Value, "steer_interval", translate("引导检测间隔（毫秒）"))
o.datatype = "and(uinteger,min(5000),max(300000))"
o.placeholder = "30000"
o.description = translate("每隔多久评估一次是否把终端引导到 5G（默认 30 秒）")

o = s2:option(Value, "steer_min_signal", translate("上行 5G 信号阈值（dBm）"))
o.datatype = "range(-90, -30)"
o.placeholder = "-60"
o.description = translate("终端在 5G 上能稳定维持的最低信号，高于此值才引导上 5G（防反复横跳）")

o = s2:option(Value, "kick_min_signal", translate("弱信号剔除阈值（dBm）"))
o.datatype = "range(-95, -40)"
o.placeholder = "-75"
o.description = translate("信号低于此值的终端将被剔除促其重连到更好频段")
return m
