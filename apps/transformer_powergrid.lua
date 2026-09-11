-- Transformer - PowerGrid transformer winding calculator.
-- Подбирает витки обмоток (Np:Ns) под нужное выходное напряжение.
--
-- Физика мода PowerGrid: на холостом ходу Vout = Vin*(Ns/Np) ТОЧНО (проверено по
-- байткоду: рассеяние ~1e-4 Ом против ~735 Ом ветви намагничивания).
-- Лимит суммарный: Np + Ns <= maxTurns (small 60, medium 240).
--
-- Ввод дробных вольт поддерживается. Цифры вводятся с экранной клавиатуры
-- (справа, в стиле экрана входа) и с физической клавиатуры.

local FsUtil = dofile("/os/lib/fsutil.lua")

local M = {}
M.id       = "transformer_powergrid"
M.name     = "Transformer (PowerGrid)"
M.icon     = "Tx"
M.iconBg   = colors.orange
M.iconFg   = colors.black
M.version  = 10
M.category = "automation"

local DB = "/data/transformer_powergrid.db"

local SIZES = {
    { id = "small",  label = "[Sm]", maxTurns = 60  },
    { id = "medium", label = "[Md]", maxTurns = 240 },
}
local MODES = { "exact", "range", "max" }

local function sizeFor(sizeId)
    for _, s in ipairs(SIZES) do if s.id == sizeId then return s end end
    return SIZES[1]
end

-- Раскладка числовой клавиатуры (как на экране входа).
-- Цифры + десятичная точка + backspace ("X"). Кнопка OK — отдельная широкая
-- полоса под клавиатурой (рисуется в drawKeypad).
local KEYPAD = {
    { 7, 8, 9 },
    { 4, 5, 6 },
    { 1, 2, 3 },
    { ".", 0, "X" },
}
local BTN_W, BTN_H = 3, 1

-- ── Вспомогательные функции рисования ───────────────────────────────────────

local function writeAt(win, x, y, bg, fg, text)
    win.setCursorPos(x, y)
    win.setBackgroundColor(bg)
    win.setTextColor(fg)
    win.write(tostring(text or ""))
end

local function padC(s, w)
    s = tostring(s or "")
    if #s >= w then return string.sub(s, 1, w) end
    local pad = w - #s
    local l = math.floor(pad / 2)
    return string.rep(" ", l) .. s .. string.rep(" ", pad - l)
end

-- Тема рабочего стола (как у системных экранов), с безопасными запасными цветами.
local function getTheme(ctx)
    local ok, themes = pcall(function() return ctx and ctx.themes and ctx.themes() end)
    local idx = (ctx and ctx.desktop and ctx.desktop.themeIndex) or 1
    if ok and type(themes) == "table" and themes[idx] then
        return themes[idx]
    end
    return {}
end

-- Короткое строковое представление числа (без лишних нулей в дробной части).
local function fmtNum(v)
    if v == nil then return "-" end
    if math.abs(v - math.floor(v + 0.5)) < 1e-6 then
        return tostring(math.floor(v + 0.5))
    end
    local s = string.format("%.2f", v)
    s = string.gsub(s, "0+$", "")
    s = string.gsub(s, "%.$", "")
    return s
end

-- ── Солвер: перебор целых Np, Ns при Np + Ns <= maxTurns ─────────────────────

-- Возвращает таблицу результата:
--   { status = "exact"|"closest"|"in range"|"<= max"|"too high"|"err",
--     msg, np, ns, ratio, vout }
local function solve(st)
    local vin = tonumber(st.inputs.vin)
    if not vin or vin <= 0 then
        return { status = "err", msg = "Set Vin > 0" }
    end
    local maxT = sizeFor(st.size).maxTurns
    local mode = st.mode

    -- Параметры цели по режиму.
    local T, lo, hi, cap
    if mode == "exact" then
        T = tonumber(st.inputs.target)
        if not T or T <= 0 then return { status = "err", msg = "Set target > 0" } end
    elseif mode == "range" then
        lo = tonumber(st.inputs.rmin)
        hi = tonumber(st.inputs.rmax)
        if not lo or not hi or lo <= 0 or hi <= 0 then
            return { status = "err", msg = "Set Lo and Hi" }
        end
        if lo > hi then lo, hi = hi, lo end
    else -- "max"
        cap = tonumber(st.inputs.target)
        if not cap or cap <= 0 then return { status = "err", msg = "Set max > 0" } end
    end

    local best, bestScore, bestFeasible
    for np = 1, maxT - 1 do
        for ns = 1, maxT - np do
            local vout = vin * ns / np
            local feasible, score
            if mode == "exact" then
                local diff = math.abs(vout - T)
                feasible = diff < 1e-6
                score = diff * 1e6 + (np + ns)
            elseif mode == "range" then
                if vout >= lo and vout <= hi then
                    feasible = true
                    local mid = (lo + hi) / 2
                    score = (np + ns) + math.abs(vout - mid) * 1e-3
                else
                    feasible = false
                    local d = (vout < lo) and (lo - vout) or (vout - hi)
                    score = 1e9 + d * 1e6 + (np + ns)
                end
            else -- "max"
                if vout <= cap then
                    feasible = true
                    score = (cap - vout) * 1e6 + (np + ns)
                else
                    feasible = false
                    score = 1e9 + (vout - cap) * 1e6 + (np + ns)
                end
            end
            if not bestScore or score < bestScore then
                bestScore, best, bestFeasible = score, { np = np, ns = ns, vout = vout }, feasible
            end
        end
    end

    if not best then
        return { status = "err", msg = "No solution" }
    end

    local status
    if mode == "exact" then
        status = bestFeasible and "exact" or "closest"
    elseif mode == "range" then
        status = bestFeasible and "in range" or "closest"
    else
        status = bestFeasible and "<= max" or "too high"
    end

    return {
        status = status,
        np     = best.np,
        ns     = best.ns,
        ratio  = best.ns / best.np,
        vout   = best.vout,
    }
end

-- ── Сохранение/загрузка настроек ─────────────────────────────────────────────

local function loadDb()
    local db = { vin = "", size = "small", mode = "exact" }
    local ok, raw = pcall(FsUtil.readFile, DB)
    if ok and type(raw) == "string" then
        local okU, t = pcall(textutils.unserialize, raw)
        if okU and type(t) == "table" then
            db.vin = tostring(t.vin or "")
            for _, s in ipairs(SIZES) do if t.size == s.id then db.size = s.id end end
            for _, m in ipairs(MODES) do if t.mode == m then db.mode = m end end
        end
    end
    return db
end

local function saveDb(st)
    local db = { vin = st.inputs.vin, size = st.size, mode = st.mode }
    pcall(FsUtil.ensureDir, "/data")
    pcall(FsUtil.atomicWrite, DB, textutils.serialize(db))
end

-- ── Геометрия и интерактивные зоны ───────────────────────────────────────────

-- Строит описание UI (позиции клавиатуры, кнопок и полей) под размер окна.
-- Используется и в draw, и в обработке кликов — единый источник координат.
local function buildUI(st, W, H)
    local halfW  = math.floor(W / 2)
    local rightX = halfW + 2
    local rightW = W - halfW - 1
    local kpadW  = 3 * (BTN_W + 1) - 1
    local kpadX  = rightX + math.floor((rightW - kpadW) / 2)
    local kpadY  = math.floor(H / 2) - 1

    local buttons = {
        { id = "mode_exact",  x = 1, y = 3, w = 4, label = "[Ex]", on = (st.mode == "exact") },
        { id = "mode_range",  x = 5, y = 3, w = 4, label = "[Rg]", on = (st.mode == "range") },
        { id = "mode_max",    x = 9, y = 3, w = 4, label = "[Mx]", on = (st.mode == "max") },
        { id = "size_small",  x = 1, y = 5, w = 4, label = "[Sm]", on = (st.size == "small") },
        { id = "size_medium", x = 5, y = 5, w = 4, label = "[Md]", on = (st.size == "medium") },
    }

    local fields = {
        { id = "vin", key = "vin", x = 1, y = 7, labelW = 4, label = "Vin:" },
    }
    if st.mode == "range" then
        fields[#fields + 1] = { id = "rmin", key = "rmin", x = 1, y = 9,  labelW = 4, label = "Lo: " }
        fields[#fields + 1] = { id = "rmax", key = "rmax", x = 1, y = 10, labelW = 4, label = "Hi: " }
    else
        local lbl = (st.mode == "max") and "Max:" or "Out:"
        fields[#fields + 1] = { id = "target", key = "target", x = 1, y = 9, labelW = 4, label = lbl }
    end

    local resultY = 12

    return {
        halfW = halfW, rightX = rightX, rightW = rightW,
        kpadX = kpadX, kpadY = kpadY, kpadW = kpadW,
        okX = kpadX, okW = kpadW, okY = kpadY + #KEYPAD * (BTN_H + 1),
        buttons = buttons, fields = fields,
        resultY = resultY,
    }
end

-- ── Отрисовка ────────────────────────────────────────────────────────────────

local function drawKeypad(win, ui, theme)
    local ac = theme.accentBg or colors.cyan
    for row, keys in ipairs(KEYPAD) do
        local y = ui.kpadY + (row - 1) * (BTN_H + 1)
        for col, k in ipairs(keys) do
            local x = ui.kpadX + (col - 1) * (BTN_W + 1)
            local kbg = (k == "X") and colors.red or ac
            local kfg = (kbg == colors.red) and colors.white or colors.black
            writeAt(win, x, y, kbg, kfg, padC(tostring(k), BTN_W))
        end
    end
    -- Широкая кнопка OK (= посчитать) под клавиатурой.
    writeAt(win, ui.okX, ui.okY, colors.green, colors.white, padC("OK", ui.okW))
end

function M.draw(st, win)
    st.win = win
    local W, H = win.getSize()
    local theme = getTheme(st.ctx)
    local bg = theme.pageBg   or colors.black
    local hb = theme.headerBg or colors.blue
    local hf = theme.headerFg or colors.white
    local ac = theme.accentBg or colors.cyan
    local sf = theme.rowFg    or colors.white
    local mf = theme.mutedFg  or colors.lightGray

    win.setBackgroundColor(bg)
    win.clear()

    if W < 22 or H < 14 then
        writeAt(win, 1, 1, bg, colors.red, "Window too small")
        return
    end

    local ui = buildUI(st, W, H)

    -- Заголовок
    writeAt(win, 1, 1, hb, hf, string.sub(" Transformer ", 1, ui.halfW))

    -- Разделитель половин
    win.setTextColor(colors.gray); win.setBackgroundColor(bg)
    for y = 1, H do win.setCursorPos(ui.halfW + 1, y); win.write("|") end

    -- Кнопки режима и размера
    for _, b in ipairs(ui.buttons) do
        local bbg = b.on and ac or colors.gray
        local bfg = b.on and colors.black or colors.white
        writeAt(win, b.x, b.y, bbg, bfg, b.label)
    end
    -- Лимит суммы витков рядом с кнопками размера
    writeAt(win, 10, 5, bg, mf, sizeFor(st.size).maxTurns .. "t")

    -- Поля ввода
    for _, f in ipairs(ui.fields) do
        writeAt(win, f.x, f.y, bg, mf, f.label)
        local boxX = f.x + f.labelW
        local boxW = ui.halfW - f.labelW - 1
        if boxW < 3 then boxW = 3 end
        local focused = (st.focus == f.key)
        local val = st.inputs[f.key] or ""
        local shown = val
        if focused then shown = shown .. "_" end
        shown = string.sub(shown, 1, boxW)
        shown = shown .. string.rep(" ", boxW - #shown)
        writeAt(win, boxX, f.y, focused and ac or colors.gray,
                focused and colors.black or colors.white, shown)
    end

    -- Результат
    local ry = ui.resultY
    local r = st.result
    if not r then
        writeAt(win, 1, ry, bg, mf, "Enter values,")
        writeAt(win, 1, ry + 1, bg, mf, "press OK")
    elseif r.status == "err" then
        writeAt(win, 1, ry, bg, colors.red, string.sub(r.msg or "Error", 1, ui.halfW))
    else
        writeAt(win, 1, ry,     bg, sf, string.sub("Ratio x" .. fmtNum(r.ratio), 1, ui.halfW))
        writeAt(win, 1, ry + 1, bg, colors.yellow, string.sub("Turns " .. r.np .. ":" .. r.ns, 1, ui.halfW))
        writeAt(win, 1, ry + 2, bg, colors.lime, "Out " .. fmtNum(r.vout) .. " V")
        local stColor = (r.status == "closest" or r.status == "too high") and colors.orange or colors.green
        writeAt(win, 1, ry + 3, bg, stColor, string.sub(r.status, 1, ui.halfW))
    end

    -- Клавиатура
    drawKeypad(win, ui, theme)
end

-- ── Ввод ─────────────────────────────────────────────────────────────────────

local function activeFields(st)
    if st.mode == "range" then return { "vin", "rmin", "rmax" } end
    return { "vin", "target" }
end

local function cycleFocus(st)
    local fl = activeFields(st)
    local cur = 1
    for i, k in ipairs(fl) do if k == st.focus then cur = i end end
    st.focus = fl[(cur % #fl) + 1]
end

-- Дописывает символ (цифру или ".") в активное поле. Допускается одна точка;
-- ведущая точка превращается в "0." для корректного разбора.
local function appendChar(st, ch)
    local k = st.focus
    if not k then return end
    ch = tostring(ch)
    local cur = st.inputs[k] or ""
    if ch == "." then
        if string.find(cur, ".", 1, true) then return end
        if cur == "" then cur = "0" end
    end
    if #cur < 7 then st.inputs[k] = cur .. ch end
end

local function backspace(st)
    local k = st.focus
    if not k then return end
    local cur = st.inputs[k] or ""
    st.inputs[k] = string.sub(cur, 1, -2)
end

local function compute(st)
    st.result = solve(st)
    saveDb(st)
end

local function setMode(st, mode)
    st.mode = mode
    st.result = nil
    -- Сбросить фокус, если текущее поле исчезло из набора.
    local valid = false
    for _, k in ipairs(activeFields(st)) do if k == st.focus then valid = true end end
    if not valid then st.focus = "vin" end
end

local function setSize(st, id)
    if st.size == id then return end
    st.size = id
    st.result = nil
end

-- Hit-тест клавиатуры. Возвращает "input"/"backspace"/"ok" + значение.
local function hitKeypad(ui, x, y)
    if y == ui.okY and x >= ui.okX and x < ui.okX + ui.okW then
        return "ok"
    end
    for row, keys in ipairs(KEYPAD) do
        local ky = ui.kpadY + (row - 1) * (BTN_H + 1)
        if y == ky then
            for col, k in ipairs(keys) do
                local kx = ui.kpadX + (col - 1) * (BTN_W + 1)
                if x >= kx and x < kx + BTN_W then
                    if k == "X" then return "backspace" end
                    return "input", tostring(k)
                end
            end
        end
    end
    return nil
end

function M.onEvent(st, event, p1, p2, p3)
    if event == "mouse_click" or event == "monitor_touch" then
        local x, y = p2, p3
        local W, H = st.win.getSize()
        local ui = buildUI(st, W, H)

        -- Клавиатура
        local act, val = hitKeypad(ui, x, y)
        if act == "input" then appendChar(st, val); return st, true end
        if act == "backspace" then backspace(st); return st, true end
        if act == "ok" then compute(st); return st, true end

        -- Кнопки режима и размера
        for _, b in ipairs(ui.buttons) do
            if y == b.y and x >= b.x and x < b.x + b.w then
                if b.id == "mode_exact"      then setMode(st, "exact")
                elseif b.id == "mode_range"  then setMode(st, "range")
                elseif b.id == "mode_max"    then setMode(st, "max")
                elseif b.id == "size_small"  then setSize(st, "small")
                elseif b.id == "size_medium" then setSize(st, "medium") end
                return st, true
            end
        end

        -- Поля ввода (фокус)
        for _, f in ipairs(ui.fields) do
            local boxX = f.x + f.labelW
            local boxW = ui.halfW - f.labelW - 1
            if y == f.y and x >= f.x and x < boxX + boxW then
                st.focus = f.key
                return st, true
            end
        end
        return st, false

    elseif event == "char" then
        if type(p1) == "string" and (string.match(p1, "^%d$") or p1 == ".") then
            appendChar(st, p1)
            return st, true
        end
        return st, false

    elseif event == "key" then
        if p1 == keys.backspace then
            backspace(st); return st, true
        elseif p1 == keys.enter or (keys.numPadEnter and p1 == keys.numPadEnter) then
            compute(st); return st, true
        elseif p1 == keys.tab then
            cycleFocus(st); return st, true
        end
        return st, false
    end
    return st, false
end

function M.init(win, ctx)
    local db = loadDb()
    return {
        win    = win,
        ctx    = ctx,
        mode   = db.mode,
        size   = db.size,
        focus  = "vin",
        inputs = { vin = db.vin or "", target = "", rmin = "", rmax = "" },
        result = nil,
    }
end

function M.onClose(st)
    if st then saveDb(st) end
end

return M
