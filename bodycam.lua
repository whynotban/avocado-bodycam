-- bodycam.lua
script_name('avocado - bodycam')
script_author('whynotban')
script_version('0.0.1')

require('lib.moonloader')
local imgui = require('mimgui')
local inicfg = require('inicfg')
local vkeys =require('vkeys')
local json = require('cjson')
local samp = require('lib.samp.events')
local fa = require('fAwesome6_solid')
local encoding = require('encoding')
encoding.default = 'CP1251'
u8 = encoding.UTF8
local wm = require 'lib.windows.message'

local FULL_CONFIG_DIR = 'moonloader/config/bodycam'
local INICFG_RELATIVE_PATH = 'bodycam/config.ini'

local STATS_FILE = FULL_CONFIG_DIR .. '/stats.json'
local sw, sh = getScreenResolution()

if not doesDirectoryExist('moonloader/config') then createDirectory('moonloader/config') end
if not doesDirectoryExist(FULL_CONFIG_DIR) then createDirectory(FULL_CONFIG_DIR) end

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

-- ####################### AUTO-UPDATER WITH SEMVER SUPPORT #######################
function isVersionNewer(onlineVersion, currentVersion)
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

function checkForUpdate()
    local url = config.update_config.json_url .. "?" .. os.time()

    downloadUrlToFile(url, os.tmpname(), function(id, status, p1, p2)
        if status == require('moonloader').download_status.STATUSEX_ENDDOWNLOAD then
            local file = io.open(os.tmpname(), "r")
            if file and file:seek("end") > 0 then
                file:seek("set")
                local json_string = file:read("*a")
                file:close()
                os.remove(os.tmpname())

                local success, data = pcall(json.decode, json_string)
                if success and type(data) == "table" then
                    if data.latest and isVersionNewer(data.latest, thisScript().version) then
                        sampAddChatMessage(config.update_config.prefix .. "{FFFFFF}Обнаружено обновление! Новая версия: {00FF00}" .. data.latest, -1)

                        if data.changelog and type(data.changelog) == "table" then
                            sampAddChatMessage(config.update_config.prefix .. "{FFFFFF}Список изменений:", -1)
                            for _, line in ipairs(data.changelog) do
                                sampAddChatMessage("{CCCCCC}- " .. line, -1)
                            end
                        end

                        sampAddChatMessage(config.update_config.prefix .. "{FFFFFF}Начинаю загрузку...", -1)

                        downloadUrlToFile(data.updateurl, thisScript().path, function(id, status, p1, p2)
                            if status == require('moonloader').download_status.STATUSEX_ENDDOWNLOAD then
                                sampAddChatMessage(config.update_config.prefix .. "{00FF00}Обновление успешно завершено! Скрипт будет перезагружен.", -1)
                                thisScript():reload()
                            elseif status == require('moonloader').download_status.STATUSEX_CONNCENT_FAIL or status == require('moonloader').download_status.STATUSEX_REQUEST_SENT_FAIL then
                                sampAddChatMessage(config.update_config.prefix .. "{FF0000}Ошибка: не удалось скачать обновление. Попробуйте позже.", -1)
                            end
                        end)
                    end
                else
                    sampAddChatMessage(config.update_config.prefix .. "{FF0000}Ошибка проверки обновления. Возможно, файл на сервере поврежден.", -1)
                end
            else
                sampAddChatMessage(config.update_config.prefix .. "{FF0000}Не удалось проверить обновление. Проверьте вручную: {FFFFFF}" .. config.update_config.project_url, -1)
            end
        end
    end)
end

local settings = {
    displayMode = imgui.new.int(config.main.displayMode - 1),
    collectStats = imgui.new.bool(config.main.collectStats)
}
local displayModes = { u8('Анимированный'), u8('Статичный') }
local displayModes_c = imgui.new['const char*'][#displayModes](displayModes)

local keyNames = {}
for name, code in pairs(vkeys) do keyNames[code] = name:gsub('VK_', '') end
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

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    fa.Init(16)
end)

local function saveConfig()
    config.main.displayMode = settings.displayMode[0] + 1
    config.main.collectStats = settings.collectStats[0]
    inicfg.save(config, INICFG_RELATIVE_PATH)
end

local function loadStats()
    if doesFileExist(STATS_FILE) then
        local file = io.open(STATS_FILE, 'r')
        if file then
            local data = file:read('*a')
            file:close()
            local success, result = pcall(json.decode, data)
            if success and type(result) == 'table' then
                stats = result
            else
                stats = {}
            end
        end
    else
        stats = {}
    end
end

local function saveStats()
    local year_ago_timestamp = os.time() - (365 * 24 * 60 * 60)
    for date_str, recordings in pairs(stats) do
        local year, month, day = date_str:match('(%d+)-(%d+)-(%d+)')
        if year and month and day then
            local entry_timestamp = os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day) })
            if entry_timestamp < year_ago_timestamp then
                stats[date_str] = nil
            end
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

local function addRecordingToStats(startTime, duration)
    if not config.main.collectStats then return end

    local date_str = os.date('%Y-%m-%d', startTime)
    if not stats[date_str] then
        stats[date_str] = {}
    end
    table.insert(stats[date_str], { start_time = startTime, duration_seconds = duration })
    saveStats()
end

function triggerUidFetch()
    local id = select(2, sampGetPlayerIdByCharHandle(PLAYER_PED))
    local nick = sampGetPlayerNickname(id)
    if nick then
        isWaitingForUid = true
        uidRequestTime = os.time()
        sampSendChat('/id ' .. nick)
    else
        sampAddChatMessage('{808080}[Bodycam]: {FF0000}Не удалось получить ваш никнейм.', -1)
    end
end

function toggleRecording()
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

function calculateAlpha()
    if config.main.displayMode == 2 then
        windowAlpha = 1.0
        return
    end

    local progress = (os.clock() - animationStartTime) / ANIMATION_DURATION
    if progress > 1.0 then progress = 1.0 end

    if isRecording then
        windowAlpha = progress -- Анимация появления
    else
        windowAlpha = 1.0 - progress -- Анимация исчезновения
    end
end

function onWindowMessage(msg, wparam, lparam)
    if wparam == vkeys.VK_LBUTTON then
        if msg == wm.WM_LBUTTONDOWN then

            -- Режим перемещения оверлея
            if isPositioningMode then
                local x, y = getCursorPos()
                config.main.posX, config.main.posY = x, y
                saveConfig()
                isPositioningMode = false
                sampAddChatMessage('{808080}[Bodycam]: {00FF00}Позиция сохранена.', -1)
            end
        end
    end
    if wparam == vkeys.VK_ESCAPE then
        if showSettings[0] then
            if msg == wm.WM_KEYDOWN then
                consumeWindowMessage(true, false)
            end
            if msg == wm.WM_KEYUP then
                showSettings[0] = false
            end
        end
        if isPositioningMode then
            if msg == wm.WM_KEYDOWN then
                consumeWindowMessage(true, false)
            end
            if msg == wm.WM_KEYUP then
                isPositioningMode = false
                sampAddChatMessage('{808080}[Bodycam]: {FFFF00}Изменение позиции отменено.', -1)
            end
        end
    end
end

samp.onPlayerSpawn = function()
    -- Запрашиваем UID через 3 секунды после спавна
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
            return false -- Скрываем сообщение из чата
        end
    end
end

-- // Основная логика скрипта
function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    lua_thread.create(function()
        wait(3000)
        checkForUpdate()
    end)

    loadStats()
    sampRegisterChatCommand('bcam', function()
        showSettings[0] = not showSettings[0]
    end)

    -- Первичный запрос UID через 5 секунд после запуска скрипта
    lua_thread.create(function()
        wait(5000)
        triggerUidFetch()
    end)

    while true do
        wait(0)

        -- Обработка горячей клавиши включения/выключения
        if not isPauseMenuActive() and not sampIsChatInputActive() and not sampIsDialogActive() and not isPositioningMode then
            if isKeyJustPressed(config.main.toggleKey) and not showSettings[0] then
                toggleRecording()
            end
        end

        -- Ожидание нажатия клавиши для бинда
        if isWaitingForKeybind then
            for i = 1, 255 do
                if isKeyJustPressed(i) then
                    if i ~= vkeys.VK_ESCAPE then
                        config.main.toggleKey = i
                        saveConfig()
                        local keyName = keyNames[i] or ('KEY_' .. i)
                        sampAddChatMessage('{808080}[Bodycam]: {FFFFFF}Новая клавиша установлена на {00FF00}' .. keyName, -1)
                    else
                        sampAddChatMessage('{808080}[Bodycam]: {FFFFFF}Изменение отменено.', -1)
                    end
                    isWaitingForKeybind = false
                    break
                end
            end
        end

        -- Таймаут для запроса UID
        if isWaitingForUid and os.time() - uidRequestTime > 5 then
            sampAddChatMessage('{808080}[Bodycam]: {FF0000}Таймаут ожидания ответа от сервера на команду /id.', -1)
            isWaitingForUid = false
        end

    end
end

-- // ---------- Отрисовка ImGui ----------

-- Окно с информацией о записи (оверлей)
local bodycamFrame = imgui.OnFrame(
    function() -- Условие отрисовки
        return ((config.main.displayMode == 2) or (isRecording or windowAlpha > 0) or isPositioningMode)
            and not isPauseMenuActive()
            and not sampIsChatInputActive()
            and not sampIsDialogActive()
    end,
    function(self) -- Функция отрисовки
        calculateAlpha()
        if windowAlpha <= 0 and not isPositioningMode then return end

        local currentAlpha = isPositioningMode and 1.0 or windowAlpha
        imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, currentAlpha)
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(8, 6))
        imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.06, 0.06, 0.06, 0.85))
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.9, 0.9, 0.9, 1.0))

        local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.AlwaysAutoResize
        local windowName = 'Bodycam Overlay'

        if isPositioningMode then
            windowName = windowName .. '##Positioning'
            local x, y = getCursorPos()
            imgui.SetNextWindowPos(imgui.ImVec2(x, y), imgui.Cond.Always)
        else
            flags = flags + imgui.WindowFlags.NoMove
            imgui.SetNextWindowPos(imgui.ImVec2(config.main.posX, config.main.posY), imgui.Cond.Always)
        end

        imgui.Begin(windowName, nil, flags)

        local drawList = imgui.GetWindowDrawList()
        local wPos = imgui.GetWindowPos()
        local wSize = imgui.GetWindowSize()

        -- Иконка и текст "bodycam #UID"
        local baseY = imgui.GetCursorPosY() + 2
        imgui.SetCursorPosY(baseY + 3)
        imgui.Text(fa.VIDEO)
        imgui.SameLine()
        imgui.SetCursorPosY(baseY)
        imgui.Text('bodycam #' .. uid)

        imgui.SameLine(0, 15)

        -- Координаты для мигающей точки
        local dotX = wPos.x + wSize.x - 12
        local dotY = wPos.y + (imgui.GetTextLineHeight() / 2) + 8

        if isRecording then
            -- Мигающая красная точка
            if math.floor(os.clock() * 1.5) % 2 == 0 then
                local color = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 0, 0, 1))
                drawList:AddCircleFilled(imgui.ImVec2(dotX, dotY), 5, color)
            end
            imgui.NewLine()
            imgui.Text('Rec from ' .. recordingStartDateStr)
            local elapsed = (os.time() - recordingStartTime)
            local h = math.floor(elapsed / 3600)
            local m = math.floor((elapsed % 3600) / 60)
            local s = elapsed % 60
            imgui.Text(string.format('%02d:%02d:%02d', h, m, s) .. u8(' с начала записи'))
        else
            -- Серая точка
            local color = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.5, 0.5, 0.5, 1))
            drawList:AddCircleFilled(imgui.ImVec2(dotX, dotY), 5, color)
            imgui.NewLine()
            imgui.Text(u8('Запись неактивна'))
        end

        if isPositioningMode then
            imgui.NewLine()
            imgui.TextColored(imgui.ImVec4(1, 1, 0, 1), u8('--- РЕЖИМ ПЕРЕМЕЩЕНИЯ ---'))
            imgui.Text(u8('ЛКМ - сохранить, ESC - отмена'))
        end

        imgui.End()
        imgui.PopStyleColor(2)
        imgui.PopStyleVar(2)
    end
)

-- Окно настроек
local settingsFrame = imgui.OnFrame(
    function() -- Условие отрисовки
        return showSettings[0]
    end,
    function(self) -- Функция отрисовки
        imgui.SetNextWindowSize(imgui.ImVec2(450, 320), imgui.Cond.FirstUseEver)
        imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.Begin(u8('Настройки Bodycam'), showSettings, imgui.WindowFlags.NoCollapse)

        imgui.Text(u8('Основные настройки')); imgui.Separator()

        -- Кнопка смены клавиши
        local keyName = keyNames[config.main.toggleKey] or ('KEY_' .. config.main.toggleKey)
        imgui.Text(u8('Текущая клавиша активации: ') .. keyName)
        local btnTxt = isWaitingForKeybind and u8('Нажмите любую клавишу... (ESC для отмены)') or u8('Изменить клавишу')
        if imgui.Button(btnTxt, imgui.ImVec2(0, 0)) then
            isWaitingForKeybind = not isWaitingForKeybind
        end
        imgui.SameLine()

        -- Кнопка изменения положения
        if imgui.Button(u8('Изменить положение'), imgui.ImVec2(0, 0)) then
            isPositioningMode = true
            showSettings[0] = false
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(u8('Позволяет перетащить меню записи в иное место.')) end
        imgui.SameLine()

        -- Кнопка обновления UID
        if imgui.Button(u8('Обновить UID'), imgui.ImVec2(0, 0)) then
            triggerUidFetch()
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(u8('Обновляет ID аккаунта.')) end

        imgui.Spacing()
        imgui.Text(u8('Режим отображения')); imgui.Separator()
        imgui.PushItemWidth(-1)
        if imgui.Combo('##displaymode', settings.displayMode, displayModes_c, #displayModes) then
            saveConfig()
        end
        imgui.PopItemWidth()
        if imgui.IsItemHovered() then imgui.SetTooltip(u8('Выберите, как будет отображаться меню записи.')) end

        imgui.Spacing()
        imgui.Text(u8('Данные')); imgui.Separator()
        if imgui.Checkbox(u8('Ведение статистики'), settings.collectStats) then
            saveConfig()
        end

        imgui.End()
    end
)
