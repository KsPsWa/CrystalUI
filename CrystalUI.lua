--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                                                                           ║
    ║    C R Y S T A L U I   —   Glassmorphism GUI Framework for Roblox         ║
    ║                                                                           ║
    ║    • Pure Lua (single script, no modules required)                        ║
    ║    • Puzzle-assembly intro animation (1.9 s)                              ║
    ║    • Spring + easing animation engine                                     ║
    ║    • Window / Tabs / Sections / 15+ elements                              ║
    ║    • Notifications, Tooltips, Dialogs, Watermark, Keybind list            ║
    ║    • Config system (save / load / autoload) + Theme manager               ║
    ║                                                                           ║
    ║    Quick start (see the DEMO block at the very bottom of this file):      ║
    ║                                                                           ║
    ║      local Window = CrystalUI:CreateWindow({ Title = "My Hub" })          ║
    ║      local Tab    = Window:AddTab({ Name = "Main", Icon = "home" })       ║
    ║      local Sec    = Tab:AddSection({ Name = "Combat" })                   ║
    ║      Sec:AddToggle({ Flag = "esp", Text = "ESP", Default = true })        ║
    ║                                                                           ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

-- ════════════════════════════════════════════════════════════════════════════
--  SECTION 1 — BOOTSTRAP: services, executor compatibility, base classes
-- ════════════════════════════════════════════════════════════════════════════

local Library = {}
Library.__index = Library
Library.Name = "CrystalUI"
Library.Version = "1.0.0"
Library.Flags = {}          -- [flag] = current value
Library.Elements = {}       -- [flag] = element object
Library.Windows = {}
Library.Keybinds = {}       -- all registered keybind objects
Library.Unloaded = false
Library.Toggled = true

local GlobalEnv = (getgenv and getgenv()) or _G

-- If the script is executed twice, tear down the previous instance first.
if GlobalEnv.CrystalUI and type(GlobalEnv.CrystalUI.Unload) == "function" then
    pcall(function() GlobalEnv.CrystalUI:Unload() end)
end

-- ── Compatibility layer ─────────────────────────────────────────────────────
local Compat = {}
Compat.cloneref = cloneref or function(obj) return obj end
Compat.gethui = gethui
Compat.protect = (syn and syn.protect_gui) or protect_gui
Compat.setclipboard = setclipboard or toclipboard or (Clipboard and Clipboard.set)
Compat.request = request or http_request or (syn and syn.request)
Compat.HasFS = (type(writefile) == "function") and (type(readfile) == "function")
    and (type(isfile) == "function") and (type(makefolder) == "function")
    and (type(isfolder) == "function")
Compat.listfiles = listfiles
Compat.delfile = delfile

-- ── Services ────────────────────────────────────────────────────────────────
local S = {}
for _, name in ipairs({
    "Players", "RunService", "UserInputService", "TweenService", "HttpService",
    "Lighting", "CoreGui", "TextService", "GuiService", "Stats", "ContextActionService",
}) do
    local ok, svc = pcall(function() return Compat.cloneref(game:GetService(name)) end)
    S[name] = ok and svc or game:GetService(name)
end

local LocalPlayer = S.Players.LocalPlayer
local Mouse = LocalPlayer and LocalPlayer:GetMouse()
local Camera = workspace.CurrentCamera

-- ════════════════════════════════════════════════════════════════════════════
--  Signal — lightweight event class
-- ════════════════════════════════════════════════════════════════════════════

local Signal = {}
Signal.__index = Signal

function Signal.new()
    return setmetatable({ _handlers = {}, _waiting = {} }, Signal)
end

function Signal:Connect(fn)
    local conn = { Connected = true, _fn = fn, _sig = self }
    function conn:Disconnect()
        if not self.Connected then return end
        self.Connected = false
        local list = self._sig._handlers
        for i = 1, #list do
            if list[i] == self then
                table.remove(list, i)
                break
            end
        end
    end
    table.insert(self._handlers, conn)
    return conn
end

function Signal:Once(fn)
    local conn
    conn = self:Connect(function(...)
        if conn then conn:Disconnect() end
        fn(...)
    end)
    return conn
end

function Signal:Fire(...)
    local snapshot = table.clone and table.clone(self._handlers) or { unpack(self._handlers) }
    for i = 1, #snapshot do
        local c = snapshot[i]
        if c.Connected then
            task.spawn(c._fn, ...)
        end
    end
    if #self._waiting > 0 then
        local waiting = self._waiting
        self._waiting = {}
        for _, th in ipairs(waiting) do
            task.spawn(th, ...)
        end
    end
end

function Signal:Wait()
    table.insert(self._waiting, coroutine.running())
    return coroutine.yield()
end

function Signal:DisconnectAll()
    for i = #self._handlers, 1, -1 do
        self._handlers[i].Connected = false
        self._handlers[i] = nil
    end
end
Signal.Destroy = Signal.DisconnectAll

-- ════════════════════════════════════════════════════════════════════════════
--  Maid — cleans up connections / instances / functions in one call
-- ════════════════════════════════════════════════════════════════════════════

local Maid = {}
Maid.__index = Maid

function Maid.new()
    return setmetatable({ _tasks = {} }, Maid)
end

local function destroyTask(t)
    local ty = typeof(t)
    if ty == "RBXScriptConnection" then
        t:Disconnect()
    elseif ty == "Instance" then
        t:Destroy()
    elseif ty == "function" then
        t()
    elseif ty == "table" then
        if t.Disconnect then t:Disconnect()
        elseif t.Destroy then t:Destroy()
        elseif t.Cancel then t:Cancel() end
    end
end

function Maid:Give(task_)
    table.insert(self._tasks, task_)
    return task_
end

function Maid:Clean()
    local list = self._tasks
    self._tasks = {}
    for i = #list, 1, -1 do
        pcall(destroyTask, list[i])
    end
end
Maid.Destroy = Maid.Clean

-- The library-wide maid: everything long-lived is registered here so that
-- Library:Unload() can wipe every trace of the UI.
local RootMaid = Maid.new()

-- ════════════════════════════════════════════════════════════════════════════
--  Utilities
-- ════════════════════════════════════════════════════════════════════════════

local U = {}

function U.Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function U.Lerp(a, b, t)
    return a + (b - a) * t
end

function U.Map(v, inLo, inHi, outLo, outHi)
    if inHi == inLo then return outLo end
    return outLo + (v - inLo) * (outHi - outLo) / (inHi - inLo)
end

function U.Round(v, step)
    step = step or 1
    if step == 0 then return v end
    local r = math.floor(v / step + 0.5) * step
    -- clean up floating point noise (0.30000000000000004 -> 0.3)
    local decimals = 0
    local s = tostring(step)
    local dot = s:find("%.")
    if dot then decimals = #s - dot end
    local mult = 10 ^ decimals
    return math.floor(r * mult + 0.5) / mult
end

function U.FormatNumber(v, decimals)
    if decimals and decimals > 0 then
        return string.format("%." .. decimals .. "f", v)
    end
    if math.abs(v - math.floor(v)) < 1e-9 then
        return tostring(math.floor(v))
    end
    local s = string.format("%.3f", v)
    s = s:gsub("0+$", ""):gsub("%.$", "")
    return s
end

function U.DecimalsOf(step)
    local s = tostring(step)
    local dot = s:find("%.")
    if dot then return #s - dot end
    return 0
end

function U.Truncate(text, maxLen)
    if #text <= maxLen then return text end
    return text:sub(1, math.max(1, maxLen - 1)) .. "…"
end

function U.Trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function U.Split(s, sep)
    local out = {}
    for piece in string.gmatch(s, "([^" .. sep .. "]+)") do
        out[#out + 1] = piece
    end
    return out
end

function U.RandomId(len)
    len = len or 12
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local t = {}
    for i = 1, len do
        local r = math.random(1, #chars)
        t[i] = chars:sub(r, r)
    end
    return table.concat(t)
end

-- ── Table helpers ───────────────────────────────────────────────────────────

function U.DeepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = U.DeepCopy(v) end
    return out
end

function U.Merge(defaults, overrides)
    local out = {}
    for k, v in pairs(defaults) do out[k] = v end
    if overrides then
        for k, v in pairs(overrides) do out[k] = v end
    end
    return out
end

function U.Find(list, value)
    for i, v in ipairs(list) do
        if v == value then return i end
    end
    return nil
end

function U.Count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function U.SortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

function U.Values(t)
    local out = {}
    for _, v in pairs(t) do out[#out + 1] = v end
    return out
end

-- ── Color helpers ───────────────────────────────────────────────────────────

function U.ToHex(c)
    return string.format("#%02X%02X%02X",
        math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

function U.FromHex(str)
    if type(str) ~= "string" then return nil end
    str = str:gsub("#", ""):gsub("%s", "")
    if #str == 3 then
        str = str:sub(1, 1):rep(2) .. str:sub(2, 2):rep(2) .. str:sub(3, 3):rep(2)
    end
    if #str ~= 6 or not str:match("^%x+$") then return nil end
    local r = tonumber(str:sub(1, 2), 16)
    local g = tonumber(str:sub(3, 4), 16)
    local b = tonumber(str:sub(5, 6), 16)
    return Color3.fromRGB(r, g, b)
end

function U.Mix(a, b, t)
    return a:Lerp(b, t)
end

function U.Lighten(c, amount)
    return c:Lerp(Color3.new(1, 1, 1), amount)
end

function U.Darken(c, amount)
    return c:Lerp(Color3.new(0, 0, 0), amount)
end

function U.Luma(c)
    return 0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B
end

function U.Readable(bg, light, dark)
    if U.Luma(bg) > 0.58 then
        return dark or Color3.fromRGB(18, 20, 28)
    end
    return light or Color3.fromRGB(255, 255, 255)
end

function U.Saturate(c, amount)
    local h, s, v = c:ToHSV()
    return Color3.fromHSV(h, U.Clamp(s + amount, 0, 1), v)
end

function U.ShiftHue(c, delta)
    local h, s, v = c:ToHSV()
    return Color3.fromHSV((h + delta) % 1, s, v)
end

function U.Rainbow(speed, offset)
    speed = speed or 0.25
    return Color3.fromHSV(((os.clock() * speed) + (offset or 0)) % 1, 0.85, 1)
end

-- ── Text measuring ──────────────────────────────────────────────────────────

function U.TextSize(text, size, font, width)
    local ok, res = pcall(function()
        return S.TextService:GetTextSize(text, size, font or Enum.Font.GothamMedium,
            Vector2.new(width or 100000, 100000))
    end)
    if ok then return res end
    return Vector2.new(#text * size * 0.55, size)
end

-- ── Input helpers ───────────────────────────────────────────────────────────

function U.IsTouch()
    return S.UserInputService.TouchEnabled and not S.UserInputService.KeyboardEnabled
end

function U.IsPointer(input)
    local t = input.UserInputType
    return t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch
end

function U.IsMove(input)
    local t = input.UserInputType
    return t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch
end

function U.MousePos()
    return S.UserInputService:GetMouseLocation()
end

function U.InBounds(gui, pos)
    local p, s = gui.AbsolutePosition, gui.AbsoluteSize
    return pos.X >= p.X and pos.X <= p.X + s.X and pos.Y >= p.Y and pos.Y <= p.Y + s.Y
end

function U.KeyName(kc)
    if typeof(kc) == "EnumItem" then
        if kc.EnumType == Enum.KeyCode then
            local n = kc.Name
            local map = {
                LeftShift = "LShift", RightShift = "RShift", LeftControl = "LCtrl", RightControl = "RCtrl",
                LeftAlt = "LAlt", RightAlt = "RAlt", Return = "Enter", Backspace = "Bksp",
                Escape = "Esc", Space = "Space", Zero = "0", One = "1", Two = "2", Three = "3",
                Four = "4", Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9",
                Minus = "-", Equals = "=", LeftBracket = "[", RightBracket = "]", Semicolon = ";",
                Quote = "'", Comma = ",", Period = ".", Slash = "/", BackSlash = "\\",
                Backquote = "`", Insert = "Ins", Delete = "Del", PageUp = "PgUp", PageDown = "PgDn",
            }
            return map[n] or n
        elseif kc.EnumType == Enum.UserInputType then
            local map = { MouseButton1 = "MB1", MouseButton2 = "MB2", MouseButton3 = "MB3" }
            return map[kc.Name] or kc.Name
        end
    end
    return "None"
end

-- ── Misc ────────────────────────────────────────────────────────────────────

function U.SafeCall(fn, ...)
    if type(fn) ~= "function" then return true end
    local ok, err = pcall(fn, ...)
    if not ok then
        warn("[CrystalUI] callback error: " .. tostring(err))
    end
    return ok, err
end

function U.Throttle(fn, interval)
    local last = 0
    return function(...)
        local now = os.clock()
        if now - last >= interval then
            last = now
            return fn(...)
        end
    end
end

function U.Debounce(fn, delay)
    local token = 0
    return function(...)
        token = token + 1
        local my = token
        local args = table.pack(...)
        task.delay(delay, function()
            if my == token then fn(table.unpack(args, 1, args.n)) end
        end)
    end
end

-- Resolve where the ScreenGuis should live (hidden UI > CoreGui > PlayerGui)
function U.GuiParent()
    if Compat.gethui then
        local ok, h = pcall(Compat.gethui)
        if ok and h then return h end
    end
    local ok = pcall(function() return S.CoreGui.Name end)
    if ok then return S.CoreGui end
    return LocalPlayer:WaitForChild("PlayerGui")
end

function U.NewScreenGui(name, order)
    local gui = Instance.new("ScreenGui")
    gui.Name = name or U.RandomId(14)
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = order or 1000
    gui.OnTopOfCoreBlur = true
    if Compat.protect then pcall(Compat.protect, gui) end
    gui.Parent = U.GuiParent()
    return gui
end

-- ════════════════════════════════════════════════════════════════════════════
--  SECTION 2 — ANIMATION ENGINE
--  • 35+ easing functions
--  • property tween engine (number, Color3, UDim2, UDim, Vector2, Vector3 ...)
--  • critically-tunable spring engine with velocity preservation
--  • sequencing / stagger / looping helpers
-- ════════════════════════════════════════════════════════════════════════════

local Ease = {}
do
    local pi, sin, cos, sqrt = math.pi, math.sin, math.cos, math.sqrt

    local function bounceOut(t)
        local n1, d1 = 7.5625, 2.75
        if t < 1 / d1 then
            return n1 * t * t
        elseif t < 2 / d1 then
            t = t - 1.5 / d1
            return n1 * t * t + 0.75
        elseif t < 2.5 / d1 then
            t = t - 2.25 / d1
            return n1 * t * t + 0.9375
        else
            t = t - 2.625 / d1
            return n1 * t * t + 0.984375
        end
    end

    -- Every "base" function below is an EaseIn curve. Out / InOut are derived.
    local bases = {
        Sine = function(t) return 1 - cos(t * pi / 2) end,
        Quad = function(t) return t * t end,
        Cubic = function(t) return t * t * t end,
        Quart = function(t) return t * t * t * t end,
        Quint = function(t) return t * t * t * t * t end,
        Expo = function(t) if t == 0 then return 0 end return 2 ^ (10 * t - 10) end,
        Circ = function(t) return 1 - sqrt(1 - t * t) end,
        Back = function(t)
            local c1 = 1.70158
            local c3 = c1 + 1
            return c3 * t * t * t - c1 * t * t
        end,
        Elastic = function(t)
            if t == 0 or t == 1 then return t end
            return -(2 ^ (10 * t - 10)) * sin((t * 10 - 10.75) * ((2 * pi) / 3))
        end,
        Bounce = function(t) return 1 - bounceOut(1 - t) end,
    }

    for name, fnIn in pairs(bases) do
        Ease[name .. "In"] = fnIn
        Ease[name .. "Out"] = function(t) return 1 - fnIn(1 - t) end
        Ease[name .. "InOut"] = function(t)
            if t < 0.5 then
                return fnIn(2 * t) / 2
            end
            return 1 - fnIn(2 - 2 * t) / 2
        end
    end

    Ease.Linear = function(t) return t end
    Ease.Smooth = function(t) return t * t * (3 - 2 * t) end
    Ease.Smoother = function(t) return t * t * t * (t * (t * 6 - 15) + 10) end
    Ease.Snap = function(t) return 1 - (1 - t) ^ 6 end

    -- Back easing with custom overshoot: Ease.BackOutWith(2.2)
    function Ease.BackOutWith(overshoot)
        local c3 = overshoot + 1
        return function(t)
            local u = t - 1
            return 1 + c3 * u * u * u + overshoot * u * u
        end
    end

    -- Damped-sine "wobble" settle curve (cheap pseudo spring as an easing)
    function Ease.Wobble(freq, decay)
        freq = freq or 3
        decay = decay or 6
        return function(t)
            if t >= 1 then return 1 end
            return 1 - math.exp(-decay * t) * cos(freq * pi * 2 * t)
        end
    end

    -- Accepts "OutQuad", "QuadOut", a function, or nil.
    function Ease.Get(e)
        if type(e) == "function" then return e end
        if e == nil then return Ease.QuadOut end
        local direct = Ease[e]
        if type(direct) == "function" then return direct end
        local str = tostring(e)
        local mode, name = str:match("^(InOut)(%a+)$")
        if not mode then mode, name = str:match("^(In)(%a+)$") end
        if not mode then mode, name = str:match("^(Out)(%a+)$") end
        if mode and name then
            local f = Ease[name .. mode]
            if type(f) == "function" then return f end
        end
        return Ease.QuadOut
    end
end

-- ── Value <-> component conversion (used by tweens & springs) ───────────────

local function lerpValue(a, b, t)
    local ty = typeof(a)
    if ty == "number" then
        return a + (b - a) * t
    elseif ty == "Color3" or ty == "UDim2" or ty == "Vector2" or ty == "Vector3" then
        return a:Lerp(b, t)
    elseif ty == "UDim" then
        return UDim.new(a.Scale + (b.Scale - a.Scale) * t, a.Offset + (b.Offset - a.Offset) * t)
    elseif ty == "Rect" then
        return Rect.new(a.Min:Lerp(b.Min, t), a.Max:Lerp(b.Max, t))
    end
    if t >= 1 then return b end
    return a
end

local function toComps(v)
    local ty = typeof(v)
    if ty == "number" then
        return { v }, ty, { 0.003 }
    elseif ty == "Color3" then
        return { v.R, v.G, v.B }, ty, { 0.001, 0.001, 0.001 }
    elseif ty == "UDim2" then
        return { v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset }, ty, { 0.0004, 0.04, 0.0004, 0.04 }
    elseif ty == "UDim" then
        return { v.Scale, v.Offset }, ty, { 0.0004, 0.04 }
    elseif ty == "Vector2" then
        return { v.X, v.Y }, ty, { 0.03, 0.03 }
    elseif ty == "Vector3" then
        return { v.X, v.Y, v.Z }, ty, { 0.01, 0.01, 0.01 }
    end
    return nil
end

local function fromComps(ty, c)
    if ty == "number" then return c[1]
    elseif ty == "Color3" then
        return Color3.new(U.Clamp(c[1], 0, 1), U.Clamp(c[2], 0, 1), U.Clamp(c[3], 0, 1))
    elseif ty == "UDim2" then return UDim2.new(c[1], c[2], c[3], c[4])
    elseif ty == "UDim" then return UDim.new(c[1], c[2])
    elseif ty == "Vector2" then return Vector2.new(c[1], c[2])
    elseif ty == "Vector3" then return Vector3.new(c[1], c[2], c[3])
    end
end

-- ── The engine ──────────────────────────────────────────────────────────────

local Anim = {}
Anim.TimeScale = 1       -- global speed multiplier (0.5 = slow-mo)
Anim.Enabled = true      -- when false every animation completes instantly

local Tweens = {}        -- active tween records
local Springs = {}       -- active spring records
local Loops = {}         -- per-frame callbacks
local Locks = setmetatable({}, { __mode = "k" })  -- [inst][prop] = record (latest wins)

local function lockOf(inst)
    local l = Locks[inst]
    if not l then
        l = {}
        Locks[inst] = l
    end
    return l
end

local function removeFrom(list, rec)
    for i = #list, 1, -1 do
        if list[i] == rec then
            table.remove(list, i)
            return
        end
    end
end

local function releaseLocks(rec)
    if rec.inst and rec.props then
        local l = Locks[rec.inst]
        if l then
            for prop in pairs(rec.props) do
                if l[prop] == rec then l[prop] = nil end
            end
        end
    end
end

-- Tween step ----------------------------------------------------------------

local function stepTween(rec, now)
    if now < rec.start then return false end
    local inst = rec.inst
    local lock = Locks[inst]

    if not rec.began then
        rec.began = true
        for prop, data in pairs(rec.props) do
            data.from = inst[prop]
        end
    end

    local alpha = (now - rec.start) / rec.dur
    if alpha > 1 then alpha = 1 end
    local eased = rec.ease(alpha)

    local remaining = 0
    for prop, data in pairs(rec.props) do
        if lock and lock[prop] ~= rec then
            rec.props[prop] = nil       -- superseded by a newer tween / spring
        else
            remaining = remaining + 1
            inst[prop] = lerpValue(data.from, data.to, eased)
        end
    end

    if alpha >= 1 or remaining == 0 then
        if remaining > 0 then
            for prop, data in pairs(rec.props) do
                inst[prop] = data.to
            end
        end
        return true
    end
    return false
end

local function stepCustom(rec, now)
    if now < rec.start then return false end
    local alpha = (now - rec.start) / rec.dur
    if alpha > 1 then alpha = 1 end
    rec.fn(rec.ease(alpha), alpha)
    return alpha >= 1
end

-- Spring step ---------------------------------------------------------------

local SUBSTEP = 1 / 120

local function stepSpring(rec, dt)
    local pos, vel, target, thr = rec.pos, rec.vel, rec.target, rec.thr
    local k, d = rec.stiffness, rec.damping
    local n = math.max(1, math.ceil(dt / SUBSTEP))
    local h = dt / n
    for _ = 1, n do
        for i = 1, #pos do
            local acc = -k * (pos[i] - target[i]) - d * vel[i]
            vel[i] = vel[i] + acc * h
            pos[i] = pos[i] + vel[i] * h
        end
    end

    local settled = true
    for i = 1, #pos do
        if math.abs(pos[i] - target[i]) > thr[i] or math.abs(vel[i]) > thr[i] * 4 then
            settled = false
            break
        end
    end

    local inst = rec.inst
    if settled then
        inst[rec.prop] = rec.finalValue
        return true
    end
    inst[rec.prop] = fromComps(rec.kind, pos)
    return false
end

-- Main loop -----------------------------------------------------------------

local lastClock = os.clock()
local function onFrame()
    local now = os.clock()
    local dt = math.min(now - lastClock, 0.1) * Anim.TimeScale
    lastClock = now

    -- Tweens (swap-remove, iterate backwards)
    for i = #Tweens, 1, -1 do
        local rec = Tweens[i]
        local ok, finished
        if rec.dead then
            ok, finished = true, true
        elseif rec.fn then
            ok, finished = pcall(stepCustom, rec, now)
        else
            ok, finished = pcall(stepTween, rec, now)
        end
        if not ok then
            warn("[CrystalUI] tween error: " .. tostring(finished))
            finished = true
        end
        if finished then
            table.remove(Tweens, i)
            releaseLocks(rec)
            if rec.done and not rec.dead then
                task.spawn(rec.done)
            end
        end
    end

    -- Springs
    for i = #Springs, 1, -1 do
        local rec = Springs[i]
        local lock = Locks[rec.inst]
        local ok, finished
        if rec.dead or (lock and lock[rec.prop] ~= rec) then
            ok, finished = true, true
        else
            ok, finished = pcall(stepSpring, rec, dt)
        end
        if not ok then
            warn("[CrystalUI] spring error: " .. tostring(finished))
            finished = true
        end
        if finished then
            table.remove(Springs, i)
            if lock and lock[rec.prop] == rec then lock[rec.prop] = nil end
            if rec.done and not rec.dead and ok then task.spawn(rec.done) end
        end
    end

    -- Loops
    for i = #Loops, 1, -1 do
        local l = Loops[i]
        if l.dead then
            table.remove(Loops, i)
        else
            local ok, err = pcall(l.fn, dt, now)
            if not ok then
                warn("[CrystalUI] loop error: " .. tostring(err))
                l.dead = true
            end
        end
    end
end

RootMaid:Give(S.RunService.RenderStepped:Connect(onFrame))

-- ── Public animation API ────────────────────────────────────────────────────

-- Tween properties of an instance.
--   Anim.Tween(inst, { BackgroundTransparency = 0.5 }, 0.3, "OutQuad", delay, onDone)
function Anim.Tween(inst, props, dur, ease, delay, onDone)
    dur = (dur or 0.25)
    delay = delay or 0
    if not Anim.Enabled or Anim.TimeScale <= 0 then dur, delay = 0, 0 end
    dur = dur / math.max(Anim.TimeScale, 0.001)
    delay = delay / math.max(Anim.TimeScale, 0.001)

    if dur <= 0 and delay <= 0 then
        for p, v in pairs(props) do inst[p] = v end
        if onDone then task.spawn(onDone) end
        return { Cancel = function() end }
    end

    local rec = {
        inst = inst, props = {}, start = os.clock() + delay, dur = math.max(dur, 0.0001),
        ease = Ease.Get(ease), done = onDone, began = false,
    }
    local lock = lockOf(inst)
    for p, v in pairs(props) do
        rec.props[p] = { to = v }
        lock[p] = rec
    end
    table.insert(Tweens, rec)

    return {
        Cancel = function()
            rec.dead = true
        end,
    }
end

-- Run a custom eased value over time: onUpdate(eased, linearAlpha)
function Anim.Custom(dur, ease, onUpdate, onDone, delay)
    delay = delay or 0
    dur = dur or 0.3
    if not Anim.Enabled then dur, delay = 0.0001, 0 end
    local rec = {
        fn = onUpdate, start = os.clock() + delay / math.max(Anim.TimeScale, 0.001),
        dur = math.max(dur / math.max(Anim.TimeScale, 0.001), 0.0001),
        ease = Ease.Get(ease), done = onDone,
    }
    table.insert(Tweens, rec)
    return { Cancel = function() rec.dead = true end }
end

-- Animate a plain number: Anim.Number(0, 100, 1, "OutCubic", function(v) ... end)
function Anim.Number(from, to, dur, ease, onUpdate, onDone, delay)
    return Anim.Custom(dur, ease, function(e)
        onUpdate(from + (to - from) * e)
    end, onDone, delay)
end

-- Spring a single property toward a target value.
--   Anim.Spring(frame, "Position", UDim2.new(...), { Stiffness = 220, Damping = 22 })
function Anim.Spring(inst, prop, target, opts)
    opts = opts or {}
    if opts.Delay and opts.Delay > 0 then
        local o = U.Merge(opts, { Delay = 0 })
        task.delay(opts.Delay, function() Anim.Spring(inst, prop, target, o) end)
        return nil
    end
    local stiffness = opts.Stiffness or 220
    local damping = opts.Damping or (2 * math.sqrt(stiffness) * (opts.Ratio or 0.8))

    if not Anim.Enabled then
        inst[prop] = target
        return nil
    end

    local lock = lockOf(inst)
    local existing = lock[prop]

    if existing and existing.isSpring and not existing.dead then
        -- retarget an in-flight spring while preserving velocity (feels organic)
        local comps = toComps(target)
        existing.target = comps
        existing.finalValue = target
        existing.stiffness = stiffness
        existing.damping = damping
        existing.done = opts.Done
        return existing
    end

    local current = inst[prop]
    local comps, kind, thr = toComps(current)
    if not comps then
        inst[prop] = target
        return nil
    end
    local tcomps = toComps(target)
    local vel = {}
    for i = 1, #comps do vel[i] = 0 end

    local rec = {
        isSpring = true, inst = inst, prop = prop, kind = kind, thr = thr,
        pos = comps, vel = vel, target = tcomps, finalValue = target,
        stiffness = stiffness, damping = damping, done = opts.Done, props = { [prop] = true },
    }
    lock[prop] = rec
    table.insert(Springs, rec)
    return rec
end

-- Give a spring an initial kick (e.g. press "squash" feeling)
function Anim.Impulse(rec, amount)
    if rec and rec.vel then
        for i = 1, #rec.vel do rec.vel[i] = rec.vel[i] + amount end
    end
end

-- Register a per-frame callback; returns a handle with :Cancel()
function Anim.Every(fn)
    local rec = { fn = fn }
    table.insert(Loops, rec)
    return {
        Cancel = function() rec.dead = true end,
        Disconnect = function() rec.dead = true end,
    }
end

-- Delay that can be cancelled (returns handle)
function Anim.Delay(seconds, fn)
    seconds = seconds / math.max(Anim.TimeScale, 0.001)
    local thread = task.delay(seconds, fn)
    return { Cancel = function() pcall(task.cancel, thread) end }
end

-- Call fn(i) for i=1..count with `interval` seconds between each
function Anim.Stagger(count, interval, fn, startDelay)
    startDelay = startDelay or 0
    for i = 1, count do
        local d = startDelay + (i - 1) * interval
        if d <= 0 then
            fn(i)
        else
            Anim.Delay(d, function() fn(i) end)
        end
    end
end

-- Chain tweens one after another:
--   Anim.Sequence({ {inst, props, dur, ease}, {inst, props, dur, ease}, ... }, onDone)
function Anim.Sequence(steps, onDone)
    local index = 0
    local cancelled = false
    local current
    local function nextStep()
        if cancelled then return end
        index = index + 1
        local s = steps[index]
        if not s then
            if onDone then onDone() end
            return
        end
        if s.Wait then
            current = Anim.Delay(s.Wait, nextStep)
        else
            current = Anim.Tween(s[1], s[2], s[3], s[4], s[5], nextStep)
        end
    end
    nextStep()
    return { Cancel = function() cancelled = true if current then current.Cancel() end end }
end

-- Tween out and back (flash/pulse)
function Anim.Pulse(inst, prop, peak, dur, ease)
    local original = inst[prop]
    dur = dur or 0.3
    return Anim.Tween(inst, { [prop] = peak }, dur * 0.4, ease or "OutQuad", 0, function()
        Anim.Tween(inst, { [prop] = original }, dur * 0.6, "InOutQuad")
    end)
end

-- Shake a gui object's position
function Anim.Shake(inst, magnitude, dur)
    local origin = inst.Position
    magnitude = magnitude or 6
    return Anim.Custom(dur or 0.35, "Linear", function(_, a)
        local falloff = (1 - a)
        local ox = math.sin(a * 55) * magnitude * falloff
        local oy = math.cos(a * 43) * magnitude * 0.4 * falloff
        inst.Position = UDim2.new(origin.X.Scale, origin.X.Offset + ox, origin.Y.Scale, origin.Y.Offset + oy)
    end, function()
        inst.Position = origin
    end)
end

-- Immediately set properties (and cancel anything animating them)
function Anim.Set(inst, props)
    local lock = Locks[inst]
    for p, v in pairs(props) do
        if lock and lock[p] then
            lock[p].dead = true
            lock[p] = nil
        end
        inst[p] = v
    end
end

-- Cancel everything running on an instance
function Anim.Stop(inst)
    local lock = Locks[inst]
    if lock then
        for p, rec in pairs(lock) do
            rec.dead = true
            lock[p] = nil
        end
    end
end

-- Handy named durations
Anim.D = { Instant = 0.06, Fast = 0.14, Normal = 0.24, Slow = 0.42, Slower = 0.7 }

-- Common spring presets
Anim.Springs = {
    Snappy = { Stiffness = 380, Ratio = 0.78 },
    Smooth = { Stiffness = 190, Ratio = 0.95 },
    Bouncy = { Stiffness = 260, Ratio = 0.52 },
    Gentle = { Stiffness = 120, Ratio = 1.0 },
    Stiff = { Stiffness = 520, Ratio = 0.9 },
}

function Anim.Clear()
    for i = #Tweens, 1, -1 do Tweens[i].dead = true end
    for i = #Springs, 1, -1 do Springs[i].dead = true end
    for i = #Loops, 1, -1 do Loops[i].dead = true end
end

RootMaid:Give(function() Anim.Clear() end)

-- ════════════════════════════════════════════════════════════════════════════
--  SECTION 3 — THEME ENGINE, INSTANCE FACTORY, GLASS PRIMITIVES, ICONS
-- ════════════════════════════════════════════════════════════════════════════

local Fonts = {
    Regular = Enum.Font.Gotham,
    Medium = Enum.Font.GothamMedium,
    Semibold = Enum.Font.GothamSemibold,
    Bold = Enum.Font.GothamBold,
    Black = Enum.Font.GothamBlack,
    Mono = Enum.Font.Code,
}

-- ── Theme presets ───────────────────────────────────────────────────────────
-- Every token is a plain value. Anything bound to a token re-tweens when the
-- theme changes (Theme.Apply), so swapping themes is fully animated.

local ThemePresets = {
    Aurora = {
        Accent = Color3.fromRGB(139, 92, 246), Accent2 = Color3.fromRGB(56, 189, 248),
        Glass = Color3.fromRGB(16, 18, 32), GlassTransparency = 0.22,
        Surface = Color3.fromRGB(255, 255, 255), SurfaceTransparency = 0.935,
        Stroke = Color3.fromRGB(255, 255, 255), StrokeTransparency = 0.86,
        Text = Color3.fromRGB(244, 246, 255), SubText = Color3.fromRGB(176, 182, 212),
        Muted = Color3.fromRGB(112, 118, 150),
        Success = Color3.fromRGB(74, 222, 128), Warning = Color3.fromRGB(251, 191, 36),
        Error = Color3.fromRGB(248, 113, 113), Info = Color3.fromRGB(96, 165, 250),
        Shadow = Color3.fromRGB(0, 0, 0), BlobA = Color3.fromRGB(139, 92, 246), BlobB = Color3.fromRGB(34, 211, 238),
        Dark = true,
    },
    Midnight = {
        Accent = Color3.fromRGB(59, 130, 246), Accent2 = Color3.fromRGB(99, 102, 241),
        Glass = Color3.fromRGB(8, 12, 26), GlassTransparency = 0.2,
        Surface = Color3.fromRGB(180, 200, 255), SurfaceTransparency = 0.92,
        Stroke = Color3.fromRGB(150, 180, 255), StrokeTransparency = 0.84,
        Text = Color3.fromRGB(236, 241, 255), SubText = Color3.fromRGB(160, 174, 212),
        Muted = Color3.fromRGB(100, 112, 150),
        Success = Color3.fromRGB(52, 211, 153), Warning = Color3.fromRGB(251, 191, 36),
        Error = Color3.fromRGB(251, 113, 133), Info = Color3.fromRGB(56, 189, 248),
        Shadow = Color3.fromRGB(0, 0, 0), BlobA = Color3.fromRGB(59, 130, 246), BlobB = Color3.fromRGB(99, 102, 241),
        Dark = true,
    },
    Ocean = {
        Accent = Color3.fromRGB(20, 184, 166), Accent2 = Color3.fromRGB(14, 165, 233),
        Glass = Color3.fromRGB(8, 24, 34), GlassTransparency = 0.22,
        Surface = Color3.fromRGB(200, 255, 250), SurfaceTransparency = 0.93,
        Stroke = Color3.fromRGB(160, 255, 245), StrokeTransparency = 0.85,
        Text = Color3.fromRGB(236, 254, 255), SubText = Color3.fromRGB(150, 196, 204),
        Muted = Color3.fromRGB(96, 138, 148),
        Success = Color3.fromRGB(74, 222, 128), Warning = Color3.fromRGB(250, 204, 21),
        Error = Color3.fromRGB(248, 113, 113), Info = Color3.fromRGB(56, 189, 248),
        Shadow = Color3.fromRGB(0, 0, 0), BlobA = Color3.fromRGB(20, 184, 166), BlobB = Color3.fromRGB(14, 165, 233),
        Dark = true,
    },
    Rose = {
        Accent = Color3.fromRGB(244, 63, 130), Accent2 = Color3.fromRGB(251, 146, 60),
        Glass = Color3.fromRGB(28, 12, 22), GlassTransparency = 0.22,
        Surface = Color3.fromRGB(255, 220, 235), SurfaceTransparency = 0.935,
        Stroke = Color3.fromRGB(255, 190, 215), StrokeTransparency = 0.85,
        Text = Color3.fromRGB(255, 240, 246), SubText = Color3.fromRGB(212, 168, 188),
        Muted = Color3.fromRGB(150, 108, 128),
        Success = Color3.fromRGB(74, 222, 128), Warning = Color3.fromRGB(251, 191, 36),
        Error = Color3.fromRGB(248, 113, 113), Info = Color3.fromRGB(129, 140, 248),
        Shadow = Color3.fromRGB(0, 0, 0), BlobA = Color3.fromRGB(244, 63, 130), BlobB = Color3.fromRGB(251, 146, 60),
        Dark = true,
    },
    Emerald = {
        Accent = Color3.fromRGB(16, 185, 129), Accent2 = Color3.fromRGB(163, 230, 53),
        Glass = Color3.fromRGB(8, 24, 18), GlassTransparency = 0.22,
        Surface = Color3.fromRGB(210, 255, 232), SurfaceTransparency = 0.93,
        Stroke = Color3.fromRGB(170, 255, 210), StrokeTransparency = 0.85,
        Text = Color3.fromRGB(238, 255, 246), SubText = Color3.fromRGB(152, 200, 176),
        Muted = Color3.fromRGB(98, 140, 120),
        Success = Color3.fromRGB(74, 222, 128), Warning = Color3.fromRGB(250, 204, 21),
        Error = Color3.fromRGB(248, 113, 113), Info = Color3.fromRGB(56, 189, 248),
        Shadow = Color3.fromRGB(0, 0, 0), BlobA = Color3.fromRGB(16, 185, 129), BlobB = Color3.fromRGB(163, 230, 53),
        Dark = true,
    },
    Sunset = {
        Accent = Color3.fromRGB(251, 113, 60), Accent2 = Color3.fromRGB(236, 72, 153),
        Glass = Color3.fromRGB(26, 14, 20), GlassTransparency = 0.2,
        Surface = Color3.fromRGB(255, 226, 210), SurfaceTransparency = 0.935,
        Stroke = Color3.fromRGB(255, 205, 180), StrokeTransparency = 0.85,
        Text = Color3.fromRGB(255, 244, 238), SubText = Color3.fromRGB(214, 176, 160),
        Muted = Color3.fromRGB(152, 114, 100),
        Success = Color3.fromRGB(74, 222, 128), Warning = Color3.fromRGB(253, 224, 71),
        Error = Color3.fromRGB(248, 113, 113), Info = Color3.fromRGB(129, 140, 248),
        Shadow = Color3.fromRGB(0, 0, 0), BlobA = Color3.fromRGB(251, 113, 60), BlobB = Color3.fromRGB(236, 72, 153),
        Dark = true,
    },
    Frost = {
        Accent = Color3.fromRGB(79, 70, 229), Accent2 = Color3.fromRGB(14, 165, 233),
        Glass = Color3.fromRGB(244, 247, 255), GlassTransparency = 0.18,
        Surface = Color3.fromRGB(255, 255, 255), SurfaceTransparency = 0.45,
        Stroke = Color3.fromRGB(120, 130, 180), StrokeTransparency = 0.72,
        Text = Color3.fromRGB(24, 28, 48), SubText = Color3.fromRGB(86, 94, 128),
        Muted = Color3.fromRGB(136, 144, 176),
        Success = Color3.fromRGB(22, 163, 74), Warning = Color3.fromRGB(217, 119, 6),
        Error = Color3.fromRGB(220, 38, 38), Info = Color3.fromRGB(37, 99, 235),
        Shadow = Color3.fromRGB(30, 40, 90), BlobA = Color3.fromRGB(129, 140, 248), BlobB = Color3.fromRGB(56, 189, 248),
        Dark = false,
    },
    Mono = {
        Accent = Color3.fromRGB(226, 232, 240), Accent2 = Color3.fromRGB(148, 163, 184),
        Glass = Color3.fromRGB(14, 14, 16), GlassTransparency = 0.2,
        Surface = Color3.fromRGB(255, 255, 255), SurfaceTransparency = 0.94,
        Stroke = Color3.fromRGB(255, 255, 255), StrokeTransparency = 0.88,
        Text = Color3.fromRGB(245, 245, 247), SubText = Color3.fromRGB(168, 168, 178),
        Muted = Color3.fromRGB(106, 106, 116),
        Success = Color3.fromRGB(134, 239, 172), Warning = Color3.fromRGB(253, 224, 71),
        Error = Color3.fromRGB(252, 165, 165), Info = Color3.fromRGB(147, 197, 253),
        Shadow = Color3.fromRGB(0, 0, 0), BlobA = Color3.fromRGB(148, 163, 184), BlobB = Color3.fromRGB(100, 116, 139),
        Dark = true,
    },
}

local ThemeOrder = { "Aurora", "Midnight", "Ocean", "Rose", "Emerald", "Sunset", "Frost", "Mono" }

local Theme = {
    Name = "Aurora",
    Current = {},
    Registry = {},
    Changed = Signal.new(),
    AccentOverride = nil,
    GlassOffset = 0,
}

-- Rebuild the flattened "Current" table (base preset + overrides + derived tokens)
function Theme.Rebuild()
    local base = ThemePresets[Theme.Name] or ThemePresets.Aurora
    local c = {}
    for k, v in pairs(base) do c[k] = v end

    if Theme.AccentOverride then
        c.Accent = Theme.AccentOverride
        c.Accent2 = U.ShiftHue(Theme.AccentOverride, 0.08)
    end

    c.GlassTransparency = U.Clamp(c.GlassTransparency + Theme.GlassOffset, 0, 0.95)

    -- derived tokens
    c.AccentDark = U.Darken(c.Accent, 0.35)
    c.AccentLight = U.Lighten(c.Accent, 0.35)
    c.AccentText = U.Readable(c.Accent, Color3.new(1, 1, 1), Color3.fromRGB(14, 16, 28))
    c.TrackOff = c.Dark and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(60, 70, 120)
    c.TrackOffTransparency = c.Dark and 0.86 or 0.8
    c.Hover = c.Dark and 0.88 or 0.3
    c.Press = c.Dark and 0.82 or 0.2
    c.ShadowTransparency = c.Dark and 0.9 or 0.93
    c.Knob = Color3.fromRGB(255, 255, 255)
    c.AccentSeq = ColorSequence.new(c.Accent, c.Accent2)
    c.GlassSheen = c.Dark and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(255, 255, 255)
    Theme.Current = c
    return c
end
Theme.Rebuild()

function Theme.Get(token)
    return Theme.Current[token]
end

local function resolveToken(spec)
    if type(spec) == "string" then
        return Theme.Current[spec]
    elseif type(spec) == "function" then
        return spec(Theme.Current)
    end
    return spec
end

local function applyValue(inst, prop, value, animate, dur)
    if value == nil then return end
    local ty = typeof(value)
    if animate and (ty == "Color3" or ty == "number") then
        Anim.Tween(inst, { [prop] = value }, dur or 0.45, "OutCubic")
    else
        Anim.Set(inst, { [prop] = value })
    end
end

-- Bind instance properties to theme tokens.
--   Theme.Bind(frame, { BackgroundColor3 = "Accent", BackgroundTransparency = function(t) return t.GlassTransparency end })
function Theme.Bind(inst, map)
    local entry = { inst = inst, map = map }
    table.insert(Theme.Registry, entry)
    for prop, spec in pairs(map) do
        local v = resolveToken(spec)
        if v ~= nil then
            pcall(function() inst[prop] = v end)
        end
    end
    local conn
    conn = inst.Destroying:Connect(function()
        entry.dead = true
        if conn then conn:Disconnect() end
    end)
    return entry
end

-- Bind an arbitrary callback: fn(themeTable, animate)
function Theme.BindFn(inst, fn)
    local entry = { inst = inst, fn = fn }
    table.insert(Theme.Registry, entry)
    pcall(fn, Theme.Current, false)
    local conn
    conn = inst.Destroying:Connect(function()
        entry.dead = true
        if conn then conn:Disconnect() end
    end)
    return entry
end

-- Re-skin everything. `animate` tweens each bound property.
function Theme.Apply(name, animate)
    if name and ThemePresets[name] then
        Theme.Name = name
    end
    Theme.Rebuild()
    if animate == nil then animate = true end

    local alive = {}
    for _, entry in ipairs(Theme.Registry) do
        if not entry.dead then
            alive[#alive + 1] = entry
            if entry.map then
                for prop, spec in pairs(entry.map) do
                    local v = resolveToken(spec)
                    local ok = pcall(applyValue, entry.inst, prop, v, animate, 0.5)
                    if not ok then entry.dead = true end
                end
            end
            if entry.fn then
                pcall(entry.fn, Theme.Current, animate)
            end
        end
    end
    Theme.Registry = alive
    Theme.Changed:Fire(Theme.Name)
end

function Theme.SetAccent(color)
    Theme.AccentOverride = color
    Theme.Apply(nil, true)
end

function Theme.ClearAccent()
    Theme.AccentOverride = nil
    Theme.Apply(nil, true)
end

function Theme.SetGlassOffset(v)
    Theme.GlassOffset = v
    Theme.Apply(nil, false)
end

function Theme.Register(name, preset)
    local base = ThemePresets.Aurora
    local merged = {}
    for k, v in pairs(base) do merged[k] = v end
    for k, v in pairs(preset) do merged[k] = v end
    ThemePresets[name] = merged
    if not U.Find(ThemeOrder, name) then table.insert(ThemeOrder, name) end
end

-- ── Instance factory ────────────────────────────────────────────────────────

local ClassDefaults = {
    Frame = { BorderSizePixel = 0, BackgroundColor3 = Color3.new(1, 1, 1) },
    CanvasGroup = { BorderSizePixel = 0, BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1 },
    TextLabel = {
        BackgroundTransparency = 1, BorderSizePixel = 0, Font = Fonts.Medium, TextSize = 14,
        TextColor3 = Color3.new(1, 1, 1), Text = "", TextXAlignment = Enum.TextXAlignment.Left,
    },
    TextButton = {
        BackgroundTransparency = 1, BorderSizePixel = 0, AutoButtonColor = false, Font = Fonts.Medium,
        TextSize = 14, Text = "", TextColor3 = Color3.new(1, 1, 1),
    },
    TextBox = {
        BackgroundTransparency = 1, BorderSizePixel = 0, Font = Fonts.Medium, TextSize = 14, Text = "",
        TextColor3 = Color3.new(1, 1, 1), ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left,
    },
    ImageLabel = { BackgroundTransparency = 1, BorderSizePixel = 0 },
    ImageButton = { BackgroundTransparency = 1, BorderSizePixel = 0, AutoButtonColor = false },
    ScrollingFrame = {
        BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
        ScrollBarImageColor3 = Color3.new(1, 1, 1), ScrollBarImageTransparency = 0.6,
        CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y, ElasticBehavior = Enum.ElasticBehavior.Never,
        TopImage = "rbxasset://textures/ui/Scroll/scroll-middle.png",
        MidImage = "rbxasset://textures/ui/Scroll/scroll-middle.png",
        BottomImage = "rbxasset://textures/ui/Scroll/scroll-middle.png",
    },
    UIListLayout = { SortOrder = Enum.SortOrder.LayoutOrder },
    UIGridLayout = { SortOrder = Enum.SortOrder.LayoutOrder },
}

-- New("Frame", { Size = ..., Theme = { BackgroundColor3 = "Glass" }, Parent = x }, { child1, child2 })
local function New(class, props, children)
    local inst = Instance.new(class)
    local defaults = ClassDefaults[class]
    if defaults then
        for k, v in pairs(defaults) do inst[k] = v end
    end
    local parent, themeMap
    if props then
        for k, v in pairs(props) do
            if k == "Parent" then
                parent = v
            elseif k == "Theme" then
                themeMap = v
            else
                inst[k] = v
            end
        end
    end
    if children then
        for _, child in ipairs(children) do
            child.Parent = inst
        end
    end
    if themeMap then Theme.Bind(inst, themeMap) end
    if parent then inst.Parent = parent end
    return inst
end

local function Corner(radius)
    local r = radius
    if typeof(r) ~= "UDim" then r = UDim.new(0, r or 8) end
    return New("UICorner", { CornerRadius = r })
end

local function Pad(l, t, r, b)
    if t == nil then t, r, b = l, l, l end
    return New("UIPadding", {
        PaddingLeft = UDim.new(0, l), PaddingTop = UDim.new(0, t),
        PaddingRight = UDim.new(0, r), PaddingBottom = UDim.new(0, b),
    })
end

local function List(padding, direction, hAlign, vAlign)
    return New("UIListLayout", {
        Padding = UDim.new(0, padding or 0),
        FillDirection = direction or Enum.FillDirection.Vertical,
        HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Left,
        VerticalAlignment = vAlign or Enum.VerticalAlignment.Top,
    })
end

local function Stroke(thickness, colorToken, transToken, mode)
    return New("UIStroke", {
        Thickness = thickness or 1,
        ApplyStrokeMode = mode or Enum.ApplyStrokeMode.Border,
        LineJoinMode = Enum.LineJoinMode.Round,
        Theme = {
            Color = colorToken or "Stroke",
            Transparency = transToken or "StrokeTransparency",
        },
    })
end

local function Gradient(colors, rotation, transparency)
    local g = Instance.new("UIGradient")
    if typeof(colors) == "ColorSequence" then
        g.Color = colors
    elseif typeof(colors) == "Color3" then
        g.Color = ColorSequence.new(colors)
    elseif type(colors) == "table" then
        local kps = {}
        for i, c in ipairs(colors) do
            kps[i] = ColorSequenceKeypoint.new((i - 1) / math.max(#colors - 1, 1), c)
        end
        g.Color = ColorSequence.new(kps)
    end
    g.Rotation = rotation or 0
    if transparency then g.Transparency = transparency end
    return g
end

local function ns(...)
    -- ns(0,0.2, 1,0.9) -> NumberSequence from (time,value) pairs
    local a = { ... }
    local kps = {}
    for i = 1, #a, 2 do
        kps[#kps + 1] = NumberSequenceKeypoint.new(a[i], a[i + 1])
    end
    return NumberSequence.new(kps)
end

-- Accent gradient helper that follows the theme (Accent -> Accent2)
local function AccentGradient(rotation)
    local g = Instance.new("UIGradient")
    g.Rotation = rotation or 0
    Theme.BindFn(g, function(t) g.Color = ColorSequence.new(t.Accent, t.Accent2) end)
    return g
end

-- ── Glass primitives ────────────────────────────────────────────────────────

-- Layered shadow (no image assets required): stacked rounded frames fading out.
local function Shadow(parent, radius, spread, offsetY)
    radius = radius or 18
    spread = spread or 26
    offsetY = offsetY or 10
    local holder = New("Frame", {
        Name = "Shadow", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
        Position = UDim2.fromOffset(0, 0), ZIndex = 0, Parent = parent,
    })
    local layers = 9
    for i = 1, layers do
        local grow = (spread * i) / layers
        local f = New("Frame", {
            Name = "L" .. i, AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0.5, 0, 0.5, offsetY),
            Size = UDim2.new(1, grow * 2 - 8, 1, grow * 2 - 8),
            BackgroundColor3 = Color3.new(0, 0, 0), ZIndex = 0, Parent = holder,
            Theme = {
                BackgroundColor3 = "Shadow",
                BackgroundTransparency = function(t)
                    -- outer layers fade out; inner ones carry weight
                    local base = t.ShadowTransparency
                    return U.Clamp(base + (1 - base) * ((i - 1) / layers) ^ 0.55 * 0.9, 0, 1)
                end,
            },
        }, { Corner(radius + grow * 0.65) })
    end
    return holder
end

-- A glassy panel: tinted translucent fill + soft sheen gradient + gradient hairline.
-- opts: Radius, Strength (extra transparency), Sheen (bool), Name, Parent...
local function Glass(props, opts)
    opts = opts or {}
    local radius = opts.Radius or 14
    local frame = New("Frame", U.Merge({
        BackgroundColor3 = Theme.Current.Glass,
        BackgroundTransparency = Theme.Current.GlassTransparency,
        Theme = {
            BackgroundColor3 = "Glass",
            BackgroundTransparency = function(t) return U.Clamp(t.GlassTransparency + (opts.Strength or 0), 0, 1) end,
        },
    }, props or {}))
    Corner(radius).Parent = frame

    -- sheen: light enters from the top-left corner
    local sheen = Instance.new("UIGradient")
    sheen.Rotation = 35
    sheen.Transparency = ns(0, 0, 0.55, 0.06, 1, 0.12)
    Theme.BindFn(sheen, function(t)
        sheen.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, U.Lighten(t.Glass, t.Dark and 0.14 or 0.0)),
            ColorSequenceKeypoint.new(1, U.Darken(t.Glass, t.Dark and 0.18 or 0.06)),
        })
    end)
    sheen.Parent = frame

    -- hairline border with gradient transparency (bright top-left, faint bottom-right)
    local stroke = New("UIStroke", {
        Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Color = Color3.new(1, 1, 1),
        Theme = { Color = "Stroke" },
    })
    local sg = Instance.new("UIGradient")
    sg.Rotation = 45
    sg.Transparency = ns(0, 0.35, 0.35, 0.78, 0.7, 0.92, 1, 0.6)
    sg.Parent = stroke
    stroke.Parent = frame

    return frame
end

-- Soft top edge highlight line (adds crisp "glass lip")
local function Lip(parent, inset)
    inset = inset or 14
    local line = New("Frame", {
        Name = "Lip", Size = UDim2.new(1, -inset * 2, 0, 1), Position = UDim2.new(0, inset, 0, 0),
        BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.7, ZIndex = 3, Parent = parent,
    })
    local g = Instance.new("UIGradient")
    g.Transparency = ns(0, 1, 0.25, 0.2, 0.75, 0.2, 1, 1)
    g.Parent = line
    return line
end

-- Material-style ripple. `container` must have ClipsDescendants = true.
local function Ripple(container, x, y, color, strength)
    local absPos, absSize = container.AbsolutePosition, container.AbsoluteSize
    local scale = Library._scale or 1
    local rx = (x - absPos.X) / math.max(scale, 0.001)
    local ry = (y - absPos.Y) / math.max(scale, 0.001)
    local maxDim = math.sqrt(absSize.X ^ 2 + absSize.Y ^ 2) / math.max(scale, 0.001)

    local circle = New("Frame", {
        Name = "Ripple", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(rx, ry),
        Size = UDim2.fromOffset(0, 0), BackgroundColor3 = color or Color3.new(1, 1, 1),
        BackgroundTransparency = strength or 0.72, ZIndex = 20, Parent = container,
    }, { Corner(UDim.new(1, 0)) })

    Anim.Tween(circle, { Size = UDim2.fromOffset(maxDim * 2.1, maxDim * 2.1) }, 0.55, "OutCubic")
    Anim.Tween(circle, { BackgroundTransparency = 1 }, 0.55, "OutQuad", 0.08, function()
        circle:Destroy()
    end)
end

-- ── Vector icons (drawn from frames: no asset ids, always crisp, tintable) ──
-- Geometry lives in a unit square; stroke thickness is in unit space too.

local Icons = {}
local IconParts = setmetatable({}, { __mode = "k" })

local function iconBar(parts, root, x0, y0, x1, y1, thick)
    local dx, dy = x1 - x0, y1 - y0
    local len = math.sqrt(dx * dx + dy * dy)
    local f = New("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale((x0 + x1) / 2, (y0 + y1) / 2),
        Size = UDim2.fromScale(len + thick * 0.9, thick),
        Rotation = math.deg(math.atan2(dy, dx)),
        BackgroundColor3 = Color3.new(1, 1, 1), Parent = root,
    }, { Corner(UDim.new(0.5, 0)) })
    parts[#parts + 1] = { inst = f, kind = "fill" }
end

local function iconRect(parts, root, size, x, y, w, h, radius, hollow, thick, rot)
    local f = New("Frame", {
        Position = UDim2.fromScale(x, y), Size = UDim2.fromScale(w, h),
        Rotation = rot or 0,
        BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = hollow and 1 or 0, Parent = root,
    })
    if rot then
        f.AnchorPoint = Vector2.new(0.5, 0.5)
        f.Position = UDim2.fromScale(x + w / 2, y + h / 2)
    end
    New("UICorner", { CornerRadius = UDim.new(radius or 0, 0) }).Parent = f
    if hollow then
        local s = New("UIStroke", { Thickness = math.max(1, (thick or 0.1) * size), Color = Color3.new(1, 1, 1) })
        s.Parent = f
        parts[#parts + 1] = { inst = s, kind = "stroke" }
    else
        parts[#parts + 1] = { inst = f, kind = "fill" }
    end
end

local function iconCircle(parts, root, size, cx, cy, d, hollow, thick)
    local f = New("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(cx, cy),
        Size = UDim2.fromScale(d, d), BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = hollow and 1 or 0, Parent = root,
    }, { Corner(UDim.new(0.5, 0)) })
    if hollow then
        local s = New("UIStroke", { Thickness = math.max(1, (thick or 0.1) * size), Color = Color3.new(1, 1, 1) })
        s.Parent = f
        parts[#parts + 1] = { inst = s, kind = "stroke" }
    else
        parts[#parts + 1] = { inst = f, kind = "fill" }
    end
end

local IconBuilders = {}

IconBuilders.chevron = function(p, r, s)
    iconBar(p, r, 0.24, 0.4, 0.5, 0.64, 0.12)
    iconBar(p, r, 0.5, 0.64, 0.76, 0.4, 0.12)
end
IconBuilders.check = function(p, r, s)
    iconBar(p, r, 0.2, 0.52, 0.42, 0.74, 0.13)
    iconBar(p, r, 0.42, 0.74, 0.8, 0.3, 0.13)
end
IconBuilders.close = function(p, r, s)
    iconBar(p, r, 0.26, 0.26, 0.74, 0.74, 0.12)
    iconBar(p, r, 0.74, 0.26, 0.26, 0.74, 0.12)
end
IconBuilders.minus = function(p, r, s)
    iconBar(p, r, 0.22, 0.5, 0.78, 0.5, 0.12)
end
IconBuilders.plus = function(p, r, s)
    iconBar(p, r, 0.22, 0.5, 0.78, 0.5, 0.12)
    iconBar(p, r, 0.5, 0.22, 0.5, 0.78, 0.12)
end
IconBuilders.arrow = function(p, r, s)
    iconBar(p, r, 0.2, 0.5, 0.8, 0.5, 0.11)
    iconBar(p, r, 0.58, 0.28, 0.8, 0.5, 0.11)
    iconBar(p, r, 0.58, 0.72, 0.8, 0.5, 0.11)
end
IconBuilders.dot = function(p, r, s)
    iconCircle(p, r, s, 0.5, 0.5, 0.36, false)
end
IconBuilders.search = function(p, r, s)
    iconCircle(p, r, s, 0.44, 0.44, 0.5, true, 0.1)
    iconBar(p, r, 0.64, 0.64, 0.84, 0.84, 0.12)
end
IconBuilders.menu = function(p, r, s)
    iconBar(p, r, 0.2, 0.3, 0.8, 0.3, 0.1)
    iconBar(p, r, 0.2, 0.5, 0.8, 0.5, 0.1)
    iconBar(p, r, 0.2, 0.7, 0.8, 0.7, 0.1)
end
IconBuilders.gear = function(p, r, s)
    for i = 0, 7 do
        local a = math.rad(i * 45)
        local cx, cy = 0.5 + math.cos(a) * 0.37, 0.5 + math.sin(a) * 0.37
        iconRect(p, r, s, cx - 0.085, cy - 0.085, 0.17, 0.17, 0.2, false, nil, math.deg(a))
    end
    iconCircle(p, r, s, 0.5, 0.5, 0.56, true, 0.12)
    iconCircle(p, r, s, 0.5, 0.5, 0.18, true, 0.08)
end
IconBuilders.home = function(p, r, s)
    iconBar(p, r, 0.1, 0.5, 0.5, 0.16, 0.1)
    iconBar(p, r, 0.5, 0.16, 0.9, 0.5, 0.1)
    iconRect(p, r, s, 0.24, 0.5, 0.52, 0.36, 0.08, true, 0.09)
    iconRect(p, r, s, 0.43, 0.64, 0.14, 0.22, 0.2, false)
end
IconBuilders.user = function(p, r, s)
    iconCircle(p, r, s, 0.5, 0.32, 0.34, false)
    iconRect(p, r, s, 0.2, 0.58, 0.6, 0.38, 0.5, false)
end
IconBuilders.eye = function(p, r, s)
    iconRect(p, r, s, 0.08, 0.28, 0.84, 0.44, 0.5, true, 0.09)
    iconCircle(p, r, s, 0.5, 0.5, 0.22, false)
end
IconBuilders.sliders = function(p, r, s)
    iconBar(p, r, 0.16, 0.32, 0.84, 0.32, 0.08)
    iconBar(p, r, 0.16, 0.68, 0.84, 0.68, 0.08)
    iconCircle(p, r, s, 0.36, 0.32, 0.22, false)
    iconCircle(p, r, s, 0.64, 0.68, 0.22, false)
end
IconBuilders.folder = function(p, r, s)
    iconRect(p, r, s, 0.12, 0.3, 0.76, 0.52, 0.12, true, 0.09)
    iconBar(p, r, 0.15, 0.26, 0.4, 0.26, 0.09)
end
IconBuilders.save = function(p, r, s)
    iconRect(p, r, s, 0.16, 0.16, 0.68, 0.68, 0.1, true, 0.09)
    iconRect(p, r, s, 0.32, 0.16, 0.36, 0.2, 0.0, false)
    iconRect(p, r, s, 0.3, 0.52, 0.4, 0.32, 0.1, true, 0.07)
end
IconBuilders.bolt = function(p, r, s)
    iconBar(p, r, 0.58, 0.1, 0.3, 0.54, 0.11)
    iconBar(p, r, 0.3, 0.54, 0.7, 0.5, 0.11)
    iconBar(p, r, 0.7, 0.5, 0.42, 0.92, 0.11)
end
IconBuilders.info = function(p, r, s)
    iconCircle(p, r, s, 0.5, 0.5, 0.84, true, 0.09)
    iconCircle(p, r, s, 0.5, 0.31, 0.1, false)
    iconBar(p, r, 0.5, 0.46, 0.5, 0.72, 0.1)
end
IconBuilders.success = function(p, r, s)
    iconCircle(p, r, s, 0.5, 0.5, 0.84, true, 0.09)
    iconBar(p, r, 0.32, 0.52, 0.45, 0.65, 0.1)
    iconBar(p, r, 0.45, 0.65, 0.69, 0.38, 0.1)
end
IconBuilders.error = function(p, r, s)
    iconCircle(p, r, s, 0.5, 0.5, 0.84, true, 0.09)
    iconBar(p, r, 0.36, 0.36, 0.64, 0.64, 0.1)
    iconBar(p, r, 0.64, 0.36, 0.36, 0.64, 0.1)
end
IconBuilders.warn = function(p, r, s)
    iconBar(p, r, 0.5, 0.12, 0.9, 0.84, 0.09)
    iconBar(p, r, 0.9, 0.84, 0.1, 0.84, 0.09)
    iconBar(p, r, 0.1, 0.84, 0.5, 0.12, 0.09)
    iconBar(p, r, 0.5, 0.4, 0.5, 0.6, 0.09)
    iconCircle(p, r, s, 0.5, 0.72, 0.09, false)
end
IconBuilders.bell = function(p, r, s)
    iconRect(p, r, s, 0.26, 0.18, 0.48, 0.5, 0.5, true, 0.09)
    iconRect(p, r, s, 0.16, 0.66, 0.68, 0.09, 0.5, false)
    iconCircle(p, r, s, 0.5, 0.86, 0.13, false)
end
IconBuilders.palette = function(p, r, s)
    iconCircle(p, r, s, 0.5, 0.5, 0.84, true, 0.09)
    iconCircle(p, r, s, 0.34, 0.42, 0.1, false)
    iconCircle(p, r, s, 0.52, 0.3, 0.1, false)
    iconCircle(p, r, s, 0.68, 0.46, 0.1, false)
end
IconBuilders.target = function(p, r, s)
    iconCircle(p, r, s, 0.5, 0.5, 0.7, true, 0.08)
    iconCircle(p, r, s, 0.5, 0.5, 0.14, false)
    iconBar(p, r, 0.5, 0.06, 0.5, 0.2, 0.08)
    iconBar(p, r, 0.5, 0.8, 0.5, 0.94, 0.08)
    iconBar(p, r, 0.06, 0.5, 0.2, 0.5, 0.08)
    iconBar(p, r, 0.8, 0.5, 0.94, 0.5, 0.08)
end
IconBuilders.list = function(p, r, s)
    for i = 0, 2 do
        iconCircle(p, r, s, 0.2, 0.3 + i * 0.2, 0.09, false)
        iconBar(p, r, 0.34, 0.3 + i * 0.2, 0.84, 0.3 + i * 0.2, 0.08)
    end
end
IconBuilders.copy = function(p, r, s)
    iconRect(p, r, s, 0.34, 0.34, 0.5, 0.52, 0.1, true, 0.08)
    iconRect(p, r, s, 0.16, 0.14, 0.5, 0.52, 0.1, true, 0.08)
end
IconBuilders.refresh = function(p, r, s)
    iconCircle(p, r, s, 0.5, 0.52, 0.64, true, 0.09)
    iconRect(p, r, s, 0.5, 0.1, 0.4, 0.26, 0, false)
    iconBar(p, r, 0.62, 0.14, 0.82, 0.3, 0.1)
    iconBar(p, r, 0.82, 0.3, 0.58, 0.38, 0.1)
end
IconBuilders.trash = function(p, r, s)
    iconRect(p, r, s, 0.26, 0.32, 0.48, 0.54, 0.1, true, 0.08)
    iconBar(p, r, 0.18, 0.26, 0.82, 0.26, 0.09)
    iconBar(p, r, 0.4, 0.15, 0.6, 0.15, 0.08)
end
IconBuilders.lock = function(p, r, s)
    iconRect(p, r, s, 0.34, 0.14, 0.32, 0.46, 0.5, true, 0.09)
    iconRect(p, r, s, 0.22, 0.46, 0.56, 0.42, 0.14, false)
end
IconBuilders.globe = function(p, r, s)
    iconCircle(p, r, s, 0.5, 0.5, 0.84, true, 0.08)
    iconRect(p, r, s, 0.33, 0.08, 0.34, 0.84, 0.5, true, 0.07)
    iconBar(p, r, 0.08, 0.5, 0.92, 0.5, 0.07)
end
IconBuilders.keyboard = function(p, r, s)
    iconRect(p, r, s, 0.08, 0.26, 0.84, 0.48, 0.14, true, 0.08)
    for i = 0, 3 do
        iconCircle(p, r, s, 0.26 + i * 0.16, 0.42, 0.08, false)
    end
    iconBar(p, r, 0.3, 0.58, 0.7, 0.58, 0.07)
end
IconBuilders.star = function(p, r, s)
    -- 5-point star outline built from 5 bars
    local pts = {}
    for i = 0, 4 do
        local a = math.rad(-90 + i * 72)
        pts[#pts + 1] = { 0.5 + math.cos(a) * 0.42, 0.54 + math.sin(a) * 0.42 }
    end
    local order = { 1, 3, 5, 2, 4, 1 }
    for i = 1, #order - 1 do
        local a, b = pts[order[i]], pts[order[i + 1]]
        iconBar(p, r, a[1], a[2], b[1], b[2], 0.07)
    end
end
IconBuilders.layers = function(p, r, s)
    iconRect(p, r, s, 0.24, 0.24, 0.52, 0.52, 0.08, true, 0.08, 45)
    iconRect(p, r, s, 0.24, 0.4, 0.52, 0.52, 0.08, true, 0.07, 45)
end
IconBuilders.sword = function(p, r, s)
    iconBar(p, r, 0.2, 0.8, 0.78, 0.22, 0.1)
    iconBar(p, r, 0.3, 0.52, 0.48, 0.7, 0.09)
    iconBar(p, r, 0.16, 0.84, 0.26, 0.74, 0.1)
end
IconBuilders.shield = function(p, r, s)
    iconRect(p, r, s, 0.2, 0.14, 0.6, 0.5, 0.18, true, 0.09)
    iconBar(p, r, 0.2, 0.52, 0.5, 0.88, 0.09)
    iconBar(p, r, 0.8, 0.52, 0.5, 0.88, 0.09)
end
IconBuilders.run = function(p, r, s)
    iconCircle(p, r, s, 0.6, 0.2, 0.16, false)
    iconBar(p, r, 0.54, 0.36, 0.42, 0.62, 0.1)
    iconBar(p, r, 0.54, 0.36, 0.76, 0.46, 0.09)
    iconBar(p, r, 0.42, 0.62, 0.62, 0.74, 0.09)
    iconBar(p, r, 0.42, 0.62, 0.26, 0.86, 0.09)
end

local IconAliases = {
    settings = "gear", x = "close", cross = "close", tick = "check", ok = "check",
    down = "chevron", add = "plus", config = "save", cog = "gear", visual = "eye", esp = "eye",
    combat = "sword", aim = "target", movement = "run", misc = "layers", player = "user",
    ui = "palette", theme = "palette", keybinds = "keyboard", success_ = "success", warning = "warn",
    notify = "bell", reload = "refresh", delete = "trash", world = "globe", main = "home",
}

local function isAssetIcon(name)
    return type(name) == "string" and (name:find("^rbxassetid://") or name:find("^rbxasset://") or name:match("^%d+$"))
end

-- Icons.Create("home", 18, color) -> Frame (or ImageLabel for asset ids)
function Icons.Create(name, size, color)
    size = size or 18
    if isAssetIcon(name) then
        local img = name
        if name:match("^%d+$") then img = "rbxassetid://" .. name end
        local lbl = New("ImageLabel", {
            Size = UDim2.fromOffset(size, size), Image = img, ImageColor3 = color or Color3.new(1, 1, 1),
            Name = "Icon",
        })
        IconParts[lbl] = { image = true }
        return lbl
    end
    name = IconAliases[name] or name
    local builder = IconBuilders[name] or IconBuilders.dot
    local root = New("Frame", {
        Name = "Icon_" .. tostring(name), BackgroundTransparency = 1, Size = UDim2.fromOffset(size, size),
    })
    local parts = {}
    builder(parts, root, size)
    IconParts[root] = parts
    Icons.SetColor(root, color or Color3.new(1, 1, 1), 0)
    return root
end

function Icons.SetColor(icon, color, dur)
    local parts = IconParts[icon]
    if not parts then return end
    if parts.image then
        if dur and dur > 0 then Anim.Tween(icon, { ImageColor3 = color }, dur, "OutQuad")
        else icon.ImageColor3 = color end
        return
    end
    for _, part in ipairs(parts) do
        local prop = part.kind == "fill" and "BackgroundColor3" or "Color"
        if dur and dur > 0 then
            Anim.Tween(part.inst, { [prop] = color }, dur, "OutQuad")
        else
            part.inst[prop] = color
        end
    end
end

function Icons.SetTransparency(icon, value, dur)
    local parts = IconParts[icon]
    if not parts then return end
    if parts.image then
        Anim.Tween(icon, { ImageTransparency = value }, dur or 0, "OutQuad")
        return
    end
    for _, part in ipairs(parts) do
        local prop = part.kind == "fill" and "BackgroundTransparency" or "Transparency"
        Anim.Tween(part.inst, { [prop] = value }, dur or 0, "OutQuad")
    end
end

-- Bind icon color to a theme token (re-tints when the theme changes)
function Icons.Bind(icon, token)
    Theme.BindFn(icon, function(t, animate)
        Icons.SetColor(icon, resolveToken(token) or Color3.new(1, 1, 1), animate and 0.4 or 0)
    end)
end

function Icons.Exists(name)
    return isAssetIcon(name) or IconBuilders[IconAliases[name] or name] ~= nil
end

-- ════════════════════════════════════════════════════════════════════════════
--  SECTION 4 — INTERACTION HELPERS & GLOBAL SERVICES
--  hosts • hover/press/drag helpers • buttons • tooltips • notifications
--  dialogs • watermark • keybind list • background blur
-- ════════════════════════════════════════════════════════════════════════════

Library._scale = 1
Library.Gui = nil
Library.Overlay = nil

local function EnsureHosts()
    if Library.Gui and Library.Gui.Parent and Library.Overlay and Library.Overlay.Parent then return end
    if Library.Gui then pcall(function() Library.Gui:Destroy() end) end
    if Library.Overlay then pcall(function() Library.Overlay:Destroy() end) end
    Library.Gui = RootMaid:Give(U.NewScreenGui(nil, 1000))
    Library.Overlay = RootMaid:Give(U.NewScreenGui(nil, 1100))
end

local Interact = {}

local function pointerPos(input)
    if input and input.UserInputType == Enum.UserInputType.Touch then
        return Vector2.new(input.Position.X, input.Position.Y)
    end
    return S.UserInputService:GetMouseLocation()
end

function Interact.Hover(inst, onEnter, onLeave)
    local state = { Hovering = false }
    inst.MouseEnter:Connect(function()
        state.Hovering = true
        if onEnter then onEnter() end
    end)
    inst.MouseLeave:Connect(function()
        state.Hovering = false
        if onLeave then onLeave() end
    end)
    return state
end

function Interact.Press(inst, onDown, onUp)
    local state = { Pressed = false }
    inst.InputBegan:Connect(function(input)
        if U.IsPointer(input) then
            state.Pressed = true
            if onDown then onDown(input) end
        end
    end)
    inst.InputEnded:Connect(function(input)
        if U.IsPointer(input) and state.Pressed then
            state.Pressed = false
            if onUp then onUp(input) end
        end
    end)
    return state
end

-- Generic drag surface. Calls onBegin(pos), onMove(pos), onEnd(pos) with screen positions.
function Interact.Drag(inst, onBegin, onMove, onEnd)
    inst.InputBegan:Connect(function(input)
        if not U.IsPointer(input) then return end
        local moveConn, endConn
        local function finish()
            if moveConn then moveConn:Disconnect() moveConn = nil end
            if endConn then endConn:Disconnect() endConn = nil end
        end
        if onBegin then onBegin(pointerPos(input), input) end
        moveConn = S.UserInputService.InputChanged:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseMovement or i == input then
                if onMove then onMove(pointerPos(i), i) end
            end
        end)
        endConn = S.UserInputService.InputEnded:Connect(function(i)
            if i == input or (input.UserInputType == Enum.UserInputType.MouseButton1
                and i.UserInputType == Enum.UserInputType.MouseButton1) then
                finish()
                if onEnd then onEnd(pointerPos(i), i) end
            end
        end)
    end)
end

-- Smooth draggable window/panel. `handle` receives the input, `target` is moved.
function Interact.Draggable(handle, target, opts)
    opts = opts or {}
    local smooth = opts.Smooth ~= false
    local origin, startMouse, startAbs
    local goal = target.Position
    local dragging = false

    local function clampDelta(delta)
        local vp = Camera and Camera.ViewportSize or Vector2.new(1920, 1080)
        local size = target.AbsoluteSize
        local keep = 60
        local desired = startAbs + delta
        local cx = U.Clamp(desired.X, keep - size.X, vp.X - keep)
        local cy = U.Clamp(desired.Y, 0, vp.Y - keep)
        return Vector2.new(cx, cy) - startAbs
    end

    Interact.Drag(handle, function(pos)
        dragging = true
        origin = target.Position
        goal = target.Position
        startMouse = pos
        startAbs = target.AbsolutePosition
        if opts.OnBegin then opts.OnBegin() end
    end, function(pos)
        if not dragging then return end
        local d = clampDelta(pos - startMouse)
        goal = UDim2.new(origin.X.Scale, origin.X.Offset + d.X, origin.Y.Scale, origin.Y.Offset + d.Y)
        if not smooth then target.Position = goal end
    end, function()
        dragging = false
        if opts.OnEnd then opts.OnEnd() end
    end)

    if smooth then
        local loop = Anim.Every(function(dt)
            if target.Position ~= goal then
                local cur = target.Position
                local a = 1 - math.exp(-dt * 26)
                local nx = cur.X.Offset + (goal.X.Offset - cur.X.Offset) * a
                local ny = cur.Y.Offset + (goal.Y.Offset - cur.Y.Offset) * a
                if math.abs(goal.X.Offset - nx) < 0.1 then nx = goal.X.Offset end
                if math.abs(goal.Y.Offset - ny) < 0.1 then ny = goal.Y.Offset end
                target.Position = UDim2.new(goal.X.Scale, nx, goal.Y.Scale, ny)
            end
        end)
        RootMaid:Give(loop)
    end

    return {
        IsDragging = function() return dragging end,
        SetPosition = function(pos) goal = pos target.Position = pos end,
    }
end

-- ── Standard button control (used by dialogs, notifications, config UI) ─────
local Controls = {}

-- opts: Text, Style = "Primary" | "Secondary" | "Danger" | "Ghost", Size, Icon, Callback, Parent
function Controls.Button(opts)
    local style = opts.Style or "Secondary"
    local btn = New("TextButton", {
        Name = opts.Name or "Button", Size = opts.Size or UDim2.new(0, 96, 0, 32),
        ClipsDescendants = true, AutoButtonColor = false, Text = "",
        LayoutOrder = opts.LayoutOrder or 0, Parent = opts.Parent,
        BackgroundTransparency = 0, ZIndex = opts.ZIndex or 1,
    })
    Corner(opts.Radius or 9).Parent = btn

    local stroke
    if style == "Primary" then
        btn.BackgroundColor3 = Color3.new(1, 1, 1)
        AccentGradient(0).Parent = btn
        stroke = New("UIStroke", { Thickness = 1, Color = Color3.new(1, 1, 1), Transparency = 0.8, Parent = btn })
    elseif style == "Danger" then
        Theme.Bind(btn, { BackgroundColor3 = "Error", BackgroundTransparency = function() return 0.72 end })
        stroke = New("UIStroke", { Thickness = 1, Parent = btn, Theme = { Color = "Error", Transparency = function() return 0.5 end } })
    elseif style == "Ghost" then
        btn.BackgroundTransparency = 1
        stroke = New("UIStroke", { Thickness = 1, Parent = btn, Theme = { Color = "Stroke", Transparency = "StrokeTransparency" } })
    else
        Theme.Bind(btn, { BackgroundColor3 = "Surface", BackgroundTransparency = "SurfaceTransparency" })
        stroke = New("UIStroke", { Thickness = 1, Parent = btn, Theme = { Color = "Stroke", Transparency = "StrokeTransparency" } })
    end

    local shine = New("Frame", {
        Name = "Shine", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 1, ZIndex = 2, Parent = btn,
    })
    local scale = New("UIScale", { Scale = 1, Parent = btn })

    local content = New("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 3, Parent = btn })
    local row = New("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center,
        VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 6), Parent = content,
    })

    local icon
    if opts.Icon then
        icon = Icons.Create(opts.Icon, 14)
        icon.LayoutOrder = 1
        icon.Parent = content
        if style == "Primary" then
            Theme.BindFn(icon, function(t) Icons.SetColor(icon, t.AccentText, 0) end)
        else
            Icons.Bind(icon, "Text")
        end
    end

    local label = New("TextLabel", {
        Name = "Label", Text = opts.Text or "Button", Font = Fonts.Semibold, TextSize = opts.TextSize or 13,
        AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 1, 0), LayoutOrder = 2,
        TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 3, Parent = content,
        Theme = { TextColor3 = style == "Primary" and "AccentText" or "Text" },
    })

    local obj = { Instance = btn, Label = label, Icon = icon }

    Interact.Hover(btn, function()
        Anim.Tween(shine, { BackgroundTransparency = 0.9 }, 0.15)
    end, function()
        Anim.Tween(shine, { BackgroundTransparency = 1 }, 0.2)
    end)
    Interact.Press(btn, function()
        Anim.Spring(scale, "Scale", 0.95, Anim.Springs.Stiff)
    end, function()
        Anim.Spring(scale, "Scale", 1, Anim.Springs.Bouncy)
    end)
    btn.MouseLeave:Connect(function()
        Anim.Spring(scale, "Scale", 1, Anim.Springs.Smooth)
    end)
    btn.Activated:Connect(function()
        local m = U.MousePos()
        Ripple(btn, m.X, m.Y, Color3.new(1, 1, 1), 0.75)
        if opts.Callback then U.SafeCall(opts.Callback) end
    end)

    function obj:SetText(t) label.Text = t end
    function obj:SetCallback(fn) opts.Callback = fn end
    return obj
end

-- ── Background blur (real screen blur behind the glass) ─────────────────────
Library.BlurEnabled = true
Library.BlurSize = 14
local BlurEffect

local function ensureBlur()
    if BlurEffect and BlurEffect.Parent then return BlurEffect end
    BlurEffect = Instance.new("BlurEffect")
    BlurEffect.Name = U.RandomId(10)
    BlurEffect.Size = 0
    BlurEffect.Enabled = true
    BlurEffect.Parent = S.Lighting
    RootMaid:Give(BlurEffect)
    return BlurEffect
end

function Library:UpdateBlur()
    local anyVisible = false
    for _, w in ipairs(Library.Windows) do
        if w.Visible and not w.Destroyed then anyVisible = true break end
    end
    local want = (Library.BlurEnabled and anyVisible) and Library.BlurSize or 0
    local blur = ensureBlur()
    Anim.Tween(blur, { Size = want }, 0.5, "OutCubic")
end

function Library:SetBlur(enabled, size)
    if enabled ~= nil then Library.BlurEnabled = enabled end
    if size then Library.BlurSize = size end
    Library:UpdateBlur()
end

-- ── Tooltips ────────────────────────────────────────────────────────────────
local Tooltip = { Delay = 0.45, Token = 0, Owner = nil, Following = false }

local function buildTooltip()
    if Tooltip.Frame and Tooltip.Frame.Parent then return end
    EnsureHosts()
    local holder = New("CanvasGroup", {
        Name = "Tooltip", Size = UDim2.fromOffset(120, 30), GroupTransparency = 1, ZIndex = 50,
        BackgroundTransparency = 1, Parent = Library.Overlay, Visible = false,
    })
    local glass = Glass({ Size = UDim2.fromScale(1, 1), Parent = holder }, { Radius = 8, Strength = -0.1 })
    local label = New("TextLabel", {
        Size = UDim2.fromScale(1, 1), Font = Fonts.Medium, TextSize = 12, TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 3, Parent = glass,
        Theme = { TextColor3 = "Text" },
    }, { Pad(9, 6, 9, 6) })
    local scale = New("UIScale", { Scale = 0.92, Parent = holder })
    Tooltip.Frame, Tooltip.Label, Tooltip.Scale = holder, label, scale

    local loop = Anim.Every(function(dt)
        if Tooltip.Frame and Tooltip.Frame.Visible then
            local m = U.MousePos()
            local vp = Camera and Camera.ViewportSize or Vector2.new(1920, 1080)
            local sz = Tooltip.Frame.AbsoluteSize
            local x = m.X + 16
            local y = m.Y + 20
            if x + sz.X > vp.X - 8 then x = m.X - sz.X - 12 end
            if y + sz.Y > vp.Y - 8 then y = m.Y - sz.Y - 12 end
            Tooltip.Frame.Position = UDim2.fromOffset(x, y)
        end
    end)
    RootMaid:Give(loop)
end

function Tooltip.Show(text)
    buildTooltip()
    local size = U.TextSize(text, 12, Fonts.Medium, 240)
    Tooltip.Label.Text = text
    Tooltip.Frame.Size = UDim2.fromOffset(math.ceil(size.X) + 20, math.ceil(size.Y) + 14)
    Tooltip.Frame.Visible = true
    Anim.Tween(Tooltip.Frame, { GroupTransparency = 0 }, 0.16, "OutQuad")
    Anim.Spring(Tooltip.Scale, "Scale", 1, Anim.Springs.Snappy)
end

function Tooltip.Hide()
    if not Tooltip.Frame then return end
    Tooltip.Token = Tooltip.Token + 1
    Anim.Tween(Tooltip.Frame, { GroupTransparency = 1 }, 0.12, "OutQuad", 0, function()
        if Tooltip.Frame and Tooltip.Frame.GroupTransparency >= 0.99 then
            Tooltip.Frame.Visible = false
        end
    end)
    Anim.Spring(Tooltip.Scale, "Scale", 0.92, Anim.Springs.Snappy)
end

-- Attach a tooltip to any GuiObject. `source` is a string or function returning a string.
function Tooltip.Attach(inst, source)
    if not source then return end
    inst.MouseEnter:Connect(function()
        Tooltip.Token = Tooltip.Token + 1
        local my = Tooltip.Token
        task.delay(Tooltip.Delay, function()
            if my ~= Tooltip.Token then return end
            local text = type(source) == "function" and source() or source
            if text and text ~= "" then Tooltip.Show(text) end
        end)
    end)
    inst.MouseLeave:Connect(function()
        Tooltip.Hide()
    end)
    inst.Destroying:Connect(function()
        Tooltip.Token = Tooltip.Token + 1
    end)
end

Library.Tooltip = Tooltip

-- ── Notifications ───────────────────────────────────────────────────────────
local Notif = { List = {}, Position = "BottomRight", Width = 316, Gap = 10, Max = 6 }

local function notifAnchor(pos)
    if pos == "BottomLeft" then
        return { anchor = Vector2.new(0, 1), xs = 0, xo = 18, ys = 1, yo = -18, dir = -1, hide = -360 }
    elseif pos == "TopRight" then
        return { anchor = Vector2.new(1, 0), xs = 1, xo = -18, ys = 0, yo = 18, dir = 1, hide = 360 }
    elseif pos == "TopLeft" then
        return { anchor = Vector2.new(0, 0), xs = 0, xo = 18, ys = 0, yo = 18, dir = 1, hide = -360 }
    elseif pos == "TopCenter" then
        return { anchor = Vector2.new(0.5, 0), xs = 0.5, xo = 0, ys = 0, yo = 18, dir = 1, hide = 0, hideY = -140 }
    end
    return { anchor = Vector2.new(1, 1), xs = 1, xo = -18, ys = 1, yo = -18, dir = -1, hide = 360 }
end

local function notifPlace(entry, offset, hidden)
    local a = notifAnchor(Notif.Position)
    local x = a.xo + (hidden and a.hide or 0)
    local y = a.yo + a.dir * offset + ((hidden and a.hideY) or 0)
    return UDim2.new(a.xs, x, a.ys, y)
end

local function notifRelayout(animate)
    local offset = 0
    for _, entry in ipairs(Notif.List) do
        if not entry.closing then
            entry.holder.AnchorPoint = notifAnchor(Notif.Position).anchor
            if animate then
                Anim.Spring(entry.holder, "Position", notifPlace(entry, offset, false), Anim.Springs.Smooth)
            else
                entry.holder.Position = notifPlace(entry, offset, false)
            end
            offset = offset + entry.height + Notif.Gap
        end
    end
end

local function notifClose(entry)
    if entry.closing then return end
    entry.closing = true
    if entry.loop then entry.loop.Cancel() end
    for i, e in ipairs(Notif.List) do
        if e == entry then table.remove(Notif.List, i) break end
    end
    Anim.Tween(entry.card, { GroupTransparency = 1 }, 0.25, "InQuad")
    Anim.Tween(entry.holder, { Position = notifPlace(entry, 0, true) }, 0.35, "InBack", 0, function()
        entry.holder:Destroy()
    end)
    notifRelayout(true)
    if entry.opts.OnClose then U.SafeCall(entry.opts.OnClose) end
end

-- Library:Notify({ Title, Content, Duration, Type = "info"|"success"|"warning"|"error", Icon, Buttons, OnClick })
function Library:Notify(opts)
    if type(opts) == "string" then opts = { Content = opts } end
    opts = opts or {}
    EnsureHosts()

    local ntype = opts.Type or "info"
    local colorToken = ({ info = "Info", success = "Success", warning = "Warning", error = "Error" })[ntype] or "Info"
    local iconName = opts.Icon or ({ info = "info", success = "success", warning = "warn", error = "error" })[ntype] or "info"
    local duration = opts.Duration
    if duration == nil then duration = 4.5 end

    local W = Notif.Width
    local textW = W - 62
    local titleH = (opts.Title and opts.Title ~= "") and 18 or 0
    local contentH = 0
    if opts.Content and opts.Content ~= "" then
        contentH = math.ceil(U.TextSize(opts.Content, 13, Fonts.Regular, textW).Y)
    end
    local buttonsH = (opts.Buttons and #opts.Buttons > 0) and 38 or 0
    local height = 16 + titleH + (titleH > 0 and contentH > 0 and 3 or 0) + contentH + buttonsH + 16
    height = math.max(height, 56)

    -- while hidden, `holder` carries the position; `card` clips + fades
    local holder = New("Frame", {
        Name = "Notification", Size = UDim2.fromOffset(W, height), BackgroundTransparency = 1,
        ZIndex = 40, Parent = Library.Overlay,
    })
    holder.AnchorPoint = notifAnchor(Notif.Position).anchor

    local card = New("CanvasGroup", {
        Size = UDim2.fromScale(1, 1), GroupTransparency = 1, BackgroundTransparency = 1, Parent = holder,
    }, { Corner(13) })
    local glass = Glass({ Size = UDim2.fromScale(1, 1), Parent = card }, { Radius = 13, Strength = -0.08 })

    local bar = New("Frame", {
        Size = UDim2.new(0, 3, 1, 0), BorderSizePixel = 0, ZIndex = 4, Parent = glass,
        Theme = { BackgroundColor3 = colorToken },
    })
    local tint = New("Frame", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 0.92, ZIndex = 2, Parent = glass,
        Theme = { BackgroundColor3 = colorToken },
    }, { Corner(13) })
    local tg = Instance.new("UIGradient")
    tg.Transparency = ns(0, 0, 0.5, 0.7, 1, 1)
    tg.Parent = tint

    local icon = Icons.Create(iconName, 20)
    icon.Position = UDim2.fromOffset(18, 14)
    icon.ZIndex = 4
    icon.Parent = glass
    Icons.Bind(icon, colorToken)

    local y = 14
    if titleH > 0 then
        New("TextLabel", {
            Text = opts.Title, Font = Fonts.Semibold, TextSize = 14, Position = UDim2.fromOffset(48, y - 2),
            Size = UDim2.fromOffset(textW, 18), ZIndex = 4, Parent = glass, TextTruncate = Enum.TextTruncate.AtEnd,
            Theme = { TextColor3 = "Text" },
        })
        y = y + titleH + (contentH > 0 and 3 or 0) - 2
    end
    if contentH > 0 then
        New("TextLabel", {
            Text = opts.Content, Font = Fonts.Regular, TextSize = 13, TextWrapped = true,
            Position = UDim2.fromOffset(48, y), Size = UDim2.fromOffset(textW, contentH),
            TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 4, Parent = glass,
            Theme = { TextColor3 = "SubText" },
        })
        y = y + contentH
    end

    -- progress line
    local progress
    if duration > 0 then
        progress = New("Frame", {
            Size = UDim2.new(1, 0, 0, 2), Position = UDim2.new(0, 0, 1, -2), ZIndex = 5,
            BackgroundTransparency = 0.35, Parent = glass, Theme = { BackgroundColor3 = colorToken },
        })
    end

    local entry = { holder = holder, card = card, height = height, opts = opts, elapsed = 0, hovered = false }

    -- click-to-dismiss layer (below buttons)
    local catcher = New("TextButton", {
        Size = UDim2.fromScale(1, 1), Text = "", ZIndex = 3, Parent = glass, AutoButtonColor = false,
    })
    catcher.MouseEnter:Connect(function() entry.hovered = true end)
    catcher.MouseLeave:Connect(function() entry.hovered = false end)
    catcher.Activated:Connect(function()
        if opts.OnClick then U.SafeCall(opts.OnClick) end
        notifClose(entry)
    end)

    if buttonsH > 0 then
        local row = New("Frame", {
            Size = UDim2.new(1, -62, 0, 28), Position = UDim2.new(0, 48, 1, -40), BackgroundTransparency = 1,
            ZIndex = 6, Parent = glass,
        }, { List(8, Enum.FillDirection.Horizontal) })
        for i, b in ipairs(opts.Buttons) do
            local w = math.max(64, math.ceil(U.TextSize(b.Text or "OK", 12, Fonts.Semibold).X) + 24)
            Controls.Button({
                Text = b.Text, Style = b.Style or (i == 1 and "Primary" or "Secondary"), Size = UDim2.fromOffset(w, 28),
                TextSize = 12, Parent = row, ZIndex = 6, LayoutOrder = i, Radius = 8,
                Callback = function()
                    if b.Callback then U.SafeCall(b.Callback) end
                    notifClose(entry)
                end,
            })
        end
    end

    -- enforce max count
    table.insert(Notif.List, 1, entry)
    while #Notif.List > Notif.Max do
        notifClose(Notif.List[#Notif.List])
    end

    -- place hidden, then animate in
    holder.Position = notifPlace(entry, 0, true)
    notifRelayout(true)
    Anim.Tween(card, { GroupTransparency = 0 }, 0.3, "OutQuad")

    if duration > 0 then
        entry.loop = Anim.Every(function(dt)
            if entry.closing then return end
            if not entry.hovered then entry.elapsed = entry.elapsed + dt end
            local alpha = U.Clamp(entry.elapsed / duration, 0, 1)
            if progress then progress.Size = UDim2.new(1 - alpha, 0, 0, 2) end
            if alpha >= 1 then notifClose(entry) end
        end)
    end

    local api = {}
    function api:Close() notifClose(entry) end
    function api:Dismiss() notifClose(entry) end
    return api
end

function Library:SetNotifyPosition(pos)
    Notif.Position = pos
    notifRelayout(true)
end

function Library:ClearNotifications()
    for i = #Notif.List, 1, -1 do notifClose(Notif.List[i]) end
end

-- ── Dialog (modal) ──────────────────────────────────────────────────────────
-- Library:Dialog({ Title, Content, Icon, Buttons = {{ Text, Style, Callback }}, Dismissible = true })
function Library:Dialog(opts)
    opts = opts or {}
    EnsureHosts()
    local W = 380
    local textW = W - 48
    local contentH = opts.Content and math.ceil(U.TextSize(opts.Content, 13, Fonts.Regular, textW).Y) or 0
    local height = 24 + 26 + 8 + contentH + 22 + 36 + 22

    local dim = New("TextButton", {
        Name = "DialogDim", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0),
        BackgroundTransparency = 1, Text = "", AutoButtonColor = false, ZIndex = 60, Parent = Library.Overlay,
    })
    local holder = New("CanvasGroup", {
        Size = UDim2.fromOffset(W, height), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        GroupTransparency = 1, BackgroundTransparency = 1, ZIndex = 61, Parent = dim,
    })
    local scale = New("UIScale", { Scale = 0.86, Parent = holder })
    local glass = Glass({ Size = UDim2.fromScale(1, 1), Parent = holder }, { Radius = 16, Strength = -0.1 })
    Lip(glass, 20)

    local ic = Icons.Create(opts.Icon or "info", 20)
    ic.Position = UDim2.fromOffset(24, 25)
    ic.ZIndex = 63
    ic.Parent = glass
    Theme.BindFn(ic, function(t) Icons.SetColor(ic, t.Accent, 0) end)

    New("TextLabel", {
        Text = opts.Title or "Dialog", Font = Fonts.Bold, TextSize = 17, Position = UDim2.fromOffset(54, 22),
        Size = UDim2.new(1, -78, 0, 26), ZIndex = 63, Parent = glass, Theme = { TextColor3 = "Text" },
    })
    if contentH > 0 then
        New("TextLabel", {
            Text = opts.Content, Font = Fonts.Regular, TextSize = 13, TextWrapped = true,
            Position = UDim2.fromOffset(24, 62), Size = UDim2.fromOffset(textW, contentH),
            TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 63, Parent = glass,
            Theme = { TextColor3 = "SubText" },
        })
    end

    local closed = false
    local function close()
        if closed then return end
        closed = true
        Anim.Tween(dim, { BackgroundTransparency = 1 }, 0.25, "OutQuad")
        Anim.Tween(holder, { GroupTransparency = 1 }, 0.2, "InQuad")
        Anim.Spring(scale, "Scale", 0.9, Anim.Springs.Stiff)
        Anim.Delay(0.3, function() dim:Destroy() end)
    end

    local row = New("Frame", {
        Size = UDim2.new(1, -48, 0, 36), Position = UDim2.new(0, 24, 1, -58), BackgroundTransparency = 1,
        ZIndex = 63, Parent = glass,
    }, { List(10, Enum.FillDirection.Horizontal, Enum.HorizontalAlignment.Right) })

    local buttons = opts.Buttons or { { Text = "OK", Style = "Primary" } }
    for i, b in ipairs(buttons) do
        local w = math.max(84, math.ceil(U.TextSize(b.Text or "OK", 13, Fonts.Semibold).X) + 32)
        Controls.Button({
            Text = b.Text, Style = b.Style or (i == #buttons and "Primary" or "Secondary"),
            Size = UDim2.fromOffset(w, 36), Parent = row, ZIndex = 64, LayoutOrder = i,
            Callback = function()
                local keep = false
                if b.Callback then
                    local ok, res = pcall(b.Callback)
                    if ok and res == false then keep = true end
                end
                if not keep then close() end
            end,
        })
    end

    if opts.Dismissible ~= false then
        dim.Activated:Connect(close)
    end

    Anim.Tween(dim, { BackgroundTransparency = 0.5 }, 0.3, "OutQuad")
    Anim.Tween(holder, { GroupTransparency = 0 }, 0.25, "OutQuad")
    Anim.Spring(scale, "Scale", 1, Anim.Springs.Bouncy)

    return { Close = close }
end

-- ── Keybind list (shows active keybinds) ────────────────────────────────────
Library.KeybindListObj = nil

function Library:CreateKeybindList(opts)
    opts = opts or {}
    EnsureHosts()
    if Library.KeybindListObj then
        Library.KeybindListObj:SetVisible(true)
        return Library.KeybindListObj
    end

    local holder = New("CanvasGroup", {
        Name = "KeybindList", Size = UDim2.fromOffset(190, 36), AutomaticSize = Enum.AutomaticSize.Y,
        Position = opts.Position or UDim2.new(0, 18, 0.5, -60), BackgroundTransparency = 1,
        GroupTransparency = 1, Parent = Library.Overlay, ZIndex = 20,
    })
    local glass = Glass({ Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = holder },
        { Radius = 12, Strength = -0.05 })
    Pad(0, 0, 0, 10).Parent = glass
    local layout = List(0)
    layout.Parent = glass

    local head = New("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, LayoutOrder = 0, Parent = glass })
    local hi = Icons.Create("keyboard", 15)
    hi.Position = UDim2.fromOffset(12, 10)
    hi.Parent = head
    Theme.BindFn(hi, function(t) Icons.SetColor(hi, t.Accent, 0) end)
    New("TextLabel", {
        Text = opts.Title or "Keybinds", Font = Fonts.Semibold, TextSize = 13, Position = UDim2.fromOffset(34, 0),
        Size = UDim2.new(1, -44, 1, 0), Parent = head, Theme = { TextColor3 = "Text" },
    })
    New("Frame", {
        Size = UDim2.new(1, -24, 0, 1), Position = UDim2.new(0, 12, 1, -1), BackgroundTransparency = 0.88, Parent = head,
        Theme = { BackgroundColor3 = "Stroke" },
    })

    local rows = {}
    local obj = { Instance = holder, Visible = true }
    Interact.Draggable(head, holder, { Smooth = true })

    function obj:Refresh()
        for _, r in pairs(rows) do r.frame:Destroy() end
        rows = {}
        local count = 0
        for _, kb in ipairs(Library.Keybinds) do
            if kb.Key and kb.Key ~= "None" and not kb.HideInList then
                count = count + 1
                local active = kb:GetState()
                local frame = New("Frame", { Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1, LayoutOrder = count, Parent = glass })
                local name = New("TextLabel", {
                    Text = kb.Name or "Keybind", Font = Fonts.Medium, TextSize = 12, Position = UDim2.fromOffset(14, 0),
                    Size = UDim2.new(1, -90, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = frame,
                    TextColor3 = active and Theme.Current.Accent or Theme.Current.SubText,
                })
                local key = New("TextLabel", {
                    Text = "[" .. U.KeyName(kb.Key) .. "]", Font = Fonts.Mono, TextSize = 11, AnchorPoint = Vector2.new(1, 0),
                    Position = UDim2.new(1, -14, 0, 0), Size = UDim2.fromOffset(70, 24),
                    TextXAlignment = Enum.TextXAlignment.Right, Parent = frame,
                    TextColor3 = active and Theme.Current.Accent or Theme.Current.Muted,
                })
                rows[kb] = { frame = frame, name = name, key = key }
            end
        end
        obj.Count = count
        if count == 0 then
            Anim.Tween(holder, { GroupTransparency = 1 }, 0.25, "OutQuad")
        elseif obj.Visible then
            Anim.Tween(holder, { GroupTransparency = 0 }, 0.3, "OutQuad")
        end
    end

    function obj:SetVisible(v)
        obj.Visible = v
        if v and (obj.Count or 0) > 0 then
            Anim.Tween(holder, { GroupTransparency = 0 }, 0.25, "OutQuad")
        else
            Anim.Tween(holder, { GroupTransparency = 1 }, 0.25, "OutQuad")
        end
    end

    function obj:Destroy()
        holder:Destroy()
        Library.KeybindListObj = nil
    end

    Library.KeybindListObj = obj
    obj:Refresh()
    return obj
end

function Library:_KeybindsChanged()
    if Library.KeybindListObj then Library.KeybindListObj:Refresh() end
end

-- ── Watermark ───────────────────────────────────────────────────────────────
-- Library:CreateWatermark({ Title = "CrystalUI", ShowFPS = true, ShowPing = true, ShowTime = true })
function Library:CreateWatermark(opts)
    opts = opts or {}
    EnsureHosts()
    local obj = { Title = opts.Title or "CrystalUI", Fields = {}, Visible = true }
    obj.ShowFPS = opts.ShowFPS ~= false
    obj.ShowPing = opts.ShowPing ~= false
    obj.ShowTime = opts.ShowTime ~= false
    obj.Custom = opts.Custom   -- optional function returning extra text

    local holder = New("CanvasGroup", {
        Name = "Watermark", Size = UDim2.fromOffset(240, 32), Position = opts.Position or UDim2.fromOffset(18, 18),
        BackgroundTransparency = 1, GroupTransparency = 1, Parent = Library.Overlay, ZIndex = 20,
    })
    local glass = Glass({ Size = UDim2.fromScale(1, 1), Parent = holder }, { Radius = 10, Strength = -0.05 })
    local accent = New("Frame", {
        Size = UDim2.new(1, -20, 0, 2), Position = UDim2.new(0, 10, 0, 0), ZIndex = 4, Parent = glass,
        BackgroundColor3 = Color3.new(1, 1, 1),
    }, { Corner(UDim.new(0.5, 0)), AccentGradient(0) })
    local label = New("TextLabel", {
        Text = "", Font = Fonts.Semibold, TextSize = 12, Size = UDim2.new(1, -20, 1, 0), Position = UDim2.fromOffset(10, 1),
        RichText = true, ZIndex = 4, Parent = glass, Theme = { TextColor3 = "Text" },
    })

    Interact.Draggable(holder, holder, { Smooth = true })

    local frames, fps, lastUpdate = 0, 60, os.clock()
    local function currentText()
        local parts = {}
        local acc = U.ToHex(Theme.Current.Accent):gsub("#", "")
        local accHex = string.format('<font color="#%s">%s</font>', acc, obj.Title)
        parts[#parts + 1] = accHex
        if obj.ShowFPS then parts[#parts + 1] = string.format("%d fps", math.floor(fps + 0.5)) end
        if obj.ShowPing then
            local ping = 0
            pcall(function()
                ping = math.floor(S.Stats.Network.ServerStatsItem["Data Ping"]:GetValue() + 0.5)
            end)
            parts[#parts + 1] = ping .. " ms"
        end
        if obj.ShowTime then parts[#parts + 1] = os.date("%H:%M:%S") end
        if obj.Custom then
            local ok, extra = pcall(obj.Custom)
            if ok and extra and extra ~= "" then parts[#parts + 1] = tostring(extra) end
        end
        return table.concat(parts, '  <font transparency="0.6">|</font>  ')
    end

    local function refresh()
        local txt = currentText()
        label.Text = txt
        local plain = txt:gsub("<[^>]+>", "")
        local w = math.ceil(U.TextSize(plain, 12, Fonts.Semibold).X) + 24
        Anim.Spring(holder, "Size", UDim2.fromOffset(w, 32), Anim.Springs.Smooth)
    end

    local acc = 0
    local loop = Anim.Every(function(dt)
        frames = frames + 1
        acc = acc + dt
        if acc >= 0.5 then
            fps = frames / acc
            frames, acc = 0, 0
            if obj.Visible then refresh() end
        end
    end)
    RootMaid:Give(loop)

    function obj:SetVisible(v)
        obj.Visible = v
        Anim.Tween(holder, { GroupTransparency = v and 0 or 1 }, 0.3, "OutQuad")
    end
    function obj:SetTitle(t) obj.Title = t refresh() end
    function obj:Destroy() loop.Cancel() holder:Destroy() end

    refresh()
    Anim.Tween(holder, { GroupTransparency = 0 }, 0.5, "OutQuad", 0.1)
    return obj
end

-- ════════════════════════════════════════════════════════════════════════════
--  SECTION 5 — INTRO ANIMATION (PUZZLE ASSEMBLY, 1.9 s) AND WINDOW
-- ════════════════════════════════════════════════════════════════════════════

local INTRO_DURATION = 1.9

-- Timeline (seconds):
--   0.00 – 0.15  stage dims in, title glow fades up
--   0.05 – 1.15  tiles fly in from random places, spin and settle (staggered)
--   1.15 – 1.35  "lock": tiles close their gaps, a bright flash sweeps across
--   1.30 – 1.90  tiles dissolve into the real window, content cascades in
-- Everything is scheduled relative to the same start time, so the window is
-- fully interactive exactly INTRO_DURATION after the script runs.

local function PlayIntro(window)
    local root = window.Root
    local size = window.Size
    local W, H = size.X.Offset, size.Y.Offset
    local rng = Random.new(os.clock() * 1000)

    local COLS, ROWS = 8, 5
    local tw, th = W / COLS, H / ROWS
    local GAP = 3

    local stage = New("Frame", {
        Name = "IntroStage", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 40,
        ClipsDescendants = false, Parent = root,
    })

    local tiles = {}
    local accentA, accentB = Theme.Current.Accent, Theme.Current.Accent2

    for r = 0, ROWS - 1 do
        for c = 0, COLS - 1 do
            local idx = r * COLS + c + 1
            local mix = (c + r) / (COLS + ROWS - 2)
            local tint = accentA:Lerp(accentB, mix)

            -- final (assembled) geometry
            local fx, fy = c * tw, r * th
            local finalPos = UDim2.fromOffset(fx + tw / 2, fy + th / 2)
            local gapSize = UDim2.fromOffset(tw - GAP, th - GAP)
            local fullSize = UDim2.fromOffset(tw + 1, th + 1)

            -- scattered start
            local angle = rng:NextNumber(0, math.pi * 2)
            local dist = rng:NextNumber(380, 980)
            local startPos = UDim2.fromOffset(
                fx + tw / 2 + math.cos(angle) * dist,
                fy + th / 2 + math.sin(angle) * dist * 0.75
            )
            local startRot = rng:NextNumber(-220, 220)

            local tile = New("Frame", {
                Name = "Tile" .. idx, AnchorPoint = Vector2.new(0.5, 0.5), Position = startPos,
                Size = UDim2.fromOffset(tw * 0.35, th * 0.35), Rotation = startRot,
                BackgroundColor3 = U.Darken(tint, 0.35), BackgroundTransparency = 1, ZIndex = 41, Parent = stage,
            })
            local cr = New("UICorner", { CornerRadius = UDim.new(0, 7), Parent = tile })
            local g = Instance.new("UIGradient")
            g.Rotation = 45
            g.Color = ColorSequence.new(U.Lighten(tint, 0.15), U.Darken(tint, 0.45))
            g.Parent = tile
            local st = New("UIStroke", {
                Thickness = 1, Color = U.Lighten(tint, 0.5), Transparency = 1, Parent = tile,
            })

            -- puzzle knob (alternating in / out like jigsaw pieces)
            local knobDir = ((r + c) % 2 == 0) and 1 or -1
            local knob = New("Frame", {
                AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, 0, 0.5, 0),
                Size = UDim2.fromOffset(9, 9), BackgroundColor3 = U.Darken(tint, 0.3),
                BackgroundTransparency = 1, ZIndex = 42, Parent = tile,
            }, { Corner(UDim.new(0.5, 0)) })
            if knobDir < 0 then knob.Position = UDim2.new(1, -4, 0.5, 0) end
            local knob2 = New("Frame", {
                AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 1, 0),
                Size = UDim2.fromOffset(9, 9), BackgroundColor3 = U.Darken(tint, 0.3),
                BackgroundTransparency = 1, ZIndex = 42, Parent = tile,
            }, { Corner(UDim.new(0.5, 0)) })
            if knobDir > 0 then knob2.Position = UDim2.new(0.5, 0, 1, -4) end
            -- edge tiles have no outward knob
            if c == COLS - 1 then knob.Visible = false end
            if r == ROWS - 1 then knob2.Visible = false end

            -- stagger: pieces nearer the center land first, with some jitter
            local cx, cy = (c + 0.5) / COLS - 0.5, (r + 0.5) / ROWS - 0.5
            local centerDist = math.sqrt(cx * cx + cy * cy) / 0.7
            local delay = 0.05 + centerDist * 0.42 + rng:NextNumber(0, 0.18)
            local flight = rng:NextNumber(0.52, 0.72)
            if delay + flight > 1.14 then flight = 1.14 - delay end

            tiles[#tiles + 1] = {
                tile = tile, stroke = st, knob = knob, knob2 = knob2, grad = g,
                finalPos = finalPos, gapSize = gapSize, fullSize = fullSize, delay = delay, flight = flight,
                tint = tint,
            }
        end
    end

    -- glow title in the middle
    local title = New("TextLabel", {
        Name = "IntroTitle", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.46),
        Size = UDim2.fromOffset(W, 60), Text = string.upper(window.Title), Font = Fonts.Black, TextSize = 38,
        TextColor3 = Color3.new(1, 1, 1), TextTransparency = 1, TextXAlignment = Enum.TextXAlignment.Center,
        ZIndex = 60, Parent = stage,
    })
    local tstroke = New("UIStroke", {
        Thickness = 2, Color = accentA, Transparency = 1, Parent = title,
    })
    local tgrad = Instance.new("UIGradient")
    tgrad.Color = ColorSequence.new(accentA:Lerp(Color3.new(1, 1, 1), 0.5), accentB:Lerp(Color3.new(1, 1, 1), 0.5))
    tgrad.Parent = title

    local sub = New("TextLabel", {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.57), Size = UDim2.fromOffset(W, 20),
        Text = window.Subtitle or "", Font = Fonts.Medium, TextSize = 13, TextColor3 = Color3.new(1, 1, 1),
        TextTransparency = 1, TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 60, Parent = stage,
    })

    -- loading bar + percent
    local barBack = New("Frame", {
        AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -30), Size = UDim2.fromOffset(W * 0.42, 4),
        BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1, ZIndex = 60, Parent = stage,
    }, { Corner(UDim.new(0.5, 0)) })
    local barFill = New("Frame", {
        Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1,
        ZIndex = 61, Parent = barBack,
    }, { Corner(UDim.new(0.5, 0)), Gradient({ accentA, accentB }, 0) })
    local percent = New("TextLabel", {
        AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -40), Size = UDim2.fromOffset(120, 16),
        Text = "0%", Font = Fonts.Mono, TextSize = 12, TextColor3 = Color3.new(1, 1, 1), TextTransparency = 1,
        TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 60, Parent = stage,
    })

    -- flash sweep (bright diagonal band that wipes across when the puzzle locks)
    local flash = New("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(-0.3, 0, 0.5, 0), Size = UDim2.fromOffset(110, H * 1.6),
        Rotation = 18, BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1, ZIndex = 70, Parent = stage,
    })
    local fg = Instance.new("UIGradient")
    fg.Transparency = ns(0, 1, 0.5, 0.2, 1, 1)
    fg.Parent = flash

    -- ── schedule ────────────────────────────────────────────────────────────
    -- (all via Anim.Tween with explicit delays so the timeline is deterministic)

    -- title + loader
    Anim.Tween(title, { TextTransparency = 0 }, 0.35, "OutQuad", 0.15)
    Anim.Tween(tstroke, { Transparency = 0.55 }, 0.45, "OutQuad", 0.15)
    Anim.Tween(sub, { TextTransparency = 0.25 }, 0.4, "OutQuad", 0.3)
    Anim.Tween(barBack, { BackgroundTransparency = 0.85 }, 0.3, "OutQuad", 0.1)
    Anim.Tween(barFill, { BackgroundTransparency = 0 }, 0.3, "OutQuad", 0.1)
    Anim.Tween(percent, { TextTransparency = 0.2 }, 0.3, "OutQuad", 0.1)

    Anim.Custom(INTRO_DURATION - 0.1, "OutSine", function(e)
        barFill.Size = UDim2.fromScale(e, 1)
        percent.Text = math.floor(e * 100 + 0.5) .. "%"
    end, nil, 0.05)

    -- tiles fly in
    for _, t in ipairs(tiles) do
        Anim.Tween(t.tile, { BackgroundTransparency = 0.18 }, 0.25, "OutQuad", t.delay)
        Anim.Tween(t.stroke, { Transparency = 0.45 }, 0.3, "OutQuad", t.delay)
        Anim.Tween(t.knob, { BackgroundTransparency = 0.18 }, 0.25, "OutQuad", t.delay)
        Anim.Tween(t.knob2, { BackgroundTransparency = 0.18 }, 0.25, "OutQuad", t.delay)
        Anim.Tween(t.tile, { Position = t.finalPos, Rotation = 0, Size = t.gapSize },
            t.flight, Ease.BackOutWith(1.35), t.delay)
    end

    -- lock moment: tiles close gaps, flash sweeps across
    Anim.Delay(1.15, function()
        for _, t in ipairs(tiles) do
            Anim.Tween(t.tile, { Size = t.fullSize }, 0.18, "OutCubic")
            Anim.Tween(t.stroke, { Transparency = 0.15 }, 0.12, "OutQuad", 0, function()
                Anim.Tween(t.stroke, { Transparency = 0.7 }, 0.3, "OutQuad")
            end)
        end
        Anim.Tween(flash, { BackgroundTransparency = 0.2, Position = UDim2.new(1.3, 0, 0.5, 0) }, 0.55, "InOutSine")
        Anim.Tween(flash, { BackgroundTransparency = 1 }, 0.2, "OutQuad", 0.38)
        Anim.Tween(title, { TextTransparency = 0.6 }, 0.35, "OutQuad", 0.08)
        Anim.Tween(tstroke, { Transparency = 1 }, 0.3, "OutQuad", 0.05)
    end)

    -- dissolve tiles into the real window
    Anim.Delay(1.3, function()
        window.Main.GroupTransparency = 1
        Anim.Tween(window.Main, { GroupTransparency = 0 }, 0.55, "OutCubic")
        Anim.Tween(window.ShadowFrame, { GroupTransparency = 0 }, 0.6, "OutCubic")
        for i, t in ipairs(tiles) do
            Anim.Tween(t.tile, { BackgroundTransparency = 1 }, 0.5, "OutQuad", (i % COLS) * 0.012)
            Anim.Tween(t.stroke, { Transparency = 1 }, 0.4, "OutQuad")
            Anim.Tween(t.knob, { BackgroundTransparency = 1 }, 0.35, "OutQuad")
            Anim.Tween(t.knob2, { BackgroundTransparency = 1 }, 0.35, "OutQuad")
        end
        Anim.Tween(title, { TextTransparency = 1 }, 0.35, "OutQuad")
        Anim.Tween(sub, { TextTransparency = 1 }, 0.3, "OutQuad")
        Anim.Tween(barBack, { BackgroundTransparency = 1 }, 0.3, "OutQuad")
        Anim.Tween(barFill, { BackgroundTransparency = 1 }, 0.3, "OutQuad")
        Anim.Tween(percent, { TextTransparency = 1 }, 0.3, "OutQuad")
        window:PlayEntrance()
    end)

    Anim.Delay(INTRO_DURATION, function()
        stage:Destroy()
        window.IntroDone = true
        window.Loaded:Fire()
    end)
end

-- ── Window ──────────────────────────────────────────────────────────────────

local Window = {}
Window.__index = Window

local TAB_H, TAB_GAP = 36, 4

-- Window options:
--   Title, Subtitle, Size (UDim2 offset), MinSize (Vector2), Theme, ToggleKey, Intro (bool),
--   Blur (bool), BlurSize, Footer, ConfigFolder, AutoShow, Icon, Resizable
function Library:CreateWindow(opts)
    opts = opts or {}
    EnsureHosts()
    if opts.Theme and ThemePresets[opts.Theme] then
        Theme.Name = opts.Theme
        Theme.Apply(nil, false)
    end

    local self = setmetatable({}, Window)
    self.Title = opts.Title or "CrystalUI"
    self.Subtitle = opts.Subtitle or ("v" .. Library.Version)
    self.Footer = opts.Footer or "CrystalUI"
    self.Size = opts.Size or UDim2.fromOffset(760, 500)
    self.MinSize = opts.MinSize or Vector2.new(560, 380)
    self.ToggleKey = opts.ToggleKey or Enum.KeyCode.RightShift
    self.Tabs = {}
    self.TabOrder = {}
    self.SearchIndex = {}
    self.Visible = false
    self.Minimized = false
    self.Destroyed = false
    self.IntroDone = false
    self.Loaded = Signal.new()
    self.Maid = Maid.new()
    self.ConfigFolder = opts.ConfigFolder or "CrystalUI"
    Library.ConfigFolder = self.ConfigFolder
    Library.Window = self

    local W, H = self.Size.X.Offset, self.Size.Y.Offset

    -- Root: positions the window, hosts the shadow and the UIScale
    local root = New("Frame", {
        Name = "Root", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Size = self.Size, BackgroundTransparency = 1, Visible = false, Parent = Library.Gui,
    })
    local uiscale = New("UIScale", { Scale = 0.88, Parent = root })
    self.Root, self.UIScale = root, uiscale
    Library._scale = 1

    -- shadow lives in a CanvasGroup (bigger than the window) so it can fade as one piece
    local shadowGroup = New("CanvasGroup", {
        Name = "ShadowGroup", Size = UDim2.new(1, 160, 1, 160), Position = UDim2.fromOffset(-80, -80),
        BackgroundTransparency = 1, GroupTransparency = 1, Parent = root,
    })
    local shadowInner = New("Frame", {
        Size = UDim2.new(1, -160, 1, -160), Position = UDim2.fromOffset(80, 80), BackgroundTransparency = 1,
        Parent = shadowGroup,
    })
    Shadow(shadowInner, 22, 30, 12)
    self.ShadowFrame = shadowGroup

    -- Main glass surface (CanvasGroup => rounded clipping + whole-window fade)
    local main = New("CanvasGroup", {
        Name = "Main", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, GroupTransparency = 1,
        Parent = root,
    }, { Corner(18) })
    self.Main = main
    local glass = Glass({ Name = "Glass", Size = UDim2.fromScale(1, 1), ClipsDescendants = true, Parent = main },
        { Radius = 18 })
    self.Glass = glass

    -- animated colour blobs behind everything (fake radial glows, built from stacked circles)
    local backdrop = New("Frame", {
        Name = "Backdrop", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 0,
        ClipsDescendants = true, Parent = glass,
    })
    local blobs = {}
    local function makeBlob(token, x, y, d)
        local holder = New("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(x, y), Size = UDim2.fromOffset(d, d),
            BackgroundTransparency = 1, ZIndex = 0, Parent = backdrop,
        })
        for i = 1, 7 do
            local k = i / 7
            New("Frame", {
                AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
                Size = UDim2.fromScale(1 - k * 0.78, 1 - k * 0.78), ZIndex = 0, Parent = holder,
                Theme = {
                    BackgroundColor3 = token,
                    BackgroundTransparency = function(t)
                        return t.Dark and (0.965 - k * 0.04) or (0.9 - k * 0.04)
                    end,
                },
            }, { Corner(UDim.new(0.5, 0)) })
        end
        return holder
    end
    blobs[1] = makeBlob("BlobA", 0.18, 0.2, 440)
    blobs[2] = makeBlob("BlobB", 0.85, 0.82, 480)
    self.Blobs = blobs

    local blobLoop = Anim.Every(function(dt, now)
        if not self.Visible then return end
        blobs[1].Position = UDim2.fromScale(0.18 + math.sin(now * 0.31) * 0.06, 0.2 + math.cos(now * 0.27) * 0.06)
        blobs[2].Position = UDim2.fromScale(0.85 + math.cos(now * 0.23) * 0.07, 0.82 + math.sin(now * 0.29) * 0.06)
    end)
    self.Maid:Give(blobLoop)

    -- content container (everything interactive lives here)
    local frame = New("Frame", { Name = "Frame", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 2, Parent = glass })
    self.Frame = frame

    -- ── Topbar ──────────────────────────────────────────────────────────────
    local TOP_H = 52
    local topbar = New("Frame", { Name = "Topbar", Size = UDim2.new(1, 0, 0, TOP_H), BackgroundTransparency = 1, Parent = frame })
    self.Topbar = topbar
    local topLine = New("Frame", {
        Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 1, 0), BackgroundTransparency = 0.9, BorderSizePixel = 0,
        Parent = topbar, Theme = { BackgroundColor3 = "Stroke" },
    })

    -- logo mark
    local logo = New("Frame", {
        Size = UDim2.fromOffset(30, 30), Position = UDim2.fromOffset(16, 11), BackgroundColor3 = Color3.new(1, 1, 1), Parent = topbar,
    }, { Corner(9), AccentGradient(45) })
    local logoIcon = Icons.Create(opts.Icon or "layers", 16, Color3.new(1, 1, 1))
    logoIcon.AnchorPoint = Vector2.new(0.5, 0.5)
    logoIcon.Position = UDim2.fromScale(0.5, 0.5)
    logoIcon.Parent = logo
    Theme.BindFn(logoIcon, function(t) Icons.SetColor(logoIcon, t.AccentText, 0) end)
    self.Logo = logo

    local titleLabel = New("TextLabel", {
        Text = self.Title, Font = Fonts.Bold, TextSize = 15, Position = UDim2.fromOffset(54, 8), Size = UDim2.fromOffset(170, 20),
        Parent = topbar, TextTruncate = Enum.TextTruncate.AtEnd, Theme = { TextColor3 = "Text" },
    })
    local subLabel = New("TextLabel", {
        Text = self.Subtitle, Font = Fonts.Medium, TextSize = 11, Position = UDim2.fromOffset(54, 27), Size = UDim2.fromOffset(170, 16),
        Parent = topbar, TextTruncate = Enum.TextTruncate.AtEnd, Theme = { TextColor3 = "Muted" },
    })
    self.TitleLabel, self.SubLabel = titleLabel, subLabel

    -- window buttons (minimize, close)
    local function windowButton(iconName, xFromRight, hoverToken)
        local b = New("TextButton", {
            Size = UDim2.fromOffset(28, 28), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -xFromRight, 0.5, 0),
            BackgroundTransparency = 1, Text = "", ClipsDescendants = true, Parent = topbar,
            BackgroundColor3 = Color3.new(1, 1, 1),
        }, { Corner(8) })
        local ic = Icons.Create(iconName, 14)
        ic.AnchorPoint = Vector2.new(0.5, 0.5)
        ic.Position = UDim2.fromScale(0.5, 0.5)
        ic.Parent = b
        Icons.Bind(ic, "SubText")
        Interact.Hover(b, function()
            Anim.Tween(b, { BackgroundTransparency = 0.88 }, 0.15)
            if hoverToken then Anim.Tween(b, { BackgroundColor3 = Theme.Current[hoverToken] }, 0.15) end
            Icons.SetColor(ic, Theme.Current.Text, 0.15)
        end, function()
            Anim.Tween(b, { BackgroundTransparency = 1 }, 0.2)
            Icons.SetColor(ic, Theme.Current.SubText, 0.2)
        end)
        return b, ic
    end
    local closeBtn = windowButton("close", 14, "Error")
    local minBtn = windowButton("minus", 46, nil)
    self.CloseButton, self.MinButton = closeBtn, minBtn

    -- search
    local searchBox = New("Frame", {
        Name = "Search", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -84, 0.5, 0),
        Size = UDim2.fromOffset(170, 30), BackgroundColor3 = Color3.new(1, 1, 1), Parent = topbar,
        Theme = { BackgroundColor3 = "Surface", BackgroundTransparency = "SurfaceTransparency" },
    }, { Corner(9) })
    local searchStroke = Stroke(1)
    searchStroke.Parent = searchBox
    local sIcon = Icons.Create("search", 14)
    sIcon.Position = UDim2.fromOffset(10, 8)
    sIcon.Parent = searchBox
    Icons.Bind(sIcon, "Muted")
    local searchInput = New("TextBox", {
        Size = UDim2.new(1, -56, 1, 0), Position = UDim2.fromOffset(32, 0), PlaceholderText = "Search...",
        Font = Fonts.Medium, TextSize = 13, ClearTextOnFocus = false, Parent = searchBox,
        Theme = { TextColor3 = "Text", PlaceholderColor3 = "Muted" },
    })
    local clearBtn = New("TextButton", {
        Size = UDim2.fromOffset(20, 20), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0),
        BackgroundTransparency = 1, Text = "", Visible = false, Parent = searchBox,
    })
    local clearIcon = Icons.Create("close", 10)
    clearIcon.AnchorPoint = Vector2.new(0.5, 0.5)
    clearIcon.Position = UDim2.fromScale(0.5, 0.5)
    clearIcon.Parent = clearBtn
    Icons.Bind(clearIcon, "SubText")
    self.SearchBox, self.SearchInput = searchBox, searchInput

    searchInput.Focused:Connect(function()
        Anim.Tween(searchBox, { Size = UDim2.fromOffset(230, 30) }, 0.3, "OutBack")
        Anim.Tween(searchStroke, { Color = Theme.Current.Accent, Transparency = 0.2 }, 0.2)
        Icons.SetColor(sIcon, Theme.Current.Accent, 0.2)
    end)
    searchInput.FocusLost:Connect(function()
        if searchInput.Text == "" then
            Anim.Tween(searchBox, { Size = UDim2.fromOffset(170, 30) }, 0.3, "OutCubic")
        end
        Anim.Tween(searchStroke, { Color = Theme.Current.Stroke, Transparency = Theme.Current.StrokeTransparency }, 0.2)
        Icons.SetColor(sIcon, Theme.Current.Muted, 0.2)
    end)
    clearBtn.Activated:Connect(function()
        searchInput.Text = ""
        searchInput:ReleaseFocus()
    end)

    -- ── Sidebar ─────────────────────────────────────────────────────────────
    local SIDE_W = 176
    local sidebar = New("Frame", {
        Name = "Sidebar", Size = UDim2.new(0, SIDE_W, 1, -TOP_H), Position = UDim2.fromOffset(0, TOP_H),
        BackgroundTransparency = 1, Parent = frame,
    })
    local sideLine = New("Frame", {
        Size = UDim2.new(0, 1, 1, 0), Position = UDim2.new(1, 0, 0, 0), BackgroundTransparency = 0.9, BorderSizePixel = 0,
        Parent = sidebar, Theme = { BackgroundColor3 = "Stroke" },
    })
    local tabHolder = New("ScrollingFrame", {
        Name = "Tabs", Size = UDim2.new(1, 0, 1, -66), Position = UDim2.fromOffset(0, 0), ScrollBarThickness = 0,
        AutomaticCanvasSize = Enum.AutomaticSize.None, CanvasSize = UDim2.new(0, 0, 0, 0), Parent = sidebar,
    }, { Pad(10, 12, 10, 8) })
    self.Sidebar, self.TabHolder = sidebar, tabHolder

    -- selection pill (springs between tabs)
    local pill = New("Frame", {
        Name = "Pill", Size = UDim2.new(1, 0, 0, TAB_H), Position = UDim2.fromOffset(0, 0), BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 0.82, ZIndex = 1, Visible = false, Parent = tabHolder,
    }, { Corner(10), AccentGradient(0) })
    local pillStroke = New("UIStroke", { Thickness = 1, Color = Color3.new(1, 1, 1), Transparency = 0.75, Parent = pill })
    local pillGrad = Instance.new("UIGradient")
    pillGrad.Parent = pillStroke
    Theme.BindFn(pillGrad, function(t) pillGrad.Color = ColorSequence.new(t.Accent, t.Accent2) end)
    local pillBar = New("Frame", {
        Size = UDim2.fromOffset(3, 18), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, -10, 0.5, 0),
        BackgroundColor3 = Color3.new(1, 1, 1), ZIndex = 3, Parent = pill,
    }, { Corner(UDim.new(0.5, 0)), AccentGradient(90) })
    self.Pill = pill

    -- user card (footer of the sidebar)
    local user = New("Frame", {
        Name = "User", Size = UDim2.new(1, -20, 0, 48), Position = UDim2.new(0, 10, 1, -58), Parent = sidebar,
        Theme = { BackgroundColor3 = "Surface", BackgroundTransparency = "SurfaceTransparency" },
    }, { Corner(12), Stroke(1) })
    local avatar = New("ImageLabel", {
        Size = UDim2.fromOffset(32, 32), Position = UDim2.fromOffset(8, 8), BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 0.85, Parent = user,
    }, { Corner(UDim.new(0.5, 0)), Stroke(1.5, "Accent", nil) })
    task.spawn(function()
        local ok, img = pcall(function()
            return S.Players:GetUserThumbnailAsync(LocalPlayer.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
        end)
        if ok and img and avatar.Parent then avatar.Image = img end
    end)
    New("TextLabel", {
        Text = LocalPlayer.DisplayName, Font = Fonts.Semibold, TextSize = 12, Position = UDim2.fromOffset(48, 8),
        Size = UDim2.new(1, -56, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, Parent = user, Theme = { TextColor3 = "Text" },
    })
    New("TextLabel", {
        Text = "@" .. LocalPlayer.Name, Font = Fonts.Regular, TextSize = 11, Position = UDim2.fromOffset(48, 25),
        Size = UDim2.new(1, -56, 0, 14), TextTruncate = Enum.TextTruncate.AtEnd, Parent = user, Theme = { TextColor3 = "Muted" },
    })
    self.UserCard = user

    -- ── Content area ────────────────────────────────────────────────────────
    local content = New("Frame", {
        Name = "Content", Size = UDim2.new(1, -SIDE_W - 1, 1, -TOP_H), Position = UDim2.fromOffset(SIDE_W + 1, TOP_H),
        BackgroundTransparency = 1, ClipsDescendants = true, Parent = frame,
    })
    self.Content = content

    -- footer / status line
    local footer = New("TextLabel", {
        Text = self.Footer, Font = Fonts.Medium, TextSize = 10, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -16, 1, -8),
        Size = UDim2.fromOffset(240, 14), TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 5, Parent = frame,
        Theme = { TextColor3 = "Muted" },
    })
    self.FooterLabel = footer

    -- empty-search message
    local emptyMsg = New("TextLabel", {
        Text = "No results", Font = Fonts.Medium, TextSize = 14, AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(240, 24), TextXAlignment = Enum.TextXAlignment.Center,
        Visible = false, Parent = content, Theme = { TextColor3 = "Muted" },
    })
    self.EmptyMsg = emptyMsg

    -- ── resize grip ─────────────────────────────────────────────────────────
    if opts.Resizable ~= false then
        local grip = New("TextButton", {
            Size = UDim2.fromOffset(22, 22), AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1, Text = "", ZIndex = 30, Parent = frame,
        })
        for i = 1, 3 do
            New("Frame", {
                AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -5, 1, -5 - (i - 1) * 4),
                Size = UDim2.fromOffset(i * 4 + 2, 1), Rotation = 0, BackgroundTransparency = 0.7, ZIndex = 31, Parent = grip,
                BorderSizePixel = 0, Theme = { BackgroundColor3 = "SubText" },
            })
        end
        local startSize, startMouse
        Interact.Drag(grip, function(pos)
            startSize = Vector2.new(root.Size.X.Offset, root.Size.Y.Offset)
            startMouse = pos
        end, function(pos)
            local d = (pos - startMouse) / math.max(Library._scale, 0.01)
            local vp = Camera and Camera.ViewportSize or Vector2.new(1920, 1080)
            local nw = U.Clamp(startSize.X + d.X * 2, self.MinSize.X, math.max(self.MinSize.X, vp.X - 40))
            local nh = U.Clamp(startSize.Y + d.Y * 2, self.MinSize.Y, math.max(self.MinSize.Y, vp.Y - 40))
            self.Size = UDim2.fromOffset(nw, nh)
            root.Size = self.Size
            self:_UpdateLayout()
        end)
        grip.MouseEnter:Connect(function()
            Anim.Tween(grip, { Rotation = 0 }, 0.1)
        end)
    end

    -- window drag by topbar
    self.Drag = Interact.Draggable(topbar, root, { Smooth = true })

    -- ── Window buttons behaviour ────────────────────────────────────────────
    closeBtn.Activated:Connect(function()
        if opts.ConfirmClose == false then
            self:Hide()
            return
        end
        Library:Dialog({
            Title = "Close interface?", Content = "You can hide the window and bring it back with " ..
                U.KeyName(self.ToggleKey) .. ", or unload it completely.",
            Icon = "warn",
            Buttons = {
                { Text = "Cancel", Style = "Ghost" },
                { Text = "Hide", Style = "Secondary", Callback = function() self:Hide() end },
                { Text = "Unload", Style = "Danger", Callback = function() Library:Unload() end },
            },
        })
    end)
    minBtn.Activated:Connect(function() self:SetMinimized(not self.Minimized) end)

    -- search behaviour
    searchInput:GetPropertyChangedSignal("Text"):Connect(function()
        clearBtn.Visible = searchInput.Text ~= ""
        self:_Search(searchInput.Text)
    end)

    -- toggle key
    self.Maid:Give(S.UserInputService.InputBegan:Connect(function(input, processed)
        if processed or Library.Unloaded then return end
        if input.KeyCode == self.ToggleKey and not S.UserInputService:GetFocusedTextBox() then
            self:Toggle()
        end
    end))

    -- mobile toggle button
    if S.UserInputService.TouchEnabled then
        local mob = New("TextButton", {
            Name = "MobileToggle", Size = UDim2.fromOffset(46, 46), AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 12),
            BackgroundColor3 = Color3.new(1, 1, 1), Text = "", Parent = Library.Overlay, ZIndex = 30,
        }, { Corner(UDim.new(0.5, 0)), AccentGradient(45), Stroke(1.2) })
        local mi = Icons.Create("layers", 20, Color3.new(1, 1, 1))
        mi.AnchorPoint = Vector2.new(0.5, 0.5)
        mi.Position = UDim2.fromScale(0.5, 0.5)
        mi.Parent = mob
        Interact.Draggable(mob, mob, { Smooth = true })
        mob.Activated:Connect(function() self:Toggle() end)
        self.Maid:Give(mob)
    end

    table.insert(Library.Windows, self)
    self:_UpdateLayout()

    -- tab strip bookkeeping
    self._tabCursor = 0
    self._tabButtons = {}

    -- show with intro
    if opts.Blur ~= nil then Library.BlurEnabled = opts.Blur end
    if opts.BlurSize then Library.BlurSize = opts.BlurSize end
    local intro = opts.Intro ~= false
    if opts.AutoShow ~= false then
        task.defer(function()
            self:Show(intro)
        end)
    end
    return self
end

-- Pushes layout-dependent numbers after a resize (search width etc.)
function Window:_UpdateLayout()
    local w = self.Root.Size.X.Offset
    if self.SearchBox and not self.SearchInput:IsFocused() then
        local target = w < 640 and 130 or 170
        self.SearchBox.Size = UDim2.fromOffset(target, 30)
    end
end

function Window:Show(playIntro)
    if self.Destroyed then return end
    self.Visible = true
    Library.Toggled = true
    self.Root.Visible = true
    Library:UpdateBlur()

    if playIntro and not self._introPlayed then
        self._introPlayed = true
        self.Main.GroupTransparency = 1
        self.ShadowFrame.GroupTransparency = 1
        self.UIScale.Scale = Library._scale
        self:_PrepareEntrance()
        PlayIntro(self)
        return
    end

    self.Main.GroupTransparency = 1
    self.UIScale.Scale = 0.9 * Library._scale
    Anim.Tween(self.Main, { GroupTransparency = 0 }, 0.28, "OutCubic")
    Anim.Tween(self.ShadowFrame, { GroupTransparency = 0 }, 0.35, "OutCubic")
    Anim.Spring(self.UIScale, "Scale", Library._scale, Anim.Springs.Bouncy)
end

function Window:Hide()
    if not self.Visible then return end
    self.Visible = false
    Library.Toggled = false
    Tooltip.Hide()
    Anim.Tween(self.Main, { GroupTransparency = 1 }, 0.2, "InQuad")
    Anim.Tween(self.ShadowFrame, { GroupTransparency = 1 }, 0.2, "InQuad")
    Anim.Spring(self.UIScale, "Scale", 0.92 * Library._scale, Anim.Springs.Stiff)
    Anim.Delay(0.24, function()
        if not self.Visible and self.Root then self.Root.Visible = false end
    end)
    Library:UpdateBlur()
end

function Window:Toggle()
    if self.Visible then self:Hide() else self:Show(false) end
end

function Window:SetMinimized(state)
    if self.Minimized == state then return end
    self.Minimized = state
    local topH = 52
    if state then
        self._restoreSize = self.Root.Size
        self.Sidebar.Visible = false
        self.Content.Visible = false
        Anim.Spring(self.Root, "Size", UDim2.fromOffset(self.Root.Size.X.Offset, topH), Anim.Springs.Smooth)
    else
        local target = self._restoreSize or self.Size
        Anim.Spring(self.Root, "Size", target, { Stiffness = 220, Ratio = 0.85, Done = function()
            self.Sidebar.Visible = true
            self.Content.Visible = true
        end })
        Anim.Delay(0.12, function()
            self.Sidebar.Visible = true
            self.Content.Visible = true
        end)
    end
end

function Window:SetToggleKey(key)
    self.ToggleKey = key
end

function Window:SetTitle(title, subtitle)
    self.Title = title or self.Title
    self.TitleLabel.Text = self.Title
    if subtitle then self.SubLabel.Text = subtitle end
end

function Window:SetScale(scale)
    scale = U.Clamp(scale, 0.5, 1.6)
    Library._scale = scale
    self.UIScale.Scale = scale
end

-- Hide the interface chrome before the intro reveals it
function Window:_PrepareEntrance()
    -- Sidebar, topbar and content slide/fade in sequentially (see PlayEntrance)
    self.Topbar.Position = UDim2.fromOffset(0, -18)
    self.Sidebar.Position = UDim2.fromOffset(-30, 52)
    self.Content.Position = UDim2.fromOffset(190, 52 + 22)
end

function Window:PlayEntrance()
    local topH = 52
    Anim.Tween(self.Topbar, { Position = UDim2.fromOffset(0, 0) }, 0.55, "OutCubic", 0.05)
    Anim.Tween(self.Sidebar, { Position = UDim2.fromOffset(0, topH) }, 0.6, "OutCubic", 0.1)
    Anim.Tween(self.Content, { Position = UDim2.fromOffset(177, topH) }, 0.6, "OutCubic", 0.15)
    -- tab buttons cascade
    local i = 0
    for _, b in ipairs(self._tabButtons) do
        if b.Button then
            i = i + 1
            local final = b.Button.Position
            b.Button.Position = final + UDim2.fromOffset(-24, 0)
            Anim.Tween(b.Button, { Position = final }, 0.45, "OutBack", 0.1 + i * 0.045)
        end
    end
    -- first tab's sections cascade in as well
    if self.ActiveTab then
        Anim.Delay(0.18, function()
            if self.ActiveTab then self.ActiveTab:_PlayIn() end
        end)
    end
end

-- Cross-tab search ----------------------------------------------------------
function Window:_RegisterSearch(entry)
    table.insert(self.SearchIndex, entry)
end

function Window:_Search(query)
    query = string.lower(U.Trim(query or ""))
    local any = false
    local firstTabWithHit
    local tabHits = {}

    for _, e in ipairs(self.SearchIndex) do
        local alive = e.Frame and e.Frame.Parent
        if alive then
            local match = query == "" or string.find(e.Text, query, 1, true) ~= nil
            e.Match = match
            if match then
                tabHits[e.Tab] = (tabHits[e.Tab] or 0) + 1
                any = true
            end
        end
    end

    for _, e in ipairs(self.SearchIndex) do
        if e.Frame and e.Frame.Parent then
            e.Frame.Visible = e.Match ~= false and (e.UserVisible ~= false)
        end
    end

    -- section visibility: show when any element is visible or its name matches
    for _, tab in ipairs(self.TabOrder) do
        for _, sec in ipairs(tab.Sections) do
            local visible = query == ""
            if not visible then
                if string.find(string.lower(sec.Name), query, 1, true) then
                    visible = true
                    for _, e in ipairs(self.SearchIndex) do
                        if e.Section == sec then e.Frame.Visible = e.UserVisible ~= false end
                    end
                else
                    for _, e in ipairs(self.SearchIndex) do
                        if e.Section == sec and e.Match then visible = true break end
                    end
                end
            end
            sec.Holder.Visible = visible
        end
    end

    -- dim tabs without hits and jump to the first tab that has some
    for _, tab in ipairs(self.TabOrder) do
        local hits = tabHits[tab] or 0
        local dim = query ~= "" and hits == 0
        if tab.Button then
            Anim.Tween(tab.Label, { TextTransparency = dim and 0.65 or 0 }, 0.2)
            Icons.SetTransparency(tab.IconObj, dim and 0.65 or 0, 0.2)
        end
        if query ~= "" and hits > 0 and not firstTabWithHit then firstTabWithHit = tab end
    end

    if query ~= "" and firstTabWithHit and self.ActiveTab and (tabHits[self.ActiveTab] or 0) == 0 then
        self:SelectTab(firstTabWithHit)
    end

    self.EmptyMsg.Visible = query ~= "" and not any
end

-- Tabs ----------------------------------------------------------------------

-- Window:AddTab({ Name = "Main", Icon = "home" })
function Window:AddTab(opts)
    if type(opts) == "string" then opts = { Name = opts } end
    opts = opts or {}
    local tab = setmetatable({}, Library.Tab)
    tab.Window = self
    tab.Name = opts.Name or ("Tab " .. (#self.TabOrder + 1))
    tab.Sections = {}
    tab.Index = #self.TabOrder + 1
    tab.Y = self._tabCursor

    local y = self._tabCursor
    local btn = New("TextButton", {
        Name = "Tab_" .. tab.Name, Size = UDim2.new(1, 0, 0, TAB_H), Position = UDim2.fromOffset(0, y), Text = "",
        BackgroundTransparency = 1, ZIndex = 2, ClipsDescendants = true, Parent = self.TabHolder,
        BackgroundColor3 = Color3.new(1, 1, 1),
    }, { Corner(10) })
    local iconObj = Icons.Create(opts.Icon or "dot", 16)
    iconObj.Position = UDim2.fromOffset(12, 10)
    iconObj.ZIndex = 3
    iconObj.Parent = btn
    Icons.Bind(iconObj, "SubText")
    local label = New("TextLabel", {
        Text = tab.Name, Font = Fonts.Medium, TextSize = 13, Position = UDim2.fromOffset(38, 0),
        Size = UDim2.new(1, -46, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 3, Parent = btn,
        Theme = { TextColor3 = "SubText" },
    })

    tab.Button, tab.IconObj, tab.Label = btn, iconObj, label
    self._tabCursor = y + TAB_H + TAB_GAP
    self.TabHolder.CanvasSize = UDim2.new(0, 0, 0, self._tabCursor + 16)
    table.insert(self._tabButtons, tab)

    Interact.Hover(btn, function()
        if self.ActiveTab ~= tab then
            Anim.Tween(btn, { BackgroundTransparency = 0.92 }, 0.15)
            Icons.SetColor(iconObj, Theme.Current.Text, 0.15)
            Anim.Tween(label, { TextColor3 = Theme.Current.Text }, 0.15)
        end
    end, function()
        if self.ActiveTab ~= tab then
            Anim.Tween(btn, { BackgroundTransparency = 1 }, 0.2)
            Icons.SetColor(iconObj, Theme.Current.SubText, 0.2)
            Anim.Tween(label, { TextColor3 = Theme.Current.SubText }, 0.2)
        end
    end)
    btn.Activated:Connect(function()
        local m = U.MousePos()
        Ripple(btn, m.X, m.Y, Theme.Current.Accent, 0.8)
        self:SelectTab(tab)
    end)

    -- page: a scrolling frame with two columns
    local page = New("ScrollingFrame", {
        Name = "Page_" .. tab.Name, Size = UDim2.fromScale(1, 1), Visible = false, ScrollBarThickness = 3,
        Parent = self.Content,
        Theme = { ScrollBarImageColor3 = "Accent" },
    }, { Pad(14, 14, 14, 14) })
    local cols = New("Frame", {
        Name = "Columns", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = page,
    })
    local colGap = 12
    local left = New("Frame", {
        Name = "Left", Size = UDim2.new(0.5, -colGap / 2, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1, Parent = cols,
    }, { List(12) })
    local right = New("Frame", {
        Name = "Right", Size = UDim2.new(0.5, -colGap / 2, 0, 0), Position = UDim2.new(0.5, colGap / 2, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = cols,
    }, { List(12) })
    tab.Page, tab.Left, tab.Right, tab.Columns = page, left, right, cols

    -- narrow windows collapse to a single column
    local function layoutColumns()
        local w = page.AbsoluteSize.X / math.max(Library._scale, 0.01)
        if w < 470 then
            left.Size = UDim2.new(1, 0, 0, 0)
            right.Size = UDim2.new(1, 0, 0, 0)
            right.Position = UDim2.new(0, 0, 0, left.AbsoluteSize.Y / math.max(Library._scale, 0.01) + 12)
            tab.SingleColumn = true
        else
            left.Size = UDim2.new(0.5, -colGap / 2, 0, 0)
            right.Size = UDim2.new(0.5, -colGap / 2, 0, 0)
            right.Position = UDim2.new(0.5, colGap / 2, 0, 0)
            tab.SingleColumn = false
        end
    end
    page:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutColumns)
    left:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
        if tab.SingleColumn then layoutColumns() end
    end)

    self.Tabs[tab.Name] = tab
    table.insert(self.TabOrder, tab)

    if not self.ActiveTab then
        self:SelectTab(tab, true)
    end
    return tab
end

-- Small group label in the sidebar between tabs
function Window:AddTabDivider(text)
    local y = self._tabCursor
    local lbl = New("TextLabel", {
        Text = string.upper(text or ""), Font = Fonts.Bold, TextSize = 10, Position = UDim2.fromOffset(12, y + 6),
        Size = UDim2.new(1, -24, 0, 14), Parent = self.TabHolder, Theme = { TextColor3 = "Muted" },
    })
    self._tabCursor = y + 28
    self.TabHolder.CanvasSize = UDim2.new(0, 0, 0, self._tabCursor + 16)
    return lbl
end

function Window:SelectTab(tab, instant)
    if type(tab) == "string" then tab = self.Tabs[tab] end
    if not tab or self.ActiveTab == tab then return end
    local previous = self.ActiveTab
    self.ActiveTab = tab

    -- pill glides to the new tab
    self.Pill.Visible = true
    local target = UDim2.fromOffset(0, tab.Y)
    if instant then
        self.Pill.Position = target
    else
        Anim.Spring(self.Pill, "Position", target, Anim.Springs.Snappy)
        -- stretch a bit while travelling (squash & stretch feel)
        local dist = previous and math.abs(previous.Y - tab.Y) or 0
        local stretch = math.min(dist * 0.18, 16)
        Anim.Tween(self.Pill, { Size = UDim2.new(1, 0, 0, TAB_H + stretch) }, 0.12, "OutQuad", 0, function()
            Anim.Spring(self.Pill, "Size", UDim2.new(1, 0, 0, TAB_H), Anim.Springs.Bouncy)
        end)
    end

    for _, t in ipairs(self.TabOrder) do
        local active = t == tab
        Icons.SetColor(t.IconObj, active and Theme.Current.Accent or Theme.Current.SubText, 0.2)
        Anim.Tween(t.Label, { TextColor3 = active and Theme.Current.Text or Theme.Current.SubText }, 0.2)
        Anim.Tween(t.Button, { BackgroundTransparency = 1 }, 0.15)
        t.Label.Font = active and Fonts.Semibold or Fonts.Medium
    end

    -- page transition
    if previous then previous:_PlayOut() end
    tab.Page.Visible = true
    tab.Page.CanvasPosition = Vector2.new(0, 0)
    if instant then
        tab:_SetSectionsVisible(true)
    else
        Anim.Delay(0.1, function()
            if self.ActiveTab == tab then tab:_PlayIn() end
        end)
    end
    self.EmptyMsg.Visible = false
    if self.SearchInput and self.SearchInput.Text ~= "" then
        task.defer(function() self:_Search(self.SearchInput.Text) end)
    end
end

function Window:Destroy()
    if self.Destroyed then return end
    self.Destroyed = true
    self.Visible = false
    self.Maid:Clean()
    pcall(function() self.Root:Destroy() end)
    for i, w in ipairs(Library.Windows) do
        if w == self then table.remove(Library.Windows, i) break end
    end
    Library:UpdateBlur()
end

-- Dialog with a theme switcher etc. are provided by the settings tab (Section 9)

Library.WindowClass = Window

-- ════════════════════════════════════════════════════════════════════════════
--  SECTION 6 — TABS, SECTIONS AND BASIC ELEMENTS
--  Tab • Section • Element base • Label • Paragraph • Divider • Button
--  ButtonRow • Toggle • Slider • ProgressBar
-- ════════════════════════════════════════════════════════════════════════════

local Tab = {}
Tab.__index = Tab
Library.Tab = Tab

local Section = {}
Section.__index = Section
Library.Section = Section

local Element = {}
Element.__index = Element
Library.Element = Element

Library.OnFlagChanged = Signal.new()

local HEADER_H = 38

local function currentScale(window)
    return (window and window.UIScale and window.UIScale.Scale) or 1
end

-- ── Tab ─────────────────────────────────────────────────────────────────────

function Tab:_SetSectionsVisible(state)
    for _, sec in ipairs(self.Sections) do
        sec.Card.GroupTransparency = state and 0 or 1
        sec.Scale.Scale = 1
    end
end

-- Cascade: every section card fades + pops in with a small delay between them
function Tab:_PlayIn()
    self._token = (self._token or 0) + 1
    local token = self._token
    for i, sec in ipairs(self.Sections) do
        sec.Card.GroupTransparency = 1
        sec.Scale.Scale = 0.94
        Anim.Tween(sec.Card, { GroupTransparency = 0 }, 0.4, "OutCubic", (i - 1) * 0.06)
        Anim.Spring(sec.Scale, "Scale", 1, { Stiffness = 240, Ratio = 0.72, Delay = (i - 1) * 0.06 })
    end
    -- elements inside get a tiny stagger of their own (rows slide in a few px)
    local n = 0
    for _, sec in ipairs(self.Sections) do
        for _, el in ipairs(sec.Elements) do
            if el.Row and el.Row.Parent then
                n = n + 1
                if n <= 22 then
                    local row = el.Row
                    row.BackgroundTransparency = 1
                    Anim.Tween(row, { BackgroundTransparency = Theme.Current.SurfaceTransparency }, 0.35, "OutQuad", 0.1 + n * 0.025)
                end
            end
        end
    end
end

function Tab:_PlayOut()
    self._token = (self._token or 0) + 1
    local token = self._token
    for _, sec in ipairs(self.Sections) do
        Anim.Tween(sec.Card, { GroupTransparency = 1 }, 0.12, "InQuad")
    end
    Anim.Delay(0.14, function()
        if self._token == token and self.Window.ActiveTab ~= self then
            self.Page.Visible = false
        end
    end)
end

-- Tab:AddSection({ Name, Side = "Left"|"Right", Icon, Collapsible = true, Collapsed = false })
function Tab:AddSection(opts)
    if type(opts) == "string" then opts = { Name = opts } end
    opts = opts or {}
    local window = self.Window

    local sec = setmetatable({}, Section)
    sec.Tab, sec.Window = self, window
    sec.Name = opts.Name or "Section"
    sec.Elements = {}
    sec._order = 1
    sec.Collapsible = opts.Collapsible ~= false
    sec.Collapsed = opts.Collapsed == true

    self._weights = self._weights or { Left = 0, Right = 0 }
    local side = opts.Side
    if side ~= "Left" and side ~= "Right" then
        side = (self._weights.Left <= self._weights.Right) and "Left" or "Right"
    end
    self._weights[side] = self._weights[side] + 1
    local column = (side == "Left") and self.Left or self.Right
    sec.Side = side

    local card = New("CanvasGroup", {
        Name = "Section_" .. sec.Name, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1, LayoutOrder = #self.Sections + 1, Parent = column,
    }, { Corner(13) })
    local scale = New("UIScale", { Scale = 1, Parent = card })

    -- surface
    local surface = New("Frame", {
        Name = "Surface", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = card,
        Theme = { BackgroundColor3 = "Surface", BackgroundTransparency = "SurfaceTransparency" },
    }, { Corner(13), Stroke(1) })
    local surfaceList = List(0)
    surfaceList.Parent = surface
    Lip(surface, 16)

    -- header
    local header = New("TextButton", {
        Name = "Header", Size = UDim2.new(1, 0, 0, HEADER_H), Text = "", BackgroundTransparency = 1, LayoutOrder = 1,
        Parent = surface, AutoButtonColor = false,
    })
    local nameX = 14
    if opts.Icon then
        local ic = Icons.Create(opts.Icon, 15)
        ic.Position = UDim2.fromOffset(14, 11)
        ic.Parent = header
        Theme.BindFn(ic, function(t) Icons.SetColor(ic, t.Accent, 0) end)
        nameX = 36
    end
    local nameLabel = New("TextLabel", {
        Text = sec.Name, Font = Fonts.Semibold, TextSize = 13, Position = UDim2.fromOffset(nameX, 0),
        Size = UDim2.new(1, -nameX - 40, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = header,
        Theme = { TextColor3 = "Text" },
    })
    local chevron
    if sec.Collapsible then
        chevron = Icons.Create("chevron", 14)
        chevron.AnchorPoint = Vector2.new(0.5, 0.5)
        chevron.Position = UDim2.new(1, -22, 0.5, 0)
        chevron.Parent = header
        Icons.Bind(chevron, "SubText")
    end
    local headLine = New("Frame", {
        Size = UDim2.new(1, -28, 0, 1), Position = UDim2.new(0, 14, 1, 0), BackgroundTransparency = 0.9, BorderSizePixel = 0,
        Parent = header, Theme = { BackgroundColor3 = "Stroke" },
    })

    -- body (clipped container so we can animate collapse)
    local bodyClip = New("Frame", {
        Name = "BodyClip", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
        ClipsDescendants = true, LayoutOrder = 2, Parent = surface,
    })
    local body = New("Frame", {
        Name = "Body", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
        Parent = bodyClip,
    }, { Pad(10, 10, 10, 12), List(6) })

    sec.Card, sec.Scale, sec.Surface, sec.Header, sec.Body, sec.BodyClip = card, scale, surface, header, body, bodyClip
    sec.Holder = card   -- (search hides the whole card)
    sec.Chevron = chevron

    -- collapse / expand
    local function setCollapsed(state, instant)
        if sec.Collapsed == state and not instant then return end
        sec.Collapsed = state
        sec._collapseToken = (sec._collapseToken or 0) + 1
        local token = sec._collapseToken
        local natural = body.AbsoluteSize.Y / math.max(currentScale(window), 0.01)
        if chevron then
            Anim.Tween(chevron, { Rotation = state and -90 or 0 }, instant and 0 or 0.3, "OutBack")
        end
        if instant then
            bodyClip.AutomaticSize = state and Enum.AutomaticSize.None or Enum.AutomaticSize.Y
            if state then bodyClip.Size = UDim2.new(1, 0, 0, 0) end
            return
        end
        if state then
            bodyClip.AutomaticSize = Enum.AutomaticSize.None
            bodyClip.Size = UDim2.new(1, 0, 0, natural)
            Anim.Tween(bodyClip, { Size = UDim2.new(1, 0, 0, 0) }, 0.32, "InOutCubic")
        else
            bodyClip.AutomaticSize = Enum.AutomaticSize.None
            bodyClip.Size = UDim2.new(1, 0, 0, 0)
            Anim.Tween(bodyClip, { Size = UDim2.new(1, 0, 0, natural) }, 0.36, "OutCubic", 0, function()
                if sec._collapseToken == token and not sec.Collapsed then
                    bodyClip.AutomaticSize = Enum.AutomaticSize.Y
                    bodyClip.Size = UDim2.new(1, 0, 0, 0)
                end
            end)
        end
    end
    sec.SetCollapsed = function(_, state) setCollapsed(state) end

    if sec.Collapsible then
        header.Activated:Connect(function()
            setCollapsed(not sec.Collapsed)
        end)
        Interact.Hover(header, function()
            if chevron then Icons.SetColor(chevron, Theme.Current.Text, 0.15) end
        end, function()
            if chevron then Icons.SetColor(chevron, Theme.Current.SubText, 0.2) end
        end)
    end
    if sec.Collapsed then
        task.defer(function() setCollapsed(true, true) end)
        if chevron then chevron.Rotation = -90 end
    end

    table.insert(self.Sections, sec)
    if self.Window.ActiveTab == self and self.Window.IntroDone then
        -- tab already visible and we're adding live: pop the new section in
        card.GroupTransparency = 1
        Anim.Tween(card, { GroupTransparency = 0 }, 0.35, "OutCubic")
    end
    return sec
end

-- ── Element base ────────────────────────────────────────────────────────────

local function lower(s) return string.lower(tostring(s or "")) end

-- Creates holder + (optionally) a styled row. Returns element, row, holder.
function Section:_Make(kind, opts, rowHeight, noRow)
    opts = opts or {}
    local el = setmetatable({}, Element)
    el.Section, el.Window, el.Kind, el.Options = self, self.Window, kind, opts
    el.Flag = opts.Flag
    el.Text = opts.Text or opts.Name or opts.Title or kind
    el.Changed = Signal.new()
    el.UserVisible = true
    el.Disabled = false
    el.Callback = opts.Callback
    el.Maid = Maid.new()

    local holder = New("Frame", {
        Name = kind .. "_" .. tostring(el.Text), Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1, LayoutOrder = self._order, Parent = self.Body,
    }, { List(5) })
    self._order = self._order + 1
    el.Holder = holder

    if not noRow then
        local row = New("TextButton", {
            Name = "Row", Size = UDim2.new(1, 0, 0, rowHeight or 36), Text = "", AutoButtonColor = false,
            LayoutOrder = 1, Parent = holder,
            Theme = { BackgroundColor3 = "Surface", BackgroundTransparency = "SurfaceTransparency" },
        }, { Corner(10), Stroke(1) })
        el.Row = row
        el.RowStroke = row:FindFirstChildOfClass("UIStroke")
        Interact.Hover(row, function()
            if not el.Disabled then
                Anim.Tween(row, { BackgroundTransparency = math.max(Theme.Current.SurfaceTransparency - 0.045, 0) }, 0.15)
            end
        end, function()
            Anim.Tween(row, { BackgroundTransparency = Theme.Current.SurfaceTransparency }, 0.22)
        end)
        if opts.Tooltip then
            el._tip = opts.Tooltip
            Tooltip.Attach(row, function() return el._tip end)
        end
    end

    -- search registration
    local entry = {
        Frame = holder, Tab = self.Tab, Section = self, UserVisible = true, Match = true,
        Text = lower(el.Text .. " " .. (opts.Keywords or "") .. " " .. (opts.Tooltip or "")),
    }
    el.SearchEntry = entry
    self.Window:_RegisterSearch(entry)

    table.insert(self.Elements, el)
    if el.Flag then
        Library.Elements[el.Flag] = el
    end
    return el, el.Row, holder
end

function Element:SetVisible(v)
    self.UserVisible = v
    if self.SearchEntry then self.SearchEntry.UserVisible = v end
    self.Holder.Visible = v and (self.SearchEntry == nil or self.SearchEntry.Match ~= false)
end

function Element:SetDisabled(state)
    if self.Disabled == state then return end
    self.Disabled = state
    local target = self.Row or self.Holder
    if state then
        if not self._cover then
            self._cover = New("TextButton", {
                Name = "DisabledCover", Size = UDim2.fromScale(1, 1), Text = "", AutoButtonColor = false, ZIndex = 50,
                BackgroundTransparency = 1, Parent = target, BackgroundColor3 = Color3.new(0, 0, 0),
            }, { Corner(10) })
        end
        self._cover.Visible = true
        Anim.Tween(self._cover, { BackgroundTransparency = 0.55 }, 0.2)
    elseif self._cover then
        Anim.Tween(self._cover, { BackgroundTransparency = 1 }, 0.2, "OutQuad", 0, function()
            if not self.Disabled and self._cover then self._cover.Visible = false end
        end)
    end
end

function Element:SetTooltip(text)
    self._tip = text
    if not self._tipAttached and (self.Row or self.Holder) then
        self._tipAttached = true
        Tooltip.Attach(self.Row or self.Holder, function() return self._tip end)
    end
end

function Element:SetText(text)
    self.Text = text
    if self.Label then self.Label.Text = text end
    if self.SearchEntry then self.SearchEntry.Text = lower(text) end
end

function Element:OnChanged(fn)
    return self.Changed:Connect(fn)
end

function Element:Get()
    return self.Value
end

-- Commit a new value: store flag, fire callback + signals (unless silent)
function Element:_Commit(value, silent)
    self.Value = value
    if self.Flag then Library.Flags[self.Flag] = value end
    if not silent then
        if self.Callback then U.SafeCall(self.Callback, value) end
        self.Changed:Fire(value)
        Library.OnFlagChanged:Fire(self.Flag, value, self)
    end
end

function Element:Serialize()
    return self.Value
end

function Element:Deserialize(data)
    if self.Set then self:Set(data, false) end
end

function Element:Destroy()
    if self.Destroyed then return end
    self.Destroyed = true
    self.Maid:Clean()
    if self.SearchEntry then
        for i, e in ipairs(self.Window.SearchIndex) do
            if e == self.SearchEntry then table.remove(self.Window.SearchIndex, i) break end
        end
    end
    if self.Flag then
        Library.Elements[self.Flag] = nil
        Library.Flags[self.Flag] = nil
    end
    for i, e in ipairs(self.Section.Elements) do
        if e == self then table.remove(self.Section.Elements, i) break end
    end
    self.Holder:Destroy()
end

-- Standard left label used by most rows
local function rowLabel(el, row, text, xOffset, widthSub)
    local label = New("TextLabel", {
        Name = "Label", Text = text, Font = Fonts.Medium, TextSize = 13, Position = UDim2.fromOffset(xOffset or 12, 0),
        Size = UDim2.new(1, -(widthSub or 80), 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row,
        Theme = { TextColor3 = "Text" },
    })
    el.Label = label
    return label
end

-- Addon container on the right side of a row (hosts keybind chips, colour swatches)
local function rowAddons(el, row, rightInset)
    local addons = New("Frame", {
        Name = "Addons", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -(rightInset or 12), 0.5, 0),
        Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, Parent = row,
    }, { List(6, Enum.FillDirection.Horizontal, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center) })
    el.Addons = addons
    el.AddonsInset = rightInset or 12
    local label = el.Label
    local base = (rightInset or 12) + 14
    addons:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
        if label and label.Parent then
            local w = addons.AbsoluteSize.X / math.max(currentScale(el.Window), 0.01)
            label.Size = UDim2.new(1, -(base + w + 8), 1, 0)
        end
    end)
    return addons
end

-- ── Label / Paragraph / Divider / Spacer ────────────────────────────────────

-- Section:AddLabel("text") or { Text, Color = "SubText"|"Accent"|..., Wrap = true }
function Section:AddLabel(opts)
    if type(opts) == "string" then opts = { Text = opts } end
    opts = opts or {}
    local el, _, holder = self:_Make("Label", opts, nil, true)
    local lbl = New("TextLabel", {
        Name = "Label", Text = opts.Text or "", Font = Fonts.Medium, TextSize = opts.TextSize or 13, TextWrapped = opts.Wrap ~= false,
        Size = UDim2.new(1, 0, 0, 20), AutomaticSize = Enum.AutomaticSize.Y, TextYAlignment = Enum.TextYAlignment.Top,
        Parent = holder, Theme = { TextColor3 = opts.Color or "SubText" },
    }, { Pad(4, 3, 4, 3) })
    el.Label = lbl
    function el:SetText(t)
        el.Text = t
        lbl.Text = t
        el.SearchEntry.Text = lower(t)
    end
    function el:SetColor(token)
        Theme.Bind(lbl, { TextColor3 = token })
    end
    -- labels can carry colour pickers / keybinds as well
    rowAddons(el, lbl, 4)
    return el
end

-- Section:AddParagraph({ Title, Content })
function Section:AddParagraph(opts)
    opts = opts or {}
    local el, row = self:_Make("Paragraph", { Text = (opts.Title or "") .. " " .. (opts.Content or ""), Tooltip = opts.Tooltip }, 0)
    row.AutomaticSize = Enum.AutomaticSize.Y
    row.Size = UDim2.new(1, 0, 0, 0)
    row.Active = false
    local inner = New("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = row },
        { Pad(12, 10, 12, 10), List(4) })
    local title = New("TextLabel", {
        Text = opts.Title or "", Font = Fonts.Semibold, TextSize = 13, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = 1,
        Parent = inner, Theme = { TextColor3 = "Text" },
    })
    local content = New("TextLabel", {
        Text = opts.Content or "", Font = Fonts.Regular, TextSize = 12, TextWrapped = true, Size = UDim2.new(1, 0, 0, 14),
        AutomaticSize = Enum.AutomaticSize.Y, TextYAlignment = Enum.TextYAlignment.Top, LayoutOrder = 2, Parent = inner,
        Theme = { TextColor3 = "SubText" },
    })
    if (opts.Title or "") == "" then title.Visible = false end
    function el:SetTitle(t) title.Text = t title.Visible = t ~= "" end
    function el:SetContent(t) content.Text = t end
    return el
end

function Section:AddDivider(text)
    local el, _, holder = self:_Make("Divider", { Text = text or "divider" }, nil, true)
    local h = New("Frame", { Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1, Parent = holder })
    local function line(anchorX, posX, sizeX)
        local l = New("Frame", {
            AnchorPoint = Vector2.new(anchorX, 0.5), Position = UDim2.new(posX, 0, 0.5, 0), Size = sizeX, BorderSizePixel = 0,
            BackgroundTransparency = 0.88, Parent = h, Theme = { BackgroundColor3 = "Stroke" },
        })
        return l
    end
    if text and text ~= "" then
        local w = math.ceil(U.TextSize(text, 11, Fonts.Semibold).X) + 16
        New("TextLabel", {
            Text = string.upper(text), Font = Fonts.Semibold, TextSize = 10, AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(w, 14), TextXAlignment = Enum.TextXAlignment.Center,
            Parent = h, Theme = { TextColor3 = "Muted" },
        })
        line(0, 0, UDim2.new(0.5, -w / 2, 0, 1))
        line(1, 1, UDim2.new(0.5, -w / 2, 0, 1))
    else
        line(0, 0, UDim2.new(1, 0, 0, 1))
    end
    el.SearchEntry.Text = lower(text or "") .. " "
    el.SearchEntry.Match = true
    return el
end

function Section:AddSpacer(height)
    local el, _, holder = self:_Make("Spacer", { Text = "spacer" }, nil, true)
    New("Frame", { Size = UDim2.new(1, 0, 0, height or 8), BackgroundTransparency = 1, Parent = holder })
    el.SearchEntry.Text = "\0"
    return el
end

-- ── Button ──────────────────────────────────────────────────────────────────

-- Section:AddButton({ Text, Callback, Style = "Primary"|"Secondary"|"Danger", Icon, DoubleClick = false })
function Section:AddButton(opts)
    if type(opts) == "string" then opts = { Text = opts } end
    opts = opts or {}
    local el, _, holder = self:_Make("Button", opts, nil, true)
    local armed, armToken = false, 0
    local original = opts.Text or "Button"

    local btn
    btn = Controls.Button({
        Text = original, Style = opts.Style or "Secondary", Icon = opts.Icon, Size = UDim2.new(1, 0, 0, opts.Height or 34),
        Parent = holder, Radius = 10, TextSize = 13,
        Callback = function()
            if el.Disabled then return end
            if opts.DoubleClick then
                if not armed then
                    armed = true
                    armToken = armToken + 1
                    local my = armToken
                    btn:SetText("Click again to confirm")
                    Anim.Shake(btn.Instance, 4, 0.25)
                    task.delay(2.2, function()
                        if armed and armToken == my then
                            armed = false
                            btn:SetText(el.Text)
                        end
                    end)
                    return
                end
                armed = false
                btn:SetText(el.Text)
            end
            if opts.Callback then U.SafeCall(opts.Callback) end
            el.Changed:Fire()
        end,
    })
    el.Row = btn.Instance
    el.Label = btn.Label
    if opts.Tooltip then
        el._tip = opts.Tooltip
        Tooltip.Attach(btn.Instance, function() return el._tip end)
    end
    function el:SetText(t)
        el.Text = t
        btn:SetText(t)
        el.SearchEntry.Text = lower(t)
    end
    function el:SetCallback(fn) opts.Callback = fn end
    function el:Click() if opts.Callback then U.SafeCall(opts.Callback) end end
    return el
end

-- Section:AddButtonRow({ {Text=..., Callback=..., Style=...}, {...} })
function Section:AddButtonRow(list, opts)
    opts = opts or {}
    local text = {}
    for _, b in ipairs(list) do text[#text + 1] = b.Text or "" end
    local el, _, holder = self:_Make("ButtonRow", { Text = table.concat(text, " ") }, nil, true)
    local row = New("Frame", { Size = UDim2.new(1, 0, 0, opts.Height or 34), BackgroundTransparency = 1, Parent = holder })
    local n, gap = #list, 8
    el.Buttons = {}
    for i, b in ipairs(list) do
        local btn = Controls.Button({
            Text = b.Text, Style = b.Style or "Secondary", Icon = b.Icon,
            Size = UDim2.new(1 / n, -gap * (n - 1) / n, 1, 0), Parent = row, Radius = 10, TextSize = 13,
            Callback = function() if not el.Disabled and b.Callback then U.SafeCall(b.Callback) end end,
        })
        btn.Instance.Position = UDim2.new((i - 1) / n, (i - 1) * gap / n, 0, 0)
        if b.Tooltip then Tooltip.Attach(btn.Instance, b.Tooltip) end
        el.Buttons[i] = btn
    end
    return el
end

-- ── Toggle ──────────────────────────────────────────────────────────────────

-- Section:AddToggle({ Flag, Text, Default, Callback, Tooltip, Style = "Switch"|"Check" })
function Section:AddToggle(opts)
    opts = opts or {}
    local el, row = self:_Make("Toggle", opts, 38)
    local style = opts.Style or "Switch"
    local state = opts.Default == true
    local pressed = false
    local label = rowLabel(el, row, el.Text, 12, 80)

    local switchW = style == "Check" and 22 or 42
    local trackOffX = switchW + 20
    local addons = rowAddons(el, row, trackOffX)

    local setVisual   -- forward

    if style == "Check" then
        local box = New("Frame", {
            Name = "Box", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(22, 22),
            Parent = row, Theme = { BackgroundColor3 = "TrackOff", BackgroundTransparency = "TrackOffTransparency" },
        }, { Corner(7), Stroke(1) })
        local fill = New("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(0, 0),
            BackgroundColor3 = Color3.new(1, 1, 1), Parent = box,
        }, { Corner(6), AccentGradient(45) })
        local tick = Icons.Create("check", 16)
        tick.AnchorPoint = Vector2.new(0.5, 0.5)
        tick.Position = UDim2.fromScale(0.5, 0.5)
        tick.ZIndex = 3
        tick.Parent = box
        Theme.BindFn(tick, function(t) Icons.SetColor(tick, t.AccentText, 0) end)
        local tickScale = New("UIScale", { Scale = 0, Parent = tick })
        el.Box = box
        setVisual = function(instant)
            if instant then
                fill.Size = state and UDim2.fromOffset(22, 22) or UDim2.fromOffset(0, 0)
                tickScale.Scale = state and 1 or 0
            else
                Anim.Spring(fill, "Size", state and UDim2.fromOffset(22, 22) or UDim2.fromOffset(0, 0), Anim.Springs.Bouncy)
                Anim.Spring(tickScale, "Scale", state and 1 or 0, state and Anim.Springs.Bouncy or Anim.Springs.Stiff)
            end
        end
    else
        local track = New("Frame", {
            Name = "Track", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(42, 22),
            Parent = row, Theme = { BackgroundColor3 = "TrackOff", BackgroundTransparency = "TrackOffTransparency" },
        }, { Corner(UDim.new(0.5, 0)) })
        local tStroke = Stroke(1)
        tStroke.Parent = track
        local fill = New("Frame", {
            Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1, Parent = track,
        }, { Corner(UDim.new(0.5, 0)), AccentGradient(0) })
        local knob = New("Frame", {
            Name = "Knob", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0), Size = UDim2.fromOffset(16, 16),
            BackgroundColor3 = Color3.new(1, 1, 1), ZIndex = 3, Parent = track,
        }, { Corner(UDim.new(0.5, 0)) })
        local kShadow = New("UIStroke", { Thickness = 1, Color = Color3.new(0, 0, 0), Transparency = 0.85, Parent = knob })
        el.Track, el.Knob = track, knob
        local function knobX()
            local w = pressed and 21 or 16
            return state and (42 - 3 - w) or 3, w
        end
        setVisual = function(instant)
            local x, w = knobX()
            local pos = UDim2.new(0, x, 0.5, 0)
            local size = UDim2.fromOffset(w, 16)
            if instant then
                knob.Position, knob.Size = pos, size
                fill.BackgroundTransparency = state and 0 or 1
                tStroke.Transparency = state and 0.4 or Theme.Current.StrokeTransparency
                tStroke.Color = state and Theme.Current.Accent or Theme.Current.Stroke
            else
                Anim.Spring(knob, "Position", pos, Anim.Springs.Snappy)
                Anim.Spring(knob, "Size", size, Anim.Springs.Snappy)
                Anim.Tween(fill, { BackgroundTransparency = state and 0 or 1 }, 0.22, "OutQuad")
                Anim.Tween(tStroke, {
                    Transparency = state and 0.4 or Theme.Current.StrokeTransparency,
                    Color = state and Theme.Current.Accent or Theme.Current.Stroke,
                }, 0.22, "OutQuad")
            end
        end
        Interact.Press(row, function()
            pressed = true
            setVisual(false)
        end, function()
            pressed = false
            setVisual(false)
        end)
        row.MouseLeave:Connect(function()
            if pressed then pressed = false setVisual(false) end
        end)
    end

    local function labelColor(instant)
        local c = state and Theme.Current.Text or Theme.Current.SubText
        if instant then label.TextColor3 = c else Anim.Tween(label, { TextColor3 = c }, 0.2) end
    end

    function el:Set(v, silent)
        v = v and true or false
        local changed = v ~= state
        state = v
        setVisual(false)
        labelColor(false)
        if changed or silent == false then el:_Commit(state, silent) else el.Value = state if el.Flag then Library.Flags[el.Flag] = state end end
    end
    function el:Toggle() el:Set(not state) end
    function el:Get() return state end

    row.Activated:Connect(function()
        if el.Disabled then return end
        el:Set(not state)
    end)

    Theme.BindFn(row, function(t, animate)
        setVisual(true)
        labelColor(true)
    end)

    el.Value = state
    if el.Flag then Library.Flags[el.Flag] = state end
    setVisual(true)
    labelColor(true)
    return el
end

-- ── Slider ──────────────────────────────────────────────────────────────────

-- Section:AddSlider({ Flag, Text, Min, Max, Default, Step, Suffix, Prefix, Decimals, Callback })
function Section:AddSlider(opts)
    opts = opts or {}
    local el, row = self:_Make("Slider", opts, 54)
    local min, max = opts.Min or 0, opts.Max or 100
    local step = opts.Step or opts.Rounding or 1
    local decimals = opts.Decimals or U.DecimalsOf(step)
    local suffix, prefix = opts.Suffix or "", opts.Prefix or ""
    local value = U.Clamp(opts.Default or min, min, max)
    local dragging = false

    rowLabel(el, row, el.Text, 12, 96)

    local box = New("TextBox", {
        Name = "ValueBox", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 7), Size = UDim2.fromOffset(70, 22),
        Font = Fonts.Semibold, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Center, ClearTextOnFocus = false,
        BackgroundTransparency = 0, Parent = row,
        Theme = { TextColor3 = "Text", BackgroundColor3 = "Surface", BackgroundTransparency = "SurfaceTransparency" },
    }, { Corner(7) })
    local boxStroke = Stroke(1)
    boxStroke.Parent = box

    local hit = New("TextButton", {
        Name = "Hit", Size = UDim2.new(1, -24, 0, 22), Position = UDim2.fromOffset(12, 30), Text = "", BackgroundTransparency = 1,
        Parent = row,
    })
    local track = New("Frame", {
        Name = "Track", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.new(1, 0, 0, 6),
        Parent = hit, Theme = { BackgroundColor3 = "TrackOff", BackgroundTransparency = "TrackOffTransparency" },
    }, { Corner(UDim.new(0.5, 0)) })
    local fill = New("Frame", {
        Name = "Fill", Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = Color3.new(1, 1, 1), Parent = track,
    }, { Corner(UDim.new(0.5, 0)), AccentGradient(0) })
    local knob = New("Frame", {
        Name = "Knob", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(14, 14),
        BackgroundColor3 = Color3.new(1, 1, 1), ZIndex = 4, Parent = track,
    }, { Corner(UDim.new(0.5, 0)) })
    local kStroke = New("UIStroke", { Thickness = 2, Parent = knob, Theme = { Color = "Accent" } })

    -- value bubble (visible while dragging)
    local bubble = New("TextLabel", {
        Name = "Bubble", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0, 0, 0, -10), Size = UDim2.fromOffset(46, 20),
        BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1, TextTransparency = 1, Font = Fonts.Bold, TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 6, Parent = track,
        Theme = { TextColor3 = "AccentText" },
    }, { Corner(6), AccentGradient(0) })

    local function fmt(v)
        return prefix .. U.FormatNumber(v, decimals) .. suffix
    end

    local function ratioOf(v)
        if max == min then return 0 end
        return (v - min) / (max - min)
    end

    local function visual(instant)
        local r = ratioOf(value)
        local w = UDim2.new(r, 0, 1, 0)
        local kp = UDim2.new(r, 0, 0.5, 0)
        local bp = UDim2.new(r, 0, 0, -10)
        box.Text = fmt(value)
        bubble.Text = fmt(value)
        local bw = math.max(40, math.ceil(U.TextSize(bubble.Text, 11, Fonts.Bold).X) + 16)
        bubble.Size = UDim2.fromOffset(bw, 20)
        if instant then
            fill.Size, knob.Position, bubble.Position = w, kp, bp
        else
            Anim.Spring(fill, "Size", w, { Stiffness = 420, Ratio = 0.95 })
            Anim.Spring(knob, "Position", kp, { Stiffness = 420, Ratio = 0.95 })
            Anim.Spring(bubble, "Position", bp, { Stiffness = 420, Ratio = 0.95 })
        end
    end

    local function setFromRatio(r)
        local raw = min + U.Clamp(r, 0, 1) * (max - min)
        local v = U.Clamp(U.Round(raw, step), min, max)
        if v ~= value then
            value = v
            visual(false)
            el:_Commit(value)
        end
    end

    function el:Set(v, silent)
        if type(v) ~= "number" then v = tonumber(v) end
        if not v then return end
        v = U.Clamp(U.Round(v, step), min, max)
        local changed = v ~= value
        value = v
        visual(false)
        if changed or silent == false then el:_Commit(value, silent) else el.Value = value if el.Flag then Library.Flags[el.Flag] = value end end
    end
    function el:SetMin(m) min = m value = U.Clamp(value, min, max) visual(true) end
    function el:SetMax(m) max = m value = U.Clamp(value, min, max) visual(true) end
    function el:Get() return value end

    local function showBubble(show)
        Anim.Tween(bubble, { BackgroundTransparency = show and 0.05 or 1, TextTransparency = show and 0 or 1 }, 0.15, "OutQuad")
    end

    Interact.Hover(hit, function()
        if el.Disabled then return end
        Anim.Spring(knob, "Size", UDim2.fromOffset(18, 18), Anim.Springs.Snappy)
        Anim.Tween(track, { Size = UDim2.new(1, 0, 0, 8) }, 0.15)
    end, function()
        if not dragging then
            Anim.Spring(knob, "Size", UDim2.fromOffset(14, 14), Anim.Springs.Snappy)
            Anim.Tween(track, { Size = UDim2.new(1, 0, 0, 6) }, 0.2)
        end
    end)

    Interact.Drag(hit, function(pos)
        if el.Disabled then return end
        dragging = true
        showBubble(true)
        setFromRatio((pos.X - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1))
    end, function(pos)
        if not dragging then return end
        setFromRatio((pos.X - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1))
    end, function()
        dragging = false
        showBubble(false)
        Anim.Spring(knob, "Size", UDim2.fromOffset(14, 14), Anim.Springs.Snappy)
        Anim.Tween(track, { Size = UDim2.new(1, 0, 0, 6) }, 0.2)
    end)

    box.Focused:Connect(function()
        Anim.Tween(boxStroke, { Color = Theme.Current.Accent, Transparency = 0.15 }, 0.18)
    end)
    box.FocusLost:Connect(function()
        Anim.Tween(boxStroke, { Color = Theme.Current.Stroke, Transparency = Theme.Current.StrokeTransparency }, 0.2)
        local txt = box.Text
        if prefix ~= "" and txt:sub(1, #prefix) == prefix then txt = txt:sub(#prefix + 1) end
        if suffix ~= "" and txt:sub(-#suffix) == suffix then txt = txt:sub(1, #txt - #suffix) end
        local n = tonumber(txt)
        if n then el:Set(n) else box.Text = fmt(value) end
    end)

    el.Value = value
    if el.Flag then Library.Flags[el.Flag] = value end
    visual(true)
    return el
end

-- ── Progress bar ────────────────────────────────────────────────────────────

-- Section:AddProgress({ Text, Min, Max, Value, Suffix, Indeterminate })
function Section:AddProgress(opts)
    opts = opts or {}
    local el, row = self:_Make("Progress", opts, 46)
    local min, max = opts.Min or 0, opts.Max or 1
    local value = opts.Value or 0
    local indeterminate = opts.Indeterminate == true
    rowLabel(el, row, el.Text, 12, 90)
    local pct = New("TextLabel", {
        AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 0), Size = UDim2.fromOffset(70, 28),
        Font = Fonts.Semibold, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Right, Parent = row,
        Theme = { TextColor3 = "SubText" },
    })
    local track = New("Frame", {
        Position = UDim2.fromOffset(12, 30), Size = UDim2.new(1, -24, 0, 6), Parent = row, ClipsDescendants = true,
        Theme = { BackgroundColor3 = "TrackOff", BackgroundTransparency = "TrackOffTransparency" },
    }, { Corner(UDim.new(0.5, 0)) })
    local fill = New("Frame", {
        Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.new(1, 1, 1), Parent = track, ClipsDescendants = true,
    }, { Corner(UDim.new(0.5, 0)), AccentGradient(0) })
    local shimmer = New("Frame", {
        Size = UDim2.new(0, 40, 1, 0), Position = UDim2.new(-0.3, 0, 0, 0), BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 0.6, Parent = fill,
    })
    local sg = Instance.new("UIGradient")
    sg.Transparency = ns(0, 1, 0.5, 0, 1, 1)
    sg.Parent = shimmer
    local shimmerLoop = Anim.Every(function(dt, now)
        local p = (now * 0.7) % 1.6 - 0.3
        shimmer.Position = UDim2.new(p, 0, 0, 0)
        if indeterminate then
            local c = (now * 0.9) % 1.4 - 0.2
            fill.Position = UDim2.fromScale(c, 0)
            fill.Size = UDim2.fromScale(0.35, 1)
        end
    end)
    el.Maid:Give(shimmerLoop)

    local function visual()
        if indeterminate then
            pct.Text = "..."
            return
        end
        local r = (max == min) and 0 or U.Clamp((value - min) / (max - min), 0, 1)
        fill.Position = UDim2.fromScale(0, 0)
        Anim.Spring(fill, "Size", UDim2.fromScale(r, 1), Anim.Springs.Smooth)
        pct.Text = (opts.Suffix and (U.FormatNumber(value, opts.Decimals) .. opts.Suffix)) or (math.floor(r * 100 + 0.5) .. "%")
    end
    function el:Set(v)
        value = v
        indeterminate = false
        visual()
        el:_Commit(value)
    end
    function el:SetIndeterminate(state)
        indeterminate = state
        if not state then fill.Position = UDim2.fromScale(0, 0) end
        visual()
    end
    function el:Get() return value end
    visual()
    return el
end

-- ════════════════════════════════════════════════════════════════════════════
--  SECTION 7 — ADVANCED ELEMENTS
--  Dropdown • MultiDropdown • Textbox • Keybind • ColorPicker (+ addons)
-- ════════════════════════════════════════════════════════════════════════════

-- Shared helper: animated expanding panel inside an element holder.
local function makePanel(el, height)
    local panel = New("Frame", {
        Name = "Panel", Size = UDim2.new(1, 0, 0, 0), ClipsDescendants = true, Visible = false, LayoutOrder = 2,
        Parent = el.Holder,
        Theme = { BackgroundColor3 = "Surface", BackgroundTransparency = "SurfaceTransparency" },
    }, { Corner(10), Stroke(1) })
    local api = { Frame = panel, Open = false }
    function api:SetOpen(state, targetHeight)
        api.Open = state
        if state then
            panel.Visible = true
            Anim.Spring(panel, "Size", UDim2.new(1, 0, 0, targetHeight or height or 100), { Stiffness = 260, Ratio = 0.82 })
        else
            Anim.Spring(panel, "Size", UDim2.new(1, 0, 0, 0), {
                Stiffness = 300, Ratio = 0.95,
                Done = function()
                    if not api.Open then panel.Visible = false end
                end,
            })
        end
    end
    function api:Resize(h)
        if api.Open then
            Anim.Spring(panel, "Size", UDim2.new(1, 0, 0, h), { Stiffness = 300, Ratio = 0.9 })
        end
    end
    return api
end

-- ── Dropdown / MultiDropdown ────────────────────────────────────────────────

local ITEM_H = 28

local function buildDropdown(section, opts, multi)
    opts = opts or {}
    local el, row = section:_Make(multi and "MultiDropdown" or "Dropdown", opts, 38)
    local values = U.DeepCopy(opts.Values or {})
    local maxVisible = opts.MaxVisible or 6
    local searchable = opts.Searchable == true
    local showBar = multi and opts.SelectAll ~= false
    local minSel, maxSel = opts.Min or 0, opts.Max or math.huge
    local selected = nil
    local map = {}
    local itemRefs = {}
    local filter = ""

    -- label + value
    local label = New("TextLabel", {
        Name = "Label", Text = el.Text, Font = Fonts.Medium, TextSize = 13, Position = UDim2.fromOffset(12, 0),
        Size = UDim2.new(0.45, -12, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row, Theme = { TextColor3 = "Text" },
    })
    el.Label = label
    local valueLabel = New("TextLabel", {
        Name = "Value", Text = "None", Font = Fonts.Medium, TextSize = 12, AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -36, 0, 0), Size = UDim2.new(0.55, -46, 1, 0), TextXAlignment = Enum.TextXAlignment.Right,
        TextTruncate = Enum.TextTruncate.AtEnd, Parent = row, Theme = { TextColor3 = "SubText" },
    })
    local chevron = Icons.Create("chevron", 14)
    chevron.AnchorPoint = Vector2.new(0.5, 0.5)
    chevron.Position = UDim2.new(1, -20, 0.5, 0)
    chevron.Parent = row
    Icons.Bind(chevron, "SubText")

    -- panel
    local panel = makePanel(el)
    local pf = panel.Frame

    local searchBox
    if searchable then
        searchBox = New("TextBox", {
            Size = UDim2.new(1, -16, 0, 26), Position = UDim2.fromOffset(8, 8), PlaceholderText = "Search...", Font = Fonts.Medium,
            TextSize = 12, ClearTextOnFocus = false, Parent = pf,
            Theme = { TextColor3 = "Text", PlaceholderColor3 = "Muted", BackgroundColor3 = "Surface", BackgroundTransparency = "SurfaceTransparency" },
        }, { Corner(7), Pad(9, 0, 9, 0), Stroke(1) })
        searchBox.BackgroundTransparency = Theme.Current.SurfaceTransparency
    end

    local barY = 8 + (searchable and 34 or 0)
    local selectAllBtn, clearBtn
    if showBar then
        local bar = New("Frame", { Size = UDim2.new(1, -16, 0, 24), Position = UDim2.fromOffset(8, barY), BackgroundTransparency = 1, Parent = pf },
            { List(6, Enum.FillDirection.Horizontal) })
        local function mini(text, order)
            local b = New("TextButton", {
                Size = UDim2.new(0.5, -3, 1, 0), Text = text, Font = Fonts.Semibold, TextSize = 11, LayoutOrder = order, Parent = bar,
                ClipsDescendants = true, Theme = { TextColor3 = "SubText", BackgroundColor3 = "Surface", BackgroundTransparency = "SurfaceTransparency" },
            }, { Corner(7), Stroke(1) })
            b.BackgroundTransparency = Theme.Current.SurfaceTransparency
            Interact.Hover(b, function() Anim.Tween(b, { TextColor3 = Theme.Current.Text }, 0.12) end,
                function() Anim.Tween(b, { TextColor3 = Theme.Current.SubText }, 0.15) end)
            return b
        end
        selectAllBtn = mini("Select all", 1)
        clearBtn = mini("Clear", 2)
    end

    local listY = barY + (showBar and 30 or 0)
    local list = New("ScrollingFrame", {
        Name = "List", Position = UDim2.fromOffset(6, listY), Size = UDim2.new(1, -12, 0, 0), ScrollBarThickness = 2, Parent = pf,
        Theme = { ScrollBarImageColor3 = "Accent" },
    }, { List(2) })

    local function visibleCount()
        local n = 0
        for _, v in ipairs(values) do
            if filter == "" or string.find(string.lower(tostring(v)), filter, 1, true) then n = n + 1 end
        end
        return n
    end
    local function listHeight()
        return math.min(math.max(visibleCount(), 1), maxVisible) * (ITEM_H + 2)
    end
    local function panelHeight()
        return listY + listHeight() + 8
    end

    -- value text
    local function selectedList()
        local out = {}
        for _, v in ipairs(values) do
            if map[v] then out[#out + 1] = v end
        end
        return out
    end
    local function refreshText()
        if multi then
            local sel = selectedList()
            if #sel == 0 then
                valueLabel.Text = "None"
            elseif #sel <= 2 then
                valueLabel.Text = table.concat(sel, ", ")
            else
                valueLabel.Text = sel[1] .. ", " .. sel[2] .. " +" .. (#sel - 2)
            end
        else
            valueLabel.Text = selected ~= nil and tostring(selected) or "None"
        end
    end

    local function refreshItemVisual(name, instant)
        local ref = itemRefs[name]
        if not ref then return end
        local on = multi and map[name] or (not multi and selected == name)
        local d = instant and 0 or 0.18
        Anim.Tween(ref.label, { TextColor3 = on and Theme.Current.Accent or Theme.Current.Text }, d)
        Anim.Tween(ref.bg, { BackgroundTransparency = on and 0.86 or 1 }, d)
        Icons.SetTransparency(ref.check, on and 0 or 1, d)
        if on then
            Anim.Spring(ref.checkScale, "Scale", 1, Anim.Springs.Bouncy)
        else
            Anim.Spring(ref.checkScale, "Scale", 0.4, Anim.Springs.Stiff)
        end
    end

    local function applyFilter()
        for _, v in ipairs(values) do
            local ref = itemRefs[v]
            if ref then
                ref.btn.Visible = filter == "" or string.find(string.lower(tostring(v)), filter, 1, true) ~= nil
            end
        end
        list.Size = UDim2.new(1, -12, 0, listHeight())
        panel:Resize(panelHeight())
    end

    local function commit(silent)
        refreshText()
        if multi then
            local copy = {}
            for k, v in pairs(map) do copy[k] = v end
            el:_Commit(copy, silent)
        else
            el:_Commit(selected, silent)
        end
    end

    local function selectedCount()
        local n = 0
        for _, v in pairs(map) do if v then n = n + 1 end end
        return n
    end

    local function onItemClick(name)
        if el.Disabled then return end
        if multi then
            local on = map[name]
            if on and selectedCount() <= minSel then
                Anim.Shake(itemRefs[name].btn, 3, 0.2)
                return
            end
            if not on and selectedCount() >= maxSel then
                Anim.Shake(itemRefs[name].btn, 3, 0.2)
                return
            end
            map[name] = (not on) or nil
            refreshItemVisual(name)
            commit()
        else
            local prev = selected
            if selected == name and opts.AllowNone then
                selected = nil
            else
                selected = name
            end
            if prev then refreshItemVisual(prev) end
            refreshItemVisual(name)
            commit()
            if opts.CloseOnSelect ~= false then
                el:SetOpen(false)
            end
        end
    end

    local function buildItems()
        for _, ref in pairs(itemRefs) do ref.btn:Destroy() end
        itemRefs = {}
        for i, name in ipairs(values) do
            local btn = New("TextButton", {
                Name = "Item", Size = UDim2.new(1, -6, 0, ITEM_H), Text = "", LayoutOrder = i, Parent = list, ClipsDescendants = true,
            })
            local bg = New("Frame", {
                Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = btn, Theme = { BackgroundColor3 = "Accent" },
            }, { Corner(7) })
            local lbl = New("TextLabel", {
                Text = tostring(name), Font = Fonts.Medium, TextSize = 12, Position = UDim2.fromOffset(10, 0),
                Size = UDim2.new(1, -36, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = btn, Theme = { TextColor3 = "Text" },
            })
            local check = Icons.Create(multi and "check" or "check", 14)
            check.AnchorPoint = Vector2.new(1, 0.5)
            check.Position = UDim2.new(1, -8, 0.5, 0)
            check.Parent = btn
            Theme.BindFn(check, function(t) Icons.SetColor(check, t.Accent, 0) end)
            Icons.SetTransparency(check, 1, 0)
            local cs = New("UIScale", { Scale = 0.4, Parent = check })
            local hoverBg = New("Frame", {
                Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BackgroundColor3 = Color3.new(1, 1, 1), Parent = btn, ZIndex = 0,
            }, { Corner(7) })
            Interact.Hover(btn, function() Anim.Tween(hoverBg, { BackgroundTransparency = 0.93 }, 0.1) end,
                function() Anim.Tween(hoverBg, { BackgroundTransparency = 1 }, 0.15) end)
            btn.Activated:Connect(function() onItemClick(name) end)
            itemRefs[name] = { btn = btn, label = lbl, bg = bg, check = check, checkScale = cs }
        end
        for _, name in ipairs(values) do refreshItemVisual(name, true) end
        applyFilter()
    end

    -- open / close
    el.IsOpen = false
    function el:SetOpen(state)
        if el.Disabled and state then return end
        el.IsOpen = state
        Anim.Tween(chevron, { Rotation = state and 180 or 0 }, 0.3, "OutBack")
        Icons.SetColor(chevron, state and Theme.Current.Accent or Theme.Current.SubText, 0.2)
        if state then
            list.Size = UDim2.new(1, -12, 0, listHeight())
            panel:SetOpen(true, panelHeight())
            -- items cascade in
            local i = 0
            for _, v in ipairs(values) do
                local ref = itemRefs[v]
                if ref and ref.btn.Visible then
                    i = i + 1
                    if i <= 10 then
                        ref.label.TextTransparency = 1
                        Anim.Tween(ref.label, { TextTransparency = 0 }, 0.25, "OutQuad", 0.03 * i)
                    end
                end
            end
        else
            panel:SetOpen(false)
            if searchBox then searchBox.Text = "" end
        end
    end
    row.Activated:Connect(function()
        if el.Disabled then return end
        el:SetOpen(not el.IsOpen)
    end)

    if searchBox then
        searchBox:GetPropertyChangedSignal("Text"):Connect(function()
            filter = string.lower(searchBox.Text)
            applyFilter()
        end)
    end

    if multi then
        selectAllBtn.Activated:Connect(function()
            local count = 0
            for _, v in ipairs(values) do
                if count < maxSel then map[v] = true count = count + 1 end
            end
            for _, v in ipairs(values) do refreshItemVisual(v) end
            commit()
        end)
        clearBtn.Activated:Connect(function()
            local keep = 0
            for _, v in ipairs(values) do
                if keep < minSel and map[v] then keep = keep + 1 else map[v] = nil end
            end
            for _, v in ipairs(values) do refreshItemVisual(v) end
            commit()
        end)
    end

    -- API
    function el:Set(v, silent)
        if multi then
            map = {}
            if type(v) == "table" then
                for k, val in pairs(v) do
                    if type(k) == "number" then
                        if U.Find(values, val) then map[val] = true end
                    elseif val and U.Find(values, k) then
                        map[k] = true
                    end
                end
            end
            for _, name in ipairs(values) do refreshItemVisual(name) end
        else
            local prev = selected
            if v ~= nil and U.Find(values, v) then
                selected = v
            elseif type(v) == "number" and values[v] then
                selected = values[v]
            elseif v == nil and opts.AllowNone then
                selected = nil
            else
                return
            end
            if prev then refreshItemVisual(prev) end
            if selected then refreshItemVisual(selected) end
        end
        commit(silent)
    end

    function el:SetValues(newValues, keepSelection)
        values = U.DeepCopy(newValues or {})
        if multi then
            if keepSelection then
                for k in pairs(map) do if not U.Find(values, k) then map[k] = nil end end
            else
                map = {}
            end
        else
            if not keepSelection or not U.Find(values, selected) then
                selected = (opts.AllowNone and nil) or values[1]
            end
        end
        buildItems()
        refreshText()
        if el.IsOpen then panel:Resize(panelHeight()) end
        commit(true)
    end
    el.Refresh = el.SetValues

    function el:GetList()
        return multi and selectedList() or { selected }
    end
    function el:Get()
        if multi then
            local copy = {}
            for k, v in pairs(map) do copy[k] = v end
            return copy
        end
        return selected
    end
    function el:Serialize()
        if multi then return selectedList() end
        return selected
    end
    function el:Deserialize(data)
        el:Set(data, false)
    end

    -- defaults
    if multi then
        local d = opts.Default
        if type(d) == "table" then
            for k, v in pairs(d) do
                if type(k) == "number" then map[v] = true elseif v then map[k] = true end
            end
        end
    else
        local d = opts.Default
        if type(d) == "number" and values[d] then selected = values[d]
        elseif d ~= nil and U.Find(values, d) then selected = d
        elseif not opts.AllowNone then selected = values[1] end
    end
    buildItems()
    refreshText()
    el.Value = multi and el:Get() or selected
    if el.Flag then Library.Flags[el.Flag] = el.Value end
    return el
end

function Section:AddDropdown(opts)
    return buildDropdown(self, opts, opts and opts.Multi == true)
end

function Section:AddMultiDropdown(opts)
    return buildDropdown(self, opts, true)
end

-- ── Textbox ─────────────────────────────────────────────────────────────────

-- Section:AddTextbox({ Flag, Text, Default, Placeholder, Numeric, Min, Max, Live, MaxLength, Callback })
function Section:AddTextbox(opts)
    opts = opts or {}
    local el, row = self:_Make("Textbox", opts, 58)
    local numeric = opts.Numeric == true
    local value = opts.Default
    if value == nil then value = numeric and 0 or "" end

    local label = New("TextLabel", {
        Text = el.Text, Font = Fonts.Medium, TextSize = 13, Position = UDim2.fromOffset(12, 5), Size = UDim2.new(1, -24, 0, 18),
        TextTruncate = Enum.TextTruncate.AtEnd, Parent = row, Theme = { TextColor3 = "Text" },
    })
    el.Label = label

    local field = New("Frame", {
        Position = UDim2.fromOffset(10, 28), Size = UDim2.new(1, -20, 0, 24), Parent = row,
        Theme = { BackgroundColor3 = "Surface", BackgroundTransparency = "SurfaceTransparency" }, ClipsDescendants = true,
    }, { Corner(8) })
    field.BackgroundTransparency = Theme.Current.SurfaceTransparency
    local fStroke = Stroke(1)
    fStroke.Parent = field
    local box = New("TextBox", {
        Size = UDim2.new(1, -16, 1, 0), Position = UDim2.fromOffset(8, 0), Text = tostring(value), PlaceholderText = opts.Placeholder or "",
        Font = Fonts.Medium, TextSize = 12, ClearTextOnFocus = opts.ClearOnFocus == true, Parent = field,
        Theme = { TextColor3 = "Text", PlaceholderColor3 = "Muted" },
    })
    if opts.MaxLength then box.MaxVisibleGraphemes = opts.MaxLength end

    -- animated underline glow
    local glow = New("Frame", {
        AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, 0), Size = UDim2.new(0, 0, 0, 2), BackgroundColor3 = Color3.new(1, 1, 1),
        Parent = field,
    }, { AccentGradient(0) })

    box.Focused:Connect(function()
        Anim.Tween(glow, { Size = UDim2.new(1, 0, 0, 2) }, 0.3, "OutCubic")
        Anim.Tween(fStroke, { Color = Theme.Current.Accent, Transparency = 0.3 }, 0.2)
    end)
    box.FocusLost:Connect(function(enter)
        Anim.Tween(glow, { Size = UDim2.new(0, 0, 0, 2) }, 0.25, "InCubic")
        Anim.Tween(fStroke, { Color = Theme.Current.Stroke, Transparency = Theme.Current.StrokeTransparency }, 0.2)
        local text = box.Text
        if opts.MaxLength and #text > opts.MaxLength then text = text:sub(1, opts.MaxLength) end
        if numeric then
            local n = tonumber(text)
            if n == nil then
                box.Text = tostring(value)
                Anim.Shake(field, 3, 0.25)
                return
            end
            if opts.Min then n = math.max(n, opts.Min) end
            if opts.Max then n = math.min(n, opts.Max) end
            value = n
            box.Text = tostring(n)
        else
            value = text
            box.Text = text
        end
        el:_Commit(value)
        if opts.Finished then U.SafeCall(opts.Finished, value, enter) end
    end)
    if opts.Live then
        box:GetPropertyChangedSignal("Text"):Connect(function()
            if numeric then
                local n = tonumber(box.Text)
                if n then value = n el:_Commit(value) end
            else
                value = box.Text
                el:_Commit(value)
            end
        end)
    end

    function el:Set(v, silent)
        value = v
        box.Text = tostring(v)
        el:_Commit(value, silent)
    end
    function el:Get() return value end
    function el:Focus() box:CaptureFocus() end

    el.Value = value
    if el.Flag then Library.Flags[el.Flag] = value end
    return el
end

-- ── Keybind ─────────────────────────────────────────────────────────────────

local function hookKeybinds()
    if Library._kbHooked then return end
    Library._kbHooked = true
    RootMaid:Give(S.UserInputService.InputBegan:Connect(function(input, gp)
        if Library.Unloaded or Library._kbListening or gp then return end
        local list = Library.Keybinds
        for i = 1, #list do
            local kb = list[i]
            if kb and kb._OnInput then kb:_OnInput(input, true) end
        end
    end))
    RootMaid:Give(S.UserInputService.InputEnded:Connect(function(input)
        if Library.Unloaded then return end
        local list = Library.Keybinds
        for i = 1, #list do
            local kb = list[i]
            if kb and kb._OnInput then kb:_OnInput(input, false) end
        end
    end))
end

local KEY_MODES = { "Toggle", "Hold", "Always" }
local KEY_MODE_TAG = { Toggle = "T", Hold = "H", Always = "A" }

local function parseKey(name, ktype)
    if not name or name == "None" then return "None" end
    local enum = ktype == "UserInputType" and Enum.UserInputType or Enum.KeyCode
    local ok, v = pcall(function() return enum[name] end)
    if ok and v then return v end
    return "None"
end

local function makeKeybind(host, opts)
    opts = opts or {}
    hookKeybinds()
    local kb = setmetatable({}, Element)
    kb.Kind = "KeybindWidget"
    kb.Section, kb.Window, kb.Options = host.Section, host.Window, opts
    kb.Changed = Signal.new()
    kb.Maid = Maid.new()
    kb.Name = opts.Text or opts.Name or host.Text or "Keybind"
    kb.Key = opts.Default or "None"
    kb.Mode = opts.Mode or "Toggle"
    kb.Flag = opts.Flag or (host.Flag and (host.Flag .. "_Bind")) or nil
    kb.Callback = opts.Callback
    kb.HideInList = opts.HideInList == true
    kb.Host = (host.Kind ~= "Keybind") and host or nil
    kb.State = (kb.Mode == "Always")
    kb.Holder = host.Holder

    local listening = false

    local chip = New("TextButton", {
        Name = "KeybindChip", Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X, Text = "", AutoButtonColor = false,
        LayoutOrder = 5, Parent = host.Addons, ClipsDescendants = true,
        Theme = { BackgroundColor3 = "Surface", BackgroundTransparency = function(t) return math.max(t.SurfaceTransparency - 0.03, 0) end },
    }, { Corner(7), Stroke(1), List(5, Enum.FillDirection.Horizontal, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center), Pad(8, 0, 8, 0) })
    local chipStroke = chip:FindFirstChildOfClass("UIStroke")
    local keyLabel = New("TextLabel", {
        Text = "None", Font = Fonts.Semibold, TextSize = 11, Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X,
        LayoutOrder = 1, Parent = chip, TextXAlignment = Enum.TextXAlignment.Center, Theme = { TextColor3 = "SubText" },
    })
    local modeLabel = New("TextLabel", {
        Text = KEY_MODE_TAG[kb.Mode], Font = Fonts.Bold, TextSize = 9, Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X,
        LayoutOrder = 2, Parent = chip, TextXAlignment = Enum.TextXAlignment.Center, Theme = { TextColor3 = "Muted" },
    })

    local function refreshChip()
        keyLabel.Text = listening and "..." or U.KeyName(kb.Key)
        modeLabel.Text = KEY_MODE_TAG[kb.Mode] or "T"
        modeLabel.Visible = not listening and kb.Key ~= "None"
        local hot = listening or (kb.State and kb.Key ~= "None" and kb.Mode ~= "Always")
        Anim.Tween(keyLabel, { TextColor3 = hot and Theme.Current.Accent or Theme.Current.SubText }, 0.15)
        Anim.Tween(chipStroke, {
            Color = hot and Theme.Current.Accent or Theme.Current.Stroke,
            Transparency = hot and 0.2 or Theme.Current.StrokeTransparency,
        }, 0.15)
        Library:_KeybindsChanged()
    end
    kb._Refresh = refreshChip

    Tooltip.Attach(chip, function()
        return "Click: rebind  •  Right-click: mode (" .. kb.Mode .. ")  •  Backspace: clear"
    end)

    -- pulse while listening
    local pulse
    local function setListening(state)
        listening = state
        Library._kbListening = state
        if pulse then pulse.Cancel() pulse = nil end
        if state then
            pulse = Anim.Every(function(dt, now)
                chipStroke.Transparency = 0.15 + (math.sin(now * 8) * 0.5 + 0.5) * 0.5
            end)
        end
        refreshChip()
    end
    kb.Maid:Give(function() if pulse then pulse.Cancel() end end)

    function kb:GetState()
        if kb.Key == "None" then return kb.Mode == "Always" end
        return kb.State
    end

    function kb:_Fire(state)
        kb.State = state
        if kb.Host and kb.Host.Set then
            kb.Host:Set(state)
        end
        if kb.Callback then U.SafeCall(kb.Callback, state) end
        kb.Changed:Fire(state)
        refreshChip()
    end

    function kb:_OnInput(input, down)
        if listening or kb.Key == "None" then return end
        local match
        if typeof(kb.Key) == "EnumItem" then
            if kb.Key.EnumType == Enum.KeyCode then
                match = input.KeyCode == kb.Key
            else
                match = input.UserInputType == kb.Key
            end
        end
        if not match then return end
        if kb.Mode == "Toggle" then
            if down then
                local nextState
                if kb.Host and kb.Host.Get then nextState = not kb.Host:Get() else nextState = not kb.State end
                kb:_Fire(nextState)
            end
        elseif kb.Mode == "Hold" then
            kb:_Fire(down)
        end
    end

    function kb:SetKey(key, silent)
        kb.Key = key or "None"
        refreshChip()
        if kb.Flag then Library.Flags[kb.Flag] = kb.Key end
        if not silent then
            kb.Changed:Fire(kb.State)
            Library.OnFlagChanged:Fire(kb.Flag, kb.Key, kb)
        end
    end
    function kb:SetMode(mode, silent)
        if not U.Find(KEY_MODES, mode) then return end
        kb.Mode = mode
        if mode == "Always" then
            kb:_Fire(true)
        elseif mode == "Hold" then
            kb.State = false
        end
        refreshChip()
        if not silent then Library.OnFlagChanged:Fire(kb.Flag, kb.Key, kb) end
    end
    function kb:Set(v, silent)
        if type(v) == "table" then
            kb.Mode = v.Mode or kb.Mode
            kb:SetKey(parseKey(v.Key, v.Type), silent)
        else
            kb:SetKey(v, silent)
        end
    end
    function kb:Get() return kb.Key end
    function kb:Serialize()
        local name, ktype = "None", "KeyCode"
        if typeof(kb.Key) == "EnumItem" then
            name = kb.Key.Name
            ktype = tostring(kb.Key.EnumType) == "Enum.UserInputType" and "UserInputType" or "KeyCode"
        end
        return { Key = name, Type = ktype, Mode = kb.Mode }
    end
    function kb:Deserialize(data)
        if type(data) ~= "table" then return end
        kb.Mode = data.Mode or kb.Mode
        kb:SetKey(parseKey(data.Key, data.Type), true)
    end
    function kb:Destroy()
        for i, k in ipairs(Library.Keybinds) do
            if k == kb then table.remove(Library.Keybinds, i) break end
        end
        if kb.Flag then Library.Elements[kb.Flag] = nil Library.Flags[kb.Flag] = nil end
        kb.Maid:Clean()
        chip:Destroy()
        Library:_KeybindsChanged()
    end

    -- interaction
    chip.Activated:Connect(function()
        if listening then return end
        setListening(true)
        local conn
        conn = S.UserInputService.InputBegan:Connect(function(input, gp)
            local t = input.UserInputType
            if t == Enum.UserInputType.Keyboard then
                conn:Disconnect()
                if input.KeyCode == Enum.KeyCode.Escape then
                    setListening(false)
                elseif input.KeyCode == Enum.KeyCode.Backspace or input.KeyCode == Enum.KeyCode.Delete then
                    setListening(false)
                    kb:SetKey("None")
                else
                    setListening(false)
                    kb:SetKey(input.KeyCode)
                end
            elseif t == Enum.UserInputType.MouseButton2 or t == Enum.UserInputType.MouseButton3 then
                conn:Disconnect()
                task.defer(function()
                    setListening(false)
                    kb:SetKey(t)
                end)
            end
        end)
        task.delay(8, function()
            if listening then
                if conn then conn:Disconnect() end
                setListening(false)
            end
        end)
    end)
    chip.MouseButton2Click:Connect(function()
        if listening then return end
        local idx = U.Find(KEY_MODES, kb.Mode) or 1
        kb:SetMode(KEY_MODES[(idx % #KEY_MODES) + 1])
        Anim.Shake(chip, 2, 0.2)
    end)

    table.insert(Library.Keybinds, kb)
    if kb.Flag then
        Library.Elements[kb.Flag] = kb
        Library.Flags[kb.Flag] = kb.Key
    end
    refreshChip()
    return kb
end

-- Section:AddKeybind({ Flag, Text, Default = Enum.KeyCode.X, Mode = "Toggle"|"Hold"|"Always", Callback })
function Section:AddKeybind(opts)
    opts = opts or {}
    local rowOpts = U.Merge(opts, { Flag = false })
    local el, row = self:_Make("Keybind", rowOpts, 38)
    rowLabel(el, row, el.Text, 12, 110)
    rowAddons(el, row, 12)
    local kb = makeKeybind(el, opts)
    el.Binding = kb
    function el:Set(v, silent) kb:Set(v, silent) end
    function el:Get() return kb.Key end
    function el:GetState() return kb:GetState() end
    function el:SetMode(m) kb:SetMode(m) end
    function el:OnClick(fn) return kb.Changed:Connect(fn) end
    function el:OnChanged(fn) return kb.Changed:Connect(fn) end
    row.Activated:Connect(function() end)
    return el
end

-- Any element with an Addons container can host a keybind or a colour picker:
--   toggle:AddKeybind({ Default = Enum.KeyCode.F })
--   toggle:AddColorPicker({ Default = Color3.new(1,0,0) })
function Element:AddKeybind(opts)
    if not self.Addons then
        warn("[CrystalUI] this element cannot host a keybind")
        return nil
    end
    local kb = makeKeybind(self, opts)
    self.Binding = kb
    return kb
end

-- ── Colour picker ───────────────────────────────────────────────────────────

local function makeColorPicker(host, opts)
    opts = opts or {}
    local cp = setmetatable({}, Element)
    cp.Kind = "ColorWidget"
    cp.Section, cp.Window, cp.Options = host.Section, host.Window, opts
    cp.Changed = Signal.new()
    cp.Maid = Maid.new()
    cp.Flag = opts.Flag or (host.Flag and (host.Flag .. "_Color")) or nil
    cp.Callback = opts.Callback
    cp.Holder = host.Holder
    cp.Text = opts.Text or host.Text or "Color"

    local useAlpha = opts.Alpha == true or opts.Transparency == true
    local default = opts.Default or Color3.fromRGB(255, 255, 255)
    local h, s, v = default:ToHSV()
    local alpha = opts.DefaultAlpha or 1
    local rainbow = opts.Rainbow == true
    local rainbowSpeed = opts.RainbowSpeed or 0.25
    local lastFire = 0

    -- swatch
    local swatch = New("TextButton", {
        Name = "Swatch", Size = UDim2.fromOffset(30, 20), Text = "", AutoButtonColor = false, LayoutOrder = 10,
        BackgroundColor3 = default, Parent = host.Addons,
    }, { Corner(6) })
    local swStroke = New("UIStroke", { Thickness = 1.2, Color = Color3.new(1, 1, 1), Transparency = 0.6, Parent = swatch })
    local swScale = New("UIScale", { Scale = 1, Parent = swatch })

    -- panel layout constants
    local PAD, SV_H, BAR_H = 10, 112, 12
    local alphaY = PAD + SV_H + 10 + BAR_H + 10
    local bottomY = useAlpha and (alphaY + BAR_H + 10) or alphaY
    local totalH = bottomY + 26 + PAD

    local panel = makePanel(cp, totalH)
    local pf = panel.Frame

    -- saturation / value square
    local sv = New("TextButton", {
        Name = "SV", Size = UDim2.new(1, -PAD * 2, 0, SV_H), Position = UDim2.fromOffset(PAD, PAD), Text = "", AutoButtonColor = false,
        BackgroundColor3 = Color3.fromHSV(h, 1, 1), Parent = pf, ClipsDescendants = true,
    }, { Corner(8) })
    local white = New("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), Parent = sv, ZIndex = 2 })
    local wg = Instance.new("UIGradient")
    wg.Transparency = ns(0, 0, 1, 1)
    wg.Parent = white
    local black = New("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), Parent = sv, ZIndex = 3 })
    local bg = Instance.new("UIGradient")
    bg.Rotation = 90
    bg.Transparency = ns(0, 1, 1, 0)
    bg.Parent = black
    local svCursor = New("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(14, 14), BackgroundTransparency = 1, ZIndex = 5, Parent = sv,
    }, { Corner(UDim.new(0.5, 0)) })
    New("UIStroke", { Thickness = 2, Color = Color3.new(1, 1, 1), Parent = svCursor })
    local svDot = New("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(2, 2),
        BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.5, ZIndex = 5, Parent = svCursor,
    }, { Corner(UDim.new(0.5, 0)) })
    local svCursorScale = New("UIScale", { Scale = 1, Parent = svCursor })

    -- hue bar
    local hueBar = New("TextButton", {
        Size = UDim2.new(1, -PAD * 2, 0, BAR_H), Position = UDim2.fromOffset(PAD, PAD + SV_H + 10), Text = "", AutoButtonColor = false,
        BackgroundColor3 = Color3.new(1, 1, 1), Parent = pf,
    }, { Corner(UDim.new(0.5, 0)) })
    local hg = Instance.new("UIGradient")
    local hueKeys = {}
    for i = 0, 6 do hueKeys[#hueKeys + 1] = ColorSequenceKeypoint.new(i / 6, Color3.fromHSV(i / 6, 1, 1)) end
    hg.Color = ColorSequence.new(hueKeys)
    hg.Parent = hueBar
    local hueHandle = New("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(h, 0, 0.5, 0), Size = UDim2.fromOffset(16, 16),
        BackgroundColor3 = Color3.new(1, 1, 1), ZIndex = 3, Parent = hueBar,
    }, { Corner(UDim.new(0.5, 0)) })
    local hueScale = New("UIScale", { Scale = 1, Parent = hueHandle })
    New("UIStroke", { Thickness = 1, Color = Color3.new(0, 0, 0), Transparency = 0.7, Parent = hueHandle })

    -- alpha bar
    local alphaBar, alphaHandle, alphaFill
    if useAlpha then
        alphaBar = New("TextButton", {
            Size = UDim2.new(1, -PAD * 2, 0, BAR_H), Position = UDim2.fromOffset(PAD, alphaY), Text = "", AutoButtonColor = false,
            BackgroundColor3 = Color3.fromRGB(70, 74, 90), Parent = pf,
        }, { Corner(UDim.new(0.5, 0)) })
        alphaFill = New("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = default, Parent = alphaBar }, { Corner(UDim.new(0.5, 0)) })
        local ag = Instance.new("UIGradient")
        ag.Transparency = ns(0, 0, 1, 1)
        ag.Parent = alphaFill
        alphaHandle = New("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(alpha, 0, 0.5, 0), Size = UDim2.fromOffset(16, 16),
            BackgroundColor3 = Color3.new(1, 1, 1), ZIndex = 3, Parent = alphaBar,
        }, { Corner(UDim.new(0.5, 0)) })
        New("UIStroke", { Thickness = 1, Color = Color3.new(0, 0, 0), Transparency = 0.7, Parent = alphaHandle })
    end

    -- bottom row: hex, copy, rainbow
    local hexBox = New("TextBox", {
        Size = UDim2.fromOffset(86, 26), Position = UDim2.fromOffset(PAD, bottomY), Font = Fonts.Mono, TextSize = 12,
        Text = "#FFFFFF", ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Center, Parent = pf,
        Theme = { TextColor3 = "Text", BackgroundColor3 = "Surface", BackgroundTransparency = "SurfaceTransparency" },
    }, { Corner(7), Stroke(1) })
    hexBox.BackgroundTransparency = Theme.Current.SurfaceTransparency
    local copyBtn = New("TextButton", {
        Size = UDim2.fromOffset(26, 26), Position = UDim2.fromOffset(PAD + 92, bottomY), Text = "", Parent = pf, AutoButtonColor = false,
        Theme = { BackgroundColor3 = "Surface", BackgroundTransparency = "SurfaceTransparency" },
    }, { Corner(7), Stroke(1) })
    copyBtn.BackgroundTransparency = Theme.Current.SurfaceTransparency
    local copyIcon = Icons.Create("copy", 14)
    copyIcon.AnchorPoint = Vector2.new(0.5, 0.5)
    copyIcon.Position = UDim2.fromScale(0.5, 0.5)
    copyIcon.Parent = copyBtn
    Icons.Bind(copyIcon, "SubText")

    local rainbowBtn = New("TextButton", {
        AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -PAD, 0, bottomY), Size = UDim2.fromOffset(92, 26), Text = "",
        Parent = pf, AutoButtonColor = false, ClipsDescendants = true,
        Theme = { BackgroundColor3 = "Surface", BackgroundTransparency = "SurfaceTransparency" },
    }, { Corner(7), Stroke(1) })
    rainbowBtn.BackgroundTransparency = Theme.Current.SurfaceTransparency
    local rbDot = New("Frame", {
        AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 9, 0.5, 0), Size = UDim2.fromOffset(10, 10),
        BackgroundColor3 = Color3.new(1, 1, 1), Parent = rainbowBtn,
    }, { Corner(UDim.new(0.5, 0)) })
    local rbg = Instance.new("UIGradient")
    rbg.Color = ColorSequence.new(hueKeys)
    rbg.Parent = rbDot
    local rbLabel = New("TextLabel", {
        Text = "Rainbow", Font = Fonts.Semibold, TextSize = 11, Position = UDim2.fromOffset(26, 0), Size = UDim2.new(1, -30, 1, 0),
        Parent = rainbowBtn, Theme = { TextColor3 = "SubText" },
    })

    -- ── state helpers ───────────────────────────────────────────────────────
    local function currentColor() return Color3.fromHSV(h, s, v) end

    local function visuals(skipHue)
        local c = currentColor()
        sv.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
        svCursor.Position = UDim2.fromScale(s, 1 - v)
        hueHandle.Position = UDim2.new(h, 0, 0.5, 0)
        hueHandle.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
        svCursor.BackgroundColor3 = c
        swatch.BackgroundColor3 = c
        if alphaFill then
            alphaFill.BackgroundColor3 = c
            alphaHandle.Position = UDim2.new(alpha, 0, 0.5, 0)
        end
        if not hexBox:IsFocused() then hexBox.Text = U.ToHex(c) end
        swatch.BackgroundTransparency = useAlpha and (1 - alpha) * 0.85 or 0
    end

    local function commit(silent, throttle)
        local c = currentColor()
        cp.Value = c
        cp.Alpha = alpha
        if cp.Flag then Library.Flags[cp.Flag] = c end
        if silent then return end
        if throttle then
            local now = os.clock()
            if now - lastFire < 0.05 then return end
            lastFire = now
        end
        if cp.Callback then U.SafeCall(cp.Callback, c, alpha) end
        cp.Changed:Fire(c, alpha)
        Library.OnFlagChanged:Fire(cp.Flag, c, cp)
    end

    function cp:Set(color, a, silent)
        if typeof(color) == "table" then
            h, s, v = color.H or h, color.S or s, color.V or v
            alpha = color.A or alpha
            rainbow = color.Rainbow == true
        elseif typeof(color) == "Color3" then
            h, s, v = color:ToHSV()
            if a then alpha = a end
        end
        visuals()
        commit(silent)
    end
    function cp:Get() return currentColor() end
    function cp:GetAlpha() return alpha end
    function cp:SetRainbow(state) rainbow = state cp:_RainbowVisual() end
    function cp:Serialize()
        return { H = h, S = s, V = v, A = alpha, Rainbow = rainbow }
    end
    function cp:Deserialize(data)
        if type(data) ~= "table" then return end
        h, s, v, alpha = data.H or h, data.S or s, data.V or v, data.A or alpha
        rainbow = data.Rainbow == true
        visuals()
        cp:_RainbowVisual()
        commit(false)
    end

    function cp:_RainbowVisual()
        Anim.Tween(rbLabel, { TextColor3 = rainbow and Theme.Current.Accent or Theme.Current.SubText }, 0.15)
    end

    -- ── interaction ─────────────────────────────────────────────────────────
    local function svFrom(pos)
        s = U.Clamp((pos.X - sv.AbsolutePosition.X) / math.max(sv.AbsoluteSize.X, 1), 0, 1)
        v = 1 - U.Clamp((pos.Y - sv.AbsolutePosition.Y) / math.max(sv.AbsoluteSize.Y, 1), 0, 1)
        visuals()
        commit(false, true)
    end
    Interact.Drag(sv, function(pos)
        rainbow = false cp:_RainbowVisual()
        Anim.Spring(svCursorScale, "Scale", 1.25, Anim.Springs.Snappy)
        svFrom(pos)
    end, svFrom, function()
        Anim.Spring(svCursorScale, "Scale", 1, Anim.Springs.Bouncy)
        commit(false)
    end)

    local function hueFrom(pos)
        h = U.Clamp((pos.X - hueBar.AbsolutePosition.X) / math.max(hueBar.AbsoluteSize.X, 1), 0, 0.999)
        visuals()
        commit(false, true)
    end
    Interact.Drag(hueBar, function(pos)
        rainbow = false cp:_RainbowVisual()
        Anim.Spring(hueScale, "Scale", 1.25, Anim.Springs.Snappy)
        hueFrom(pos)
    end, hueFrom, function()
        Anim.Spring(hueScale, "Scale", 1, Anim.Springs.Bouncy)
        commit(false)
    end)

    if alphaBar then
        local function alphaFrom(pos)
            alpha = U.Clamp((pos.X - alphaBar.AbsolutePosition.X) / math.max(alphaBar.AbsoluteSize.X, 1), 0, 1)
            visuals()
            commit(false, true)
        end
        Interact.Drag(alphaBar, alphaFrom, alphaFrom, function() commit(false) end)
    end

    hexBox.FocusLost:Connect(function()
        local c = U.FromHex(hexBox.Text)
        if c then
            h, s, v = c:ToHSV()
            rainbow = false
            cp:_RainbowVisual()
            visuals()
            commit(false)
        else
            hexBox.Text = U.ToHex(currentColor())
            Anim.Shake(hexBox, 3, 0.25)
        end
    end)

    copyBtn.Activated:Connect(function()
        local hex = U.ToHex(currentColor())
        if Compat.setclipboard then
            pcall(Compat.setclipboard, hex)
            Library:Notify({ Title = "Copied", Content = hex, Type = "success", Duration = 2 })
        else
            Library:Notify({ Title = "Clipboard unavailable", Content = hex, Type = "warning", Duration = 3 })
        end
    end)

    rainbowBtn.Activated:Connect(function()
        rainbow = not rainbow
        cp:_RainbowVisual()
    end)

    local rainbowLoop = Anim.Every(function(dt, now)
        if rainbow then
            h = (now * rainbowSpeed) % 1
            if s < 0.4 then s = 0.85 end
            if v < 0.4 then v = 1 end
            visuals()
            commit(false, true)
        end
    end)
    cp.Maid:Give(rainbowLoop)

    -- panel toggle
    local open = false
    swatch.Activated:Connect(function()
        if host.Disabled then return end
        open = not open
        panel:SetOpen(open, totalH)
        Anim.Spring(swScale, "Scale", open and 1.12 or 1, Anim.Springs.Bouncy)
        Anim.Tween(swStroke, { Transparency = open and 0.1 or 0.6 }, 0.2)
    end)
    Interact.Hover(swatch, function() Anim.Spring(swScale, "Scale", 1.12, Anim.Springs.Snappy) end,
        function() Anim.Spring(swScale, "Scale", open and 1.12 or 1, Anim.Springs.Snappy) end)

    function cp:Destroy()
        if cp.Flag then Library.Elements[cp.Flag] = nil Library.Flags[cp.Flag] = nil end
        cp.Maid:Clean()
        swatch:Destroy()
        panel.Frame:Destroy()
    end

    visuals()
    cp:_RainbowVisual()
    cp.Value = currentColor()
    cp.Alpha = alpha
    if cp.Flag then
        Library.Elements[cp.Flag] = cp
        Library.Flags[cp.Flag] = cp.Value
    end
    return cp
end

-- Section:AddColorPicker({ Flag, Text, Default, Alpha = false, Rainbow = false, Callback })
function Section:AddColorPicker(opts)
    opts = opts or {}
    local rowOpts = U.Merge(opts, { Flag = false })
    local el, row = self:_Make("ColorPicker", rowOpts, 38)
    rowLabel(el, row, el.Text, 12, 110)
    rowAddons(el, row, 12)
    local cp = makeColorPicker(el, opts)
    el.Picker = cp
    function el:Set(c, a, silent) cp:Set(c, a, silent) end
    function el:Get() return cp:Get() end
    function el:GetAlpha() return cp:GetAlpha() end
    function el:SetRainbow(b) cp:SetRainbow(b) end
    function el:OnChanged(fn) return cp.Changed:Connect(fn) end
    return el
end

function Element:AddColorPicker(opts)
    if not self.Addons then
        warn("[CrystalUI] this element cannot host a colour picker")
        return nil
    end
    local cp = makeColorPicker(self, opts)
    self.Picker = cp
    return cp
end

-- ════════════════════════════════════════════════════════════════════════════
--  SECTION 8 — CONFIG SYSTEM, SETTINGS TAB, UNLOAD, PUBLIC API
-- ════════════════════════════════════════════════════════════════════════════

Library.OnUnload = Signal.new()
Library.MemoryConfigs = {}
Library.AutoloadMemory = nil

-- ── Config storage ──────────────────────────────────────────────────────────

local function cfgFolder()
    return (Library.ConfigFolder or "CrystalUI")
end

local function sanitizeName(name)
    name = U.Trim(tostring(name or ""))
    name = name:gsub("[^%w_%- ]", "_")
    return name
end

function Library:_EnsureFolders()
    if not Compat.HasFS then return false end
    local ok = pcall(function()
        local root = cfgFolder()
        if not isfolder(root) then makefolder(root) end
        if not isfolder(root .. "/configs") then makefolder(root .. "/configs") end
    end)
    return ok
end

local function cfgPath(name)
    return cfgFolder() .. "/configs/" .. name .. ".json"
end

-- Collect every flagged element into a plain table
function Library:CollectConfig()
    local data = {}
    for flag, el in pairs(Library.Elements) do
        local ignore = el.Options and el.Options.Ignore
        if not ignore and not el.Destroyed and type(el.Serialize) == "function" then
            local ok, value = pcall(el.Serialize, el)
            if ok and value ~= nil then
                data[flag] = { Type = el.Kind, Data = value }
            end
        end
    end
    return data
end

function Library:ApplyConfig(data)
    local applied, missing = 0, 0
    for flag, entry in pairs(data) do
        local el = Library.Elements[flag]
        if el and type(el.Deserialize) == "function" then
            local ok, err = pcall(el.Deserialize, el, entry.Data)
            if ok then applied = applied + 1 else
                warn("[CrystalUI] failed to load flag '" .. tostring(flag) .. "': " .. tostring(err))
            end
        else
            missing = missing + 1
        end
    end
    return applied, missing
end

function Library:SaveConfig(name)
    name = sanitizeName(name)
    if name == "" then return false, "Config name is empty" end
    local data = Library:CollectConfig()
    if not Compat.HasFS then
        Library.MemoryConfigs[name] = data
        return true
    end
    Library:_EnsureFolders()
    local ok, err = pcall(function()
        writefile(cfgPath(name), S.HttpService:JSONEncode(data))
    end)
    if not ok then return false, tostring(err) end
    return true
end

function Library:LoadConfig(name)
    name = sanitizeName(name)
    if name == "" then return false, "Config name is empty" end
    local data
    if not Compat.HasFS then
        data = Library.MemoryConfigs[name]
        if not data then return false, "Config not found" end
    else
        Library:_EnsureFolders()
        local ok, res = pcall(function()
            if not isfile(cfgPath(name)) then error("Config not found") end
            return S.HttpService:JSONDecode(readfile(cfgPath(name)))
        end)
        if not ok then return false, tostring(res) end
        data = res
    end
    local applied, missing = Library:ApplyConfig(data)
    return true, applied, missing
end

function Library:DeleteConfig(name)
    name = sanitizeName(name)
    if not Compat.HasFS then
        Library.MemoryConfigs[name] = nil
        return true
    end
    local ok, err = pcall(function()
        if Compat.delfile and isfile(cfgPath(name)) then Compat.delfile(cfgPath(name)) end
    end)
    return ok, err
end

function Library:ListConfigs()
    local out = {}
    if not Compat.HasFS then
        for name in pairs(Library.MemoryConfigs) do out[#out + 1] = name end
        table.sort(out)
        return out
    end
    Library:_EnsureFolders()
    if Compat.listfiles then
        local ok, files = pcall(Compat.listfiles, cfgFolder() .. "/configs")
        if ok and files then
            for _, f in ipairs(files) do
                local n = tostring(f):match("([^/\\]+)%.json$")
                if n then out[#out + 1] = n end
            end
        end
    end
    table.sort(out)
    return out
end

function Library:SetAutoload(name)
    if not Compat.HasFS then
        Library.AutoloadMemory = name
        return true
    end
    Library:_EnsureFolders()
    local ok = pcall(function()
        if name then writefile(cfgFolder() .. "/autoload.txt", name)
        elseif Compat.delfile and isfile(cfgFolder() .. "/autoload.txt") then Compat.delfile(cfgFolder() .. "/autoload.txt") end
    end)
    return ok
end

function Library:GetAutoload()
    if not Compat.HasFS then return Library.AutoloadMemory end
    local ok, res = pcall(function()
        if isfile(cfgFolder() .. "/autoload.txt") then return readfile(cfgFolder() .. "/autoload.txt") end
    end)
    if ok and res and res ~= "" then return res end
    return nil
end

function Library:LoadAutoload()
    local name = Library:GetAutoload()
    if name then
        local ok, a = Library:LoadConfig(name)
        if ok then
            Library:Notify({ Title = "Autoload", Content = "Loaded config '" .. name .. "'", Type = "success", Duration = 3 })
        end
        return ok
    end
    return false
end

-- Autosave: any flag change writes the active config (debounced)
function Library:EnableAutosave(name)
    Library.AutosaveName = name
    if Library._autosaveConn then Library._autosaveConn:Disconnect() end
    local save = U.Debounce(function()
        if Library.AutosaveName then Library:SaveConfig(Library.AutosaveName) end
    end, 1.0)
    Library._autosaveConn = Library.OnFlagChanged:Connect(function() save() end)
end

function Library:DisableAutosave()
    Library.AutosaveName = nil
    if Library._autosaveConn then Library._autosaveConn:Disconnect() Library._autosaveConn = nil end
end

-- ── Config tab ──────────────────────────────────────────────────────────────

function Window:AddConfigTab(opts)
    opts = opts or {}
    local tab = self:AddTab({ Name = opts.Name or "Config", Icon = opts.Icon or "save" })
    local left = tab:AddSection({ Name = "Configurations", Side = "Left", Icon = "folder" })
    local right = tab:AddSection({ Name = "Autoload & Storage", Side = "Right", Icon = "bolt" })

    local nameBox = left:AddTextbox({ Text = "Config name", Placeholder = "my-config", Ignore = true })
    local dropdown = left:AddDropdown({
        Text = "Saved configs", Values = Library:ListConfigs(), AllowNone = true, Searchable = true, Ignore = true,
    })

    local function refresh(select)
        dropdown:SetValues(Library:ListConfigs(), false)
        if select then dropdown:Set(select, true) end
    end
    local function chosen()
        local n = dropdown:Get()
        if n and n ~= "" then return n end
        local typed = sanitizeName(nameBox:Get())
        if typed ~= "" then return typed end
        return nil
    end

    left:AddButtonRow({
        { Text = "Create", Style = "Primary", Icon = "plus", Callback = function()
            local n = sanitizeName(nameBox:Get())
            if n == "" then
                Library:Notify({ Title = "Config", Content = "Enter a config name first.", Type = "warning" })
                return
            end
            local ok, err = Library:SaveConfig(n)
            if ok then
                Library:Notify({ Title = "Config created", Content = "'" .. n .. "' saved.", Type = "success" })
                refresh(n)
            else
                Library:Notify({ Title = "Save failed", Content = tostring(err), Type = "error" })
            end
        end },
        { Text = "Save", Icon = "save", Callback = function()
            local n = chosen()
            if not n then Library:Notify({ Title = "Config", Content = "Select or type a config.", Type = "warning" }) return end
            local ok, err = Library:SaveConfig(n)
            Library:Notify({ Title = ok and "Config saved" or "Save failed", Content = ok and ("'" .. n .. "' updated.") or tostring(err),
                Type = ok and "success" or "error" })
        end },
        { Text = "Load", Icon = "arrow", Callback = function()
            local n = chosen()
            if not n then Library:Notify({ Title = "Config", Content = "Select a config to load.", Type = "warning" }) return end
            local ok, a, m = Library:LoadConfig(n)
            if ok then
                Library:Notify({ Title = "Config loaded", Content = a .. " settings applied.", Type = "success" })
            else
                Library:Notify({ Title = "Load failed", Content = tostring(a), Type = "error" })
            end
        end },
    })
    left:AddButtonRow({
        { Text = "Delete", Style = "Danger", Icon = "trash", Callback = function()
            local n = dropdown:Get()
            if not n then Library:Notify({ Title = "Config", Content = "Select a config to delete.", Type = "warning" }) return end
            Library:Dialog({
                Title = "Delete config?", Content = "'" .. n .. "' will be removed permanently.", Icon = "trash",
                Buttons = {
                    { Text = "Cancel", Style = "Ghost" },
                    { Text = "Delete", Style = "Danger", Callback = function()
                        Library:DeleteConfig(n)
                        refresh()
                        Library:Notify({ Title = "Deleted", Content = "'" .. n .. "' removed.", Type = "info" })
                    end },
                },
            })
        end },
        { Text = "Refresh", Icon = "refresh", Callback = function() refresh() Library:Notify({ Content = "Config list refreshed.", Duration = 2 }) end },
    })

    local autoLabel = right:AddLabel("Autoload: " .. (Library:GetAutoload() or "none"))
    right:AddButton({ Text = "Set selected as autoload", Icon = "bolt", Callback = function()
        local n = dropdown:Get()
        if not n then Library:Notify({ Title = "Autoload", Content = "Select a config first.", Type = "warning" }) return end
        Library:SetAutoload(n)
        autoLabel:SetText("Autoload: " .. n)
        Library:Notify({ Title = "Autoload set", Content = "'" .. n .. "' loads on start.", Type = "success" })
    end })
    right:AddButton({ Text = "Clear autoload", Callback = function()
        Library:SetAutoload(nil)
        autoLabel:SetText("Autoload: none")
    end })
    right:AddToggle({ Text = "Autosave active config", Ignore = true, Tooltip = "Saves the selected config whenever a setting changes.",
        Callback = function(v)
            if v then
                local n = chosen()
                if n then Library:EnableAutosave(n) else Library:Notify({ Content = "Select a config first.", Type = "warning" }) end
            else
                Library:DisableAutosave()
            end
        end })
    right:AddDivider("storage")
    right:AddParagraph({
        Title = Compat.HasFS and "Saved to disk" or "In-memory only",
        Content = Compat.HasFS and ("Files live in your executor's workspace under '" .. cfgFolder() .. "/configs'.")
            or "Your executor exposes no file API, so configs are kept in memory until you leave the game.",
    })
    return tab
end

-- ── Settings tab (themes, accent, scale, blur, overlays) ────────────────────

function Window:AddSettingsTab(opts)
    opts = opts or {}
    local window = self
    local tab = self:AddTab({ Name = opts.Name or "Settings", Icon = opts.Icon or "gear" })
    local ui = tab:AddSection({ Name = "Interface", Side = "Left", Icon = "palette" })
    local misc = tab:AddSection({ Name = "Overlays", Side = "Right", Icon = "layers" })
    local sys = tab:AddSection({ Name = "System", Side = "Right", Icon = "sliders" })

    ui:AddDropdown({
        Text = "Theme", Values = ThemeOrder, Default = Theme.Name, Ignore = true,
        Callback = function(name) Theme.Apply(name, true) end,
    })
    local accent = ui:AddColorPicker({
        Text = "Accent colour", Default = Theme.Current.Accent, Ignore = true,
        Callback = function(c) Theme.SetAccent(c) end,
    })
    ui:AddButton({ Text = "Reset accent", Icon = "refresh", Callback = function()
        Theme.ClearAccent()
        accent:Set(Theme.Current.Accent, nil, true)
    end })
    ui:AddSlider({
        Text = "Glass transparency", Min = -0.2, Max = 0.6, Default = 0, Step = 0.02, Ignore = true,
        Callback = function(v) Theme.SetGlassOffset(v) end,
    })
    ui:AddSlider({
        Text = "Interface scale", Min = 0.7, Max = 1.4, Default = 1, Step = 0.05, Suffix = "x", Ignore = true,
        Callback = function(v) window:SetScale(v) end,
    })
    ui:AddToggle({ Text = "Background blur", Default = Library.BlurEnabled, Ignore = true,
        Callback = function(v) Library:SetBlur(v) end })
    ui:AddSlider({
        Text = "Blur strength", Min = 0, Max = 32, Default = Library.BlurSize, Step = 1, Ignore = true,
        Callback = function(v) Library:SetBlur(nil, v) end,
    })

    -- overlays
    local watermark
    misc:AddToggle({ Text = "Watermark", Ignore = true, Callback = function(v)
        if v and not watermark then
            watermark = Library:CreateWatermark({ Title = window.Title })
        elseif watermark then
            watermark:SetVisible(v)
        end
    end })
    misc:AddToggle({ Text = "Keybind list", Ignore = true, Callback = function(v)
        if v then Library:CreateKeybindList():SetVisible(true)
        elseif Library.KeybindListObj then Library.KeybindListObj:SetVisible(false) end
    end })
    misc:AddDropdown({
        Text = "Notification position", Values = { "BottomRight", "BottomLeft", "TopRight", "TopLeft", "TopCenter" },
        Default = "BottomRight", Ignore = true, Callback = function(v)
            Library:SetNotifyPosition(v)
            Library:Notify({ Title = "Position changed", Content = v, Duration = 2 })
        end,
    })
    misc:AddButtonRow({
        { Text = "Info", Callback = function() Library:Notify({ Title = "Information", Content = "This is an info notification.", Type = "info" }) end },
        { Text = "Success", Callback = function() Library:Notify({ Title = "Success", Content = "Operation completed.", Type = "success" }) end },
    })
    misc:AddButtonRow({
        { Text = "Warning", Callback = function() Library:Notify({ Title = "Warning", Content = "Something needs attention.", Type = "warning" }) end },
        { Text = "Error", Callback = function() Library:Notify({ Title = "Error", Content = "Something went wrong.", Type = "error" }) end },
    })

    -- system
    local menuKey = sys:AddKeybind({
        Flag = "CrystalUI_MenuKey", Text = "Menu key", Default = self.ToggleKey, Mode = "Always", HideInList = true, Ignore = true,
    })
    Library.OnFlagChanged:Connect(function(flag, value)
        if flag == "CrystalUI_MenuKey" and typeof(value) == "EnumItem" and value.EnumType == Enum.KeyCode then
            window:SetToggleKey(value)
        end
    end)
    sys:AddSlider({
        Text = "Animation speed", Min = 0.4, Max = 2.5, Default = 1, Step = 0.1, Suffix = "x", Ignore = true,
        Callback = function(v) Anim.TimeScale = v end,
    })
    sys:AddToggle({ Text = "Animations", Default = true, Ignore = true, Callback = function(v) Anim.Enabled = v end })
    sys:AddDivider()
    sys:AddButton({ Text = "Unload interface", Style = "Danger", Icon = "close", DoubleClick = true, Callback = function()
        Library:Unload()
    end })
    return tab
end

-- ── Library-level helpers ───────────────────────────────────────────────────

function Library:SetTheme(name, animate)
    Theme.Apply(name, animate ~= false)
end

function Library:RegisterTheme(name, preset)
    Theme.Register(name, preset)
end

function Library:GetThemes()
    return U.DeepCopy(ThemeOrder)
end

function Library:Toggle()
    for _, w in ipairs(Library.Windows) do w:Toggle() end
end

function Library:SetToggleKey(key)
    for _, w in ipairs(Library.Windows) do w:SetToggleKey(key) end
end

function Library:Unload()
    if Library.Unloaded then return end
    Library.Unloaded = true
    pcall(function() Library.OnUnload:Fire() end)
    Library:DisableAutosave()
    for _, w in ipairs(Library.Windows) do
        pcall(function() w:Hide() end)
    end
    pcall(function() Library:UpdateBlur() end)
    task.delay(0.45, function()
        for i = #Library.Windows, 1, -1 do
            pcall(function() Library.Windows[i]:Destroy() end)
        end
        RootMaid:Clean()
        if GlobalEnv.CrystalUI == Library then GlobalEnv.CrystalUI = nil end
    end)
end

-- Public handles for advanced users
Library.Theme = Theme
Library.Anim = Anim
Library.Ease = Ease
Library.Icons = Icons
Library.Utils = U
Library.Signal = Signal
Library.Maid = Maid
Library.Interact = Interact
Library.Controls = Controls
Library.Themes = ThemePresets
Library.Fonts = Fonts
Library.Create = New
Library.Compat = Compat

GlobalEnv.CrystalUI = Library

-- ════════════════════════════════════════════════════════════════════════════
--  SECTION 9 — DEMO / SHOWCASE
--  Set  getgenv().CrystalUI_NoDemo = true  before running to skip this block
--  and use the library from your own script (it is exposed as CrystalUI).
-- ════════════════════════════════════════════════════════════════════════════

if not GlobalEnv.CrystalUI_NoDemo then
    local Win = Library:CreateWindow({
        Title = "CrystalUI",
        Subtitle = "Glass framework  •  v" .. Library.Version,
        Size = UDim2.fromOffset(780, 520),
        Theme = "Aurora",
        ToggleKey = Enum.KeyCode.RightShift,
        Footer = "RightShift — hide / show",
        Blur = true,
        Intro = true,
        ConfigFolder = "CrystalUI",
    })

    -- ── Home ────────────────────────────────────────────────────────────────
    local home = Win:AddTab({ Name = "Home", Icon = "home" })
    local welcome = home:AddSection({ Name = "Welcome", Icon = "star", Side = "Left" })
    welcome:AddParagraph({
        Title = "CrystalUI",
        Content = "A glassmorphism interface framework with springs, easing, a puzzle-assembly intro, "
            .. "notifications, dialogs, tooltips, colour pickers, configs and themes.",
    })
    welcome:AddButtonRow({
        { Text = "Notify", Style = "Primary", Icon = "bell", Callback = function()
            Library:Notify({
                Title = "Hello!", Content = "Notifications stack, spring into place and pause while hovered.",
                Type = "info", Duration = 5,
                Buttons = { { Text = "Nice", Style = "Primary" }, { Text = "Dismiss", Style = "Secondary" } },
            })
        end },
        { Text = "Dialog", Icon = "info", Callback = function()
            Library:Dialog({
                Title = "Modal dialog", Content = "Dialogs dim the screen, pop in with a spring and block input behind them.",
                Icon = "info",
                Buttons = {
                    { Text = "Cancel", Style = "Ghost" },
                    { Text = "Confirm", Style = "Primary", Callback = function()
                        Library:Notify({ Title = "Confirmed", Content = "You pressed Confirm.", Type = "success", Duration = 3 })
                    end },
                },
            })
        end },
    })
    welcome:AddLabel("Tip: hover almost anything — tooltips, ripples and springs are everywhere.")

    local stats = home:AddSection({ Name = "Live widgets", Icon = "bolt", Side = "Right" })
    local p1 = stats:AddProgress({ Text = "Loading assets", Value = 0 })
    local p2 = stats:AddProgress({ Text = "Indeterminate", Indeterminate = true })
    stats:AddProgress({ Text = "Static value", Value = 0.64 })
    local t0 = os.clock()
    Library.Anim.Every(function(dt, now)
        if Library.Unloaded or p1.Destroyed then return end
        p1:Set(((now - t0) * 0.12) % 1)
    end)
    stats:AddDivider("buttons")
    stats:AddButton({
        Text = "Double-click to confirm", Style = "Danger", DoubleClick = true, Icon = "trash",
        Callback = function() Library:Notify({ Title = "Executed", Content = "Dangerous action confirmed.", Type = "warning" }) end,
    })

    -- ── Combat ──────────────────────────────────────────────────────────────
    Win:AddTabDivider("Features")
    local combat = Win:AddTab({ Name = "Combat", Icon = "sword" })
    local aim = combat:AddSection({ Name = "Aim assist", Icon = "target", Side = "Left" })
    local aimToggle = aim:AddToggle({
        Flag = "aim_enabled", Text = "Enable aim assist", Default = false, Tooltip = "Main switch for the aim assist module.",
        Callback = function(v) Library:Notify({ Content = "Aim assist " .. (v and "enabled" or "disabled"), Type = v and "success" or "info", Duration = 2 }) end,
    })
    aimToggle:AddKeybind({ Default = Enum.KeyCode.E, Mode = "Toggle", Name = "Aim assist" })
    aim:AddSlider({ Flag = "aim_fov", Text = "Field of view", Min = 10, Max = 360, Default = 90, Step = 1, Suffix = "°" })
    aim:AddSlider({ Flag = "aim_smooth", Text = "Smoothness", Min = 0, Max = 1, Default = 0.35, Step = 0.01, Decimals = 2 })
    aim:AddDropdown({ Flag = "aim_part", Text = "Target part", Values = { "Head", "Torso", "Left Arm", "Right Arm", "Legs" }, Default = "Head" })
    aim:AddMultiDropdown({
        Flag = "aim_checks", Text = "Checks", Values = { "Team", "Visible", "Alive", "Distance", "Friends", "Forcefield" },
        Default = { "Team", "Alive" }, Searchable = true,
    })

    local trig = combat:AddSection({ Name = "Triggerbot", Icon = "bolt", Side = "Right" })
    trig:AddToggle({ Flag = "trig_enabled", Text = "Enable triggerbot", Style = "Check" })
    trig:AddSlider({ Flag = "trig_delay", Text = "Delay", Min = 0, Max = 500, Default = 60, Step = 5, Suffix = " ms" })
    trig:AddToggle({ Flag = "trig_head", Text = "Headshots only", Style = "Check", Default = true })
    trig:AddKeybind({ Flag = "trig_key", Text = "Trigger key", Default = Enum.KeyCode.Q, Mode = "Hold" })

    local misc1 = combat:AddSection({ Name = "Movement", Icon = "run", Side = "Left", Collapsed = true })
    misc1:AddToggle({ Flag = "mv_speed", Text = "Speed boost" })
    misc1:AddSlider({ Flag = "mv_speed_val", Text = "Walk speed", Min = 16, Max = 120, Default = 16, Step = 1 })
    misc1:AddToggle({ Flag = "mv_jump", Text = "Infinite jump" })

    -- ── Visuals ─────────────────────────────────────────────────────────────
    local vis = Win:AddTab({ Name = "Visuals", Icon = "eye" })
    local esp = vis:AddSection({ Name = "ESP", Icon = "eye", Side = "Left" })
    local espToggle = esp:AddToggle({ Flag = "esp_enabled", Text = "Enable ESP", Default = true })
    espToggle:AddColorPicker({ Flag = "esp_color", Default = Color3.fromRGB(139, 92, 246) })
    local boxes = esp:AddToggle({ Flag = "esp_boxes", Text = "Boxes", Default = true })
    boxes:AddColorPicker({ Flag = "esp_box_color", Default = Color3.fromRGB(56, 189, 248), Alpha = true, DefaultAlpha = 0.8 })
    esp:AddToggle({ Flag = "esp_names", Text = "Names" })
    esp:AddToggle({ Flag = "esp_health", Text = "Health bars", Default = true })
    esp:AddSlider({ Flag = "esp_distance", Text = "Max distance", Min = 100, Max = 5000, Default = 1500, Step = 50, Suffix = " st" })

    local world = vis:AddSection({ Name = "World", Icon = "globe", Side = "Right" })
    world:AddColorPicker({ Flag = "world_ambient", Text = "Ambient colour", Default = Color3.fromRGB(120, 130, 255) })
    world:AddColorPicker({ Flag = "world_rainbow", Text = "Rainbow sky", Default = Color3.fromRGB(255, 90, 90), Rainbow = true })
    world:AddSlider({ Flag = "world_time", Text = "Time of day", Min = 0, Max = 24, Default = 14, Step = 0.25, Suffix = " h", Decimals = 2 })
    world:AddDropdown({ Flag = "world_sky", Text = "Skybox", Values = { "Default", "Night", "Sunset", "Space", "Storm" }, Default = "Default" })

    -- ── Misc ────────────────────────────────────────────────────────────────
    local misc = Win:AddTab({ Name = "Misc", Icon = "layers" })
    local inputs = misc:AddSection({ Name = "Inputs", Icon = "keyboard", Side = "Left" })
    inputs:AddTextbox({ Flag = "misc_name", Text = "Display name", Placeholder = "Type something...", Default = "" })
    inputs:AddTextbox({ Flag = "misc_number", Text = "Number only", Numeric = true, Default = 42, Min = 0, Max = 1000 })
    inputs:AddKeybind({ Flag = "misc_key", Text = "Panic key", Default = Enum.KeyCode.Delete, Mode = "Toggle" })
    inputs:AddLabel("Right-click a keybind chip to cycle Toggle / Hold / Always.")

    local about = misc:AddSection({ Name = "About", Icon = "info", Side = "Right" })
    about:AddParagraph({ Title = "Search", Content = "Use the search box in the top bar — it filters every tab and jumps to the first match." })
    about:AddParagraph({ Title = "Dragging", Content = "Drag the top bar to move the window, the bottom-right grip to resize it." })
    about:AddButton({ Text = "Copy library name", Icon = "copy", Callback = function()
        if Compat.setclipboard then pcall(Compat.setclipboard, "CrystalUI") end
        Library:Notify({ Title = "Copied", Content = "CrystalUI", Type = "success", Duration = 2 })
    end })

    -- ── Config / Settings ───────────────────────────────────────────────────
    Win:AddTabDivider("System")
    Win:AddConfigTab()
    Win:AddSettingsTab()

    Win.Loaded:Connect(function()
        Library:Notify({
            Title = "CrystalUI loaded", Content = "Press " .. U.KeyName(Win.ToggleKey) .. " to hide or show the interface.",
            Type = "success", Duration = 5,
        })
        Library:LoadAutoload()
    end)
end

return Library
