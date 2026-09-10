local FsUtil = dofile("/os/lib/fsutil.lua")

local M = {}
M.id        = "snake"
M.name      = "Snake"
M.icon      = "Sn"
M.iconBg    = colors.lime
M.iconFg    = colors.black
M.version   = 2
M.category  = "games"

local DB = "/data/snake.db"
local SPEEDS = {
    {id = "slow",   name = "Slow",   tick = 0.36},
    {id = "normal", name = "Normal", tick = 0.24},
    {id = "fast",   name = "Fast",   tick = 0.15},
}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function padR(s, width)
    s = tostring(s or "")
    if #s >= width then return string.sub(s, 1, width) end
    return s .. string.rep(" ", width - #s)
end

local function nowMs()
    if os.epoch then return os.epoch("utc") end
    return math.floor(os.clock() * 1000)
end

local function writeAt(win, x, y, bg, fg, text)
    win.setCursorPos(x, y)
    win.setBackgroundColor(bg)
    win.setTextColor(fg)
    win.write(tostring(text or ""))
end

local function speedById(id)
    for i, s in ipairs(SPEEDS) do
        if s.id == id then return i, s end
    end
    return 2, SPEEDS[2]
end

local function loadDb()
    local db = {speed = "normal", best = {}}
    pcall(FsUtil.ensureDir, "/data")
    local okRead, raw = pcall(FsUtil.readFile, DB)
    if okRead and type(raw) == "string" then
        local ok, t = pcall(textutils.unserialize, raw)
        if ok and type(t) == "table" then
            db.speed = t.speed or db.speed
            db.best = type(t.best) == "table" and t.best or db.best
        end
    end
    if not speedById(db.speed) then db.speed = "normal" end
    return db
end

local function saveDb(st)
    local db = {
        speed = st.speed.id,
        best = st.db.best,
    }
    pcall(FsUtil.ensureDir, "/data")
    pcall(FsUtil.atomicWrite, DB, textutils.serialize(db))
end

local function boardSize(win)
    local W, H = win.getSize()
    return math.max(1, W), math.max(1, H - 5)
end

local function samePos(a, b)
    return a.x == b.x and a.y == b.y
end

local function snakeHas(st, x, y)
    for _, p in ipairs(st.snake) do
        if p.x == x and p.y == y then return true end
    end
    return false
end

local function placeFood(st)
    local free = {}
    for y = 1, st.bh do
        for x = 1, st.bw do
            if not snakeHas(st, x, y) then
                table.insert(free, {x = x, y = y})
            end
        end
    end
    if #free == 0 then
        st.food = nil
        return false
    end
    st.food = free[math.random(#free)]
    return true
end

local function setStatus(st, text)
    st.status = text
end

local function cancelTimer(st)
    st.timerId = nil
end

local function scheduleTick(st)
    st.timerId = os.startTimer(st.speed.tick)
end

local function resetGame(st)
    st.bw, st.bh = boardSize(st.win)
    local midX = math.max(3, math.floor(st.bw / 2))
    local midY = math.max(1, math.floor(st.bh / 2))
    st.snake = {
        {x = clamp(midX, 1, st.bw), y = clamp(midY, 1, st.bh)},
        {x = clamp(midX - 1, 1, st.bw), y = clamp(midY, 1, st.bh)},
        {x = clamp(midX - 2, 1, st.bw), y = clamp(midY, 1, st.bh)},
    }
    if st.bw < 3 then
        st.snake = {{x = 1, y = 1}}
    end
    st.dir = {x = 1, y = 0}
    st.nextDir = {x = 1, y = 0}
    st.score = 0
    st.running = false
    st.gameOver = false
    st.winGame = false
    st.newBest = false
    cancelTimer(st)
    placeFood(st)
    setStatus(st, "Start or tap a direction")
    saveDb(st)
end

local function finishGame(st, won)
    st.running = false
    st.gameOver = true
    st.winGame = won
    cancelTimer(st)
    local best = tonumber(st.db.best[st.speed.id]) or 0
    st.newBest = st.score > best
    if st.newBest then
        st.db.best[st.speed.id] = st.score
        saveDb(st)
    end
    setStatus(st, won and "WIN! New for next game" or "Game over. New to retry")
end

local function startGame(st)
    if st.gameOver then resetGame(st) end
    if not st.running then
        st.running = true
        setStatus(st, "Running")
        scheduleTick(st)
    end
end

local function pauseGame(st)
    if st.running then
        st.running = false
        cancelTimer(st)
        setStatus(st, "Paused")
    elseif not st.gameOver then
        startGame(st)
    end
end

local function isOpposite(a, b)
    return a.x + b.x == 0 and a.y + b.y == 0
end

local function setDirection(st, x, y)
    local nd = {x = x, y = y}
    if #st.snake > 1 and isOpposite(st.dir, nd) then return end
    st.nextDir = nd
    if not st.running and not st.gameOver then startGame(st) end
end

local function stepGame(st)
    if not st.running then return end

    st.dir = st.nextDir
    local head = st.snake[1]
    local nextHead = {x = head.x + st.dir.x, y = head.y + st.dir.y}

    if nextHead.x < 1 or nextHead.y < 1 or nextHead.x > st.bw or nextHead.y > st.bh then
        finishGame(st, false)
        return
    end

    local eating = st.food and samePos(nextHead, st.food)
    local checkUntil = eating and #st.snake or (#st.snake - 1)
    for i = 1, checkUntil do
        if samePos(nextHead, st.snake[i]) then
            finishGame(st, false)
            return
        end
    end

    table.insert(st.snake, 1, nextHead)
    if eating then
        st.score = st.score + 1
        if not placeFood(st) then
            finishGame(st, true)
            return
        end
    else
        table.remove(st.snake)
    end
    scheduleTick(st)
end

local function cycleSpeed(st)
    local idx = speedById(st.speed.id)
    idx = idx + 1
    if idx > #SPEEDS then idx = 1 end
    st.speed = SPEEDS[idx]
    setStatus(st, "Speed: " .. st.speed.name)
    if st.running then scheduleTick(st) end
    saveDb(st)
end

local function drawTitle(st, win, W)
    writeAt(win, 1, 1, colors.lime, colors.black, string.rep(" ", W))
    writeAt(win, 1, 1, colors.lime, colors.black, " Snake ")
    local best = tonumber(st.db.best[st.speed.id]) or 0
    local right = "Score " .. st.score .. "  Best " .. best
    if W >= #right then
        writeAt(win, W - #right + 1, 1, colors.lime, colors.black, right)
    end
end

local function drawToolbar(st, win, W)
    writeAt(win, 1, 2, colors.black, colors.white, string.rep(" ", W))
    writeAt(win, 1, 2, colors.gray, colors.white, "[ New ]")
    if W >= 17 then
        writeAt(win, 9, 2, st.running and colors.orange or colors.green, colors.white,
            st.running and "[ Pause ]" or "[ Start ]")
    end
    local speedText = "[ " .. st.speed.name .. " ]"
    if W >= 19 + #speedText then
        writeAt(win, 19, 2, colors.gray, colors.white, speedText)
    end
end

local function drawControls(st, win, W, H)
    local y1, y2 = H - 2, H - 1
    if y1 < 4 then return end
    writeAt(win, 1, y1, colors.black, colors.white, string.rep(" ", W))
    writeAt(win, 1, y2, colors.black, colors.white, string.rep(" ", W))

    local cx = math.max(1, math.floor((W - 5) / 2) + 1)
    writeAt(win, cx, y1, colors.gray, colors.white, "[ ^ ]")
    if cx - 6 >= 1 then writeAt(win, cx - 6, y2, colors.gray, colors.white, "[ < ]") end
    writeAt(win, cx, y2, colors.gray, colors.white, "[ v ]")
    if cx + 6 <= W - 4 then writeAt(win, cx + 6, y2, colors.gray, colors.white, "[ > ]") end

    if W >= 18 then
        writeAt(win, 1, y2, st.running and colors.orange or colors.green, colors.white,
            st.running and "[Pause]" or "[Start]")
    end
    if W >= 16 then
        local speedText = "[" .. st.speed.name .. "]"
        writeAt(win, W - #speedText + 1, y2, colors.gray, colors.white, speedText)
    end
end

local function drawBoard(st, win)
    local W, H = win.getSize()
    local visibleW = math.min(st.bw, W)
    local visibleH = math.min(st.bh, math.max(1, H - 5))
    local grid = {}
    for y = 1, st.bh do grid[y] = {} end

    if st.food then grid[st.food.y][st.food.x] = "food" end
    for i = #st.snake, 1, -1 do
        local p = st.snake[i]
        grid[p.y][p.x] = (i == 1) and "head" or "body"
    end

    for y = 1, visibleH do
        for x = 1, visibleW do
            local cell = grid[y][x]
            local sy = y + 2
            if cell == "head" then
                writeAt(win, x, sy, colors.lime, colors.black, "O")
            elseif cell == "body" then
                writeAt(win, x, sy, colors.green, colors.black, "o")
            elseif cell == "food" then
                writeAt(win, x, sy, colors.red, colors.white, "@")
            else
                writeAt(win, x, sy, colors.black, colors.gray, ".")
            end
        end
        if visibleW < W then
            writeAt(win, visibleW + 1, y + 2, colors.black, colors.white, string.rep(" ", W - visibleW))
        end
    end
    for y = visibleH + 3, H - 3 do
        writeAt(win, 1, y, colors.black, colors.white, string.rep(" ", W))
    end
end

local function drawStatus(st, win, W, H)
    local fg = colors.white
    if st.winGame then fg = colors.lime
    elseif st.gameOver then fg = colors.red
    elseif st.newBest then fg = colors.yellow end
    local extra = ""
    if st.newBest then extra = " New best!" end
    writeAt(win, 1, H, colors.black, fg, padR((st.status or "") .. extra, W))
end

function M.init(win, ctx)
    math.randomseed(nowMs() % 2147483647)
    local db = loadDb()
    local _, speed = speedById(db.speed)
    local st = {
        win = win,
        ctx = ctx,
        db = db,
        speed = speed,
    }
    resetGame(st)
    return st
end

function M.draw(st, win)
    st.win = win
    local W, H = win.getSize()
    win.setBackgroundColor(colors.black)
    win.setTextColor(colors.white)
    win.clear()
    if W < 12 or H < 8 then
        writeAt(win, 1, 1, colors.black, colors.red, "Too small")
        return
    end
    if not st.running and not st.gameOver then
        local bw, bh = boardSize(win)
        if bw ~= st.bw or bh ~= st.bh then resetGame(st) end
    end
    drawTitle(st, win, W)
    drawToolbar(st, win, W)
    drawBoard(st, win)
    drawControls(st, win, W, H)
    drawStatus(st, win, W, H)
end

local function handleControlTap(st, x, y)
    local W, H = st.win.getSize()
    if y == 2 then
        if x >= 1 and x <= 7 then resetGame(st); return true end
        if x >= 9 and x <= 17 then pauseGame(st); return true end
        if x >= 19 and x <= 30 then cycleSpeed(st); return true end
    end

    local y1, y2 = H - 2, H - 1
    local cx = math.max(1, math.floor((W - 5) / 2) + 1)
    if y == y1 and x >= cx and x <= cx + 4 then setDirection(st, 0, -1); return true end
    if y == y2 then
        if x >= cx - 6 and x <= cx - 2 then setDirection(st, -1, 0); return true end
        if x >= cx and x <= cx + 4 then setDirection(st, 0, 1); return true end
        if x >= cx + 6 and x <= cx + 10 then setDirection(st, 1, 0); return true end
        if x >= 1 and x <= 7 then pauseGame(st); return true end
        local speedText = "[" .. st.speed.name .. "]"
        if x >= W - #speedText + 1 and x <= W then cycleSpeed(st); return true end
    end
    return false
end

function M.onEvent(st, e, p1, p2, p3)
    if e == "timer" then
        if st.running and p1 == st.timerId then
            stepGame(st)
            return st, true
        end
    elseif e == "key" then
        local k = p1
        if k == keys.up then setDirection(st, 0, -1); return st, true end
        if k == keys.down then setDirection(st, 0, 1); return st, true end
        if k == keys.left then setDirection(st, -1, 0); return st, true end
        if k == keys.right then setDirection(st, 1, 0); return st, true end
        if k == keys.space or k == keys.enter then pauseGame(st); return st, true end
        if k == keys.r then resetGame(st); return st, true end
        if k == keys.d then cycleSpeed(st); return st, true end
        if k == keys.escape or k == keys.q then return st, false end
    elseif e == "char" then
        local c = string.lower(tostring(p1 or ""))
        if c == "w" then setDirection(st, 0, -1); return st, true end
        if c == "s" then setDirection(st, 0, 1); return st, true end
        if c == "a" then setDirection(st, -1, 0); return st, true end
        if c == "d" then setDirection(st, 1, 0); return st, true end
        if c == "r" then resetGame(st); return st, true end
        if c == "p" then pauseGame(st); return st, true end
        if c == "f" then cycleSpeed(st); return st, true end
        if c == "q" then return st, false end
    elseif e == "mouse_click" or e == "monitor_touch" then
        local button, x, y = p1, p2, p3
        if e == "monitor_touch" then button, x, y = 1, p2, p3 end
        if button == 1 then
            if handleControlTap(st, x, y) then return st, true end
        end
    end
    return st, false
end

function M.onClose(st)
    if st then saveDb(st) end
end

return M
