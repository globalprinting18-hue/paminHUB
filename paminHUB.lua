-- PAPAMAMIN CHARACTER & WORLD SCANNER
-- Read-only LocalScript / executor-compatible where permitted by game rules.
-- Records local character position, nearby BaseParts, and Workspace objects.
-- Buttons: SCAN, STOP, CLEAR LOG, COPY LOG, CLOSE.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local env = (getgenv and getgenv()) or _G

if env.PAPAMAMIN_SCANNER_CLOSE then pcall(env.PAPAMAMIN_SCANNER_CLOSE) end

local running, closed, scanToken = false, false, 0
local logs = {}
local MAX_LOG_LINES = 500
local NEAR_RADIUS = 30
local WORLD_MAX_OBJECTS = 2500
local YIELD_EVERY = 150

local function safeName(obj)
    local ok, result = pcall(function() return obj:GetFullName() end)
    return ok and result or (obj and obj.Name or "unknown")
end

local function getPosition(obj)
    if not obj then return nil end
    if obj:IsA("BasePart") then return obj.Position end
    if obj:IsA("Model") then
        local ok, pivot = pcall(function() return obj:GetPivot() end)
        if ok then return pivot.Position end
    elseif obj:IsA("Tool") then
        local handle = obj:FindFirstChild("Handle")
        if handle and handle:IsA("BasePart") then return handle.Position end
    end
    return nil
end

local function fmt(v)
    return v and string.format("X=%.2f, Y=%.2f, Z=%.2f", v.X, v.Y, v.Z) or "N/A"
end

local function addLog(s)
    table.insert(logs, "[" .. os.date("%H:%M:%S") .. "] " .. tostring(s))
    while #logs > MAX_LOG_LINES do table.remove(logs, 1) end
end

local old = playerGui:FindFirstChild("PAPAMAMIN_CHARACTER_SCANNER_GUI")
if old then old:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "PAPAMAMIN_CHARACTER_SCANNER_GUI"
gui.ResetOnSpawn = false
gui.DisplayOrder = 1000
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Name = "Main"
frame.Size = UDim2.new(0, 560, 0, 470)
frame.Position = UDim2.new(0.5, -280, 0.5, -235)
frame.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
frame.BorderSizePixel = 0
frame.ClipsDescendants = true
frame.Active = true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)
local outline = Instance.new("UIStroke", frame)
outline.Color = Color3.fromRGB(255, 193, 91)
outline.Thickness = 1.5

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -24, 0, 34)
title.Position = UDim2.fromOffset(12, 4)
title.BackgroundTransparency = 1
title.Text = "PAPAMAMIN — CHARACTER / WORLD SCANNER"
title.TextColor3 = Color3.fromRGB(255, 193, 91)
title.Font = Enum.Font.GothamBold
title.TextSize = 16
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = frame

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -24, 0, 22)
status.Position = UDim2.fromOffset(12, 37)
status.BackgroundTransparency = 1
status.Text = "STATUS: READY"
status.TextColor3 = Color3.fromRGB(200, 210, 220)
status.Font = Enum.Font.Gotham
status.TextSize = 12
status.TextXAlignment = Enum.TextXAlignment.Left
status.Parent = frame

local scroll = Instance.new("ScrollingFrame")
scroll.Name = "LogScroll"
scroll.Size = UDim2.new(1, -24, 1, -118)
scroll.Position = UDim2.fromOffset(12, 62)
scroll.BackgroundColor3 = Color3.fromRGB(11, 13, 17)
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 6
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.ScrollingDirection = Enum.ScrollingDirection.Y
scroll.ClipsDescendants = true
scroll.Parent = frame
Instance.new("UICorner", scroll).CornerRadius = UDim.new(0, 6)

local logLabel = Instance.new("TextLabel")
logLabel.Name = "LogText"
logLabel.Size = UDim2.new(1, -10, 0, 0)
logLabel.Position = UDim2.fromOffset(5, 4)
logLabel.AutomaticSize = Enum.AutomaticSize.Y
logLabel.BackgroundTransparency = 1
logLabel.TextColor3 = Color3.fromRGB(220, 230, 235)
logLabel.Font = Enum.Font.Code
logLabel.TextSize = 12
logLabel.TextXAlignment = Enum.TextXAlignment.Left
logLabel.TextYAlignment = Enum.TextYAlignment.Top
logLabel.TextWrapped = true
logLabel.Parent = scroll

local function refreshLog()
    logLabel.Text = table.concat(logs, "\n")
    task.defer(function()
        local height = logLabel.TextBounds.Y + 12
        scroll.CanvasSize = UDim2.new(0, 0, 0, math.max(height, scroll.AbsoluteSize.Y))
        scroll.CanvasPosition = Vector2.new(0, math.max(0, height - scroll.AbsoluteSize.Y))
    end)
end

local function makeButton(name, text, x, width, color)
    local b = Instance.new("TextButton")
    b.Name = name
    b.Size = UDim2.new(0, width, 0, 34)
    b.Position = UDim2.new(0, x, 1, -42)
    b.BackgroundColor3 = color
    b.BorderSizePixel = 0
    b.Text = text
    b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 12
    b.Parent = frame
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    return b
end

local scanButton = makeButton("Scan", "SCAN", 12, 105, Color3.fromRGB(35, 145, 80))
local stopButton = makeButton("Stop", "STOP", 123, 95, Color3.fromRGB(190, 65, 55))
local clearButton = makeButton("ClearLog", "CLEAR LOG", 224, 115, Color3.fromRGB(75, 85, 105))
local copyButton = makeButton("CopyLog", "COPY LOG", 345, 105, Color3.fromRGB(60, 105, 170))
local closeButton = makeButton("Close", "CLOSE", 456, 92, Color3.fromRGB(65, 65, 75))

-- Drag GUI by title bar.
local dragging, dragStart, startPos = false, nil, nil
title.Active = true
title.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging, dragStart, startPos = true, input.Position, frame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then dragging = false end
        end)
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)

local function scanCharacter(token)
    local character = player.Character
    if not character then addLog("CHARACTER belum tersedia."); return nil end
    local root = character:FindFirstChild("HumanoidRootPart")
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    addLog("=== POSISI KARAKTER ===")
    addLog("Character: " .. safeName(character))
    addLog("Humanoid: " .. tostring(humanoid ~= nil) .. (humanoid and (" | Health=" .. string.format("%.1f", humanoid.Health)) or ""))
    if root and root:IsA("BasePart") then
        addLog("HumanoidRootPart: " .. fmt(root.Position))
        addLog("Root CFrame: " .. tostring(root.CFrame))
    else
        addLog("HumanoidRootPart TIDAK DITEMUKAN")
    end
    local head = character:FindFirstChild("Head")
    if head and head:IsA("BasePart") then addLog("Head: " .. fmt(head.Position)) end
    local found = 0
    for _, obj in ipairs(character:GetDescendants()) do
        if token ~= scanToken or not running then return root and root.Position end
        local name = string.lower(obj.Name)
        if string.find(name, "pan", 1, true) or string.find(name, "wok", 1, true) then
            found = found + 1
            addLog("PAN/WOK di karakter: " .. safeName(obj) .. " | pos=" .. fmt(getPosition(obj)))
        end
    end
    if found == 0 then addLog("PAN/WOK pada karakter tidak ditemukan berdasarkan nama.") end
    refreshLog()
    return root and root.Position or nil
end

local function scanNearby(rootPos, token)
    addLog("=== OBJEK DI SEKITAR KARAKTER (radius " .. NEAR_RADIUS .. ") ===")
    if not rootPos then addLog("Dilewati: posisi karakter tidak tersedia."); return end
    local count = 0
    for i, obj in ipairs(Workspace:GetDescendants()) do
        if token ~= scanToken or not running then return end
        if obj:IsA("BasePart") then
            local distance = (obj.Position - rootPos).Magnitude
            if distance <= NEAR_RADIUS and not (player.Character and obj:IsDescendantOf(player.Character)) then
                count = count + 1
                addLog(string.format("NEAR %.1f | %s | %s", distance, safeName(obj), fmt(obj.Position)))
                if count >= 300 then addLog("Batas 300 part sekitar tercapai."); break end
            end
        end
        if i % YIELD_EVERY == 0 then task.wait() end
    end
    addLog("Jumlah part sekitar tercatat: " .. count)
    refreshLog()
end

local function scanWorld(token)
    addLog("=== SCAN WORKSPACE ===")
    local all = Workspace:GetDescendants()
    addLog("Total descendant Workspace: " .. #all)
    local checked, positioned = 0, 0
    for i, obj in ipairs(all) do
        if token ~= scanToken or not running then return end
        checked = checked + 1
        local pos = getPosition(obj)
        if pos then
            positioned = positioned + 1
            addLog("WORLD | " .. obj.ClassName .. " | " .. safeName(obj) .. " | " .. fmt(pos))
        end
        if checked >= WORLD_MAX_OBJECTS then
            addLog("Batas " .. WORLD_MAX_OBJECTS .. " objek tercapai untuk mengurangi risiko lag; scan dipotong.")
            break
        end
        if i % YIELD_EVERY == 0 then
            status.Text = string.format("STATUS: WORLD SCAN %d/%d", i, #all)
            refreshLog()
            task.wait()
        end
    end
    addLog("World scan selesai: diperiksa=" .. checked .. " | punya posisi=" .. positioned)
end

local function runScan()
    if running or closed then return end
    running = true
    scanToken = scanToken + 1
    local token = scanToken
    status.Text = "STATUS: SCANNING"
    addLog("========== SCAN DIMULAI ==========")
    refreshLog()
    task.spawn(function()
        local ok, err = pcall(function()
            local pos = scanCharacter(token)
            if token ~= scanToken or not running then return end
            scanNearby(pos, token)
            if token ~= scanToken or not running then return end
            scanWorld(token)
        end)
        if not ok then addLog("ERROR: " .. tostring(err)) end
        if token == scanToken then
            running = false
            status.Text = "STATUS: SELESAI"
            addLog("========== SCAN SELESAI ==========")
            refreshLog()
        end
    end)
end

scanButton.MouseButton1Click:Connect(runScan)
stopButton.MouseButton1Click:Connect(function()
    if running then
        running = false
        scanToken = scanToken + 1
        status.Text = "STATUS: DIHENTIKAN"
        addLog("Scan dihentikan oleh pengguna.")
        refreshLog()
    end
end)
clearButton.MouseButton1Click:Connect(function()
    logs = {}
    addLog("Log dibersihkan.")
    refreshLog()
end)
copyButton.MouseButton1Click:Connect(function()
    if typeof(setclipboard) == "function" then
        local ok = pcall(setclipboard, table.concat(logs, "\n"))
        status.Text = ok and "STATUS: LOG DISALIN" or "STATUS: GAGAL MENYALIN"
    else
        status.Text = "STATUS: CLIPBOARD TIDAK DIDUKUNG"
        addLog("Fungsi clipboard tidak tersedia di lingkungan ini.")
        refreshLog()
    end
end)
closeButton.MouseButton1Click:Connect(function()
    closed = true
    running = false
    scanToken = scanToken + 1
    if gui then gui:Destroy() end
    env.PAPAMAMIN_SCANNER_CLOSE = nil
end)

env.PAPAMAMIN_SCANNER_CLOSE = function()
    closed = true
    running = false
    scanToken = scanToken + 1
    if gui and gui.Parent then gui:Destroy() end
end

addLog("Scanner siap. Panel log dapat digulir dan tidak melewati batas GUI.")
addLog("Scan Workspace dibatasi " .. WORLD_MAX_OBJECTS .. " objek per sesi untuk mengurangi lag.")
refreshLog()
