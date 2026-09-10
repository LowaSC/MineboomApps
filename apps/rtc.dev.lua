local Scrollbar = dofile("/os/lib/scrollbar.lua")

local M = {}
M.id        = "rtc"
M.name      = "RTC - RS to chest"
M.icon      = "RT"
M.iconBg    = colors.cyan
M.iconFg    = colors.black
M.version   = 23
M.category  = "automation"

local DATA_FILE   = "/data/materials_missing.db"
local REPORT_FILE = "/data/materials_missing.txt"
local SETTINGS_FILE = "/data/rtc_settings.db"
local SIDES       = {"up", "down", "top", "bottom", "front", "back", "left", "right"}
local VIEWS       = {"DASH", "LIST", "EXPORT"}
local EXPORT_STEP_LIMIT = 3
local MIN_EXPORT_DELAY = 0.05
local CRAFT_WAIT_INTERVAL = 4    -- секунд между повторными пробами экспорта
local CRAFT_WAIT_TIMEOUT = 600   -- максимум секунд ждать один цикл крафта
local FsUtil      = nil

local function fsutil()
    if not FsUtil then FsUtil = dofile("/os/lib/fsutil.lua") end
    return FsUtil
end

local function loadSettings()
    local fsu = fsutil()
    local data = fsu.readFile(SETTINGS_FILE)
    if type(data) ~= "string" then return {} end
    local ok, value = pcall(textutils.unserialize, data)
    return ok and type(value) == "table" and value or {}
end

local function saveSettings(st)
    local settings = {
        direction = st.direction,
        waitForBuffer = st.waitForBuffer,
        batchSize = st.batchSize,
        exportDelay = st.exportDelay,
        waitRetrySeconds = st.waitRetrySeconds,
        view = st.view,
    }
    fsutil().atomicWrite(SETTINGS_FILE, textutils.serialize(settings))
end

local function nowSeconds()
    if os.epoch then return math.floor(os.epoch("utc") / 1000) end
    return math.floor(os.clock())
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function padR(s, width)
    s = tostring(s or "")
    if #s >= width then return string.sub(s, 1, width) end
    return s .. string.rep(" ", width - #s)
end

local function shortName(name)
    local s = tostring(name or "?")
    local ns, id = string.match(s, "^([^:]+):(.+)$")
    if id then return id end
    return s
end

local function formatCount(n)
    n = tonumber(n) or 0
    if n >= 1000000000 then return string.format("%.1fB", n / 1000000000) end
    if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
    if n >= 1000 then return string.format("%.1fk", n / 1000) end
    return tostring(math.floor(n))
end

local function writeAt(win, x, y, text, fg, bg)
    win.setCursorPos(x, y)
    win.setTextColor(fg)
    win.setBackgroundColor(bg)
    win.write(tostring(text or ""))
end

local function writeClip(win, x, y, text, width, fg, bg)
    if width <= 0 then return end
    writeAt(win, x, y, padR(text, width), fg, bg)
end

-- Скроллбар вынесен в /os/lib/scrollbar.lua и хранится в st.sb.
-- Bounds/content синхронизируются перед draw и перед обработкой клика
-- через syncScrollBar() — view (LIST/EXPORT/DASH) задаёт диапазон.

local function fillLine(win, y, bg)
    local W = win.getSize()
    win.setCursorPos(1, y)
    win.setBackgroundColor(bg)
    win.write(string.rep(" ", W))
end

local function fillRect(win, x, y, w, h, bg)
    if w <= 0 or h <= 0 then return end
    for row = 0, h - 1 do
        win.setCursorPos(x, y + row)
        win.setBackgroundColor(bg)
        win.write(string.rep(" ", w))
    end
end

local function drawButton(win, buttons, id, x, y, label, fg, bg, maxX)
    local width = #label
    local W = win.getSize()
    local limit = math.min(W, maxX or W)
    if x < 1 or x + width - 1 > limit then return x end
    writeAt(win, x, y, label, fg, bg)
    table.insert(buttons, {id = id, x = x, y = y, width = width})
    return x + width + 1
end

local function drawBar(win, x, y, w, value, label, fillBg, emptyBg, fg)
    value = clamp(tonumber(value) or 0, 0, 1)
    local fillW = math.floor(w * value + 0.5)
    writeAt(win, x, y, string.rep(" ", w), fg, emptyBg)
    if fillW > 0 then
        writeAt(win, x, y, string.rep(" ", fillW), fg, fillBg)
    end
    label = tostring(label or "")
    local tx = x + math.floor((w - #label) / 2)
    if tx < x then tx = x end
    for i = 1, #label do
        local cx = tx + i - 1
        if cx >= x and cx < x + w then
            local bg = (cx < x + fillW) and fillBg or emptyBg
            writeAt(win, cx, y, string.sub(label, i, i), fg, bg)
        end
    end
end

local function findAny(types)
    for _, typeName in ipairs(types) do
        local ok, p = pcall(peripheral.find, typeName)
        if ok and p then return p, typeName end
    end
    return nil, nil
end

local function isChecklist(item)
    if type(item) ~= "table" then return false end
    local name = item.name
    local displayName = tostring(item.displayName or "")
    local components = item.components or {}
    if components["create:clipboard_content"] then return true end
    return name == "create:clipboard"
       and string.find(displayName, "Material Checklist", 1, true) ~= nil
end

local function getChecklistItem(manager)
    local ok, item = pcall(manager.getItemInHand)
    if ok and isChecklist(item) then return item, "main hand" end

    ok, item = pcall(manager.getItemInOffHand)
    if ok and isChecklist(item) then return item, "off hand" end

    ok, item = pcall(manager.getItems)
    if ok and type(item) == "table" then
        for _, invItem in ipairs(item) do
            if isChecklist(invItem) then
                return invItem, "slot " .. tostring(invItem.slot or "?")
            end
        end
    end

    return nil, "Material Checklist not found"
end

local function extractPages(item)
    local components = item.components or {}
    local content = components["create:clipboard_content"]
    if type(content) ~= "table" then return nil, "clipboard_content not found" end
    if type(content.pages) ~= "table" then return nil, "clipboard pages not found" end
    return content.pages
end

local function addMissing(byName, id, count)
    if type(id) ~= "string" or id == "" then return end
    count = tonumber(count) or 0
    if count <= 0 then return end
    local row = byName[id]
    if not row then
        row = {name = id, label = shortName(id), count = 0, moved = 0, available = nil, status = ""}
        byName[id] = row
    end
    row.count = row.count + count
end

local function parseMissing(pages)
    local byName = {}
    for _, page in ipairs(pages or {}) do
        if type(page) == "table" then
            for _, entry in ipairs(page) do
                if type(entry) == "table" then
                    local checked = tonumber(entry.checked) or 0
                    local icon = entry.icon or {}
                    local amount = tonumber(entry.item_amount) or 0
                    if checked ~= 1 then
                        addMissing(byName, icon.id, amount)
                    end
                end
            end
        end
    end

    local items = {}
    for _, item in pairs(byName) do table.insert(items, item) end
    table.sort(items, function(a, b) return a.name < b.name end)
    return items
end

local function scanChecklist()
    local manager = findAny({"inventoryManager", "inventory_manager"})
    if not manager then return nil, nil, "Inventory Manager not found" end

    local item, sourceOrErr = getChecklistItem(manager)
    if not item then return nil, nil, sourceOrErr end

    local pages, err = extractPages(item)
    if not pages then return nil, nil, err end

    return parseMissing(pages), sourceOrErr, nil
end

local function findBridge()
    local bridge = peripheral.find("rsBridge") or peripheral.find("rs_bridge")
    if not bridge then return nil, "RS Bridge not found" end
    if type(bridge.exportItem) ~= "function" then return nil, "RS Bridge has no exportItem" end
    return bridge, nil
end

-- Превращает результат pcall в короткий читаемый ответ для диагностики.
local function fmtResult(ok, a, b)
    if not ok then return "err:" .. tostring(a) end
    local sa = (a == nil) and "nil" or tostring(a)
    if b ~= nil then sa = sa .. "," .. tostring(b) end
    return sa
end

-- Пытаемся запустить крафт. Возвращает (success, raw_response_string).
-- Пробуем сначала count, потом amount — разные версии Advanced Peripherals
-- ожидают разные поля. Логируем raw-ответ в status для диагностики.
local function safeCraftItem(bridge, name, count)
    if type(bridge.craftItem) ~= "function" then return false, "no_craft_api" end

    -- Попытка 1: count
    local ok1, r1a, r1b = pcall(bridge.craftItem, {name = name, count = count})
    local raw1 = fmtResult(ok1, r1a, r1b)
    if ok1 and r1a == true then return true, "c:" .. raw1 end

    -- Попытка 2: amount (старые версии AP)
    local ok2, r2a, r2b = pcall(bridge.craftItem, {name = name, amount = count})
    local raw2 = fmtResult(ok2, r2a, r2b)
    if ok2 and r2a == true then return true, "a:" .. raw2 end

    return false, "c:" .. raw1 .. " a:" .. raw2
end

-- Проверяет реально ли запущен крафт на текущий момент. Только для диагностики.
local function isCraftingNow(bridge, name)
    if type(bridge.isItemCrafting) ~= "function" then return nil end
    local ok, result = pcall(bridge.isItemCrafting, {name = name})
    if not ok then return nil end
    return result == true
end

local function hasCraftingJob(bridge, name, count)
    if type(bridge.isItemCrafting) ~= "function" then return false, "no_isItemCrafting" end

    local ok1, result1 = pcall(bridge.isItemCrafting, {name = name, count = count})
    if ok1 and result1 == true then return true, "count:true" end

    local ok2, result2 = pcall(bridge.isItemCrafting, {name = name})
    if ok2 and result2 == true then return true, "name:true" end

    return false, "count:" .. fmtResult(ok1, result1) .. " name:" .. fmtResult(ok2, result2)
end

local function hasCraftingPattern(bridge, name, count)
    if type(bridge.isItemCraftable) == "function" then
        local ok1, result1 = pcall(bridge.isItemCraftable, {name = name, count = count})
        if ok1 and result1 == true then return true, "craftable_count:true" end

        local ok2, result2 = pcall(bridge.isItemCraftable, {name = name})
        if ok2 and result2 == true then return true, "craftable_name:true" end
    end

    if type(bridge.getPattern) == "function" then
        local ok3, pattern = pcall(bridge.getPattern, {name = name, count = count})
        if ok3 and type(pattern) == "table" then return true, "pattern_count:true" end

        local ok4, pattern2 = pcall(bridge.getPattern, {name = name})
        if ok4 and type(pattern2) == "table" then return true, "pattern_name:true" end
    end

    return false, "no_pattern"
end

local function isPendingCraft(item)
    if not item then return false end
    if item.status == "crafting" then return true end
    return item.craftStarted ~= nil and (tonumber(item.remaining) or 0) > 0
end

local function totals(items)
    local rows, total, moved, missingStock, blocked = #items, 0, 0, 0, 0
    for _, item in ipairs(items) do
        total = total + (tonumber(item.count) or 0)
        moved = moved + (tonumber(item.moved) or 0)
        if item.status == "no_stock" or item.status == "no_craft" then missingStock = missingStock + 1 end
        if item.status == "blocked" or item.status == "crafting" then blocked = blocked + 1 end
    end
    return rows, total, moved, missingStock, blocked
end

local function buildReport(st)
    local rows, total, moved = totals(st.items)
    local lines = {
        "Material Checklist",
        "Source: " .. tostring(st.source or "?"),
        "Rows: " .. tostring(rows),
        "Total requested: " .. tostring(total),
        "Moved: " .. tostring(moved),
        "Direction: " .. tostring(st.direction),
        "",
    }
    for _, item in ipairs(st.items) do
        local suffix = ""
        if item.status and item.status ~= "" then
            suffix = "  have " .. tostring(item.available or "?")
                .. "  moved " .. tostring(item.moved or 0)
                .. "  craft " .. tostring(item.craftRequested or 0)
                .. "  " .. tostring(item.status)
        end
        table.insert(lines, padR(item.name, 44) .. " x" .. tostring(item.count) .. suffix)
    end
    return table.concat(lines, "\n")
end

local function saveSnapshot(st)
    local fsu = fsutil()
    fsu.atomicWrite(DATA_FILE, "return " .. textutils.serialize(st.items or {}))
    fsu.atomicWrite(REPORT_FILE, buildReport(st))
end

local function scan(st)
    local items, source, err = scanChecklist()
    if err then
        st.status = err
        st.statusLevel = "error"
        st.items = {}
        st.source = ""
        st.exporting = false
        return false
    end

    if st.craftTimer and os.cancelTimer then pcall(os.cancelTimer, st.craftTimer) end
    if st.exportTimer and os.cancelTimer then pcall(os.cancelTimer, st.exportTimer) end
    st.items = items or {}
    st.source = source
    st.lastScan = nowSeconds()
    st.status = #st.items == 0 and "Checklist complete" or ("Loaded " .. #st.items .. " missing rows")
    st.statusLevel = #st.items == 0 and "ok" or "warn"
    st.scroll = 0
    st.exporting = false
    st.crafting = false
    st.exportTimer = nil
    st.craftTimer = nil
    saveSnapshot(st)
    return true
end

local function resetExportState(st)
    for _, item in ipairs(st.items or {}) do
        item.remaining = item.count
        item.moved = 0
        item.available = nil
        item.craftRequested = 0
        item.craftReason = nil
        item.craftAttemptedPass = nil
        item.status = "queued"
    end
    st.exportIndex = 1
    st.exporting = true
    st.blocked = false
    st.passCount = 1
    st.phase = "export"
    st.waitStart = nil
    st.status = "Pass 1: exporting..."
    st.statusLevel = "ok"
end

local function scheduleExport(st, delay)
    st.exportTimer = os.startTimer(math.max(MIN_EXPORT_DELAY, tonumber(delay or st.exportDelay) or MIN_EXPORT_DELAY))
end

local function cancelTimers(st)
    if st.exportTimer and os.cancelTimer then
        pcall(os.cancelTimer, st.exportTimer)
    end
    if st.waitTimer and os.cancelTimer then
        pcall(os.cancelTimer, st.waitTimer)
    end
    st.exportTimer = nil
    st.waitTimer = nil
end

local function startExport(st)
    if not st.items or #st.items == 0 then
        st.status = "Nothing to export"
        st.statusLevel = "warn"
        return
    end

    cancelTimers(st)

    local bridge, err = findBridge()
    if not bridge then
        st.status = err
        st.statusLevel = "error"
        return
    end

    st.bridge = bridge
    resetExportState(st)
    st.scroll = 0
    scheduleExport(st, 0.05)
end

local function finishExport(st, message, level)
    cancelTimers(st)
    st.exporting = false
    st.blocked = false
    st.phase = "done"
    st.waitStart = nil
    st.status = message or "Export complete"
    st.statusLevel = level or "ok"
    saveSnapshot(st)
end

local function clearTask(st)
    cancelTimers(st)
    st.items = {}
    st.source = ""
    st.scroll = 0
    st.exportIndex = nil
    st.exporting = false
    st.blocked = false
    st.bridge = nil
    st.phase = nil
    st.passCount = 0
    st.waitStart = nil
    st.status = "Task cleared"
    st.statusLevel = "ok"
    saveSnapshot(st)
end

-- Пытаемся выгрузить count предметов. Возвращаем фактически перемещённое.
-- RS Bridge сам ограничивает количество тем что доступно в системе.
-- При сбое pcall возвращаем -1 как маркер ошибки.
local function tryExport(bridge, name, count, side)
    local ok, movedOrErr = pcall(bridge.exportItem,
        {name = name, count = count}, side)
    if not ok then return -1, tostring(movedOrErr) end
    return tonumber(movedOrErr) or 0, nil
end

-- Финальный итог: подсчёт статусов и завершение.
local function finishPipeline(st)
    local items = st.items or {}
    local okN, noCraft, noStock, crafting = 0, 0, 0, 0
    for _, item in ipairs(items) do
        if item.status == "ok" then okN = okN + 1
        elseif item.status == "no_craft" then noCraft = noCraft + 1
        elseif item.status == "no_stock" then noStock = noStock + 1
        elseif item.status == "crafting" then crafting = crafting + 1
        end
    end
    local skipped = noCraft + noStock
    local msg
    local level = "ok"
    if crafting > 0 then
        msg = "Done: " .. okN .. " ok, " .. crafting .. " still crafting after " .. tostring(st.passCount or 0) .. " passes"
        level = "warn"
    elseif skipped > 0 then
        msg = "Done: " .. okN .. " ok, " .. skipped .. " skipped (NC " .. noCraft .. ", NS " .. noStock .. ")"
        level = "warn"
    else
        msg = "Done: all " .. okN .. " items exported"
    end
    finishExport(st, msg, level)
end

-- Запускает фазу ожидания крафтов между проходами экспорта.
local function startWaitForCrafts(st)
    st.phase = "wait"
    st.waitStart = st.waitStart or nowSeconds()
    st.status = "Pass " .. st.passCount .. ": waiting for crafts..."
    st.statusLevel = "ok"
    st.waitTimer = os.startTimer(CRAFT_WAIT_INTERVAL)
end

-- Готовит новый проход экспорта. НЕ сбрасываем status="crafting" — иначе
-- повторно вызовем craftItem и RS вернёт false (задача уже стоит), мы пометим NC.
-- exportStep сам разберётся: если moved>0 для crafting item — переведёт в moving,
-- если moved=0 — оставит crafting и пойдёт дальше.
local function startNextPass(st)
    st.passCount = st.passCount + 1
    st.phase = "export"
    st.exportIndex = 1
    st.status = "Pass " .. st.passCount .. ": re-exporting..."
    st.statusLevel = "ok"
    scheduleExport(st, 0.1)
end

local function waitStep(st)
    if not st.exporting or st.phase ~= "wait" then return end
    local items = st.items or {}
    local bridge = st.bridge

    local activeCrafting, total = 0, 0
    for _, item in ipairs(items) do
        if isPendingCraft(item) then
            item.status = "crafting"
            total = total + 1
            local active = isCraftingNow(bridge, item.name)
            if active == true then activeCrafting = activeCrafting + 1 end
        end
    end

    local elapsed = nowSeconds() - (st.waitStart or 0)

    if total <= 0 then
        finishPipeline(st)
        return
    end

    if elapsed >= CRAFT_WAIT_TIMEOUT then
        finishPipeline(st)
        return
    end

    st.status = "Pass " .. st.passCount .. ": " .. total .. " crafting (" .. elapsed .. "s"
        .. (activeCrafting > 0 and (", active " .. activeCrafting) or "") .. ")"
    st.statusLevel = "ok"
    startNextPass(st)
end

local function exportStep(st)
    if not st.exporting then return end
    local items = st.items or {}
    local bridge = st.bridge
    if not bridge then
        finishExport(st, "RS Bridge disconnected", "error")
        return
    end

    local processed = 0
    while st.exportIndex <= #items do
        processed = processed + 1
        local item = items[st.exportIndex]
        item.remaining = tonumber(item.remaining or item.count) or 0

        if item.remaining <= 0 then
            item.status = (item.moved or 0) >= item.count and "ok" or "partial"
            st.exportIndex = st.exportIndex + 1
        else
            local request = math.min(item.remaining, st.batchSize)
            local moved, err = tryExport(bridge, item.name, request, st.direction)

            if moved < 0 then
                item.status = "error"
                finishExport(st, "Export error: " .. tostring(err), "error")
                return
            end

            if moved > 0 then
                item.moved = (tonumber(item.moved) or 0) + moved
                item.remaining = math.max(0, item.remaining - moved)
                if item.remaining > 0 and item.craftStarted then
                    item.status = "crafting"
                else
                    item.status = item.remaining > 0 and "moving" or "ok"
                end
                st.status = shortName(item.name) .. " +" .. tostring(moved)
                st.statusLevel = "ok"
                if item.remaining <= 0 then
                    st.exportIndex = st.exportIndex + 1
                end
                scheduleExport(st, st.exportDelay)
                return
            end

            -- moved == 0. Уже заказанный крафт не заказываем повторно:
            -- RS вернёт false на дубликат задачи, и это ошибочно станет no_craft.
            if item.status == "crafting" then
                st.exportIndex = st.exportIndex + 1
            -- Если ещё не пытались крафтить в этом проходе — пытаемся.
            -- no_craft (паттерна нет) пропускаем, пробовать заново бесполезно.
            elseif item.status == "no_craft" or item.craftAttemptedPass == st.passCount then
                item.status = "no_stock"
                item.craftReason = item.craftReason or ((item.moved or 0) > 0 and "rs_ran_dry" or "not_in_rs")
                st.exportIndex = st.exportIndex + 1
            else
                local ok, raw = safeCraftItem(bridge, item.name, item.remaining)
                item.craftAttemptedPass = st.passCount
                item.craftRequested = item.remaining
                item.craftReason = raw
                if ok then
                    item.status = "crafting"
                    item.craftStarted = item.craftStarted or nowSeconds()
                    st.status = "CR " .. shortName(item.name) .. " x" .. tostring(item.remaining)
                    st.statusLevel = "ok"
                    st.exportIndex = st.exportIndex + 1
                    startWaitForCrafts(st)
                    return
                else
                    local active, activeRaw = hasCraftingJob(bridge, item.name, item.remaining)
                    local craftable, craftableRaw = hasCraftingPattern(bridge, item.name, item.remaining)
                    item.status = "crafting"
                    item.craftStarted = item.craftStarted or nowSeconds()
                    item.craftReason = tostring(raw) .. " active:" .. tostring(activeRaw) .. " craftable:" .. tostring(craftableRaw)
                    st.status = "CR " .. shortName(item.name) .. " wait after craft response"
                    st.statusLevel = "ok"
                    st.exportIndex = st.exportIndex + 1
                    startWaitForCrafts(st)
                    return
                end
                st.exportIndex = st.exportIndex + 1
                scheduleExport(st, st.exportDelay)
                return
            end
        end

        if processed >= EXPORT_STEP_LIMIT and st.exportIndex <= #items then
            scheduleExport(st, st.exportDelay)
            return
        end
    end

    -- Проход завершён. Считаем сколько ушло в крафт.
    local crafting = 0
    for _, item in ipairs(items) do
        if isPendingCraft(item) then
            item.status = "crafting"
            crafting = crafting + 1
        end
    end

    if crafting > 0 then
        startWaitForCrafts(st)
    else
        finishPipeline(st)
    end
end

local function cycleDirection(st)
    local idx = 1
    for i, side in ipairs(SIDES) do
        if side == st.direction then idx = i; break end
    end
    st.direction = SIDES[(idx % #SIDES) + 1]
    st.status = "Direction: " .. st.direction
    st.statusLevel = "ok"
    saveSettings(st)
end

function M.init(win, ctx)
    local cfg = ctx.config or {}
    local settings = loadSettings()
    -- cfg-значения используются только если settings-файл не существует (первый запуск)
    local st = {
        win = win,
        ctx = ctx,
        view = tonumber(settings.view) or 1,
        scroll = 0,
        buttons = {},
        items = {},
        source = "",
        direction = settings.direction or cfg.materialOutputDirection or cfg.rsOutputDirection or "up",
        batchSize = tonumber(settings.batchSize) or tonumber(cfg.materialBatchSize) or 64,
        exportDelay = tonumber(settings.exportDelay) or tonumber(cfg.materialExportDelay) or 0.05,
        waitRetrySeconds = tonumber(settings.waitRetrySeconds) or tonumber(cfg.materialWaitRetrySeconds) or 2,
        waitForBuffer = settings.waitForBuffer,
        status = "Scanning...",
        statusLevel = "warn",
        lastScan = 0,
        exporting = false,
        phase = nil,
        passCount = 0,
    }
    if st.waitForBuffer == nil then st.waitForBuffer = cfg.materialWaitForBuffer ~= false end
    st.view = clamp(st.view, 1, #VIEWS)
    st.sb = Scrollbar.create({
        thumbBg = colors.cyan,
        thumbFg = colors.black,
    })
    -- Записываем настройки сразу, чтобы файл всегда существовал.
    -- Это гарантирует что при следующем запуске direction не сбросится на cfg-значение.
    saveSettings(st)
    scan(st)
    return st
end

function M.onClose(st)
    if not st then return end
    cancelTimers(st)
    saveSettings(st)
end

local function stateLabel(st)
    if st.exporting and st.phase == "wait" then return "WAIT", colors.cyan end
    if st.exporting then return "RUN", colors.lime end
    if st.blocked then return "WAIT", colors.yellow end
    if st.statusLevel == "error" then return "ERR", colors.red end
    return "READY", colors.lightGray
end

local function statusShort(status)
    if status == "ok" then return "OK" end
    if status == "moving" then return "MV" end
    if status == "crafting" then return "CR" end
    if status == "queued" then return "QU" end
    if status == "partial" then return "PT" end
    if status == "blocked" then return "BL" end
    if status == "no_stock" then return "NS" end
    if status == "no_craft" then return "NC" end
    if status == "error" then return "ER" end
    return "--"
end

local function countStatuses(items)
    local out = {ok = 0, moving = 0, crafting = 0, partial = 0, blocked = 0, no_craft = 0, no_stock = 0, error = 0}
    for _, item in ipairs(items or {}) do
        local s = item.status
        if out[s] ~= nil then out[s] = out[s] + 1 end
    end
    return out
end

local function drawHeader(st, win, W)
    st.buttons = {}
    fillLine(win, 1, colors.black)
    writeClip(win, 1, 1, " RTC ", 6, colors.black, colors.cyan)
    if W >= 20 then
        writeClip(win, 8, 1, "RS TO CHEST", W - 16, colors.white, colors.black)
    end
    local label, fg = stateLabel(st)
    writeClip(win, math.max(1, W - #label + 1), 1, label, #label, fg, colors.black)
end

local function drawTabs(st, win, W)
    local base = math.floor(W / #VIEWS)
    local x = 1
    for i, label in ipairs(VIEWS) do
        local width = (i == #VIEWS) and (W - x + 1) or base
        local active = i == st.view
        local bg = active and colors.white or colors.gray
        local fg = active and colors.black or colors.lightGray
        writeClip(win, x, 2, " " .. label .. " ", width, fg, bg)
        table.insert(st.buttons, {id = "view_" .. tostring(i), x = x, y = 2, width = width})
        x = x + width
    end
end

local function drawToolbar(st, win, W)
    fillLine(win, 3, colors.black)
    local x = 1
    local stopLabel = " ST "
    local busy = st.exporting
    local leftLimit = busy and (W - #stopLabel - 1) or W
    x = drawButton(win, st.buttons, "scan", x, 3, " SCAN ", colors.black, colors.lightBlue, leftLimit)
    x = drawButton(win, st.buttons, "pull", x, 3, " PULL ", colors.black, colors.lime, leftLimit)
    x = drawButton(win, st.buttons, "clear", x, 3, " CLEAR ", colors.white, colors.red, leftLimit)
    x = drawButton(win, st.buttons, "dir", x, 3, " " .. string.upper(st.direction) .. " ", colors.white, colors.blue, leftLimit)
    if busy then
        drawButton(win, st.buttons, "stop", math.max(1, W - #stopLabel + 1), 3, stopLabel, colors.white, colors.red)
    end
end

local function drawStatus(st, win, W, H)
    local bg = colors.gray
    local fg = colors.lightGray
    if st.statusLevel == "ok" then fg = colors.lime
    elseif st.statusLevel == "warn" then fg = colors.yellow
    elseif st.statusLevel == "error" then fg = colors.red end
    writeClip(win, 1, H, " " .. tostring(st.status or ""), W, fg, bg)
end

local function drawMetric(win, x, y, w, title, value, fg)
    fillRect(win, x, y, w, 3, colors.gray)
    writeClip(win, x + 1, y, string.upper(title), w - 2, colors.lightGray, colors.gray)
    writeClip(win, x + 1, y + 1, value, w - 2, fg or colors.white, colors.gray)
end

local function drawDash(st, win, W, H)
    local rows, total, moved, missingStock, blocked = totals(st.items)
    local y = 5
    local cardW = math.max(6, math.floor((W - 2) / 3))
    drawMetric(win, 1, y, cardW, "rows", tostring(rows), colors.white)
    drawMetric(win, 2 + cardW, y, cardW, "need", formatCount(total), colors.white)
    drawMetric(win, 3 + cardW * 2, y, W - (2 + cardW * 2), "moved", formatCount(moved), colors.lime)
    y = y + 4

    local progress = total > 0 and moved / total or 1
    drawBar(win, 2, y, W - 2, progress,
        formatCount(moved) .. "/" .. formatCount(total),
        colors.lime, colors.gray, colors.black)
    y = y + 2

    writeClip(win, 1, y, "Source " .. tostring(st.source or "?"), W, colors.lightGray, colors.black)
    y = y + 1
    writeClip(win, 1, y, "Out " .. st.direction .. "  Batch " .. tostring(st.batchSize) .. "  Wait " .. (st.waitForBuffer and "on" or "off"), W, colors.lightGray, colors.black)
    y = y + 1
    writeClip(win, 1, y, "Skipped " .. tostring(missingStock) .. "  Active " .. tostring(blocked), W, colors.lightGray, colors.black)
    y = y + 2

    writeClip(win, 1, y, " Most needed ", W, colors.black, colors.cyan)
    y = y + 1
    local copy = {}
    for _, item in ipairs(st.items) do table.insert(copy, item) end
    table.sort(copy, function(a, b) return (a.count or 0) > (b.count or 0) end)
    for i = 1, math.min(5, #copy) do
        if y >= H then break end
        local item = copy[i]
        local row = padR(shortName(item.name), W - 8) .. formatCount(item.count)
        writeClip(win, 1, y, row, W, colors.white, (i % 2 == 0) and colors.gray or colors.black)
        y = y + 1
    end
end

local function rowColor(status)
    if status == "ok" then return colors.green, colors.black end
    if status == "moving" then return colors.lightBlue, colors.black end
    if status == "crafting" then return colors.cyan, colors.black end
    if status == "queued" then return colors.gray, colors.white end
    if status == "partial" or status == "blocked" then return colors.orange, colors.black end
    if status == "no_stock" or status == "no_craft" or status == "error" then return colors.red, colors.white end
    return colors.black, colors.white
end

local function drawList(st, win, W, H)
    local y = 5
    local contentW = math.max(8, W - 1)
    local nameW = math.max(8, contentW - 17)
    writeClip(win, 1, y, padR("ITEM", nameW) .. padR("NEED", 6) .. padR("MOVE", 6) .. "ST", contentW, colors.white, colors.gray)
    y = y + 1
    local bottomY = H - 1
    local visible = math.max(0, bottomY - y + 1)
    local maxScroll = math.max(0, #st.items - visible)
    st.scroll = clamp(st.scroll or 0, 0, maxScroll)

    for idx = st.scroll + 1, math.min(#st.items, st.scroll + visible) do
        local item = st.items[idx]
        local bg, fg = rowColor(item.status)
        if item.status == "" then
            bg = (idx % 2 == 0) and colors.gray or colors.black
            fg = colors.white
        end
        local line = padR(shortName(item.name), nameW)
            .. padR(formatCount(item.count), 6)
            .. padR(formatCount(item.moved or 0), 6)
            .. statusShort(item.status)
        writeClip(win, 1, y, line, contentW, fg, bg)
        y = y + 1
    end

    if #st.items == 0 then
        writeClip(win, 1, y, "No missing materials", contentW, colors.gray, colors.black)
    end

    st.sb:setBounds(W, 6, bottomY)
    st.sb:setContent(visible, #st.items)
    st.sb:setScroll(st.scroll or 0)
    st.sb:draw(win)
end

local function drawExport(st, win, W, H)
    local rows, total, moved = totals(st.items)
    local counts = countStatuses(st.items)
    local y = 5
    local progress = total > 0 and moved / total or 1
    local contentW = math.max(8, W - 1)
    local barLabel = formatCount(moved) .. "/" .. formatCount(total)
    drawBar(win, 2, y, contentW - 1, progress, barLabel, colors.lime, colors.gray, colors.black)
    y = y + 2

    local phaseTag
    if st.phase == "wait" then phaseTag = "WAIT"
    elseif st.phase == "export" then phaseTag = "PASS " .. tostring(st.passCount or 1)
    elseif st.phase == "done" then phaseTag = "DONE"
    else phaseTag = "READY" end
    writeClip(win, 1, y, phaseTag .. "  Rows " .. tostring(rows) .. "  Item " .. tostring(st.exportIndex or "-"), contentW, colors.lightGray, colors.black)
    y = y + 1
    writeClip(win, 1, y, "OK " .. counts.ok .. "  CR " .. counts.crafting .. "  NS " .. counts.no_stock .. "  NC " .. counts.no_craft, contentW, colors.lightGray, colors.black)
    y = y + 2

    writeClip(win, 1, y, padR("ST", 4) .. padR("ITEM", contentW - 12) .. "LEFT", contentW, colors.white, colors.gray)
    y = y + 1

    local bottomY = H - 1
    local visible = math.max(0, bottomY - y + 1)
    local maxScroll = math.max(0, #st.items - visible)
    st.scroll = clamp(st.scroll or 0, 0, maxScroll)
    local start = st.scroll + 1
    for idx = start, math.min(#st.items, start + visible - 1) do
        local item = st.items[idx]
        local bg, fg = rowColor(item.status)
        local left = tonumber(item.remaining or item.count) or 0
        if idx == st.exportIndex then
            bg = colors.blue
            fg = colors.white
        end
        local line = padR(statusShort(item.status), 4)
            .. padR(shortName(item.name), contentW - 12)
            .. formatCount(left)
        writeClip(win, 1, y, line, contentW, fg, bg)
        y = y + 1
    end

    if #st.items > visible and H > 1 then
        local pos = tostring(st.scroll + 1) .. "-" .. tostring(math.min(#st.items, st.scroll + visible))
            .. "/" .. tostring(#st.items)
        writeClip(win, contentW - #pos + 1, H - 1, pos, #pos, colors.lightGray, colors.black)
    end

    st.sb:setBounds(W, 11, bottomY)
    st.sb:setContent(visible, #st.items)
    st.sb:setScroll(st.scroll or 0)
    st.sb:draw(win)
end

function M.draw(st, win)
    local W, H = win.getSize()
    win.setBackgroundColor(colors.black)
    win.clear()
    drawHeader(st, win, W)
    drawTabs(st, win, W)
    drawToolbar(st, win, W)
    fillLine(win, 4, colors.black)

    local view = VIEWS[st.view] or "DASH"
    if view == "LIST" then
        drawList(st, win, W, H)
    elseif view == "EXPORT" then
        drawExport(st, win, W, H)
    else
        drawDash(st, win, W, H)
    end

    drawStatus(st, win, W, H)
end

local function hitButton(st, x, y)
    for _, button in ipairs(st.buttons or {}) do
        if y == button.y and x >= button.x and x < button.x + button.width then
            return button.id
        end
    end
    return nil
end

local function getEventSize(st)
    if st.win and st.win.getSize then
        return st.win.getSize()
    end
    return term.getSize()
end

-- Возвращает (topY, bottomY) для текущего вида или nil, если в этом виде
-- нет скроллбара (например, DASH).
local function scrollBarBounds(st, H)
    local view = VIEWS[st.view] or "DASH"
    if view == "LIST" then
        return 6, H - 1
    elseif view == "EXPORT" then
        return 11, H - 1
    end
    return nil
end

-- Синхронизируем bounds/content scrollbar'а с текущим view. Вызывать
-- перед onClick/onDrag, чтобы он знал актуальный диапазон до того,
-- как пришёл следующий кадр render'а.
local function syncScrollBar(st)
    local W, H = getEventSize(st)
    local topY, bottomY = scrollBarBounds(st, H)
    if not topY then
        -- Невалидный диапазон — scrollbar не ловит клики на DASH view.
        st.sb:setBounds(W, 1, 0)
        return
    end
    local h = bottomY - topY + 1
    st.sb:setBounds(W, topY, bottomY)
    st.sb:setContent(h, #st.items)
    st.sb:setScroll(st.scroll or 0)
end

local function handleButton(st, id)
    local viewId = string.match(id, "^view_(%d+)$")
    if viewId then
        st.view = clamp(tonumber(viewId) or st.view, 1, #VIEWS)
        saveSettings(st)
        return
    end

    if id == "scan" then
        scan(st)
    elseif id == "pull" then
        startExport(st)
        st.view = 3
        saveSettings(st)
    elseif id == "clear" then
        clearTask(st)
    elseif id == "dir" then
        cycleDirection(st)
    elseif id == "view" then
        st.view = (st.view % #VIEWS) + 1
        saveSettings(st)
    elseif id == "stop" then
        finishExport(st, "Stopped by user", "warn")
    end
end

function M.onEvent(st, event, p1, p2, p3, p4)
    if event == "mouse_click" or event == "monitor_touch" then
        syncScrollBar(st)
        if st.sb:onClick(p2, p3) then
            st.scroll = st.sb.scroll
            return st, true
        end
        local id = hitButton(st, p2, p3)
        if id then handleButton(st, id); return st, true end

    elseif event == "mouse_drag" then
        syncScrollBar(st)
        if st.sb:onDrag(p2, p3) then
            st.scroll = st.sb.scroll
            return st, true
        end

    elseif event == "mouse_scroll" then
        syncScrollBar(st)
        st.sb:scrollBy(p1)
        st.scroll = st.sb.scroll
        return st, true

    elseif event == "key" then
        if p1 == keys.r then scan(st); return st, true end
        if p1 == keys.p then startExport(st); st.view = 3; saveSettings(st); return st, true end
        if p1 == keys.c then clearTask(st); return st, true end
        if p1 == keys.tab then st.view = (st.view % #VIEWS) + 1; saveSettings(st); return st, true end
        if p1 == keys.up then st.scroll = math.max(0, (st.scroll or 0) - 1); return st, true end
        if p1 == keys.down then st.scroll = (st.scroll or 0) + 1; return st, true end

    elseif event == "timer" then
        if p1 == st.exportTimer then
            st.exportTimer = nil
            exportStep(st)
            return st, true
        elseif p1 == st.waitTimer then
            st.waitTimer = nil
            waitStep(st)
            return st, true
        end
    end

    return st, false
end

return M
