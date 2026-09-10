local FsUtil = dofile("/os/lib/fsutil.lua")

local M = {}
M.id        = "tetris"
M.name      = "Tetris"
M.icon      = "Tt"
M.iconBg    = colors.cyan
M.iconFg    = colors.black
M.version   = 1
M.category  = "games"

local DB          = "/data/tetris.db"
local BOARD_W     = 10
local MIN_BOARD_H = 10
local MAX_BOARD_H = 20
local PANEL_W     = 11
local MAX_LEVEL   = 15
local MIN_W       = 14
local MIN_H       = 15
local LINE_SCORE  = {100, 300, 500, 800}

local ORDER = {"I", "O", "T", "S", "Z", "J", "L"}
local SHAPES = {
    I = {color = colors.cyan, states = {
        {{0, 1}, {1, 1}, {2, 1}, {3, 1}},
        {{2, 0}, {2, 1}, {2, 2}, {2, 3}},
        {{0, 2}, {1, 2}, {2, 2}, {3, 2}},
        {{1, 0}, {1, 1}, {1, 2}, {1, 3}},
    }},
    O = {color = colors.yellow, states = {
        {{1, 0}, {2, 0}, {1, 1}, {2, 1}},
        {{1, 0}, {2, 0}, {1, 1}, {2, 1}},
        {{1, 0}, {2, 0}, {1, 1}, {2, 1}},
        {{1, 0}, {2, 0}, {1, 1}, {2, 1}},
    }},
    T = {color = colors.purple, states = {
        {{1, 0}, {0, 1}, {1, 1}, {2, 1}},
        {{1, 0}, {1, 1}, {2, 1}, {1, 2}},
        {{0, 1}, {1, 1}, {2, 1}, {1, 2}},
        {{1, 0}, {0, 1}, {1, 1}, {1, 2}},
    }},
    S = {color = colors.lime, states = {
        {{1, 0}, {2, 0}, {0, 1}, {1, 1}},
        {{1, 0}, {1, 1}, {2, 1}, {2, 2}},
        {{1, 1}, {2, 1}, {0, 2}, {1, 2}},
        {{0, 0}, {0, 1}, {1, 1}, {1, 2}},
    }},
    Z = {color = colors.red, states = {
        {{0, 0}, {1, 0}, {1, 1}, {2, 1}},
        {{2, 0}, {1, 1}, {2, 1}, {1, 2}},
        {{0, 1}, {1, 1}, {1, 2}, {2, 2}},
        {{1, 0}, {0, 1}, {1, 1}, {0, 2}},
    }},
    J = {color = colors.blue, states = {
        {{0, 0}, {0, 1}, {1, 1}, {2, 1}},
        {{1, 0}, {2, 0}, {1, 1}, {1, 2}},
        {{0, 1}, {1, 1}, {2, 1}, {2, 2}},
        {{1, 0}, {1, 1}, {0, 2}, {1, 2}},
    }},
    L = {color = colors.orange, states = {
        {{2, 0}, {0, 1}, {1, 1}, {2, 1}},
        {{1, 0}, {1, 1}, {1, 2}, {2, 2}},
        {{0, 1}, {1, 1}, {2, 1}, {0, 2}},
        {{0, 0}, {1, 0}, {1, 1}, {1, 2}},
    }},
}

-- Rotation offsets tried in order when a plain rotation does not fit.
local KICKS = {{0, 0}, {-1, 0}, {1, 0}, {-2, 0}, {2, 0}, {0, -1}}

-- helpers --------------------------------------------------------------------

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

local function setStatus(st, text)
    st.status = text
end

-- Best scores are kept per start level, so a level change mid-game must not
-- move the running score into another slot.
local function bestKey(st)
    return "L" .. tostring(st.baseLevel)
end

local function bestScore(st)
    return tonumber(st.db.best[bestKey(st)]) or 0
end

local function tickFor(level)
    return math.max(0.06, 0.55 - (level - 1) * 0.05)
end

-- storage --------------------------------------------------------------------

local function loadDb()
    local db = {startLevel = 1, best = {}}
    pcall(FsUtil.ensureDir, "/data")
    local okRead, raw = pcall(FsUtil.readFile, DB)
    if okRead and type(raw) == "string" then
        local ok, t = pcall(textutils.unserialize, raw)
        if ok and type(t) == "table" then
            db.startLevel = clamp(math.floor(tonumber(t.startLevel) or 1), 1, 10)
            db.best = type(t.best) == "table" and t.best or db.best
        end
    end
    return db
end

local function saveDb(st)
    local db = {
        startLevel = st.startLevel,
        best = st.db.best,
    }
    pcall(FsUtil.ensureDir, "/data")
    pcall(FsUtil.atomicWrite, DB, textutils.serialize(db))
end

-- geometry -------------------------------------------------------------------

local function boardHeightFor(H)
    return clamp(H - 5, MIN_BOARD_H, MAX_BOARD_H)
end

local function layout(win)
    local W, H = win.getSize()
    local cellW = (W >= 24) and 2 or 1
    local boardPixW = BOARD_W * cellW + 2
    local panel = W >= boardPixW + 2 + PANEL_W
    local groupW = boardPixW + (panel and (2 + PANEL_W) or 0)
    local left = math.max(1, math.floor((W - groupW) / 2) + 1)
    return {
        W = W, H = H,
        cellW = cellW,
        left = left,
        top = 3,
        panel = panel,
        panelX = left + boardPixW + 2,
    }
end

-- game logic -----------------------------------------------------------------

local function newGrid(h)
    local grid = {}
    for y = 1, h do
        grid[y] = {}
        for x = 1, BOARD_W do grid[y][x] = nil end
    end
    return grid
end

local function refillBag(st)
    local bag = {}
    for i, t in ipairs(ORDER) do bag[i] = t end
    for i = #bag, 2, -1 do
        local j = math.random(i)
        bag[i], bag[j] = bag[j], bag[i]
    end
    st.bag = bag
end

local function takePiece(st)
    if not st.bag or #st.bag == 0 then refillBag(st) end
    return table.remove(st.bag)
end

local function collides(st, ptype, rot, px, py)
    local cells = SHAPES[ptype].states[rot]
    for i = 1, 4 do
        local gx = px + cells[i][1]
        local gy = py + cells[i][2]
        if gx < 1 or gx > BOARD_W or gy > st.boardH then return true end
        if gy >= 1 and st.grid[gy][gx] then return true end
    end
    return false
end

local function finishGame(st)
    st.running = false
    st.gameOver = true
    st.timerId = nil
    st.newBest = st.score > bestScore(st)
    if st.newBest then st.db.best[bestKey(st)] = st.score end
    saveDb(st)
    setStatus(st, "Game over. New to retry")
end

local function spawnPiece(st)
    local ptype = st.nextType or takePiece(st)
    st.nextType = takePiece(st)
    st.piece = {type = ptype, rot = 1, x = 4, y = 1}
    if collides(st, ptype, 1, st.piece.x, st.piece.y) then
        finishGame(st)
    end
end

local function clearLines(st)
    local kept, cleared = {}, 0
    for y = st.boardH, 1, -1 do
        local full = true
        for x = 1, BOARD_W do
            if not st.grid[y][x] then
                full = false
                break
            end
        end
        if full then
            cleared = cleared + 1
        else
            table.insert(kept, 1, st.grid[y])
        end
    end
    if cleared == 0 then return 0 end

    local grid = newGrid(cleared)
    for i, row in ipairs(kept) do grid[cleared + i] = row end
    st.grid = grid
    return cleared
end

local function scheduleTick(st)
    st.timerId = os.startTimer(tickFor(st.level))
end

local function lockPiece(st)
    local p = st.piece
    local cells = SHAPES[p.type].states[p.rot]
    local color = SHAPES[p.type].color
    local lockedOut = false
    for i = 1, 4 do
        local gx = p.x + cells[i][1]
        local gy = p.y + cells[i][2]
        if gy >= 1 then st.grid[gy][gx] = color else lockedOut = true end
    end
    st.piece = nil

    local cleared = clearLines(st)
    if cleared > 0 then
        st.lines = st.lines + cleared
        st.score = st.score + LINE_SCORE[cleared] * st.level
        local level = math.min(MAX_LEVEL, st.baseLevel + math.floor(st.lines / 10))
        if level > st.level then
            st.level = level
            setStatus(st, "Level " .. level)
        end
    end

    if lockedOut then
        finishGame(st)
        return
    end
    spawnPiece(st)
end

local function resetGame(st)
    local _, H = st.win.getSize()
    st.boardH = boardHeightFor(H)
    st.grid = newGrid(st.boardH)
    st.bag = nil
    st.nextType = nil
    st.piece = nil
    st.score = 0
    st.lines = 0
    st.level = st.startLevel
    st.baseLevel = st.startLevel
    st.running = false
    st.gameOver = false
    st.newBest = false
    st.timerId = nil
    spawnPiece(st)
    setStatus(st, "Start or tap a control")
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
        st.timerId = nil
        setStatus(st, "Paused")
    else
        startGame(st)
    end
end

local function tryMove(st, dx, dy)
    local p = st.piece
    if not p then return false end
    if collides(st, p.type, p.rot, p.x + dx, p.y + dy) then return false end
    p.x, p.y = p.x + dx, p.y + dy
    return true
end

local function tryRotate(st, dir)
    local p = st.piece
    if not p then return false end
    local rot = p.rot + dir
    if rot > 4 then rot = 1 elseif rot < 1 then rot = 4 end
    for _, kick in ipairs(KICKS) do
        if not collides(st, p.type, rot, p.x + kick[1], p.y + kick[2]) then
            p.rot = rot
            p.x = p.x + kick[1]
            p.y = p.y + kick[2]
            return true
        end
    end
    return false
end

local function ghostY(st)
    local p = st.piece
    local y = p.y
    while not collides(st, p.type, p.rot, p.x, y + 1) do y = y + 1 end
    return y
end

local function gravityStep(st)
    if not tryMove(st, 0, 1) then
        lockPiece(st)
    end
    if st.running then scheduleTick(st) end
end

-- Controls auto-start a fresh game, but never revive a finished one:
-- after game over only New or Start may clear the final board.
local function ensureRunning(st)
    if st.gameOver then return false end
    if not st.running then startGame(st) end
    return st.running
end

local function softDrop(st)
    if not ensureRunning(st) then return end
    if tryMove(st, 0, 1) then
        st.score = st.score + 1
        scheduleTick(st)
    end
end

local function hardDrop(st)
    if not ensureRunning(st) then return end
    local rows = 0
    while tryMove(st, 0, 1) do rows = rows + 1 end
    st.score = st.score + rows * 2
    lockPiece(st)
    if st.running then scheduleTick(st) end
end

local function moveSide(st, dx)
    if not ensureRunning(st) then return end
    tryMove(st, dx, 0)
end

local function rotate(st, dir)
    if not ensureRunning(st) then return end
    tryRotate(st, dir)
end

local function cycleLevel(st)
    st.startLevel = st.startLevel % 10 + 1
    if not st.running and not st.gameOver and st.lines == 0 and st.score == 0 then
        st.level = st.startLevel
        st.baseLevel = st.startLevel
        setStatus(st, "Start level " .. st.startLevel)
    else
        setStatus(st, "Start level " .. st.startLevel .. " (next game)")
    end
    saveDb(st)
end

-- drawing --------------------------------------------------------------------

local ACTIONS = {
    new    = resetGame,
    pause  = pauseGame,
    level  = cycleLevel,
    rotate = function(st) rotate(st, 1) end,
    left   = function(st) moveSide(st, -1) end,
    right  = function(st) moveSide(st, 1) end,
    down   = softDrop,
    drop   = hardDrop,
}

-- Every button registers its own hit box while it is drawn, so a button can
-- never be tappable where it is not visible, or visible where it is not tappable.
local function button(st, win, x, y, text, bg, fg, action)
    writeAt(win, x, y, bg, fg, text)
    st.hit[#st.hit + 1] = {x1 = x, x2 = x + #text - 1, y = y, action = action}
end

local function drawTitle(st, win, W)
    writeAt(win, 1, 1, colors.cyan, colors.black, string.rep(" ", W))
    writeAt(win, 1, 1, colors.cyan, colors.black, " Tetris ")
    local right = "Score " .. st.score .. "  Best " .. bestScore(st)
    if W >= #right + 9 then
        writeAt(win, W - #right + 1, 1, colors.cyan, colors.black, right)
    end
end

local function drawToolbar(st, win, W)
    local pauseBg = st.running and colors.orange or colors.green
    local pauseText = st.running and "Pause" or "Start"
    if W >= 27 then
        button(st, win, 1, 2, "[ New ]", colors.gray, colors.white, "new")
        button(st, win, 9, 2, "[ " .. pauseText .. " ]", pauseBg, colors.white, "pause")
        button(st, win, 19, 2, "[ Lv " .. st.startLevel .. " ]", colors.gray, colors.white, "level")
    else
        button(st, win, 1, 2, "[N]", colors.gray, colors.white, "new")
        button(st, win, 5, 2, "[" .. string.sub(pauseText, 1, 1) .. "]", pauseBg, colors.white, "pause")
        button(st, win, 9, 2, "[L" .. st.startLevel .. "]", colors.gray, colors.white, "level")
    end
end

local function drawBoard(st, win, L)
    local cellW, left, top = L.cellW, L.left, L.top
    local empty = "." .. string.rep(" ", cellW - 1)
    local fill  = string.rep(" ", cellW)
    local ghost = string.rep(":", cellW)

    local active, shadow = {}, {}
    local p = st.piece
    if p then
        local cells = SHAPES[p.type].states[p.rot]
        local gy = ghostY(st)
        for i = 1, 4 do
            local cx, cy = cells[i][1], cells[i][2]
            local ay = p.y + cy
            active[ay] = active[ay] or {}
            active[ay][p.x + cx] = SHAPES[p.type].color
            shadow[gy + cy] = shadow[gy + cy] or {}
            shadow[gy + cy][p.x + cx] = SHAPES[p.type].color
        end
    end

    -- A window shrunk mid-game keeps its taller board: show the bottom rows
    -- rather than painting over the control and status rows.
    local visible = math.min(st.boardH, L.H - 5)
    if visible < 1 then return end
    local firstRow = st.boardH - visible + 1

    local rightX = left + 1 + BOARD_W * cellW
    for y = firstRow, st.boardH do
        local sy = top + y - firstRow
        writeAt(win, left, sy, colors.gray, colors.gray, " ")
        for x = 1, BOARD_W do
            local sx = left + 1 + (x - 1) * cellW
            local piece = active[y] and active[y][x]
            local locked = st.grid[y][x]
            local hint = shadow[y] and shadow[y][x]
            if piece then
                writeAt(win, sx, sy, piece, colors.black, fill)
            elseif locked then
                writeAt(win, sx, sy, locked, colors.black, fill)
            elseif hint then
                writeAt(win, sx, sy, colors.black, hint, ghost)
            else
                writeAt(win, sx, sy, colors.black, colors.gray, empty)
            end
        end
        writeAt(win, rightX, sy, colors.gray, colors.gray, " ")
    end
end

local function drawPanel(st, win, L)
    local x, top, cellW = L.panelX, L.top, L.cellW
    local fill = string.rep(" ", cellW)
    writeAt(win, x, top, colors.black, colors.lightGray, padR("Next", PANEL_W))

    local marks = {}
    if st.nextType then
        local cells = SHAPES[st.nextType].states[1]
        for i = 1, 4 do
            local cx, cy = cells[i][1], cells[i][2]
            marks[cy] = marks[cy] or {}
            marks[cy][cx] = true
        end
    end
    local color = st.nextType and SHAPES[st.nextType].color or colors.black
    for row = 0, 3 do
        for col = 0, 3 do
            local on = marks[row] and marks[row][col]
            writeAt(win, x + col * cellW, top + 1 + row, on and color or colors.black,
                colors.black, fill)
        end
    end

    writeAt(win, x, top + 6, colors.black, colors.white, padR("Level " .. st.level, PANEL_W))
    writeAt(win, x, top + 7, colors.black, colors.white, padR("Lines " .. st.lines, PANEL_W))
end

local function drawControls(st, win, W, H)
    local y1, y2 = H - 2, H - 1
    local bg, fg = colors.gray, colors.white
    if W >= 24 then
        local cx = math.floor((W - 5) / 2) + 1
        button(st, win, cx, y1, "[ ^ ]", bg, fg, "rotate")
        if cx + 11 <= W then
            button(st, win, cx + 6, y1, "[Drop]", bg, fg, "drop")
        end
        button(st, win, cx - 6, y2, "[ < ]", bg, fg, "left")
        button(st, win, cx, y2, "[ v ]", bg, fg, "down")
        button(st, win, cx + 6, y2, "[ > ]", bg, fg, "right")
    else
        local cx = math.floor((W - 3) / 2) + 1
        button(st, win, cx, y1, "[^]", bg, fg, "rotate")
        button(st, win, W - 2, y1, "[D]", bg, fg, "drop")
        button(st, win, 1, y2, "[<]", bg, fg, "left")
        button(st, win, cx, y2, "[v]", bg, fg, "down")
        button(st, win, W - 2, y2, "[>]", bg, fg, "right")
    end
end

local function drawStatus(st, win, W, H)
    local fg = colors.white
    if st.gameOver then fg = colors.red
    elseif st.newBest then fg = colors.yellow end
    local extra = st.newBest and " New best!" or ""
    writeAt(win, 1, H, colors.black, fg, padR((st.status or "") .. extra, W))
end

-- app ------------------------------------------------------------------------

function M.init(win, ctx)
    math.randomseed(nowMs() % 2147483647)
    local db = loadDb()
    local st = {
        win = win,
        ctx = ctx,
        db = db,
        startLevel = db.startLevel,
        hit = {},
    }
    resetGame(st)
    return st
end

function M.draw(st, win)
    st.win = win
    st.hit = {}
    local W, H = win.getSize()
    win.setBackgroundColor(colors.black)
    win.setTextColor(colors.white)
    win.clear()
    if W < MIN_W or H < MIN_H then
        writeAt(win, 1, 1, colors.black, colors.red, "Too small")
        return
    end
    if not st.running and not st.gameOver and boardHeightFor(H) ~= st.boardH then
        resetGame(st)
    end
    local L = layout(win)
    drawTitle(st, win, W)
    drawToolbar(st, win, W)
    drawBoard(st, win, L)
    if L.panel then drawPanel(st, win, L) end
    drawControls(st, win, W, H)
    drawStatus(st, win, W, H)
end

local function handleTap(st, x, y)
    for i = 1, #st.hit do
        local b = st.hit[i]
        if y == b.y and x >= b.x1 and x <= b.x2 then
            ACTIONS[b.action](st)
            return true
        end
    end
    return false
end

function M.onEvent(st, e, p1, p2, p3)
    if e == "timer" then
        if st.running and p1 == st.timerId then
            gravityStep(st)
            return st, true
        end
    elseif e == "key" then
        local k = p1
        if k == keys.left then moveSide(st, -1); return st, true end
        if k == keys.right then moveSide(st, 1); return st, true end
        if k == keys.up or k == keys.x then rotate(st, 1); return st, true end
        if k == keys.z then rotate(st, -1); return st, true end
        if k == keys.down then softDrop(st); return st, true end
        if k == keys.space then hardDrop(st); return st, true end
        if k == keys.enter or k == keys.p then pauseGame(st); return st, true end
        if k == keys.r or k == keys.n then resetGame(st); return st, true end
        if k == keys.l then cycleLevel(st); return st, true end
        if k == keys.escape or k == keys.q then return st, false end
    elseif e == "char" then
        local c = string.lower(tostring(p1 or ""))
        if c == "a" then moveSide(st, -1); return st, true end
        if c == "d" then moveSide(st, 1); return st, true end
        if c == "w" then rotate(st, 1); return st, true end
        if c == "s" then softDrop(st); return st, true end
        if c == "q" then return st, false end
    elseif e == "mouse_click" or e == "monitor_touch" then
        local button, x, y = p1, p2, p3
        if e == "monitor_touch" then button, x, y = 1, p2, p3 end
        if button == 1 and handleTap(st, x, y) then return st, true end
    end
    return st, false
end

function M.onClose(st)
    if st then saveDb(st) end
end

return M
