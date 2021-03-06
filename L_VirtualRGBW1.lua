------------------------------------------------------------------------
-- Copyright (c) 2020-2021 Daniele Bochicchio
-- License: MIT License
-- Source Code: https://github.com/dbochicchio/Vera-VirtualDevices
------------------------------------------------------------------------

module("L_VirtualRGBW1", package.seeall)

local _PLUGIN_NAME = "VirtualRGBW"
local _PLUGIN_VERSION = "2.40"

local debugMode = false

local MYSID									= "urn:bochicchio-com:serviceId:VirtualRGBW1"
local SWITCHSID								= "urn:upnp-org:serviceId:SwitchPower1"
local DIMMERSID								= "urn:upnp-org:serviceId:Dimming1"
local COLORSID								= "urn:micasaverde-com:serviceId:Color1"
local HASID									= "urn:micasaverde-com:serviceId:HaDevice1"

local COMMANDS_SETPOWER						= "SetPowerURL"
local COMMANDS_SETPOWEROFF					= "SetPowerOffURL"
local COMMANDS_SETBRIGHTNESS				= "SetBrightnessURL"
local COMMANDS_SETRGBCOLOR					= "SetRGBColorURL"
local COMMANDS_SETWHITETEMPERATURE			= "SetWhiteTemperatureURL"
local COMMANDS_TOGGLE						= "SetToggleURL"
local DEFAULT_ENDPOINT						= "http://"

local function dump(t, seen)
	if t == nil then return "nil" end
	if seen == nil then seen = {} end
	local sep = ""
	local str = "{ "
	for k, v in pairs(t) do
		local val
		if type(v) == "table" then
			if seen[v] then
				val = "(recursion)"
			else
				seen[v] = true
				val = dump(v, seen)
			end
		elseif type(v) == "string" then
			if #v > 255 then
				val = string.format("%q", v:sub(1, 252) .. "...")
			else
				val = string.format("%q", v)
			end
		elseif type(v) == "number" and (math.abs(v - os.time()) <= 86400) then
			val = tostring(v) .. "(" .. os.date("%x.%X", v) .. ")"
		else
			val = tostring(v)
		end
		str = str .. sep .. k .. "=" .. val
		sep = ", "
	end
	str = str .. " }"
	return str
end

local function getVarNumeric(sid, name, dflt, devNum)
	local s = luup.variable_get(sid, name, devNum) or ""
	if s == "" then return dflt end
	s = tonumber(s)
	return (s == nil) and dflt or s
end

local function getVar(sid, name, dflt, devNum)
	local s = luup.variable_get(sid, name, devNum) or ""
	if s == "" then return dflt end
	return (s == nil) and dflt or s
end

local function L(devNum, msg, ...) -- luacheck: ignore 212
	local str = (_PLUGIN_NAME .. "[" .. _PLUGIN_VERSION .. "]@" .. tostring(devNum))
	local level = 50
	if type(msg) == "table" then
		str = str .. tostring(msg.prefix or _PLUGIN_NAME) .. ": " .. tostring(msg.msg)
		level = msg.level or level
	else
		str = str .. ": " .. tostring(msg)
	end
	str = string.gsub(str, "%%(%d+)", function(n)
		n = tonumber(n, 10)
		if n < 1 or n > #arg then return "nil" end
		local val = arg[n]
		if type(val) == "table" then
			return dump(val)
		elseif type(val) == "string" then
			return string.format("%q", val)
		elseif type(val) == "number" and math.abs(val - os.time()) <= 86400 then
			return tostring(val) .. "(" .. os.date("%x.%X", val) .. ")"
		end
		return tostring(val)
	end)
	luup.log(str, level)
end

local function D(devNum, msg, ...)
	debugMode = getVarNumeric(MYSID, "DebugMode", 0, devNum) == 1

	if debugMode then
		local t = debug.getinfo(2)
		local pfx = "(" .. tostring(t.name) .. "@" .. tostring(t.currentline) .. ")"
		L(devNum, {msg = msg, prefix = pfx}, ...)
	end
end

-- Set variable, only if value has changed.
local function setVar(sid, name, val, devNum)
	val = (val == nil) and "" or tostring(val)
	local s = luup.variable_get(sid, name, devNum) or ""
	D(devNum, "setVar(%1,%2,%3,%4) old value %5", sid, name, val, devNum, s)
	if s ~= val then
		luup.variable_set(sid, name, val, devNum)
		return true, s
	end
	return false, s
end

local function split(str, sep)
	if sep == nil then sep = "," end
	local arr = {}
	if #(str or "") == 0 then return arr, 0 end
	local rest = string.gsub(str or "", "([^" .. sep .. "]*)" .. sep,
		function(m)
			table.insert(arr, m)
			return ""
		end)
	table.insert(arr, rest)
	return arr, #arr
end

local function trim(s)
	if s == nil then return "" end
	if type(s) ~= "string" then s = tostring(s) end
	local from = s:match "^%s*()"
	return from > #s and "" or s:match(".*%S", from)
end

-- Array to map, where f(elem) returns key[,value]
local function map(arr, f, res)
	res = res or {}
	for ix, x in ipairs(arr) do
		if f then
			local k, v = f(x, ix)
			res[k] = (v == nil) and x or v
		else
			res[x] = x
		end
	end
	return res
end

local function initVar(sid, name, dflt, devNum)
	local currVal = luup.variable_get(sid, name, devNum)
	if currVal == nil then
		luup.variable_set(sid, name, tostring(dflt), devNum)
		return tostring(dflt)
	end
	return currVal
end

local function getChildren(masterID)
	local children = {}
	for k, v in pairs(luup.devices) do
		if tonumber(v.device_num_parent) == masterID then
			D(masterID, "Child found: %1", k)
			table.insert(children, k)
		end
	end

	table.insert(children, masterID)
	return children
end

function httpGet(devNum, url, onSuccess)
	local useCurl = url:lower():find("^curl://")
	local ltn12 = require("ltn12")
	local _, async = pcall(require, "http_async")
	local response_body = {}
	
	D(devNum, "httpGet(%1)", useCurl and "curl" or type(async) == "table" and "async" or "sync")

	-- curl
	if useCurl then
		local randommName = tostring(math.random(os.time()))
		local fileName = "/tmp/httpcall" .. randommName:gsub("%s+", "") ..".dat" 
		-- remove file
		os.execute('/bin/rm ' .. fileName)

		local httpCmd = string.format("curl -o '%s' %s", fileName, url:gsub("^curl://", ""))
		local res, err = os.execute(httpCmd)

		if res ~= 0 then
			D(devNum, "[HttpGet] CURL failed: %1 %2: %3", res, err, httpCmd)
			return false, nil
		else
			local file, err = io.open(fileName, "r")
			if not file then
				D(devNum, "[HttpGet] Cannot read response file: %1 - %2", fileName, err)

				os.execute('/bin/rm ' .. fileName)
				return false, nil
			end

			response_body = file:read('*all')
			file:close()

			D(devNum, "[HttpGet] %1 - %2", httpCmd, (response_body or ""))
			os.execute('/bin/rm ' .. fileName)

			if onSuccess ~= nil then
				D(devNum, "httpGet: onSuccess(%1)", status)
				onSuccess(response_body)
			end
			return true, response_body
		end

	-- async
	elseif type(async) == "table" then
		-- Async Handler for HTTP or HTTPS
		async.request(
		{
			method = "GET",
			url = url,
			headers = {
				["Content-Type"] = "application/json; charset=utf-8",
				["Connection"] = "keep-alive"
			},
			sink = ltn12.sink.table(response_body)
		},
		function (response, status, headers, statusline)
			D(devNum, "httpGet.Async(%1, %2, %3, %4)", url, (response or ""), (status or "-1"), table.concat(response_body or ""))

			status = tonumber(status or 100)

			if onSuccess ~= nil and status >= 200 and status < 400 then
				D(devNum, "httpGet: onSuccess(%1)", status)
				onSuccess(table.concat(response_body or ""))
			end
		end)

		return true, "" -- async requests are considered good unless they"re not
	else
		-- Sync Handler for HTTP or HTTPS
		local requestor = url:lower():find("^https:") and require("ssl.https") or require("socket.http")
		local response, status, headers = requestor.request{
			method = "GET",
			url = url,
			headers = {
				["Content-Type"] = "application/json; charset=utf-8",
				["Connection"] = "keep-alive"
			},
			sink = ltn12.sink.table(response_body)
		}

		D(devNum, "httpGet(%1, %2, %3, %4)", url, (response or ""), (status or "-1"), table.concat(response_body or ""))

		status = tonumber(status or 100)

		if status >= 200 and status < 400 then
			if onSuccess ~= nil then
				D(devNum, "httpGet: onSuccess(%1)", status)
				onSuccess(table.concat(response_body or ""))
			end

			return true, tostring(table.concat(response_body or ""))
		else
			return false, nil
		end
	end
end

local function sendDeviceCommand(cmd, params, devNum, onSuccess)
	D(devNum, "sendDeviceCommand(%1,%2,%3)", cmd, params, devNum)

	local pv = {}
	if type(params) == "table" then
		for k, v in ipairs(params) do
			if type(v) == "string" then
				pv[k] = v
			else
				pv[k] = tostring(v)
			end
		end
	elseif type(params) == "string" then
		table.insert(pv, params)
	elseif params ~= nil then
		table.insert(pv, tostring(params))
	end
	local pstr = table.concat(pv, ",")

	local cmdUrl = getVar(MYSID, cmd, DEFAULT_ENDPOINT, devNum)
	if (cmdUrl ~= DEFAULT_ENDPOINT) then
		local urls = split(cmdUrl, "\n")
		for _, url in pairs(urls) do
			D(devNum, "sendDeviceCommand.url(%1)", url)
			if #trim(url) > 0 then
				httpGet(devNum, string.format(url, pstr), onSuccess)
			end
		end
	end

	return false
end

local function restoreBrightness(devNum)
	-- Restore brightness
	local brightness = getVarNumeric(DIMMERSID, "LoadLevelLast", 0, devNum)
	local brightnessCurrent = getVarNumeric(DIMMERSID, "LoadLevelStatus", 0, devNum)

	if brightness > 0 and brightnessCurrent ~= brightness then
		setVar(DIMMERSID, "LoadLevelTarget", brightness, devNum)
		setVar(DIMMERSID, "LoadLevelLast", brightness, devNum)

		sendDeviceCommand(COMMANDS_SETBRIGHTNESS, brightness, devNum, function()
			setVar(DIMMERSID, "LoadLevelStatus", brightness, devNum)
		end)
	end
end

function actionPower(devNum, status)
	D(devNum, "actionPower(%1,%2)", devNum, status)

	-- Switch on/off
	if type(status) == "string" then
		status = (tonumber(status) or 0) ~= 0
	elseif type(status) == "number" then
		status = status ~= 0
	end

	setVar(SWITCHSID, "Target", status and "1" or "0", devNum)
	
	-- UI needs LoadLevelTarget/Status to comport with status according to Vera's rules
	if not status then
		setVar(DIMMERSID, "LoadLevelTarget", 0, devNum)
		setVar(DIMMERSID, "LoadLevelStatus", 0, devNum)

		sendDeviceCommand(COMMANDS_SETPOWEROFF, "off", devNum, function()
			setVar(SWITCHSID, "Status", status and "1" or "0", devNum)
		end)
	else
		sendDeviceCommand(COMMANDS_SETPOWER, "on", devNum, function()
			setVar(SWITCHSID, "Status", status and "1" or "0", devNum)
			restoreBrightness(devNum)
		end)
	end
end

function actionBrightness(devNum, newVal)
	D(devNum, "actionBrightness(%1,%2)", devNum, newVal)

	-- Dimming level change
	newVal = tonumber(newVal) or 100
	if newVal < 0 then
		newVal = 0
	elseif newVal > 100 then
		newVal = 100
	end -- range

	setVar(DIMMERSID, "LoadLevelTarget", newVal, devNum)

	if newVal > 0 then
		-- Level > 0, if light is off, turn it on.
		local status = getVarNumeric(SWITCHSID, "Status", 0, devNum)
		if status == 0 then
			setVar(SWITCHSID, "Target", 1, devNum)
			sendDeviceCommand(COMMANDS_SETPOWER, "on", devNum, function()
				setVar(SWITCHSID, "Status", 1, devNum)
			end)
		end
		sendDeviceCommand(COMMANDS_SETBRIGHTNESS, newVal, devNum, function()
			setVar(DIMMERSID, "LoadLevelStatus", newVal, devNum)
		end)
	elseif getVarNumeric(DIMMERSID, "AllowZeroLevel", 0, devNum) ~= 0 then
		-- Level 0 allowed as on status, just go with it.
		setVar(DIMMERSID, "LoadLevelStatus", newVal, devNum)
		sendDeviceCommand(COMMANDS_SETBRIGHTNESS, 0, devNum, function()
			setVar(DIMMERSID, "LoadLevelStatus", newVal, devNum)
		end)
	else
		setVar(SWITCHSID, "Target", 0, devNum)

		-- Level 0 (not allowed as an "on" status), switch light off.
		sendDeviceCommand(COMMANDS_SETPOWEROFF, "off", devNum, function()
			setVar(SWITCHSID, "Status", 0, devNum)
			setVar(DIMMERSID, "LoadLevelStatus", 0, devNum)
		end)
	end

	if newVal > 0 then setVar(DIMMERSID, "LoadLevelLast", newVal, devNum) end
end

-- Approximate RGB from color temperature. We don't both with most of the algorithm
-- linked below because the lower limit is 2000 (Vera) and the upper is 6500 (Yeelight).
-- We're also not going nuts with precision, since the only reason we're doing this is
-- to make the color spot on the UI look somewhat sensible when in temperature mode.
-- Ref: https://www.tannerhelland.com/4435/convert-temperature-rgb-algorithm-code/
local function approximateRGB(t)
	local function bound(v)
		if v < 0 then
			v = 0
		elseif v > 255 then
			v = 255
		end
		return math.floor(v)
	end
	local r, g, b = 255
	t = t / 100
	g = bound(99.471 * math.log(t) - 161.120)
	b = bound(138.518 * math.log(t - 10) - 305.048)
	return r, g, b
end

local function updateColor(devNum, w, c, r, g, b)
	local targetColor = string.format("0=%d,1=%d,2=%d,3=%d,4=%d", w, c, r, g, b)
	D(devNum, "updateColor(%1,%2)", device, targetColor)
	setVar(COLORSID, "CurrentColor", targetColor, devNum)
end

function actionSetColor(devNum, newVal, sendToDevice)
	D(devNum, "actionSetColor(%1,%2,%3)", devNum, newVal, sendToDevice)

	newVal = newVal or ""

	local status = getVarNumeric(SWITCHSID, "Status", 0, devNum)
	local turnOnBeforeDim = getVarNumeric(DIMMERSID, "TurnOnBeforeDim", 0, devNum)
	
	if status == 0 and turnOnBeforeDim == 1 and sendToDevice then
		setVar(SWITCHSID, "Target", 1, devNum)
		sendDeviceCommand(COMMANDS_SETPOWER, "on", devNum, function()
			setVar(SWITCHSID, "Status", 1, devNum)
		end)
	end
	local w, c, r, g, b

	local s = split(newVal, ",")

	if (#newVal == 6 or #newVal == 7) and #s == 1 then
		-- #RRGGBB or RRGGBB
		local startIndex = #newVal == 7 and 2 or 1
		r = tonumber(string.sub(newVal, startIndex, 2), 16) or 0
		g = tonumber(string.sub(newVal, startIndex+2, startIndex+3), 16) or 0
		b = tonumber(string.sub(newVal, startIndex+4, startIndex+5), 16) or 0
		w, c = 0, 0
		
		D(devNum, "actionSetColor.RGBFromHex(%1,%2,%3)", r, g, b)

		if r ~= nil and g  ~= nil and  b ~= nil and sendToDevice then
			sendDeviceCommand(COMMANDS_SETRGBCOLOR, {r, g, b}, devNum, function()
				updateColor(devNum, w, c, r, g, b)
			end)
		end

		restoreBrightness(devNum)
	elseif #s == 3 or #s == 5 then
		-- R,G,B -- handle both 255,0,255 OR R255,G0,B255 value
		-- also handle W0,D0,R255,G0,B255

		local startIndex = #s == 5 and 2 or 0
		r = tonumber(s[startIndex+1]) or tonumber(string.sub(s[startIndex+1], 2))
		g = tonumber(s[startIndex+2]) or tonumber(string.sub(s[startIndex+2], 2))
		b = tonumber(s[startIndex+3]) or tonumber(string.sub(s[startIndex+3], 2))
		w, c = 0, 0
		D(devNum, "actionSetColor.RGB(%1,%2,%3)", r, g, b)
		
		if r ~= nil and g  ~= nil and  b ~= nil and sendToDevice then
			sendDeviceCommand(COMMANDS_SETRGBCOLOR, {r, g, b}, devNum, function()
				updateColor(devNum, w, c, r, g, b)
			end)
		end

		restoreBrightness(devNum)
	else
		-- Wnnn, Dnnn (color range)
		local tempMin = getVarNumeric(MYSID, "MinTemperature", 1600, devNum)
		local tempMax = getVarNumeric(MYSID, "MaxTemperature", 6500, devNum)
		local filteredVal = newVal:gsub("W255", ""):gsub("D255", "") -- handle both
		local code, temp = filteredVal:upper():match("([WD])(%d+)")
		local t
		if code == "W" then
			t = tonumber(temp) or 128
			temp = 2000 + math.floor(t * 3500 / 255)
			if temp < tempMin then
				temp = tempMin
			elseif temp > tempMax then
				temp = tempMax
			end
			w = t
			c = 0
		elseif code == "D" then
			t = tonumber(temp) or 128
			temp = 5500 + math.floor(t * 3500 / 255)
			if temp < tempMin then
				temp = tempMin
			elseif temp > tempMax then
				temp = tempMax
			end
			c = t
			w = 0
		elseif code == nil then
			-- Try to evaluate as integer (2000-9000K)
			temp = tonumber(newVal) or 2700
			if temp < tempMin then
				temp = tempMin
			elseif temp > tempMax then
				temp = tempMax
			end
			if temp <= 5500 then
				if temp < 2000 then temp = 2000 end -- enforce Vera min
				w = math.floor((temp - 2000) / 3500 * 255)
				c = 0
				--targetColor = string.format("W%d", w)
			elseif temp > 5500 then
				if temp > 9000 then temp = 9000 end -- enforce Vera max
				c = math.floor((temp - 5500) / 3500 * 255)
				w = 0
				--targetColor = string.format("D%d", c)
			else
				L(devNum, "Unable to set color, target value %1 invalid", newVal)
				return
			end
		end

		r, g, b = approximateRGB(temp)

		D(devNum, "actionSetColor.whiteTemp(%1,%2,%3)", w, c, temp)

		if sendToDevice then
			sendDeviceCommand(COMMANDS_SETWHITETEMPERATURE, temp, devNum, function()
				updateColor(devNum, w, c, r, g, b)
			end)
		else
			updateColor(devNum, w, c, r, g, b)
		end
		restoreBrightness(devNum)

		D(devNum, "aprox RGB(%1,%2,%3)", r, g, b)
	end

	local targetColor = string.format("0=%d,1=%d,2=%d,3=%d,4=%d", w, c, r, g, b)
	setVar(COLORSID, "TargetColor", targetColor, devNum)
end

-- Toggle status
function actionToggleState(devNum)
	local cmdUrl = getVar(MYSID, COMMANDS_TOGGLE, DEFAULT_ENDPOINT, devNum)

	local status = getVarNumeric(SWITCHSID, "Status", 0, devNum)

	if (cmdUrl == DEFAULT_ENDPOINT or cmdUrl == "") then
		-- toggle by using the current status
		actionPower(devNum, status == 1 and 0 or 1)
	else
		-- update variables
		setVar(SWITCHSID, "Target", status == 1 and 0 or 1, devNum)

		-- toggle command specifically defined
		sendDeviceCommand(COMMANDS_TOGGLE, nil, devNum, function()
			setVar(SWITCHSID, "Status", status == 1 and 0 or 1, devNum)
		end)
	end
end

function startPlugin(devNum)
	L(devNum, "Plugin starting")

	-- enumerate children
	local children = getChildren(devNum)
	for k, deviceID in pairs(children) do
		L(devNum, "Plugin start: child #%1 - %2", deviceID, luup.devices[deviceID].description)

		-- generic init
		initVar(MYSID, "DebugMode", 0, deviceID)
		initVar(SWITCHSID, "Target", "0", deviceID)
		initVar(SWITCHSID, "Status", "0", deviceID)

		initVar(DIMMERSID, "LoadLevelTarget", "0", deviceID)
		initVar(DIMMERSID, "LoadLevelStatus", "0", deviceID)
		initVar(DIMMERSID ,"LoadLevelLast", "100", deviceID)
		initVar(DIMMERSID, "TurnOnBeforeDim", "1", deviceID)
		initVar(DIMMERSID, "AllowZeroLevel", "0", deviceID)

		initVar(COLORSID, "TargetColor", "0=51,1=0,2=0,3=0,4=0", deviceID)
		initVar(COLORSID, "CurrentColor", "", deviceID)
		initVar(COLORSID, "SupportedColors", "W,D,R,G,B", deviceID)

		-- TODO: white mode scale?
		initVar(MYSID, "MinTemperature", "2000", deviceID)
		initVar(MYSID, "MaxTemperature", "6500", deviceID)

		initVar(MYSID, COMMANDS_SETBRIGHTNESS, DEFAULT_ENDPOINT, deviceID)
		initVar(MYSID, COMMANDS_SETWHITETEMPERATURE, DEFAULT_ENDPOINT, deviceID)
		initVar(MYSID, COMMANDS_SETRGBCOLOR, DEFAULT_ENDPOINT, deviceID)

		local commandPower = initVar(MYSID, COMMANDS_SETPOWER, DEFAULT_ENDPOINT, deviceID)

		-- upgrade code to support power off command
		initVar(MYSID, COMMANDS_SETPOWEROFF, commandPower, deviceID)

		-- device categories
		local category_num = luup.attr_get("category_num", deviceID) or 0
		if category_num == 0 then
			luup.attr_set("category_num", "2", deviceID)
			luup.attr_set("subcategory_num", "4", deviceID)
		end

		setVar(HASID, "Configured", 1, deviceID)
		setVar(HASID, "CommFailure", 0, deviceID)
		
		-- status
		luup.set_failure(0, deviceID)

		D(devNum, "Plugin start (completed): child #%1", deviceID)
	end

	return true, "Ready", _PLUGIN_NAME
end