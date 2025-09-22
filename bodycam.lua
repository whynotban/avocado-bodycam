script_name('BodyCam')
script_author('whynotban', 'alex.morozov')
script_version('1.0.1')

local imgui = require('mimgui')
local fa = require('fAwesome6_solid')
local ev = require('samp.events')
local inicfg = require('inicfg')
local vkeys = require('vkeys')
local encoding = require('encoding')
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local wm = require('windows.message')
local json = require('cjson')
local effil = require('effil')

local game_path = 'moonloader/config/bodycam'
local config_path = 'bodycam/config.ini'
local stats_path = game_path .. '/stats.json'
local screenW, screenH = getScreenResolution()

if not doesDirectoryExist(game_path) then
    createDirectory(game_path)
end

local states = { isRecording = false, isPositioningMode = false, stats_cache_dirty = true, isWaitingKeybind = false }
local stats = {}
local recordingStartTime = 0
local recordingStartDateStr = ''

local get_uid = false
local session_uid = nil

local showWindow = imgui.new.bool(false)
local showStatsWindow = imgui.new.bool(false)

local sorted_dates_cache = {}
local stats_data_cache = {}

local default_pos_x = math.floor(screenW * (50 / 1920))
local default_pos_y = math.floor(screenH * (665 / 1080))

local config = inicfg.load({
    main = {
        record_key = vkeys.VK_F2,
        display_mode = 0,
        collect_stats = true,
        pos_x = default_pos_x,
        pos_y = default_pos_y
    },
    update_config = {
        json_url = "https://raw.githubusercontent.com/whynotban/avocado-bodycam/master/version.json",
        project_url = "https://github.com/qrlk/moonloader-script-updater/",
    }
}, config_path)

local settings = {
    display_mode = imgui.new.int(config.main.display_mode or 0),
    collect_stats = imgui.new.bool(config.main.collect_stats)
}

local keyNames = {}
for name, code in pairs(vkeys) do keyNames[code] = name:gsub('VK_', '') end
local displayModes = { u8('Пропадающий'), u8('Статичный') }
local displayModes_c = imgui.new['const char*'][#displayModes](displayModes)
local updateInfo = { version = '', url = '' }

function chatMessage(text) 
    sampAddChatMessage('{808080}[BodyCam]{FFFFFF} '..text, 0x808080)
end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    fa.Init(16)
end)

function formatDuration(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    return string.format('%02d:%02d:%02d', h, m, s)
end

function getMskTimeString(timestamp)
    local msk_offset = 3 * 60 * 60
    local msk_timestamp = timestamp + msk_offset
    return os.date('!%Y-%m-%d %H:%M:%S', msk_timestamp)
end

function asyncHttpRequest(method, url, args, resolve, reject)
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

function isVersionNewer(onlineVersion, currentVersion)
    local onlineParts, currentParts = {}, {}
    for part in onlineVersion:gmatch("([%d]+)") do table.insert(onlineParts, tonumber(part)) end
    for part in currentVersion:gmatch("([%d]+)") do table.insert(currentParts, tonumber(part)) end
    for i = 1, math.max(#onlineParts, #currentParts) do
        local online, current = onlineParts[i] or 0, currentParts[i] or 0
        if online > current then return true end
        if online < current then return false end
    end
    return false
end

function startUpdateDownload()
    chatMessage("Начинаю скачивание обновления до версии v" .. updateInfo.version .. "...")
    asyncHttpRequest('GET', updateInfo.url, { redirect = true },
        function(response_file)
            if response_file.status_code == 200 then
                local file = io.open(thisScript().path, "w")
                if file then
                    file:write(u8:decode(response_file.text)); file:close()
                    chatMessage("Обновление успешно установлено! Скрипт будет перезагружен.")
                    thisScript():reload()
                else print("Не удалось открыть файл скрипта для записи.") end
            else print("Не удалось скачать файл обновления. Код: " .. tostring(response_file.status_code)) end
        end,
        function(err) print("Критическая ошибка при скачивании обновления: "..tostring(err)) end
    )
end

function checkForUpdate()
    asyncHttpRequest('GET', config.update_config.json_url, nil,
        function(response)
            if response.status_code == 200 then
                local success, data = pcall(json.decode, response.text)
                if success and type(data) == "table" then
                    if data.latest and isVersionNewer(data.latest, thisScript().version) then
                        updateInfo.version, updateInfo.url = data.latest, data.updateurl
                        print("Доступна новая версия: v"..updateInfo.version..". Текущая: v" .. thisScript().version)
                        if updateInfo.url and #updateInfo.url > 0 then startUpdateDownload()
                        else print("URL для обновления не найден в файле версии.") end
                    else print("Обновление не требуется. Установлена актуальная версия скрипта.") end
                else print("Не удалось обработать данные о версии.") end
            else print("Не удалось проверить наличие обновлений. Код: " .. tostring(response.status_code)) end
        end,
        function(err) print("Критическая ошибка при проверке обновлений: "..tostring(err)) end
    )
end

function saveConfig()
    config.main.collect_stats = settings.collect_stats[0]
    pcall(inicfg.save, config, config_path)
end

function saveStats()
    local year_ago_timestamp = os.time() - (365 * 24 * 60 * 60)
    for date_str, recordings in pairs(stats) do
        local year, month, day = date_str:match('(%d+)-(%d+)-(%d+)')
        if year and month and day and os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day) }) < year_ago_timestamp then
            stats[date_str] = nil
        end
    end
    pcall(function()
        local file = io.open(stats_path, 'w')
        if file then
            file:write(json.encode(stats))
            file:close()
        end
    end)
    states.stats_cache_dirty = true
end

function loadStats()
    if doesFileExist(stats_path) then
        local file = io.open(stats_path, 'r')
        if file then
            local data = file:read('*a')
            file:close()
            local success, result = pcall(json.decode, data)
            stats = (success and type(result) == 'table') and result or {}
        end
    else
        stats = {}
    end
    states.stats_cache_dirty = true
end

function addRecordingToStats(startTime, duration)
    if not config.main.collect_stats then return end
    local full_date_string = getMskTimeString(startTime)
    local date_str = string.sub(full_date_string, 1, 10)
    if not stats[date_str] then stats[date_str] = {} end
    table.insert(stats[date_str], { start_time = startTime, duration_seconds = duration })
    saveStats()
end

function toggleRecording()
    if not session_uid then
        chatMessage('Невозможно начать запись, не установлен UID.')
        return nil
    else
        states.isRecording = not states.isRecording
        if states.isRecording then
            recordingStartTime = os.time()
            recordingStartDateStr = getMskTimeString(recordingStartTime)
            return true
        else
            if recordingStartTime > 0 then
                addRecordingToStats(recordingStartTime, os.time() - recordingStartTime)
                recordingStartTime = 0
            end
            return false
        end
    end
end

function apply_style()
    local style = imgui.GetStyle()
    local colors = style.Colors

    style.WindowRounding = 9.0
    style.ChildRounding = 7.0
    style.FrameRounding = 7.0
    style.GrabRounding = 7.0
    style.ScrollbarRounding = 11.0
    style.WindowTitleAlign = imgui.ImVec2(0.5, 0.5)
    
    style.WindowBorderSize = 0.0
    style.FrameBorderSize = 0.0
    style.ChildBorderSize = 0.0
    style.PopupBorderSize = 0.0

    colors[imgui.Col.Text]                   = imgui.ImVec4(0.95, 0.96, 0.98, 1.00)
    colors[imgui.Col.TextDisabled]           = imgui.ImVec4(0.50, 0.50, 0.50, 1.00)
    
    colors[imgui.Col.WindowBg]               = imgui.ImVec4(0.06, 0.06, 0.06, 0.90)
    colors[imgui.Col.ChildBg]                = imgui.ImVec4(0.10, 0.11, 0.12, 1.00)
    colors[imgui.Col.PopupBg]                = imgui.ImVec4(0.09, 0.09, 0.10, 0.96)

    colors[imgui.Col.FrameBg]                = imgui.ImVec4(0.18, 0.19, 0.20, 0.75)
    colors[imgui.Col.FrameBgHovered]         = imgui.ImVec4(0.25, 0.26, 0.28, 0.80)
    colors[imgui.Col.FrameBgActive]          = imgui.ImVec4(0.30, 0.32, 0.34, 1.00)

    colors[imgui.Col.TitleBg]                = imgui.ImVec4(0.08, 0.08, 0.09, 1.00)
    colors[imgui.Col.TitleBgActive]          = imgui.ImVec4(0.08, 0.08, 0.09, 1.00)
    colors[imgui.Col.TitleBgCollapsed]       = imgui.ImVec4(0.00, 0.00, 0.00, 0.51)

    colors[imgui.Col.ScrollbarBg]            = imgui.ImVec4(0.02, 0.02, 0.02, 0.53)
    colors[imgui.Col.ScrollbarGrab]          = imgui.ImVec4(0.31, 0.31, 0.31, 1.00)
    colors[imgui.Col.ScrollbarGrabHovered]   = imgui.ImVec4(0.41, 0.41, 0.41, 1.00)
    colors[imgui.Col.ScrollbarGrabActive]    = imgui.ImVec4(0.51, 0.51, 0.51, 1.00)

    colors[imgui.Col.CheckMark]              = imgui.ImVec4(0.85, 0.85, 0.85, 1.00)

    colors[imgui.Col.SliderGrab]             = imgui.ImVec4(0.51, 0.51, 0.51, 1.00)
    colors[imgui.Col.SliderGrabActive]       = imgui.ImVec4(0.65, 0.65, 0.65, 1.00)

    colors[imgui.Col.Button]                 = imgui.ImVec4(0.25, 0.26, 0.28, 0.60)
    colors[imgui.Col.ButtonHovered]          = imgui.ImVec4(0.35, 0.36, 0.38, 0.80)
    colors[imgui.Col.ButtonActive]           = imgui.ImVec4(0.45, 0.46, 0.48, 1.00)

    colors[imgui.Col.Header]                 = imgui.ImVec4(0.25, 0.26, 0.28, 0.31)
    colors[imgui.Col.HeaderHovered]          = imgui.ImVec4(0.25, 0.26, 0.28, 0.80)
    colors[imgui.Col.HeaderActive]           = imgui.ImVec4(0.25, 0.26, 0.28, 1.00)

    colors[imgui.Col.Separator]              = imgui.ImVec4(0.25, 0.25, 0.25, 1.00)
    colors[imgui.Col.SeparatorHovered]       = imgui.ImVec4(0.35, 0.35, 0.35, 1.00)
    colors[imgui.Col.SeparatorActive]        = imgui.ImVec4(0.45, 0.45, 0.45, 1.00)
end

local mainFrame = imgui.OnFrame(
    function() return showWindow[0] end,
    function(self)
        apply_style()
        local button_height = 30
        imgui.SetNextWindowPos(imgui.ImVec2((screenW - 400) / 2, (screenH - 274) / 2), imgui.Cond.FirstUseEver)
        imgui.SetNextWindowSize(imgui.ImVec2(400, 274), imgui.Cond.FirstUseEver)
        imgui.Begin(u8('Настройки BodyCam'), showWindow, imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse)
        imgui.Text(u8('Ваш UID: ')..u8(session_uid and tostring(session_uid) or 'Не установлен'))
        imgui.Text(u8('Клавиша активации: ')..(keyNames[config.main.record_key] or '...'))
        if imgui.Checkbox(u8('Ведение статистики'), settings.collect_stats) then 
            saveConfig() 
        end
        imgui.Separator()
        imgui.Text(u8('Режим отображения'))
        imgui.PushItemWidth(-1)
        if imgui.Combo('##displaymode', settings.display_mode, displayModes_c, #displayModes) then
            config.main.display_mode = settings.display_mode[0]
            saveConfig()
        end
        imgui.PopItemWidth()
        if imgui.Button(states.isWaitingKeybind and u8('Нажмите на клавишу...') or u8('Изменить клавишу  ')..fa.PEN_TO_SQUARE, imgui.ImVec2(-1, button_height)) then
            states.isWaitingKeybind  = not states.isWaitingKeybind 
        end
        if imgui.Button(u8'Изменить положение  '..fa.ARROWS_UP_DOWN_LEFT_RIGHT, imgui.ImVec2(-1, button_height)) then
            states.isPositioningMode = true
            showWindow[0] = false
            chatMessage('Кликните на место, где будет BodyCam. ESC - отмена.')
        end
        if imgui.Button(u8'Обновить UID  '..fa.ARROWS_ROTATE, imgui.ImVec2(-1, button_height)) then 
            getUid() 
        end
        if imgui.Button(u8'Посмотреть статистику  '..fa.CHART_SIMPLE, imgui.ImVec2(-1, button_height)) then
            showStatsWindow[0] = not showStatsWindow[0]
        end
        imgui.End()
    end
)

local statsFrame = imgui.OnFrame(
    function() return showStatsWindow[0] end,
    function(self)
        apply_style()
        imgui.SetNextWindowSize(imgui.ImVec2(500, 400), imgui.Cond.FirstUseEver)
        imgui.SetNextWindowPos(imgui.ImVec2((screenW - 500) / 2, (screenH - 400) / 2), imgui.Cond.FirstUseEver)
        imgui.Begin(u8('Статистика записей (Время по МСК)'), showStatsWindow, imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse)
        if states.stats_cache_dirty then
            sorted_dates_cache = {}
            stats_data_cache = {}
            for date_str in pairs(stats) do table.insert(sorted_dates_cache, date_str) end
            table.sort(sorted_dates_cache, function(a, b) return a > b end)
            for _, date_str in ipairs(sorted_dates_cache) do
                local recordings = stats[date_str]
                local total_duration = 0
                for _, rec in ipairs(recordings) do total_duration = total_duration + rec.duration_seconds end
                stats_data_cache[date_str] = { count = #recordings, total_duration = total_duration }
            end
            states.stats_cache_dirty = false
        end
        if not next(stats) then
            imgui.Text(u8('Статистика пока пуста. Включите запись, чтобы собрать данные.'))
        else
            for _, date_str in ipairs(sorted_dates_cache) do
                local data = stats_data_cache[date_str]
                local header_text = u8('Дата: %s (Записей: %d, Общее время: %s)'):format(date_str, data.count, formatDuration(data.total_duration))
                if imgui.CollapsingHeader(header_text) then
                    for i, rec in ipairs(stats[date_str]) do
                        local start_time_str = getMskTimeString(rec.start_time):match('%d%d:%d%d:%d%d')
                        local duration_str = formatDuration(rec.duration_seconds)
                        imgui.Text(u8('  [Запись %d] Начало в %s / Длительность: %s'):format(i, start_time_str, duration_str))
                    end
                end
            end
        end
        imgui.End()
    end
)

local bodycamFrame = imgui.OnFrame(
    function()
        if config.main.display_mode == 1 then return not isPauseMenuActive()
        else return (states.isRecording or states.isPositioningMode) and not isPauseMenuActive() end
    end,
    function(self)
        self.HideCursor = true
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(8, 6))
        imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.06, 0.06, 0.06, 0.85))

        if states.isPositioningMode then
            local x, y = getCursorPos()
            imgui.SetNextWindowPos(imgui.ImVec2(x, y), imgui.Cond.Always)
        else
            imgui.SetNextWindowPos(imgui.ImVec2(config.main.pos_x, config.main.pos_y), imgui.Cond.Always) 
        end
        
        imgui.SetNextWindowSize(imgui.ImVec2(230, 0), imgui.Cond.Always)
        imgui.Begin(u8('Bodycam Overlay'), nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoCollapse)
        
        local cursorPosX, basePosY = imgui.GetCursorPosX(), imgui.GetCursorPosY()
        local gray_color = imgui.ImVec4(0.6, 0.6, 0.6, 1.0)
        imgui.SetCursorPos(imgui.ImVec2(cursorPosX, basePosY + 2.0))
        imgui.TextColored(gray_color, fa.VIDEO) 
        imgui.SameLine(cursorPosX + imgui.CalcTextSize(fa.VIDEO).x + 4) 
        imgui.SetCursorPosY(basePosY)
        imgui.Text(u8" bodycam #"..(session_uid and tostring(session_uid) or "N/A"))
        local circleIconWidth = imgui.CalcTextSize(fa.CIRCLE).x
        imgui.SameLine(imgui.GetWindowContentRegionMax().x - circleIconWidth)
        
        if states.isRecording then
            if math.floor(os.clock() * 1.4) % 2 ~= 0 then 
                imgui.TextColored(imgui.ImVec4(1.0, 0.0, 0.0, 1.0), fa.CIRCLE)
            else    
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 0, 0, 0))
                imgui.Text(fa.CIRCLE)
                imgui.PopStyleColor() 
            end
        else 
            imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), fa.CIRCLE) 
        end
        
        imgui.NewLine()
        if states.isRecording then
            imgui.Text('Rec from ' .. recordingStartDateStr)
            local elapsed = os.time() - recordingStartTime
            imgui.Text(formatDuration(elapsed) .. u8(' с начала записи'))
        else 
            imgui.Text(u8('Запись выключена')) 
        end
        imgui.End()
        imgui.PopStyleColor()
        imgui.PopStyleVar()
    end
)

function onWindowMessage(msg, wparam, lparam)
    if states.isPositioningMode then
        if msg == wm.WM_LBUTTONDOWN and wparam == vkeys.VK_LBUTTON then
            local x, y = getCursorPos()
            config.main.pos_x, config.main.pos_y = x, y
            saveConfig()
            states.isPositioningMode = false
            showCursor(false)
            showNotify('success', 'Успешно!', 'Позиция сохранена.', 3500)
            chatMessage('Позиция сохранена.')
            showWindow[0] = true
        elseif msg == wm.WM_KEYUP and wparam == vkeys.VK_ESCAPE then
            states.isPositioningMode = false
            showCursor(false)
            chatMessage('Изменение позиции отменено.')
        end
        return
    end

    if msg == wm.WM_KEYDOWN and wparam == vkeys.VK_ESCAPE then
        if showStatsWindow[0] then
            showStatsWindow[0] = false
            consumeWindowMessage(true, false)
            return 0
        elseif showWindow[0] then
            showWindow[0] = false
            consumeWindowMessage(true, false)
            return 0
        end
    end
end

function getUid()
    if not sampIsPlayerConnected() or not sampIsLocalPlayerSpawned() then
        chatMessage('Вы не подключены к серверу или не заспавнены.')
        return
    end
    
    local _, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    local nickname = sampGetPlayerNickname(id)
    if nickname then
        get_uid = true
        sampSendChat('/id '..nickname)
    else chatMessage('Не удалось получить ваш никнейм.') end
end

function ev.onServerMessage(color, text)
    if text:find('UID: (%d+)') and get_uid then
        local found_uid = text:match('UID: (%d+)')
        if found_uid then
            session_uid = found_uid
            chatMessage('Идентификатор аккаунта установлен. UID: '..found_uid)
            get_uid = false; return false
        end
    end
end

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end
    
    loadStats()

    sampRegisterChatCommand('bcam', function()
        showWindow[0] = not showWindow[0]
    end)
    
    print('Скрипт успешно загружен.')
    print('Версия скрипта: '..thisScript().version)
    print('Разработчики: '..table.concat(thisScript().authors, ", "))

    chatMessage('Интерфейс загружен. Введите /bcam для открытия настроек.')

    lua_thread.create(checkForUpdate)
    lua_thread.create(function() wait(5000); getUid() end)

    while true do
        wait(0)

        local script_needs_cursor = states.isPositioningMode or states.isWaitingKeybind
        
        if script_needs_cursor then
            showCursor(true)
        end

        local block_hotkey = sampIsChatInputActive() or sampIsDialogActive() or isPauseMenuActive()

        if states.isWaitingKeybind then
            for i = 1, 255 do
                if isKeyJustPressed(i) then
                    if i == vkeys.VK_ESCAPE then chatMessage('Изменение клавиши отменено.')
                    else
                        config.main.record_key = i
                        local keyName = keyNames[i] or tostring(i)
                        chatMessage('Новая клавиша назначена: '..keyName)
                        showNotify('success', 'Успешно!', 'Клавиша назначена: '..keyName, 3500)
                        saveConfig()
                    end
                    states.isWaitingKeybind = false
                    break
                end
            end
        else
            if wasKeyPressed(config.main.record_key) and not block_hotkey then
                local result = toggleRecording()
                if result == true then chatMessage('Запись включена с '..recordingStartDateStr)
                elseif result == false then chatMessage('Запись выключена и сохранена в статистику.') end
            end
        end
    end
end

function showNotify(type, title, text, time)
    local function escape_js(s) return s:gsub("\\", "\\\\"):gsub('"', '\\"') end
    local safe_type, safe_title, safe_text, safe_time = escape_js(type), escape_js(title), escape_js(text), tostring(time)
    local str = ('window.executeEvent("event.notify.initialize", "[\\"%s\\", \\"%s\\", \\"%s\\", \\"%s\\"]");'):format(safe_type, safe_title, safe_text, safe_time)
    visualCEF(str, true)
end

function visualCEF(str, is_encoded)
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 17); raknetBitStreamWriteInt32(bs, 0); raknetBitStreamWriteInt16(bs, #str)
    raknetBitStreamWriteInt8(bs, is_encoded and 1 or 0)
    if is_encoded then raknetBitStreamEncodeString(bs, str) else raknetBitStreamWriteString(bs, str) end
    raknetEmulPacketReceiveBitStream(220, bs); raknetDeleteBitStream(bs)
end
