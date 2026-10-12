module("luci.controller.wififusion", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/wififusion") then
		nixio.fs.writefile("/etc/config/wififusion",
			"config wififusion 'config'\n\toption enabled '0'\n\toption ssid ''\n\toption key ''\n\toption encryption 'psk2'\n")
	end
	entry({"admin", "network", "wififusion"}, cbi("wififusion/wififusion"), _("WiFi 双频合一"), 81).dependent = false
end
