local realDofile = dofile

colors = {
    white = 1, orange = 2, magenta = 4, lightBlue = 8,
    yellow = 16, lime = 32, pink = 64, gray = 128,
    lightGray = 256, cyan = 512, purple = 1024, blue = 2048,
    brown = 4096, green = 8192, red = 16384, black = 32768,
}

keys = {
    up = 1, down = 2, left = 3, right = 4, space = 5, x = 6,
    enter = 7, p = 8, r = 9, n = 10, tab = 11, escape = 12, q = 13,
}

local timer = 0
os.startTimer = function()
    timer = timer + 1
    return timer
end

textutils = {
    serialize = function() return "{}" end,
    unserialize = function() return {} end,
}

local fsutil = {
    ensureDir = function() end,
    readFile = function() return nil end,
    atomicWrite = function() end,
}

dofile = function(path)
    if path == "/os/lib/fsutil.lua" then return fsutil end
    return realDofile(path)
end

local function window(w, h)
    return {
        getSize = function() return w or 30, h or 20 end,
        setCursorPos = function() end,
        setBackgroundColor = function() end,
        setTextColor = function() end,
        write = function() end,
        clear = function() end,
    }
end

local function equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

local sky = assert(loadfile("apps/skyraid.lua"))()

local function newState()
    return sky.init(window(), {})
end

local tests = {}

function tests.difficulty_changes_only_for_next_game()
    local st = newState()
    sky.onEvent(st, "key", keys.enter)
    equal(st.diff.id, "normal")
    sky.onEvent(st, "key", keys.tab)
    equal(st.diff.id, "normal", "active difficulty changed during a run")
    equal(st.nextDiff.id, "hard", "next difficulty was not selected")
    sky.onEvent(st, "key", keys.n)
    equal(st.diff.id, "hard", "new game did not adopt selected difficulty")
end

function tests.fast_shot_hits_enemy_along_travelled_segment()
    local st = newState()
    st.running, st.started, st.timerId = true, true, 42
    st.queue, st.qi = {}, 1
    st.pshots = {{x = 10, y = 4.8, vx = 0, vy = -2.4}}
    st.enemies = {{
        kind = "turret", x = 10, y = 3.2, hp = 10, maxHp = 10,
        hw = 1, hh = 0, t = 10, seed = -0.66, holdY = 3.2,
        leaveT = 100, fireT = 0,
    }}
    sky.onEvent(st, "timer", 42)
    equal(st.enemies[1].hp, 9, "fast shot tunnelled through the turret")
    equal(#st.pshots, 0, "hitting shot was not consumed")
end

function tests.defeated_enemy_cannot_update_or_fire_again()
    local st = newState()
    st.running, st.started, st.timerId = true, true, 43
    st.queue, st.qi = {}, 1
    st.enemies = {{
        kind = "turret", x = 10, y = 3, hp = 0, maxHp = 10,
        hw = 1, hh = 0, t = 20, seed = 0, holdY = 3,
        leaveT = 100, fireT = 99,
    }}
    sky.onEvent(st, "timer", 43)
    equal(#st.enemies, 0, "defeated enemy remained active")
    equal(#st.shots, 0, "defeated enemy fired a final volley")
end

function tests.respawn_blast_removes_nearby_bullets()
    local st = newState()
    st.running, st.started, st.timerId = true, true, 44
    st.queue, st.qi = {}, 1
    st.lives = 2
    st.px, st.py = 10, 10
    st.shots = {
        {x = 10, y = 10, vx = 0, vy = 0, ch = "o", color = colors.red},
        {x = 10, y = st.ph - 1, vx = 0, vy = 0, ch = "o", color = colors.red},
        {x = 1, y = 1, vx = 0, vy = 0, ch = "o", color = colors.red},
    }
    sky.onEvent(st, "timer", 44)
    equal(st.lives, 1, "collision did not cost one life")
    equal(#st.shots, 1, "respawn blast did not filter the rebuilt shot list")
    equal(st.shots[1].x, 1, "a distant bullet was removed")
end


local passed = 0
for name, test in pairs(tests) do
    test()
    passed = passed + 1
    io.write("ok - ", name, "\n")
end
io.write(passed, " tests passed\n")
