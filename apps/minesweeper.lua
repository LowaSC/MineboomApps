local FsUtil    = dofile("/os/lib/fsutil.lua")
local Scrollbar = dofile("/os/lib/scrollbar.lua")

local M = {}
M.id        = "minesweeper"
M.name      = "Minesweeper"
M.icon      = "MS"
M.iconBg    = colors.green
M.iconFg    = colors.white
M.version   = 3
M.category  = "games"

local DB = "/data/minesweeper.db"
local PRESETS = {
    Easy   = {w = 9,  h = 9,  mines = 10},
    Normal = {w = 16, h = 16, mines = 40},
    Hard   = {w = 24, h = 24, mines = 99},
}
local DIFFS = {"Easy", "Normal", "Hard", "Custom"}
local NUM_COLORS = {
    colors.lightBlue, colors.lime, colors.red, colors.purple,
    colors.brown, colors.cyan, colors.white, colors.lightGray,
}

-- helpers --------------------------------------------------------------------

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function padR(s, n)
    s = tostring(s or "")
    if #s >= n then return string.sub(s, 1, n) end
    return s .. string.rep(" ", n - #s)
end

local function fmtTime(sec)
    sec = math.max(0, math.floor(sec or 0))
    return string.format("%02d:%02d", math.floor(sec / 60), sec % 60)
end

local function nowMs()
    if os.epoch then return os.epoch("utc") end
    return math.floor(os.clock() * 1000)
end

local function writeAt(win, x, y, bg, fg, text)
    win.setCursorPos(x, y)
    win.setBackgroundColor(bg)
    win.setTextColor(fg)
    win.write(text)
end

local function loadDb()
    local db = {last = "Normal", custom = {w = 16, h = 16, mines = 40}, best = {}, action = "open"}
    pcall(FsUtil.ensureDir, "/data")
    local okRead, raw = pcall(FsUtil.readFile, DB)
    if okRead and type(raw) == "string" then
        local ok, t = pcall(textutils.unserialize, raw)
        if ok and type(t) == "table" then
            db.last = t.last or db.last
            db.custom = type(t.custom) == "table" and t.custom or db.custom
            db.best = type(t.best) == "table" and t.best or db.best
            db.action = t.action == "flag" and "flag" or "open"
        end
    end
    db.custom.w = clamp(tonumber(db.custom.w) or 16, 5, 40)
    db.custom.h = clamp(tonumber(db.custom.h) or 16, 5, 40)
    db.custom.mines = clamp(tonumber(db.custom.mines) or 40, 1, db.custom.w * db.custom.h - 1)
    if not PRESETS[db.last] and db.last ~= "Custom" then db.last = "Normal" end
    return db
end

local function saveDb(st)
    local db = {
        last = st.diff,
        custom = st.db.custom,
        best = st.db.best,
        action = st.action or "open",
    }
    pcall(FsUtil.ensureDir, "/data")
    pcall(FsUtil.atomicWrite, DB, textutils.serialize(db))
end

local function elapsedSeconds(st)
    if st.running and st.startMs then
        return math.floor((nowMs() - st.startMs) / 1000)
    end
    return math.floor((st.elapsedMs or 0) / 1000)
end

-- board ----------------------------------------------------------------------

local function eachNeighbor(st, x, y, fn)
    for yy = y - 1, y + 1 do
        for xx = x - 1, x + 1 do
            if not (xx == x and yy == y) and xx >= 1 and yy >= 1
                and xx <= st.bw and yy <= st.bh then
                fn(xx, yy, st.board[yy][xx])
            end
        end
    end
end

local function newBoard(w, h)
    local b = {}
    for y = 1, h do
        b[y] = {}
        for x = 1, w do
            b[y][x] = {mine = false, revealed = false, flagged = false, n = 0, boom = false, wrong = false}
        end
    end
    return b
end

local function difficultySpec(st, diff)
    if diff == "Custom" then
        local c = st.db.custom
        return c.w, c.h, c.mines
    end
    local p = PRESETS[diff] or PRESETS.Normal
    return p.w, p.h, p.mines
end

-- Геометрия viewport'а: учитывает наличие vertical sb (резервирует
-- последнюю колонку) и horizontal sb (резервирует строку H-1).
-- Возвращает (viewW, viewH, needV, needH).
local function viewport(st)
    local W, H = st.win.getSize()
    local needV = st.bh > (H - 3)
    local viewW = W - (needV and 1 or 0)
    local needH = st.bw > viewW
    local viewH = H - 3 - (needH and 1 or 0)
    -- ещё один проход — после сжатия viewH нужда в V может появиться
    needV = st.bh > viewH
    viewW = W - (needV and 1 or 0)
    needH = st.bw > viewW
    viewH = H - 3 - (needH and 1 or 0)
    return math.max(1, viewW), math.max(1, viewH), needV, needH
end

local function clampScroll(st)
    local viewW, viewH = viewport(st)
    st.scrollX = clamp(st.scrollX or 0, 0, math.max(0, st.bw - viewW))
    st.scrollY = clamp(st.scrollY or 0, 0, math.max(0, st.bh - viewH))
end

local function resetGame(st, diff)
    st.diff = diff or st.diff or "Normal"
    local w, h, mines = difficultySpec(st, st.diff)
    st.bw, st.bh, st.mines = w, h, mines
    st.board = newBoard(w, h)
    st.generated = false
    st.running = false
    st.startMs = nil
    st.elapsedMs = 0
    st.revealed = 0
    st.flags = 0
    st.status = "Ready"
    st.gameOver = false
    st.winGame = false
    st.newBest = false
    st.timerId = nil
    st.modal = nil
    st.action = st.action or st.db.action or "open"
    st.scrollX, st.scrollY = 0, 0
    clampScroll(st)
    saveDb(st)
end

local function toggleAction(st)
    st.action = st.action == "flag" and "open" or "flag"
    st.status = st.action == "flag" and "Tap mode: Flag" or "Tap mode: Open"
    saveDb(st)
end

local function flagCell(st, x, y)
    local c = st.board[y][x]
    if c.revealed then return end
    c.flagged = not c.flagged
    st.flags = st.flags + (c.flagged and 1 or -1)
    st.status = c.flagged and "Flagged" or "Unflagged"
end

local function placeMines(st, sx, sy)
    local excluded = {}
    for yy = sy - 1, sy + 1 do
        for xx = sx - 1, sx + 1 do
            if xx >= 1 and yy >= 1 and xx <= st.bw and yy <= st.bh then
                excluded[yy .. ":" .. xx] = true
            end
        end
    end
    if st.bw * st.bh - 9 < st.mines then excluded = {[sy .. ":" .. sx] = true} end
    local spots = {}
    for y = 1, st.bh do
        for x = 1, st.bw do
            if not excluded[y .. ":" .. x] then table.insert(spots, {x = x, y = y}) end
        end
    end
    for i = #spots, 2, -1 do
        local j = math.random(i)
        spots[i], spots[j] = spots[j], spots[i]
    end
    for i = 1, st.mines do
        local p = spots[i]
        st.board[p.y][p.x].mine = true
    end
    for y = 1, st.bh do
        for x = 1, st.bw do
            local c, n = st.board[y][x], 0
            if not c.mine then
                eachNeighbor(st, x, y, function(_, _, nc) if nc.mine then n = n + 1 end end)
                c.n = n
            end
        end
    end
    st.generated = true
end

local function finishGame(st, won, bx, by)
    st.running = false
    if st.startMs then st.elapsedMs = nowMs() - st.startMs end
    st.gameOver, st.winGame = true, won
    for y = 1, st.bh do
        for x = 1, st.bw do
            local c = st.board[y][x]
            if won and c.mine and not c.flagged then c.flagged = true; st.flags = st.flags + 1 end
            if not won and c.mine then c.revealed = true end
            if not won and c.flagged and not c.mine then c.wrong = true end
            if bx == x and by == y then c.boom = true end
        end
    end
    st.status = won and "WIN!" or "BOOM!"
    st.newBest = false
    if won and PRESETS[st.diff] then
        local sec = elapsedSeconds(st)
        local old = st.db.best[st.diff]
        if not old or sec < old then
            st.db.best[st.diff] = sec
            st.newBest = true
            saveDb(st)
        end
    end
    st.modal = {kind = "gameover"}
end

local function checkWin(st)
    if st.revealed >= st.bw * st.bh - st.mines then finishGame(st, true) end
end

local function revealCell(st, x, y)
    local c = st.board[y][x]
    if c.revealed or c.flagged then return end
    if not st.generated then
        placeMines(st, x, y)
        st.running = true
        st.startMs = nowMs()
        st.timerId = os.startTimer(1)
    end
    if c.mine then
        c.revealed = true
        finishGame(st, false, x, y)
        return
    end
    local stack = {{x = x, y = y}}
    while #stack > 0 do
        local p = table.remove(stack)
        local cc = st.board[p.y][p.x]
        if not cc.revealed and not cc.flagged and not cc.mine then
            cc.revealed = true
            st.revealed = st.revealed + 1
            if cc.n == 0 then
                eachNeighbor(st, p.x, p.y, function(nx, ny, nc)
                    if not nc.revealed and not nc.flagged and not nc.mine then
                        table.insert(stack, {x = nx, y = ny})
                    end
                end)
            end
        end
    end
    st.status = "Revealed"
    checkWin(st)
end

local function chordCell(st, x, y)
    local c = st.board[y][x]
    if not c.revealed or c.n <= 0 then return end
    local flags, targets = 0, {}
    eachNeighbor(st, x, y, function(nx, ny, nc)
        if nc.flagged then flags = flags + 1
        elseif not nc.revealed then table.insert(targets, {x = nx, y = ny}) end
    end)
    if flags == c.n then
        for _, p in ipairs(targets) do if not st.gameOver then revealCell(st, p.x, p.y) end end
        st.status = "Chord"
    end
end

-- layout ---------------------------------------------------------------------

local function cellAtScreen(st, x, y)
    local viewW, viewH = viewport(st)
    if y < 3 or y >= 3 + viewH or x < 1 or x > viewW then return nil end
    local bx, by = x + st.scrollX, (y - 2) + st.scrollY
    if bx >= 1 and by >= 1 and bx <= st.bw and by <= st.bh then return bx, by end
    return nil
end

local function drawTitleBar(st, win, W)
    win.setBackgroundColor(colors.green)
    win.setTextColor(colors.white)
    win.setCursorPos(1, 1)
    win.write(string.rep(" ", W))
    writeAt(win, 1, 1, colors.green, colors.white, " Minesweeper ")
    local mid = "Diff: " .. st.diff
    if W >= #mid + 2 then writeAt(win, math.max(1, math.floor((W - #mid) / 2) + 1), 1, colors.green, colors.white, mid) end
    local right = "Mines: " .. tostring(st.mines - st.flags)
    if W >= #right then writeAt(win, W - #right + 1, 1, colors.green, colors.white, right) end
end

local function drawToolbar(st, win, W)
    win.setBackgroundColor(colors.black)
    win.setTextColor(colors.white)
    win.setCursorPos(1, 2)
    win.write(string.rep(" ", W))
    writeAt(win, 1, 2, colors.gray, colors.white, "[ New ]")
    if W >= 16 then writeAt(win, 9, 2, colors.gray, colors.white, "[ Diff ]") end
    local mode = st.action == "flag" and "[ Flag ]" or "[ Open ]"
    if W >= 27 then writeAt(win, 18, 2, st.action == "flag" and colors.yellow or colors.cyan, colors.black, mode) end
    local t = fmtTime(elapsedSeconds(st))
    writeAt(win, math.max(1, W - #t + 1), 2, colors.black, colors.yellow, t)
end

local function drawCell(win, x, y, c)
    if c.wrong then writeAt(win, x, y, colors.pink, colors.black, "X"); return end
    if not c.revealed then
        if c.flagged then writeAt(win, x, y, colors.yellow, colors.black, "F")
        else writeAt(win, x, y, colors.lightGray, colors.white, " ") end
        return
    end
    if c.mine then
        writeAt(win, x, y, c.boom and colors.orange or colors.red, colors.black, "*")
    elseif c.n == 0 then
        writeAt(win, x, y, colors.gray, colors.white, " ")
    else
        writeAt(win, x, y, colors.gray, NUM_COLORS[c.n] or colors.white, tostring(c.n))
    end
end

-- Синхронизация scrollbar'ов с текущим viewport'ом. Вызывать перед
-- onClick/onDrag в обработчике событий — иначе bounds могут быть от
-- предыдущего кадра.
local function syncScrollbars(st)
    local W, H = st.win.getSize()
    local viewW, viewH, needV, needH = viewport(st)
    if needV then
        st.sbV:setBounds(W, 3, 2 + viewH)
        st.sbV:setContent(viewH, st.bh)
        st.sbV:setScroll(st.scrollY)
    else
        st.sbV:setBounds(0, 1, 0)
    end
    if needH then
        st.sbH:setBounds(H - 1, 1, viewW)
        st.sbH:setContent(viewW, st.bw)
        st.sbH:setScroll(st.scrollX)
    else
        st.sbH:setBounds(0, 1, 0)
    end
    return viewW, viewH, needV, needH
end

local function drawBoard(st, win, W, H)
    clampScroll(st)
    local viewW, viewH, needV, needH = syncScrollbars(st)

    for sy = 1, viewH do
        local by = sy + st.scrollY
        local y = sy + 2
        for sx = 1, viewW do
            local bx = sx + st.scrollX
            if bx <= st.bw and by <= st.bh then
                drawCell(win, sx, y, st.board[by][bx])
            else
                writeAt(win, sx, y, colors.black, colors.white, " ")
            end
        end
    end

    if needV then st.sbV:draw(win) end
    if needH then st.sbH:draw(win) end
end

local function drawStatus(st, win, W, H)
    local msg = st.status or ""
    if st.gameOver then msg = st.winGame and "WIN! Press R for new game." or "BOOM! Press R for new game." end
    writeAt(win, 1, H, colors.black, st.winGame and colors.lime or colors.white, padR(msg, W))
end

-- modals ---------------------------------------------------------------------

local function modalRect(win, w, h)
    local W, H = win.getSize()
    w, h = math.min(W, w), math.min(H, h)
    return math.floor((W - w) / 2) + 1, math.floor((H - h) / 2) + 1, w, h
end

local function fillLine(win, x, y, w, bg, fg, text)
    writeAt(win, x, y, bg, fg, padR(text or "", w))
end

local function drawModalBox(win, x, y, w, h, title)
    for yy = y, y + h - 1 do fillLine(win, x, yy, w, colors.gray, colors.white, "") end
    fillLine(win, x, y, w, colors.lightGray, colors.black, " " .. title)
end

local function layoutModal(st)
    local m = st.modal
    if not m then return nil end
    local win = st.win
    if m.kind == "diff" then
        local x, y, w, h = modalRect(win, 18, 7)
        local items = {}
        for i, name in ipairs(DIFFS) do items[name] = {x = x + 1, y = y + i, w = w - 2, h = 1} end
        return x, y, w, h, items
    elseif m.kind == "custom" then
        local x, y, w, h = modalRect(win, 26, 9)
        return x, y, w, h, {
            wminus = {x = x + 2, y = y + 2, w = 3, h = 1}, wplus = {x = x + w - 5, y = y + 2, w = 3, h = 1},
            hminus = {x = x + 2, y = y + 3, w = 3, h = 1}, hplus = {x = x + w - 5, y = y + 3, w = 3, h = 1},
            mminus = {x = x + 2, y = y + 4, w = 3, h = 1}, mplus = {x = x + w - 5, y = y + 4, w = 3, h = 1},
            start = {x = x + 2, y = y + h - 2, w = 9, h = 1}, cancel = {x = x + w - 10, y = y + h - 2, w = 8, h = 1},
        }
    elseif m.kind == "gameover" then
        local x, y, w, h = modalRect(win, 28, 8)
        return x, y, w, h, {
            again = {x = x + 2, y = y + h - 2, w = 14, h = 1},
            diff = {x = x + w - 12, y = y + h - 2, w = 10, h = 1},
        }
    end
end

local function hitItem(items, x, y)
    for k, r in pairs(items or {}) do
        if x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h then return k end
    end
    return nil
end

local function drawModal(st, win)
    if not st.modal then return end
    local x, y, w, h, items = layoutModal(st)
    if not x then return end
    if st.modal.kind == "diff" then
        drawModalBox(win, x, y, w, h, "Difficulty")
        for i, name in ipairs(DIFFS) do fillLine(win, x + 1, y + i, w - 2, colors.black, colors.white, " " .. name) end
    elseif st.modal.kind == "custom" then
        drawModalBox(win, x, y, w, h, "Custom")
        local c = st.db.custom
        fillLine(win, x + 1, y + 2, w - 2, colors.gray, colors.white, "")
        fillLine(win, x + 1, y + 3, w - 2, colors.gray, colors.white, "")
        fillLine(win, x + 1, y + 4, w - 2, colors.gray, colors.white, "")
        writeAt(win, items.wminus.x, items.wminus.y, colors.black, colors.white, "[-]")
        writeAt(win, items.hminus.x, items.hminus.y, colors.black, colors.white, "[-]")
        writeAt(win, items.mminus.x, items.mminus.y, colors.black, colors.white, "[-]")
        writeAt(win, items.wplus.x, items.wplus.y, colors.black, colors.white, "[+]")
        writeAt(win, items.hplus.x, items.hplus.y, colors.black, colors.white, "[+]")
        writeAt(win, items.mplus.x, items.mplus.y, colors.black, colors.white, "[+]")
        writeAt(win, x + 7, y + 2, colors.gray, colors.white, "Width  " .. c.w)
        writeAt(win, x + 7, y + 3, colors.gray, colors.white, "Height " .. c.h)
        writeAt(win, x + 7, y + 4, colors.gray, colors.white, "Mines  " .. c.mines)
        fillLine(win, items.start.x, items.start.y, items.start.w, colors.green, colors.white, "[ Start ]")
        fillLine(win, items.cancel.x, items.cancel.y, items.cancel.w, colors.black, colors.white, "[Cancel]")
    elseif st.modal.kind == "gameover" then
        drawModalBox(win, x, y, w, h, st.winGame and "WIN!" or "BOOM!")
        fillLine(win, x + 2, y + 2, w - 4, colors.gray, colors.white, "Time: " .. fmtTime(elapsedSeconds(st)))
        local best = PRESETS[st.diff] and st.db.best[st.diff] or nil
        local bestLine = best and ("Best: " .. fmtTime(best) .. (st.newBest and " NEW" or "")) or "Best: n/a"
        fillLine(win, x + 2, y + 3, w - 4, colors.gray, colors.white, bestLine)
        fillLine(win, items.again.x, items.again.y, items.again.w, colors.green, colors.white, "[ Play Again ]")
        fillLine(win, items.diff.x, items.diff.y, items.diff.w, colors.black, colors.white, "[ Diff ]")
    end
end

local function handleModalClick(st, x, y)
    local rx, ry, rw, rh, items = layoutModal(st)
    if not rx then return true end
    local inside = x >= rx and y >= ry and x < rx + rw and y < ry + rh
    if not inside then
        if st.modal.kind ~= "gameover" then
            st.modal = st.gameOver and {kind = "gameover"} or nil
        end
        return true
    end
    local hit = hitItem(items, x, y)
    if st.modal.kind == "diff" then
        if hit == "Custom" then
            st.modal = {kind = "custom"}
        elseif hit and PRESETS[hit] then
            resetGame(st, hit)
        end
    elseif st.modal.kind == "custom" then
        local c = st.db.custom
        if hit == "wminus" then c.w = clamp(c.w - 1, 5, 40)
        elseif hit == "wplus" then c.w = clamp(c.w + 1, 5, 40)
        elseif hit == "hminus" then c.h = clamp(c.h - 1, 5, 40)
        elseif hit == "hplus" then c.h = clamp(c.h + 1, 5, 40)
        elseif hit == "mminus" then c.mines = c.mines - 1
        elseif hit == "mplus" then c.mines = c.mines + 1
        elseif hit == "start" then c.mines = clamp(c.mines, 1, c.w * c.h - 1); resetGame(st, "Custom")
        elseif hit == "cancel" then st.modal = st.gameOver and {kind = "gameover"} or nil end
        c.mines = clamp(c.mines, 1, c.w * c.h - 1)
        saveDb(st)
    elseif st.modal.kind == "gameover" then
        if hit == "again" then resetGame(st, st.diff)
        elseif hit == "diff" then st.modal = {kind = "diff"} end
    end
    return true
end

-- app ------------------------------------------------------------------------

function M.init(win, ctx)
    math.randomseed(nowMs() % 2147483647)
    local db = loadDb()
    local st = {
        win = win, ctx = ctx, db = db, diff = db.last,
        sbV = Scrollbar.create({thumbBg = colors.cyan, thumbFg = colors.black}),
        sbH = Scrollbar.create({orientation = "horizontal",
                                 thumbBg = colors.cyan, thumbFg = colors.black}),
    }
    resetGame(st, st.diff)
    return st
end

function M.draw(st, win)
    st.win = win
    local W, H = win.getSize()
    win.setBackgroundColor(colors.black)
    win.setTextColor(colors.white)
    win.clear()
    if H < 4 or W < 10 then
        writeAt(win, 1, 1, colors.black, colors.red, "Too small")
        return
    end
    drawTitleBar(st, win, W)
    drawToolbar(st, win, W)
    drawBoard(st, win, W, H)
    drawStatus(st, win, W, H)
    drawModal(st, win)
end

function M.onEvent(st, e, p1, p2, p3, p4)
    if e == "mouse_click" or e == "monitor_touch" then
        local button, x, y = p1, p2, p3
        if e == "monitor_touch" then button, x, y = 1, p2, p3 end
        if st.modal then handleModalClick(st, x, y); return st, true end
        if y == 2 and button == 1 then
            if x >= 1 and x <= 7 then resetGame(st, st.diff); return st, true end
            if x >= 9 and x <= 16 then st.modal = {kind = "diff"}; return st, true end
            if x >= 18 and x <= 25 then toggleAction(st); return st, true end
        end
        -- Scrollbars (синхронизируем bounds под текущий viewport перед тестом).
        syncScrollbars(st)
        if st.sbV:onClick(x, y) then
            st.scrollY = st.sbV.scroll
            return st, true
        end
        if st.sbH:onClick(x, y) then
            st.scrollX = st.sbH.scroll
            return st, true
        end
        local bx, by = cellAtScreen(st, x, y)
        if bx and not st.gameOver then
            local c = st.board[by][bx]
            if button == 2 then
                flagCell(st, bx, by)
            elseif button == 1 then
                if c.revealed then chordCell(st, bx, by)
                elseif st.action == "flag" then flagCell(st, bx, by)
                else revealCell(st, bx, by) end
            elseif button == 3 then
                chordCell(st, bx, by)
            end
            return st, true
        end
    elseif e == "mouse_drag" then
        if st.modal then return st, false end
        syncScrollbars(st)
        if st.sbV:onDrag(p2, p3) then
            st.scrollY = st.sbV.scroll
            return st, true
        end
        if st.sbH:onDrag(p2, p3) then
            st.scrollX = st.sbH.scroll
            return st, true
        end
        return st, false
    elseif e == "mouse_scroll" then
        local dir, shiftHeld = p1, p4
        syncScrollbars(st)
        if shiftHeld then
            st.sbH:scrollBy(dir); st.scrollX = st.sbH.scroll
        else
            st.sbV:scrollBy(dir); st.scrollY = st.sbV.scroll
        end
        return st, true
    elseif e == "key" then
        local k = p1
        if k == keys.r then resetGame(st, st.diff); return st, true end
        if k == keys.d then st.modal = {kind = "diff"}; return st, true end
        if k == keys.f then toggleAction(st); return st, true end
        if k == keys.escape or k == keys.q then
            if st.modal and st.modal.kind ~= "gameover" then
                st.modal = st.gameOver and {kind = "gameover"} or nil
                return st, true
            end
            return st, false
        end
        if st.modal and st.modal.kind == "custom" then
            local c = st.db.custom
            if k == keys.left or k == keys.minus then c.mines = c.mines - 1
            elseif k == keys.right or k == keys.equals then c.mines = c.mines + 1
            elseif k == keys.enter or k == keys.space then c.mines = clamp(c.mines, 1, c.w * c.h - 1); resetGame(st, "Custom")
            else return st, false end
            c.mines = clamp(c.mines, 1, c.w * c.h - 1)
            saveDb(st)
            return st, true
        elseif not st.modal then
            if k == keys.up then st.scrollY = st.scrollY - 1
            elseif k == keys.down then st.scrollY = st.scrollY + 1
            elseif k == keys.left then st.scrollX = st.scrollX - 1
            elseif k == keys.right then st.scrollX = st.scrollX + 1
            else return st, false end
            clampScroll(st)
            return st, true
        end
    elseif e == "char" then
        if p1 == "r" or p1 == "R" then resetGame(st, st.diff); return st, true end
        if p1 == "d" or p1 == "D" then st.modal = {kind = "diff"}; return st, true end
        if p1 == "f" or p1 == "F" then toggleAction(st); return st, true end
        if p1 == "q" or p1 == "Q" then
            if st.modal and st.modal.kind ~= "gameover" then
                st.modal = st.gameOver and {kind = "gameover"} or nil
                return st, true
            end
        end
    elseif e == "timer" then
        if st.running and p1 == st.timerId then
            st.timerId = os.startTimer(1)
            return st, true
        end
    end
    return st, false
end

function M.onClose(st)
    if st then saveDb(st) end
end

return M
