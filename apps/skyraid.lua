local FsUtil = dofile("/os/lib/fsutil.lua")

local M = {}
M.id        = "skyraid"
M.name      = "Sky Raid"
M.icon      = "SR"
M.iconBg    = colors.lightBlue
M.iconFg    = colors.black
M.version   = 1
M.category  = "games"

local DB         = "/data/skyraid.db"
local MIN_W      = 20
local MIN_H      = 12
local MAX_SHOTS  = 260   -- enemy bullets alive at once
local MAX_PSHOTS = 60
local MAX_PARTS  = 90
local PI         = math.pi

-- A terminal cell is about 1.6x taller than it is wide, so horizontal speeds
-- are scaled by this: without it every "ring" of bullets comes out squashed.
local ASPECT = 1.6

local DIFFS = {
    {id = "easy",   name = "Easy",   tick = 0.12, speed = 0.85, rate = 1.35, lives = 4, bombs = 3},
    {id = "normal", name = "Normal", tick = 0.10, speed = 1.00, rate = 1.00, lives = 3, bombs = 2},
    {id = "hard",   name = "Hard",   tick = 0.09, speed = 1.20, rate = 0.75, lives = 2, bombs = 2},
}

local ENEMY = {
    grunt  = {hw = 0, hh = 0, hp = 2,  score = 100, bg = colors.lime,    fg = colors.black, ch = "v"},
    weaver = {hw = 0, hh = 0, hp = 5,  score = 180, bg = colors.orange,  fg = colors.black, ch = "w"},
    turret = {hw = 1, hh = 0, hp = 10, score = 320, bg = colors.magenta, fg = colors.black, ch = "M"},
    boss   = {hw = 3, hh = 1, hp = 70, score = 5000},
}

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

-- blit uses one hex digit per colour; colors.white (1) is "0", black is "f".
local BLIT = {}
do
    local hex = "0123456789abcdef"
    local c = 1
    for i = 1, 16 do
        BLIT[c] = string.sub(hex, i, i)
        c = c * 2
    end
end

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

local function diffById(id)
    for i, d in ipairs(DIFFS) do
        if d.id == id then return i, d end
    end
    return 2, DIFFS[2]
end

local function bestScore(st)
    return tonumber(st.db.best[st.diff.id]) or 0
end

-- storage --------------------------------------------------------------------

local function loadDb()
    local db = {diff = "normal", best = {}}
    pcall(FsUtil.ensureDir, "/data")
    local okRead, raw = pcall(FsUtil.readFile, DB)
    if okRead and type(raw) == "string" then
        local ok, t = pcall(textutils.unserialize, raw)
        if ok and type(t) == "table" then
            db.diff = t.diff or db.diff
            db.best = type(t.best) == "table" and t.best or db.best
        end
    end
    local _, d = diffById(db.diff)
    db.diff = d.id
    return db
end

local function saveDb(st)
    local db = {diff = st.diff.id, best = st.db.best}
    pcall(FsUtil.ensureDir, "/data")
    pcall(FsUtil.atomicWrite, DB, textutils.serialize(db))
end

-- frame buffer ---------------------------------------------------------------
-- The playfield is redrawn every tick, so it is composed into a buffer and
-- flushed one row per blit call instead of thousands of per-cell writes.

local function newFb(w, h)
    local fb = {w = w, h = h, ch = {}, fg = {}, bg = {}}
    for y = 1, h do
        fb.ch[y], fb.fg[y], fb.bg[y] = {}, {}, {}
    end
    return fb
end

local function fbClear(fb)
    for y = 1, fb.h do
        local ch, fg, bg = fb.ch[y], fb.fg[y], fb.bg[y]
        for x = 1, fb.w do
            ch[x], fg[x], bg[x] = " ", colors.black, colors.black
        end
    end
end

local function fbPut(fb, x, y, ch, fg, bg)
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)
    if x < 1 or y < 1 or x > fb.w or y > fb.h then return end
    fb.ch[y][x] = ch
    fb.fg[y][x] = fg or colors.white
    fb.bg[y][x] = bg or colors.black
end

local function fbRow(fb, win, y, top, buf)
    local ch, fg, bg = fb.ch[y], fb.fg[y], fb.bg[y]
    if win.blit then
        local cb, fb2, bb = buf[1], buf[2], buf[3]
        for x = 1, fb.w do
            cb[x] = ch[x]
            fb2[x] = BLIT[fg[x]] or "0"
            bb[x] = BLIT[bg[x]] or "f"
        end
        win.setCursorPos(1, top + y - 1)
        win.blit(table.concat(cb, "", 1, fb.w), table.concat(fb2, "", 1, fb.w),
            table.concat(bb, "", 1, fb.w))
        return
    end
    -- Fallback for terminals without blit: write runs of equal colour.
    local x = 1
    while x <= fb.w do
        local last = x
        while last < fb.w and fg[last + 1] == fg[x] and bg[last + 1] == bg[x] do
            last = last + 1
        end
        writeAt(win, x, top + y - 1, bg[x], fg[x], table.concat(ch, "", x, last))
        x = last + 1
    end
end

local function fbRender(fb, win, top)
    local buf = {{}, {}, {}}
    for y = 1, fb.h do fbRow(fb, win, y, top, buf) end
end

-- geometry -------------------------------------------------------------------

local function fieldSize(win)
    local W, H = win.getSize()
    return math.max(1, W), math.max(1, H - 5)
end

-- spawning -------------------------------------------------------------------

local function addShot(st, x, y, vx, vy, ch, color)
    if #st.shots >= MAX_SHOTS then return end
    st.shots[#st.shots + 1] = {x = x, y = y, vx = vx, vy = vy, ch = ch, color = color}
end

local function fireRing(st, x, y, speed, count, offset, ch, color)
    for i = 0, count - 1 do
        local a = offset + i * 2 * PI / count
        addShot(st, x, y, math.sin(a) * speed * ASPECT, math.cos(a) * speed, ch, color)
    end
end

local function ringCount(st, cap)
    return clamp(math.floor(st.pw / 3.2 + 0.5), 5, cap)
end

local function aimAt(st, x, y)
    return atan2((st.px - x) / ASPECT, st.py - y)
end

local function fireFan(st, x, y, speed, count, spread, ch, color)
    local base = aimAt(st, x, y)
    local start = base - spread / 2
    local step = (count > 1) and (spread / (count - 1)) or 0
    for i = 0, count - 1 do
        local a = start + step * i
        addShot(st, x, y, math.sin(a) * speed * ASPECT, math.cos(a) * speed, ch, color)
    end
end

local function addPart(st, x, y, vx, vy, life, color)
    if #st.parts >= MAX_PARTS then return end
    st.parts[#st.parts + 1] = {x = x, y = y, vx = vx, vy = vy, life = life, color = color}
end

local function boom(st, x, y, size)
    for _ = 1, size do
        local a = math.random() * 2 * PI
        local sp = 0.25 + math.random() * 0.55
        addPart(st, x, y, math.sin(a) * sp * ASPECT, math.cos(a) * sp,
            2 + math.random(3), colors.orange)
    end
end

local function addPowerup(st, x, y, kind)
    st.drops[#st.drops + 1] = {x = x, y = y, kind = kind}
end

local function addEnemy(st, kind, x, opt)
    opt = opt or {}
    local def = ENEMY[kind]
    local tier = math.floor(st.wave / 3)
    local e = {
        kind = kind,
        x = clamp(x, 1 + def.hw, st.pw - def.hw),
        y = opt.y or -def.hh - 1,
        hw = def.hw, hh = def.hh,
        seed = math.random() * 2 * PI,
        t = 0, fireT = math.random(6), phase = 1,
        holdY = opt.holdY or 3,
        vx = (math.random(2) == 1 and 1 or -1) * 0.55,
        leaveT = (kind == "turret") and 200 or 160,
    }
    if kind == "boss" then
        e.hp = def.hp + 30 * math.max(0, math.floor(st.wave / 5) - 1)
    else
        e.hp = def.hp + tier
    end
    e.maxHp = e.hp
    st.enemies[#st.enemies + 1] = e
    if kind == "boss" then st.boss = e end
    return e
end

-- waves ----------------------------------------------------------------------

local function pushSpawn(q, t, kind, x, opt)
    q[#q + 1] = {t = t, kind = kind, x = x, opt = opt}
end

local function buildWave(st)
    local q = {}
    local W, n = st.pw, st.wave
    local function col(f) return clamp(math.floor(W * f + 0.5), 2, math.max(2, W - 1)) end

    if n % 5 == 0 then
        pushSpawn(q, 6, "boss", col(0.5), {y = -2, holdY = 3})
        for i = 1, 6 do
            pushSpawn(q, 45 + i * 24, "grunt", col(i % 2 == 0 and 0.2 or 0.8))
        end
    else
        local t = 4
        for _ = 1, 1 + math.floor(n / 3) do
            local count = math.min(6, 3 + math.floor(n / 2))
            for i = 1, count do
                pushSpawn(q, t + (i - 1) * 2, "grunt", col((i - 0.5) / count))
            end
            t = t + 26
        end
        if n >= 2 then
            for i = 1, math.min(4, 1 + math.floor(n / 2)) do
                pushSpawn(q, t + (i - 1) * 9, "weaver",
                    col(i % 2 == 0 and 0.15 or 0.85), {holdY = 2 + i})
            end
            t = t + 32
        end
        if n >= 3 then
            pushSpawn(q, t, "turret", col(0.25), {holdY = 2})
            pushSpawn(q, t + 6, "turret", col(0.75), {holdY = 3})
            t = t + 34
        end
        if n >= 6 then
            pushSpawn(q, t, "turret", col(0.5), {holdY = 2})
            for i = 1, 4 do
                pushSpawn(q, t + i * 6, "weaver", col(0.1 + 0.26 * i), {holdY = 3 + i % 3})
            end
        end
    end

    table.sort(q, function(a, b) return a.t < b.t end)
    st.queue = q
    st.qi = 1
    st.waveTick = 0
    st.clearT = 0
end

local function nextWave(st)
    st.wave = st.wave + 1
    st.score = st.score + 150 * st.wave
    buildWave(st)
    if st.wave % 5 == 0 then
        setStatus(st, "WARNING - wave " .. st.wave .. " boss")
    else
        setStatus(st, "Wave " .. st.wave)
    end
end

-- game state -----------------------------------------------------------------

local function cancelTimer(st)
    st.timerId = nil
end

local function scheduleTick(st)
    st.timerId = os.startTimer(st.diff.tick)
end

local function resetGame(st)
    st.pw, st.ph = fieldSize(st.win)
    st.fb = newFb(st.pw, st.ph)
    st.px = math.floor(st.pw / 2) + 0.0
    st.py = st.ph - 1
    st.target = nil
    st.shots, st.pshots, st.enemies, st.parts, st.drops = {}, {}, {}, {}, {}
    st.boss = nil
    st.stars = {}
    for _ = 1, math.max(6, math.floor(st.pw * st.ph / 22)) do
        local v = 0.25 + math.random() * 0.7
        st.stars[#st.stars + 1] = {x = math.random(st.pw), y = math.random() * st.ph, v = v}
    end
    st.lives = st.diff.lives
    st.bombs = st.diff.bombs
    st.power = 1
    st.fireEvery = 2
    st.invuln = 0
    st.score = 0
    st.graze = 0
    st.kills = 0
    st.tick = 0
    st.wave = 1
    st.running = false
    st.started = false
    st.gameOver = false
    st.newBest = false
    cancelTimer(st)
    buildWave(st)
    setStatus(st, "Start, then dodge everything")
end

local function finishGame(st)
    st.running = false
    st.gameOver = true
    cancelTimer(st)
    st.newBest = st.score > bestScore(st)
    if st.newBest then st.db.best[st.diff.id] = st.score end
    saveDb(st)
    setStatus(st, "Game over on wave " .. st.wave .. ". New to retry")
end

local function startGame(st)
    if st.gameOver then resetGame(st) end
    if not st.running then
        st.running = true
        st.started = true
        setStatus(st, "Wave " .. st.wave)
        scheduleTick(st)
    end
end

local function pauseGame(st)
    if st.running then
        st.running = false
        cancelTimer(st)
        setStatus(st, "Paused")
    else
        startGame(st)
    end
end

-- Controls wake a fresh game up, but never revive a finished one: after game
-- over only New or Start may clear the final field.
local function ensureRunning(st)
    if st.gameOver then return false end
    if not st.running then startGame(st) end
    return st.running
end

local function movePlayer(st, dx, dy)
    if not ensureRunning(st) then return end
    st.target = nil
    st.px = clamp(st.px + dx, 1, st.pw)
    st.py = clamp(st.py + dy, 1, st.ph)
end

local function playerHit(st)
    if st.invuln > 0 then return end
    boom(st, st.px, st.py, 12)
    st.lives = st.lives - 1
    st.power = math.max(1, st.power - 1)
    st.bombs = st.diff.bombs
    -- Clear the bullets already on top of the player so the new life does not
    -- start inside the same wall of fire that just killed it.
    local kept = {}
    for _, b in ipairs(st.shots) do
        local dx, dy = (b.x - st.px) / ASPECT, b.y - st.py
        if dx * dx + dy * dy > 36 then kept[#kept + 1] = b end
    end
    st.shots = kept
    if st.lives <= 0 then
        finishGame(st)
        return
    end
    st.invuln = 26
    st.target = nil
    st.px = math.floor(st.pw / 2) + 0.0
    st.py = st.ph - 1
    setStatus(st, "Hit! " .. st.lives .. " left")
end

local function useBomb(st)
    if not ensureRunning(st) then return end
    if st.bombs <= 0 then
        setStatus(st, "No bombs left")
        return
    end
    st.bombs = st.bombs - 1
    st.score = st.score + #st.shots * 10
    for _, b in ipairs(st.shots) do addPart(st, b.x, b.y, 0, 0, 2, colors.lightBlue) end
    st.shots = {}
    for _, e in ipairs(st.enemies) do
        e.hp = e.hp - 14
        boom(st, e.x, e.y, 4)
    end
    st.invuln = math.max(st.invuln, 12)
    setStatus(st, "Bomb! " .. st.bombs .. " left")
end

local function cycleDiff(st)
    local idx = diffById(st.diff.id)
    idx = idx % #DIFFS + 1
    st.diff = DIFFS[idx]
    st.db.diff = st.diff.id
    saveDb(st)
    if not st.started and not st.gameOver then
        st.lives = st.diff.lives
        st.bombs = st.diff.bombs
        setStatus(st, "Difficulty: " .. st.diff.name)
    else
        setStatus(st, "Difficulty: " .. st.diff.name .. " (next game)")
    end
end

-- simulation -----------------------------------------------------------------

local function playerFire(st)
    local function shot(dx, vx)
        if #st.pshots >= MAX_PSHOTS then return end
        st.pshots[#st.pshots + 1] = {x = st.px + dx, y = st.py - 1, vx = vx or 0, vy = -2.4}
    end
    local p = st.power
    if p <= 1 then
        shot(0, 0)
    elseif p == 2 then
        shot(-1, 0); shot(1, 0)
    elseif p == 3 then
        shot(0, 0); shot(-1, -0.6); shot(1, 0.6)
    else
        shot(0, 0); shot(-1, 0); shot(1, 0); shot(-1, -0.9); shot(1, 0.9)
    end
end

local function updatePlayer(st)
    if st.invuln > 0 then st.invuln = st.invuln - 1 end
    local tg = st.target
    if tg then
        local dx, dy = tg.x - st.px, tg.y - st.py
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist <= 0.6 then
            st.px, st.py = tg.x, tg.y
            st.target = nil
        else
            local step = math.min(1.3, dist)
            st.px = clamp(st.px + dx / dist * step, 1, st.pw)
            st.py = clamp(st.py + dy / dist * step, 1, st.ph)
        end
    end
    if st.tick % st.fireEvery == 0 then playerFire(st) end
end

local function killEnemy(st, e)
    local def = ENEMY[e.kind]
    st.score = st.score + def.score
    st.kills = st.kills + 1
    boom(st, e.x, e.y, e.kind == "boss" and 26 or 6)
    if e.kind == "boss" then
        st.boss = nil
        setStatus(st, "Boss down!")
        addPowerup(st, e.x, e.y, "bomb")
        addPowerup(st, e.x - 2, e.y, "power")
        addPowerup(st, e.x + 2, e.y, "power")
    elseif e.kind == "turret" then
        addPowerup(st, e.x, e.y, math.random(4) == 1 and "bomb" or "power")
    elseif math.random(100) <= 12 then
        addPowerup(st, e.x, e.y, math.random(5) == 1 and "bomb" or "power")
    end
end

local function enemyFire(st, e)
    local sp = st.diff.speed
    local lvl = 1 + st.wave * 0.06
    if e.kind == "grunt" then
        local n = (st.wave >= 6) and 2 or 1
        fireFan(st, e.x, e.y + 1, 0.55 * sp * lvl, n, 0.45, "o", colors.red)
    elseif e.kind == "weaver" then
        local n = clamp(2 + math.floor(st.wave / 4), 2, 5)
        fireFan(st, e.x, e.y + 1, 0.5 * sp * lvl, n, 0.5 + 0.12 * n, "o", colors.yellow)
    elseif e.kind == "turret" then
        fireRing(st, e.x, e.y, 0.42 * sp, ringCount(st, math.min(16, 8 + math.floor(st.wave / 2))),
            e.t * 0.21, "*", colors.magenta)
    elseif e.kind == "boss" then
        if e.phase == 1 then
            fireFan(st, e.x, e.y + 1, 0.6 * sp, 5, 0.9, "o", colors.red)
            fireRing(st, e.x, e.y, 0.38 * sp, ringCount(st, 12), e.t * 0.17, "*", colors.magenta)
        elseif e.phase == 2 then
            -- Spiral: every burst rotates a little further than the last one.
            for k = 0, 3 do
                fireRing(st, e.x, e.y, 0.44 * sp, 3, e.t * 0.29 + k * PI / 2, "*", colors.purple)
            end
            fireFan(st, e.x, e.y + 1, 0.68 * sp, 3, 0.5, "o", colors.red)
        else
            fireRing(st, e.x, e.y, 0.4 * sp, ringCount(st, 14), e.t * 0.13, "*", colors.pink)
            fireRing(st, e.x, e.y, 0.52 * sp, ringCount(st, 10), -e.t * 0.19, "*", colors.purple)
            fireFan(st, e.x, e.y + 1, 0.78 * sp, 5, 1.1, "|", colors.yellow)
        end
    end
end

local function updateEnemy(st, e)
    e.t = e.t + 1
    local rate = st.diff.rate
    if e.kind == "grunt" then
        e.y = e.y + 0.33
        e.x = clamp(e.x + math.sin(e.t * 0.2 + e.seed) * 0.3, 1, st.pw)
        e.fireT = e.fireT + 1
        if e.y > 0 and e.fireT >= math.max(6, math.floor(14 * rate)) then
            e.fireT = 0
            enemyFire(st, e)
        end
    elseif e.kind == "weaver" then
        if e.y < e.holdY then
            e.y = e.y + 0.45
        elseif e.t > e.leaveT then
            e.y = e.y + 0.5
        else
            e.x = e.x + e.vx
            if e.x <= 1 then e.x, e.vx = 1, math.abs(e.vx) end
            if e.x >= st.pw then e.x, e.vx = st.pw, -math.abs(e.vx) end
        end
        e.fireT = e.fireT + 1
        if e.y > 0 and e.t <= e.leaveT and e.fireT >= math.max(7, math.floor(16 * rate)) then
            e.fireT = 0
            enemyFire(st, e)
        end
    elseif e.kind == "turret" then
        if e.y < e.holdY then
            e.y = e.y + 0.3
        elseif e.t > e.leaveT then
            e.y = e.y + 0.4
        else
            e.x = clamp(e.x + math.sin(e.t * 0.06 + e.seed) * 0.22, 1 + e.hw, st.pw - e.hw)
        end
        e.fireT = e.fireT + 1
        if e.y >= e.holdY and e.t <= e.leaveT and e.fireT >= math.max(8, math.floor(17 * rate)) then
            e.fireT = 0
            enemyFire(st, e)
        end
    elseif e.kind == "boss" then
        if e.y < e.holdY then
            e.y = e.y + 0.22
        else
            e.x = e.x + e.vx * 0.6
            if e.x <= 1 + e.hw then e.x, e.vx = 1 + e.hw, math.abs(e.vx) end
            if e.x >= st.pw - e.hw then e.x, e.vx = st.pw - e.hw, -math.abs(e.vx) end
        end
        local frac = e.hp / e.maxHp
        e.phase = (frac > 0.66 and 1) or (frac > 0.33 and 2) or 3
        e.fireT = e.fireT + 1
        local every = math.max(3, math.floor((e.phase == 3 and 7 or 10) * rate))
        if e.y >= e.holdY - 1 and e.fireT % every == 0 then
            enemyFire(st, e)
        end
    end
end

local function hitsEnemy(e, x, y)
    return math.abs(x - e.x) <= e.hw + 0.6 and math.abs(y - e.y) <= e.hh + 0.6
end

local function updateEnemies(st)
    local kept = {}
    for _, e in ipairs(st.enemies) do
        updateEnemy(st, e)
        if e.hp <= 0 then
            killEnemy(st, e)
        elseif e.y > st.ph + 2 then
            if e.kind == "boss" then st.boss = nil end
        else
            if st.invuln <= 0 and not st.gameOver and hitsEnemy(e, st.px, st.py) then
                playerHit(st)
            end
            kept[#kept + 1] = e
        end
    end
    st.enemies = kept
end

local function updatePlayerShots(st)
    local kept = {}
    for _, b in ipairs(st.pshots) do
        b.x = b.x + b.vx
        b.y = b.y + b.vy
        local hit = false
        for _, e in ipairs(st.enemies) do
            if e.hp > 0 and hitsEnemy(e, b.x, b.y) then
                e.hp = e.hp - 1
                st.score = st.score + 5
                hit = true
                if e.kind == "boss" and math.random(4) == 1 then
                    addPart(st, b.x, b.y, 0, -0.2, 1, colors.yellow)
                end
                break
            end
        end
        if not hit and b.y >= 0 and b.x >= 0 and b.x <= st.pw + 1 then
            kept[#kept + 1] = b
        end
    end
    st.pshots = kept
end

local function updateShots(st)
    local kept = {}
    local px, py = st.px, st.py
    for _, b in ipairs(st.shots) do
        b.x = b.x + b.vx
        b.y = b.y + b.vy
        if b.x < -2 or b.x > st.pw + 3 or b.y < -2 or b.y > st.ph + 2 then
            -- gone
        else
            local dx, dy = math.abs(b.x - px), math.abs(b.y - py)
            if st.invuln <= 0 and dx < 0.6 and dy < 0.6 then
                playerHit(st)
                if st.gameOver then
                    st.shots = kept
                    return
                end
                px, py = st.px, st.py
            else
                -- Grazing: skimming a bullet pays, which is the whole point of
                -- a bullet hell.
                if not b.grazed and dx < 1.6 and dy < 1.4 then
                    b.grazed = true
                    st.graze = st.graze + 1
                    st.score = st.score + 5
                end
                kept[#kept + 1] = b
            end
        end
    end
    st.shots = kept
end

local function updateDrops(st)
    local kept = {}
    for _, d in ipairs(st.drops) do
        d.y = d.y + 0.32
        if math.abs(d.x - st.px) < 1.6 and math.abs(d.y - st.py) < 1.2 then
            if d.kind == "bomb" then
                st.bombs = st.bombs + 1
                setStatus(st, "Bomb picked up")
            else
                if st.power < 4 then
                    st.power = st.power + 1
                    setStatus(st, "Power " .. st.power)
                else
                    st.score = st.score + 200
                end
            end
            st.score = st.score + 50
        elseif d.y <= st.ph + 1 then
            kept[#kept + 1] = d
        end
    end
    st.drops = kept
end

local function updateParts(st)
    local kept = {}
    for _, p in ipairs(st.parts) do
        p.x = p.x + p.vx
        p.y = p.y + p.vy
        p.life = p.life - 1
        if p.life > 0 then kept[#kept + 1] = p end
    end
    st.parts = kept
end

local function updateStars(st)
    for _, s in ipairs(st.stars) do
        s.y = s.y + s.v
        if s.y > st.ph then
            s.y = 0
            s.x = math.random(st.pw)
        end
    end
end

local function spawnQueued(st)
    local q = st.queue
    while st.qi <= #q and q[st.qi].t <= st.waveTick do
        local s = q[st.qi]
        addEnemy(st, s.kind, s.x, s.opt)
        st.qi = st.qi + 1
    end
end

local function stepGame(st)
    if not st.running then return end
    st.tick = st.tick + 1
    st.waveTick = st.waveTick + 1

    updateStars(st)
    spawnQueued(st)
    updatePlayer(st)
    updateEnemies(st)
    if st.gameOver then return end
    updatePlayerShots(st)
    updateShots(st)
    if st.gameOver then return end
    updateDrops(st)
    updateParts(st)

    if st.qi > #st.queue and #st.enemies == 0 then
        st.clearT = st.clearT + 1
        if st.clearT >= 12 then nextWave(st) end
    end
    scheduleTick(st)
end

-- drawing --------------------------------------------------------------------

local ACTIONS = {
    new   = resetGame,
    pause = pauseGame,
    diff  = cycleDiff,
    bomb  = useBomb,
    up    = function(st) movePlayer(st, 0, -1) end,
    down  = function(st) movePlayer(st, 0, 1) end,
    left  = function(st) movePlayer(st, -1, 0) end,
    right = function(st) movePlayer(st, 1, 0) end,
}

-- Every button registers its own hit box while it is drawn, so a button can
-- never be tappable where it is not visible, or visible where it is not tappable.
local function button(st, win, x, y, text, bg, fg, action)
    writeAt(win, x, y, bg, fg, text)
    st.hit[#st.hit + 1] = {x1 = x, x2 = x + #text - 1, y = y, action = action}
end

local function drawField(st, win)
    local fb = st.fb
    fbClear(fb)

    for _, s in ipairs(st.stars) do
        fbPut(fb, s.x, s.y, s.v > 0.7 and "'" or ".",
            s.v > 0.7 and colors.lightGray or colors.gray, colors.black)
    end
    for _, p in ipairs(st.parts) do
        fbPut(fb, p.x, p.y, p.life > 1 and "*" or ".",
            p.life > 1 and p.color or colors.gray, colors.black)
    end
    for _, d in ipairs(st.drops) do
        if d.kind == "bomb" then
            fbPut(fb, d.x, d.y, "B", colors.black, colors.cyan)
        else
            fbPut(fb, d.x, d.y, "P", colors.black, colors.yellow)
        end
    end
    for _, b in ipairs(st.pshots) do
        fbPut(fb, b.x, b.y, "|", colors.lightBlue, colors.black)
    end

    for _, e in ipairs(st.enemies) do
        if e.kind == "boss" then
            for x = -3, 3 do
                fbPut(fb, e.x + x, e.y, " ", colors.black, colors.red)
            end
            for x = -1, 1 do
                fbPut(fb, e.x + x, e.y - 1, " ", colors.black, colors.red)
            end
            fbPut(fb, e.x - 2, e.y, "o", colors.yellow, colors.red)
            fbPut(fb, e.x + 2, e.y, "o", colors.yellow, colors.red)
            for _, x in ipairs({-3, -1, 1, 3}) do
                fbPut(fb, e.x + x, e.y + 1, "v", colors.black, colors.orange)
            end
        else
            local def = ENEMY[e.kind]
            if e.hw > 0 then
                fbPut(fb, e.x - 1, e.y, "[", def.fg, def.bg)
                fbPut(fb, e.x + 1, e.y, "]", def.fg, def.bg)
            end
            fbPut(fb, e.x, e.y, def.ch, def.fg, def.bg)
        end
    end

    for _, b in ipairs(st.shots) do
        fbPut(fb, b.x, b.y, b.ch, b.color, colors.black)
    end

    -- Player: the hull cell is the only hitbox, the wings are decoration.
    if not st.gameOver then
        local blink = st.invuln > 0 and (st.invuln % 4 < 2)
        local wing = blink and colors.gray or colors.lightBlue
        local hull = blink and colors.red or colors.white
        fbPut(fb, st.px - 1, st.py, "/", wing, colors.black)
        fbPut(fb, st.px + 1, st.py, "\\", wing, colors.black)
        fbPut(fb, st.px, st.py, "A", hull, colors.black)
    end

    -- Boss health bar sits on the top row so it survives the bullet storm.
    local boss = st.boss
    if boss and boss.hp > 0 and fb.w >= 10 then
        local width = fb.w - 2
        local filled = math.floor(width * math.max(0, boss.hp) / boss.maxHp + 0.5)
        for x = 1, width do
            if x <= filled then
                fbPut(fb, x + 1, 1, "=", colors.red, colors.black)
            else
                fbPut(fb, x + 1, 1, "-", colors.gray, colors.black)
            end
        end
    end

    fbRender(fb, win, 3)
end

local function drawTitle(st, win, W)
    writeAt(win, 1, 1, colors.lightBlue, colors.black, string.rep(" ", W))
    writeAt(win, 1, 1, colors.lightBlue, colors.black, " Sky Raid ")
    local right = "Score " .. st.score .. "  Best " .. bestScore(st)
    if W < #right + 11 then right = tostring(st.score) end
    if W >= #right + 11 then
        writeAt(win, W - #right + 1, 1, colors.lightBlue, colors.black, right)
    end
end

local function drawToolbar(st, win, W)
    writeAt(win, 1, 2, colors.black, colors.white, string.rep(" ", W))
    local pauseBg = st.running and colors.orange or colors.green
    local pauseText = st.running and "Pause" or "Start"
    local endX
    if W >= 30 then
        button(st, win, 1, 2, "[ New ]", colors.gray, colors.white, "new")
        button(st, win, 9, 2, "[ " .. pauseText .. " ]", pauseBg, colors.white, "pause")
        button(st, win, 19, 2, "[ " .. st.diff.name .. " ]", colors.gray, colors.white, "diff")
        endX = 19 + #st.diff.name + 4
    else
        button(st, win, 1, 2, "[N]", colors.gray, colors.white, "new")
        button(st, win, 5, 2, "[" .. string.sub(pauseText, 1, 1) .. "]", pauseBg, colors.white, "pause")
        button(st, win, 9, 2, "[" .. string.sub(st.diff.name, 1, 1) .. "]", colors.gray, colors.white, "diff")
        endX = 12
    end
    local hud = "W" .. st.wave .. " L" .. st.lives .. " B" .. st.bombs .. " P" .. st.power
    if W - #hud >= endX + 1 then
        writeAt(win, W - #hud + 1, 2, colors.black, colors.lightGray, hud)
    end
end

local function drawControls(st, win, W, H)
    local y1, y2 = H - 2, H - 1
    local bg, fg = colors.gray, colors.white
    writeAt(win, 1, y1, colors.black, colors.white, string.rep(" ", W))
    writeAt(win, 1, y2, colors.black, colors.white, string.rep(" ", W))
    if W >= 26 then
        local cx = math.floor((W - 5) / 2) + 1
        button(st, win, cx, y1, "[ ^ ]", bg, fg, "up")
        button(st, win, cx - 6, y2, "[ < ]", bg, fg, "left")
        button(st, win, cx, y2, "[ v ]", bg, fg, "down")
        button(st, win, cx + 6, y2, "[ > ]", bg, fg, "right")
        if cx - 8 >= 1 then
            button(st, win, 1, y1, "[Bomb]", colors.red, colors.white, "bomb")
        end
    else
        local cx = math.floor((W - 3) / 2) + 1
        button(st, win, cx, y1, "[^]", bg, fg, "up")
        button(st, win, W - 2, y1, "[B]", colors.red, colors.white, "bomb")
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

-- Bullets and enemies that fall outside a shrunk window are dropped; a game in
-- progress keeps its score instead of being restarted under the player.
local function refit(st, pw, ph)
    st.pw, st.ph = pw, ph
    st.fb = newFb(pw, ph)
    st.px = clamp(st.px, 1, pw)
    st.py = clamp(st.py, 1, ph)
    st.target = nil
    local function inside(list)
        local kept = {}
        for _, o in ipairs(list) do
            if o.x >= -2 and o.x <= pw + 2 and o.y <= ph + 2 then kept[#kept + 1] = o end
        end
        return kept
    end
    st.shots, st.pshots, st.parts, st.drops = inside(st.shots), inside(st.pshots),
        inside(st.parts), inside(st.drops)
    local kept = {}
    for _, e in ipairs(st.enemies) do
        e.x = clamp(e.x, 1 + e.hw, math.max(1 + e.hw, pw - e.hw))
        if e.y <= ph then kept[#kept + 1] = e end
    end
    st.enemies = kept
    st.boss = nil
    for _, e in ipairs(st.enemies) do
        if e.kind == "boss" then st.boss = e end
    end
    for _, s in ipairs(st.stars) do
        s.x = clamp(s.x, 1, pw)
        s.y = math.min(s.y, ph)
    end
end

-- app ------------------------------------------------------------------------

function M.init(win, ctx)
    math.randomseed(nowMs() % 2147483647)
    local db = loadDb()
    local _, diff = diffById(db.diff)
    local st = {
        win  = win,
        ctx  = ctx,
        db   = db,
        diff = diff,
        hit  = {},
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
    local pw, ph = fieldSize(win)
    if pw ~= st.pw or ph ~= st.ph then
        if not st.started and not st.gameOver then
            resetGame(st)
        else
            refit(st, pw, ph)
        end
    end
    drawTitle(st, win, W)
    drawToolbar(st, win, W)
    drawField(st, win)
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
    -- A tap inside the field flies the plane there, which is the only sane
    -- control scheme on a monitor without a keyboard.
    local _, H = st.win.getSize()
    if y >= 3 and y <= H - 3 then
        if not ensureRunning(st) then return true end
        st.target = {x = clamp(x, 1, st.pw), y = clamp(y - 2, 1, st.ph)}
        return true
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
        if k == keys.up then movePlayer(st, 0, -1); return st, true end
        if k == keys.down then movePlayer(st, 0, 1); return st, true end
        if k == keys.left then movePlayer(st, -1, 0); return st, true end
        if k == keys.right then movePlayer(st, 1, 0); return st, true end
        if k == keys.space or k == keys.x then useBomb(st); return st, true end
        if k == keys.enter or k == keys.p then pauseGame(st); return st, true end
        if k == keys.r or k == keys.n then resetGame(st); return st, true end
        if k == keys.tab then cycleDiff(st); return st, true end
        if k == keys.escape or k == keys.q then return st, false end
    elseif e == "char" then
        local c = string.lower(tostring(p1 or ""))
        if c == "w" then movePlayer(st, 0, -1); return st, true end
        if c == "s" then movePlayer(st, 0, 1); return st, true end
        if c == "a" then movePlayer(st, -1, 0); return st, true end
        if c == "d" then movePlayer(st, 1, 0); return st, true end
        if c == "b" then useBomb(st); return st, true end
        if c == "q" then return st, false end
    elseif e == "mouse_click" or e == "mouse_drag" or e == "monitor_touch" then
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
