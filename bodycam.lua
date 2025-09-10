---@diagnostic disable: undefined-global, assign-type-mismatch, cast-local-type
script_name('avocado - bodycam')
script_author('whynotban and constersuonsis')
script_version('0.0.6')

require('lib.moonloader')
local imgui = require('mimgui')
local inicfg = require('inicfg')
local vkeys = require('vkeys')
local json = require('cjson')
local effil = require('effil')
local samp = require('lib.samp.events')
local fa = require('fAwesome6_solid')
local encoding = require('encoding')
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local wm = require('lib.windows.message')

local FULL_CONFIG_DIR = 'moonloader/config/bodycam'
local INICFG_RELATIVE_PATH = 'bodycam/config.ini'
local STATS_FILE = FULL_CONFIG_DIR .. '/stats.json'
local sw, sh = getScreenResolution()

if not doesDirectoryExist(FULL_CONFIG_DIR) then
    createDirectory(FULL_CONFIG_DIR)
end

local config = inicfg.load({
    main = {
        toggleKey = vkeys.VK_F2,
        displayMode = 1,
        collectStats = true,
        posX = sw - 215,
        posY = sh - 85
    },
    update_config = {
        json_url = "https://raw.githubusercontent.com/whynotban/avocado-bodycam/master/version.json",
        project_url = "https://github.com/qrlk/moonloader-script-updater/",
        prefix = "[" .. string.upper(thisScript().name) .. "]: "
    }
}, INICFG_RELATIVE_PATH)

local settings = {
    displayMode = imgui.new.int(config.main.displayMode - 1),
    collectStats = imgui.new.bool(config.main.collectStats)
}

local stats = {}
local uid = 'N/A'
local isRecording = false
local recordingStartTime = 0
local recordingStartDateStr = ''
local isWaitingForUid = false
local uidRequestTime = 0
local isPositioningMode = false
local showSettings = imgui.new.bool(false)
local isWaitingForKeybind = false
local windowAlpha = 0.0
local animationStartTime = 0
local ANIMATION_DURATION = 0.3
local updateInfo = { version = '', url = '' }
local displayModes = { u8('Анимированный'), u8('Статичный') }
local displayModes_c = imgui.new['const char*'][#displayModes](displayModes)
local keyNames = {}
for name, code in pairs(vkeys) do keyNames[code] = name:gsub('VK_', '') end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    fa.Init(16)
end)

local function asyncHttpRequest(method, url, args, resolve, reject)
    local request_thread = effil.thread(function(method, url, args)
        local requests = require('requests')
        local result, response = pcall(requests.request, method, url, args)
        if result then
            response.json, response.xml = nil, nil
            return true, response
        else
            return false, response
        end
    end)(method, url, args)
    resolve = resolve or function() end
    reject = reject or function() end
    lua_thread.create(function()
        local runner = request_thread
        while true do
            local status, err = runner:status()
            if not err then
                if status == 'completed' then
                    local result, response = runner:get()
                    if result then resolve(response) else reject(response) end
                    return
                elseif status == 'canceled' then
                    return reject(status)
                end
            else
                return reject(err)
            end
            wait(0)
        end
    end)
end

local function isVersionNewer(onlineVersion, currentVersion)
    local onlineParts, currentParts = {}, {}
    for part in onlineVersion:gmatch("([%d]+)") do table.insert(onlineParts, tonumber(part)) end
    for part in currentVersion:gmatch("([%d]+)") do table.insert(currentParts, tonumber(part)) end
    for i = 1, math.max(#onlineParts, #currentParts) do
        local online = onlineParts[i] or 0
        local current = currentParts[i] or 0
        if online > current then return true end
        if online < current then return false end
    end
    return false
end

local function startUpdateDownload()
    asyncHttpRequest('GET', updateInfo.url, { redirect = true },
        function(response_file)
            if response_file.status_code == 200 then
                local file = io.open(thisScript().path, "w")
                if file then
                    showCursor(false)
                    file:write(u8:decode(response_file.text))
                    file:close()
                    thisScript():reload()
                end
            end
        end
    )
end

local function checkForUpdate()
    asyncHttpRequest('GET', config.update_config.json_url, nil,
        function(response)
            if response.status_code == 200 then
                local success, data = pcall(json.decode, response.text)
                if success and type(data) == "table" then
                    if data.latest and data.latest ~= thisScript().version then
                        updateInfo.version = data.latest
                        updateInfo.url = data.updateurl
                        print("Установка обновления...(v.".. thisScript().version ..")")
                        if #updateInfo.url > 0 then startUpdateDownload() end
                    else
                        print("Обновление не требуется.(v.".. thisScript().version ..")")
                    end
                end
            end
        end
    )
end

local function saveConfig()
    config.main.displayMode = settings.displayMode[0] + 1
    config.main.collectStats = settings.collectStats[0]
    inicfg.save(config, INICFG_RELATIVE_PATH)
end

local function saveStats()
    local year_ago_timestamp = os.time() - (365 * 24 * 60 * 60)
    for date_str, recordings in pairs(stats) do
        local year, month, day = date_str:match('(%d+)-(%d+)-(%d+)')
        if year and month and day and os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day) }) < year_ago_timestamp then
            stats[date_str] = nil
        end
    end
    pcall(function()
        local file = io.open(STATS_FILE, 'w')
        if file then
            file:write(json.encode(stats))
            file:close()
        end
    end)
end

local function loadStats()
    if doesFileExist(STATS_FILE) then
        local file = io.open(STATS_FILE, 'r')
        if file then
            local data = file:read('*a')
            file:close()
            local success, result = pcall(json.decode, data)
            stats = (success and type(result) == 'table') and result or {}
        end
    else
        stats = {}
    end
end

local function addRecordingToStats(startTime, duration)
    if not config.main.collectStats then return end
    local date_str = os.date('%Y-%m-%d', startTime)
    if not stats[date_str] then stats[date_str] = {} end
    table.insert(stats[date_str], { start_time = startTime, duration_seconds = duration })
    saveStats()
end

local function triggerUidFetch()
    local _, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    local nick = sampGetPlayerNickname(id)
    if nick then
        isWaitingForUid = true
        uidRequestTime = os.time()
        sampSendChat('/id ' .. nick)
    else
        sampAddChatMessage('{808080}[Bodycam]: {FF0000}Не удалось получить ваш никнейм.', -1)
    end
end

local function toggleRecording()
    isRecording = not isRecording
    animationStartTime = os.clock()
    if isRecording then
        recordingStartTime = os.time()
        recordingStartDateStr = os.date('%Y-%m-%d %H:%M:%S', recordingStartTime)
    else
        if recordingStartTime > 0 then
            addRecordingToStats(recordingStartTime, os.time() - recordingStartTime)
            recordingStartTime = 0
        end
    end
end

local function calculateAlpha()
    if config.main.displayMode == 2 then
        windowAlpha = 1.0
        return
    end
    local progress = (os.clock() - animationStartTime) / ANIMATION_DURATION
    progress = math.min(progress, 1.0)
    windowAlpha = isRecording and progress or (1.0 - progress)
end

function onWindowMessage(msg, wparam, lparam)
    if isPositioningMode then
        if msg == wm.WM_LBUTTONDOWN and wparam == vkeys.VK_LBUTTON then
            config.main.posX, config.main.posY = getCursorPos()
            saveConfig()
            isPositioningMode = false
            sampAddChatMessage('{808080}[Bodycam]: {00FF00}Позиция сохранена.', -1)
        elseif msg == wm.WM_KEYUP and wparam == vkeys.VK_ESCAPE then
            isPositioningMode = false
            sampAddChatMessage('{808080}[Bodycam]: {FFFF00}Изменение позиции отменено.', -1)
        end
    end
    if showSettings[0] and wparam == vkeys.VK_ESCAPE then
        if msg == wm.WM_KEYDOWN then consumeWindowMessage(true, false) end
        if msg == wm.WM_KEYUP then
            showSettings[0] = false
        end
    end
end

samp.onPlayerSpawn = function()
    lua_thread.create(function()
        wait(3000)
        triggerUidFetch()
    end)
end

samp.onServerMessage = function(color, text)
    if isWaitingForUid then
        local found_uid = text:match('UID:%s*(%d+)')
        if found_uid then
            uid = found_uid
            isWaitingForUid = false
            sampAddChatMessage('{808080}[Bodycam]: {FFFFFF}UID {00FF00}' .. uid .. '{FFFFFF} успешно получен.', -1)
            return false
        end
    end
end

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    loadStats()
    sampRegisterChatCommand('bcam', function() showSettings[0] = not showSettings[0] end)

    lua_thread.create(checkForUpdate)
    lua_thread.create(function() wait(5000); triggerUidFetch() end)

    while true do
        wait(0)
        if not isPauseMenuActive() and not sampIsChatInputActive() and not sampIsDialogActive() and not isPositioningMode then
            if isKeyJustPressed(config.main.toggleKey) and not showSettings[0] then
                toggleRecording()
            end
        end
        if isWaitingForKeybind then
            for i = 1, 255 do
                if isKeyJustPressed(i) then
                    if i ~= vkeys.VK_ESCAPE then
                        config.main.toggleKey = i
                        saveConfig()
                        local keyName = keyNames[i] or ('KEY_' .. i)
                        sampAddChatMessage('{808080}[Bodycam]: {FFFFFF}Новая клавиша: {00FF00}' .. keyName, -1)
                    else
                        sampAddChatMessage('{808080}[Bodycam]: {FFFFFF}Изменение отменено.', -1)
                    end
                    isWaitingForKeybind = false
                    break
                end
            end
        end
        if isWaitingForUid and os.time() - uidRequestTime > 5 then
            sampAddChatMessage('{808080}[Bodycam]: {FF0000}Таймаут ожидания UID.', -1)
            isWaitingForUid = false
        end
    end
end

local bodycamFrame = imgui.OnFrame(
    function()
        return ((config.main.displayMode == 2) or (isRecording or windowAlpha > 0) or isPositioningMode)
            and not isPauseMenuActive() and not sampIsChatInputActive() and not sampIsDialogActive()
    end,
    function(self)
        calculateAlpha()
        if windowAlpha <= 0 and not isPositioningMode then return end
        imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, isPositioningMode and 1.0 or windowAlpha)
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(8, 6))
        imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.06, 0.06, 0.06, 0.85))
        local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.AlwaysAutoResize
        local windowName = 'Bodycam Overlay'
        if isPositioningMode then
            windowName = windowName .. '##Positioning'
            imgui.SetNextWindowPos(imgui.ImVec2(getCursorPos()), imgui.Cond.Always)
        else
            flags = flags + imgui.WindowFlags.NoMove
            imgui.SetNextWindowPos(imgui.ImVec2(config.main.posX, config.main.posY), imgui.Cond.Always)
        end
        imgui.Begin(windowName, nil, flags)
        local drawList, wPos, wSize = imgui.GetWindowDrawList(), imgui.GetWindowPos(), imgui.GetWindowSize()
        local baseY = imgui.GetCursorPosY() + 2
        imgui.SetCursorPosY(baseY + 3); imgui.Text(fa.VIDEO); imgui.SameLine(); imgui.SetCursorPosY(baseY)
        imgui.Text('bodycam #' .. uid)
        local dotX, dotY = wPos.x + wSize.x - 12, wPos.y + (imgui.GetTextLineHeight() / 2) + 8
        if isRecording then
            if math.floor(os.clock() * 1.5) % 2 == 0 then
                drawList:AddCircleFilled(imgui.ImVec2(dotX, dotY), 5, 0xFF0000FF)
            end
            imgui.NewLine()
            imgui.Text('Rec from ' .. recordingStartDateStr)
            local elapsed = os.time() - recordingStartTime
            local h, m, s = math.floor(elapsed / 3600), math.floor((elapsed % 3600) / 60), elapsed % 60
            imgui.Text(string.format('%02d:%02d:%02d', h, m, s) .. u8(' с начала записи'))
        else
            drawList:AddCircleFilled(imgui.ImVec2(dotX, dotY), 5, 0xFF808080)
            imgui.NewLine()
            imgui.Text(u8('Запись неактивна'))
        end
        if isPositioningMode then
            imgui.NewLine()
            imgui.TextColored(imgui.ImVec4(1, 1, 0, 1), u8('--- РЕЖИМ ПЕРЕМЕЩЕНИЯ ---'))
            imgui.Text(u8('ЛКМ - сохранить, ESC - отмена'))
        end
        imgui.End()
        imgui.PopStyleColor(1)
        imgui.PopStyleVar(2)
    end
)

local settingsFrame = imgui.OnFrame(
    function() return showSettings[0] end,
    function(self)
        imgui.SetNextWindowSize(imgui.ImVec2(450, 0), imgui.Cond.FirstUseEver)
        imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.Begin(u8('Настройки Bodycam'), showSettings, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.AlwaysAutoResize)
        imgui.Text(u8('Основные настройки')); imgui.Separator()
        imgui.Text(u8('Клавиша активации: ') .. (keyNames[config.main.toggleKey] or '...'))
        if imgui.Button(isWaitingForKeybind and u8('Нажмите клавишу...') or u8('Изменить'), imgui.ImVec2(imgui.GetContentRegionAvail().x, 0)) then
            isWaitingForKeybind = not isWaitingForKeybind
        end
        if imgui.Button(u8('Изменить положение'), imgui.ImVec2(-1, 0)) then
            isPositioningMode = true; showSettings[0] = false
        end
        if imgui.Button(u8('Обновить UID'), imgui.ImVec2(-1, 0)) then triggerUidFetch() end
        imgui.Spacing()
        imgui.Text(u8('Режим отображения')); imgui.Separator()
        imgui.PushItemWidth(-1)
        if imgui.Combo('##displaymode', settings.displayMode, displayModes_c, #displayModes) then saveConfig() end
        imgui.PopItemWidth()
        imgui.Spacing()
        imgui.Text(u8('Данные')); imgui.Separator()
        if imgui.Checkbox(u8('Ведение статистики'), settings.collectStats) then saveConfig() end
        imgui.End()
    end
)
