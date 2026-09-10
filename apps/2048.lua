local FsUtil = dofile("/os/lib/fsutil.lua")

local M = {}
M.id        = "2048"
M.name      = "2048"
M.icon      = "20"
M.iconBg    = colors.yellow
M.iconFg    = colors.black
M.version   = 2
M.category  = "games"

local DB         = "/data/2048.db"
local BOARD_SIZE = 4
local CELL_W     = 4

local TILE_COLORS = {
    [0]    = {bg = colors.gray,      fg = colors.gray},
    [2]    = {bg = colors.white,     fg = colors.black},
    [4]    = {bg = colors.lightGray, fg = colors.black},
    [8]    = {bg = colors.yellow,    fg = colors.black},
    [16]   = {bg = colors.orange,    fg = colors.black},
    [32]   = {bg = colors.lime,      fg = colors.black},
    [64]   = {bg = colors.green,     fg = colors.white},
    [128]  = {bg = colors.cyan,      fg = colors.black},
    [256]  = {bg = colors.blue,      fg = colors.white},
    [512]  = {bg = colors.purple,    fg = colors.white},
    [1024] = {bg = colors.red,       fg = colors.white},
    [2048] = {bg = colors.pink,      fg = colors.black},
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function writeAt(win, x, y, bg, fg, text)
    win.setCursorPos(x, y)
    win.setBackgroundColor(bg)
    win.setTextColor(fg)
    win.write(tostring(text or ""))
end

local function padR(s, width)
    s = tostring(s or "")
    if #s >= width then return string.sub(s, 1, width) end
    return s .. string.rep(" ", width - #s)
end

local function centerText(s, width)
    s = tostring(s or "")
    if #s >= width then return string.sub(s, 1, width) end
    local left = math.floor((width - #s) / 2)
    return string.rep(" ", left) .. s .. string.rep(" ", width - #s - left)
end

-- ── Board geometry ────────────────────────────────────────────────────────────

-- Высота клетки зависит от доступной высоты окна.
-- Строки 1-2 = заголовок + тулбар; после доски нужно 2 строки на кнопки.
local function calcCellH(H)
    local avail = H - 2
    if avail >= BOARD_SIZE * 3 + 2 then return 3
    elseif avail >= BOARD_SIZE * 2 + 2 then return 2
    else return 1 end
end

-- Возвращает: cellH, left, top, upY, arrowY, cx
local function boardGeometry(W, H)
    local cellH  = calcCellH(H)
    local boardW = BOARD_SIZE * CELL_W
    local left   = math.max(1, math.floor((W - boardW) / 2) + 1)
    local top    = 3
    local bottom = top + BOARD_SIZE * cellH - 1
    local upY    = bottom + 1
    local arrowY = bottom + 2
    local cx     = math.max(4, math.floor((W - 5) / 2) + 1)
    return cellH, left, top, upY, arrowY, cx
end

-- ── Game logic ────────────────────────────────────────────────────────────────

local function copyBoard(board)
    local out = {}
    for y = 1, BOARD_SIZE do
        out[y] = {}
        for x = 1, BOARD_SIZE do out[y][x] = board[y][x] end
    end
    return out
end

local function makeBoard()
    local board = {}
    for y = 1, BOARD_SIZE do
        board[y] = {}
        for x = 1, BOARD_SIZE do board[y][x] = nil end
    end
    return board
end

local function boardToCells(board)
    local cells, i = {}, 1
    for y = 1, BOARD_SIZE do
        for x = 1, BOARD_SIZE do
            cells[i] = board[y][x] or 0
            i = i + 1
        end
    end
    return cells
end

local function cellsToBoard(cells)
    if type(cells) ~= "table" then return nil end
    local board = makeBoard()
    local i = 1
    for y = 1, BOARD_SIZE do
        for x = 1, BOARD_SIZE do
            local v = tonumber(cells[i]) or 0
            if v > 0 then board[y][x] = v end
            i = i + 1
        end
    end
    return board
end

local function loadDb()
    local db = {best = 0}
    pcall(FsUtil.ensureDir, "/data")
    local okRead, raw = pcall(FsUtil.readFile, DB)
    if okRead and type(raw) == "string" then
        local ok, t = pcall(textutils.unserialize, raw)
        if ok and type(t) == "table" then
            db.best     = tonumber(t.best) or 0
            db.score    = tonumber(t.score) or 0
            db.won      = not not t.won
            db.gameOver = not not t.gameOver
            db.cells    = t.cells
            if type(t.board) == "table" and type(t.cells) ~= "table" then
                db.cells = boardToCells(t.board)
            end
        end
    end
    return db
end

local function saveDb(st)
    local db = {
        best     = tonumber(st.best) or 0,
        score    = tonumber(st.score) or 0,
        won      = not not st.won,
        gameOver = not not st.gameOver,
        cells    = boardToCells(st.board or makeBoard()),
    }
    pcall(FsUtil.ensureDir, "/data")
    pcall(FsUtil.atomicWrite, DB, textutils.serialize(db))
end

local function emptyCells(board)
    local free = {}
    for y = 1, BOARD_SIZE do
        for x = 1, BOARD_SIZE do
            if not board[y][x] then free[#free + 1] = {x = x, y = y} end
        end
    end
    return free
end

local function boardHasMoves(board)
    if #emptyCells(board) > 0 then return true end
    for y = 1, BOARD_SIZE do
        for x = 1, BOARD_SIZE do
            local v = board[y][x]
            if x < BOARD_SIZE and board[y][x + 1] == v then return true end
            if y < BOARD_SIZE and board[y + 1][x] == v then return true end
        end
    end
    return false
end

local function hasTile(board, target)
    for y = 1, BOARD_SIZE do
        for x = 1, BOARD_SIZE do
            if board[y][x] == target then return true end
        end
    end
    return false
end

local function spawnTile(st)
    local free = emptyCells(st.board)
    if #free == 0 then return false end
    local pos = free[math.random(#free)]
    st.board[pos.y][pos.x] = (math.random() < 0.9) and 2 or 4
    return true
end

local function lineFromBoard(board, dir, index)
    local line = {}
    if dir == "left"  then for x = 1, BOARD_SIZE do line[x] = board[index][x] end
    elseif dir == "right" then for x = 1, BOARD_SIZE do line[x] = board[index][BOARD_SIZE - x + 1] end
    elseif dir == "up"    then for y = 1, BOARD_SIZE do line[y] = board[y][index] end
    elseif dir == "down"  then for y = 1, BOARD_SIZE do line[y] = board[BOARD_SIZE - y + 1][index] end
    end
    return line
end

local function writeLineToBoard(board, dir, index, line)
    if dir == "left"  then for x = 1, BOARD_SIZE do board[index][x] = line[x] end
    elseif dir == "right" then for x = BOARD_SIZE, 1, -1 do board[index][x] = line[BOARD_SIZE - x + 1] end
    elseif dir == "up"    then for y = 1, BOARD_SIZE do board[y][index] = line[y] end
    elseif dir == "down"  then for y = BOARD_SIZE, 1, -1 do board[y][index] = line[BOARD_SIZE - y + 1] end
    end
end

local function mergeLine(line)
    local packed = {}
    for i = 1, BOARD_SIZE do
        if line[i] then packed[#packed + 1] = line[i] end
    end
    local out, scoreDelta, won = {}, 0, false
    local i = 1
    while i <= #packed do
        local v = packed[i]
        if i < #packed and packed[i + 1] == v then
            local merged = v * 2
            out[#out + 1] = merged
            scoreDelta = scoreDelta + merged
            if merged >= 2048 then won = true end
            i = i + 2
        else
            out[#out + 1] = v
            if v >= 2048 then won = true end
            i = i + 1
        end
    end
    local changed = false
    for j = 1, BOARD_SIZE do
        if line[j] ~= out[j] then changed = true; break end
    end
    return out, scoreDelta, won, changed
end

local function updateBest(st)
    if st.score > st.best then st.best = st.score; saveDb(st) end
end

local function resetGame(st, keepBoard)
    st.board    = keepBoard and copyBoard(keepBoard) or makeBoard()
    st.score    = 0
    st.won      = false
    st.gameOver = false
    spawnTile(st); spawnTile(st)
    updateBest(st); saveDb(st)
end

local function startFromDb(st, db)
    st.best = tonumber(db.best) or 0
    local board = cellsToBoard(db.cells)
    if board then
        st.board    = board
        st.score    = tonumber(db.score) or 0
        st.won      = db.won or hasTile(st.board, 2048)
        st.gameOver = not boardHasMoves(st.board)
        if st.score > st.best then st.best = st.score end
        return
    end
    resetGame(st)
end

local function newGame(st)
    resetGame(st)
end

local function move(st, dir)
    if st.gameOver then return false end
    local changed, scoreDelta, wonThisMove = false, 0, false
    for i = 1, BOARD_SIZE do
        local line = lineFromBoard(st.board, dir, i)
        local merged, delta, lineWon, lineChanged = mergeLine(line)
        if lineChanged then changed = true end
        scoreDelta = scoreDelta + delta
        wonThisMove = wonThisMove or lineWon
        writeLineToBoard(st.board, dir, i, merged)
    end
    if not changed then return false end
    st.score = st.score + scoreDelta
    if wonThisMove then st.won = true end
    updateBest(st)
    if not spawnTile(st) or not boardHasMoves(st.board) then
        st.gameOver = true
    end
    saveDb(st)
    return true
end

-- ── Drawing ───────────────────────────────────────────────────────────────────

local function tileStyle(v)
    return TILE_COLORS[v] or {bg = colors.white, fg = colors.black}
end

local function drawTitle(st, win, W)
    writeAt(win, 1, 1, colors.yellow, colors.black, string.rep(" ", W))
    writeAt(win, 1, 1, colors.yellow, colors.black, " 2048 ")
    local right = "Score:" .. st.score .. " Best:" .. st.best
    if #right > W - 6 then
        right = st.score .. "/" .. st.best
    end
    writeAt(win, W - #right + 1, 1, colors.yellow, colors.black, right)
end

-- Тулбар (строка 2): кнопка [New] + статус игры.
local function drawStatus(st, win, W)
    writeAt(win, 1, 2, colors.black, colors.white, string.rep(" ", W))
    writeAt(win, 1, 2, colors.gray,  colors.white, "[ New ]")
    if st.gameOver then
        writeAt(win, 9, 2, colors.red,  colors.white, padR(" GAME OVER  R=new", W - 8))
    elseif st.won then
        writeAt(win, 9, 2, colors.lime, colors.black, padR(" 2048! Keep going", W - 8))
    end
end

-- Поле: клетки высотой cellH строк, число рисуется в средней строке клетки.
local function drawBoard(st, win, W, H)
    local cellH, left, top = boardGeometry(W, H)
    for row = 1, BOARD_SIZE do
        for ch = 1, cellH do
            local sy      = top + (row - 1) * cellH + (ch - 1)
            local isNum   = (ch == math.ceil(cellH / 2))
            for col = 1, BOARD_SIZE do
                local v     = st.board[row][col] or 0
                local style = tileStyle(v)
                local text
                if isNum and v > 0 then
                    text = centerText(tostring(v), CELL_W)
                else
                    text = string.rep(" ", CELL_W)
                end
                writeAt(win, left + (col - 1) * CELL_W, sy, style.bg, style.fg, text)
            end
        end
    end
end

-- Кнопки управления прямо под полем.
local function drawControls(win, W, H)
    local _, _, _, upY, arrowY, cx = boardGeometry(W, H)
    if upY > H then return end
    writeAt(win, 1, upY, colors.black, colors.white, string.rep(" ", W))
    writeAt(win, cx, upY, colors.gray, colors.white, "[ ^ ]")
    if arrowY > H then return end
    writeAt(win, 1, arrowY, colors.black, colors.white, string.rep(" ", W))
    if cx - 6 >= 1        then writeAt(win, cx - 6, arrowY, colors.gray, colors.white, "[ < ]") end
    writeAt(win, cx, arrowY, colors.gray, colors.white, "[ v ]")
    if cx + 10 <= W then writeAt(win, cx + 6, arrowY, colors.gray, colors.white, "[ > ]") end
end

-- ── Hit-test ──────────────────────────────────────────────────────────────────

local function handleTap(st, x, y)
    local W, H = st.win.getSize()
    if y == 2 and x >= 1 and x <= 7 then
        newGame(st); return true
    end
    local _, _, _, upY, arrowY, cx = boardGeometry(W, H)
    if y == upY and x >= cx and x <= cx + 4 then
        return move(st, "up")
    elseif y == arrowY then
        if x >= cx - 6 and x <= cx - 2 then return move(st, "left") end
        if x >= cx     and x <= cx + 4  then return move(st, "down") end
        if x >= cx + 6 and x <= cx + 10 then return move(st, "right") end
    end
    return false
end

-- ── App interface ─────────────────────────────────────────────────────────────

function M.init(win, ctx)
    math.randomseed(os.epoch("utc"))
    local db = loadDb()
    local st = {
        win     = win,
        ctx     = ctx,
        best    = tonumber(db.best) or 0,
        score   = 0,
        won     = false,
        gameOver = false,
        board   = makeBoard(),
    }
    startFromDb(st, db)
    return st
end

function M.draw(st, win)
    st.win = win
    local W, H = win.getSize()
    win.setBackgroundColor(colors.black)
    win.clear()
    if W < 12 or H < 6 then
        writeAt(win, 1, 1, colors.black, colors.red, "Too small")
        return
    end
    drawTitle(st, win, W)
    drawStatus(st, win, W)
    drawBoard(st, win, W, H)
    drawControls(win, W, H)
end

function M.onEvent(st, e, p1, p2, p3)
    if e == "key" then
        if p1 == keys.up    then return st, move(st, "up") end
        if p1 == keys.down  then return st, move(st, "down") end
        if p1 == keys.left  then return st, move(st, "left") end
        if p1 == keys.right then return st, move(st, "right") end
        if p1 == keys.r or p1 == keys.n or p1 == keys.enter then
            newGame(st); return st, true
        end
    elseif e == "char" then
        local c = string.lower(tostring(p1 or ""))
        if c == "w" then return st, move(st, "up") end
        if c == "a" then return st, move(st, "left") end
        if c == "s" then return st, move(st, "down") end
        if c == "d" then return st, move(st, "right") end
        if c == "r" or c == "n" then newGame(st); return st, true end
    elseif e == "mouse_click" or e == "monitor_touch" then
        if p1 == 1 and handleTap(st, p2, p3) then return st, true end
    end
    return st, false
end

function M.onClose(st)
    if st then saveDb(st) end
end

return M
