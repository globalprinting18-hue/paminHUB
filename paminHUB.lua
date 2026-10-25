-- PAPAMAMIN AUTO COLLECT + AUTO THROW | FIVE ZONES RESTORED

-- Tracks a locally visible flying pan and steers toward selectable item groups across PT_Field.

-- Use only where game rules permit automation.



local Players = game:GetService("Players")

local Workspace = game:GetService("Workspace")

local VIM = game:GetService("VirtualInputManager")

-- COBA ATUR ORIENTASI HORIZONTAL
local StarterGui = game:GetService("StarterGui")

pcall(function()
    StarterGui.ScreenOrientation =
        Enum.ScreenOrientation.LandscapeSensor
end)

local player = Players.LocalPlayer

local pg = player:WaitForChild("PlayerGui")



local old = pg:FindFirstChild("PAPAMAMIN_UNIFIED_GUI")

if old then old:Destroy() end

if _G.PAPAMAMIN_UNIFIED_CLOSE then pcall(_G.PAPAMAMIN_UNIFIED_CLOSE) end
if _G.PAPAMAMIN_AUTO_COLLECT_STOP then pcall(_G.PAPAMAMIN_AUTO_COLLECT_STOP) end



local running, alive = false, true
local status -- forward-declared for persistent flight reset helpers
local refresh, scanItems -- forward declarations used by zone-toggle callbacks

local reverseAD = false

local target, previousPan, previousPos, previousTime = nil, nil, nil, nil

local flightActive, collectedEstimate = false, 0
local flightCapped = false

local maxCollect = 15

local held = {}

local lines = {}

local lastLog = 0

local lastFieldRefresh = 0

local itemCache = {}

local lastPanMove = 0

local lastSpeed = 0

local flightStart = 0

local candidateFrames = 0

local lostSince = nil

local stoppedSince = nil

local initialCamera = nil

local lastReasonLog = 0

-- Per-group collection switches. All groups start enabled for the first full-map test.
local zoneEnabled = {
    Kitchen = true,
    Neighborhood = true,
    Market = true,
    City = true,
    ["Pak GM Studio"] = true,
}

local zoneNames = {"Kitchen", "Neighborhood", "Market", "City", "Pak GM Studio"}

local priorityMode = "NEAREST"

local priorities = {
    GoldenWok=100, StoneMortar=95, Fridge=90, RantangTower=85,
    Microwave=75, Toaster=55, Thermos=45, RiceCooker=35,
    WaterGallon=25, CrackerJar=20,
    MegaBaksoBowl=100, GiantDurian=90, GiantPineapple=90,
    YellowTaxi=85, MegaRingLight=85, FlyingSaucer=80,
}

-- Recognized collectible names. Physical zone is assigned by Z position, not item type,
-- because the scan showed a few object types duplicated across distant areas.
local known = {
    "GoldenWok", "StoneMortar", "Fridge", "RantangTower", "Microwave",
    "Toaster", "Thermos", "RiceCooker", "WaterGallon", "CrackerJar",
    "FlipFlop", "Bucket", "PottedPlant", "Kite", "Bicycle", "Mailbox",
    "SatelliteDish", "WaterTower", "Becak", "FlyingSaucer",
    "Watermelon", "Coconut", "BananaBunch", "WeighingScale", "FruitCrate",
    "VendorUmbrella", "FoodCart", "GiantDurian", "GiantPineapple", "MegaBaksoBowl",
    "TrafficCone", "FireHydrant", "TrashBin", "StreetLamp", "BusStopSign",
    "VendingMachine", "YellowTaxi", "NeonSign", "TrafficLight", "MegaRingLight",

    -- Pak GM Studio (Zona 5)
    -- Penamaan mengikuti pola internal Zona 1: tanpa spasi, PascalCase.
    "EnergyDrink", "GameController", "Headphones", "Microphone", "Webcam",
    "RGBKeyboard", "GamingChair", "ArcadeCabinet", "StreamingPC", "GoldenGamerCrown",
}


-- Catalog berdasarkan daftar zona/rarity yang diberikan.
local itemGroups = {
    Kitchen = {
        Common = {"CrackerJar", "WaterGallon", "RiceCooker"},
        Uncommon = {"Toaster", "Thermos"},
        Epic = {"Microwave"},
        Legendary = {"Fridge", "RantangTower"},
        Mythic = {"StoneMortar"},
        Secret = {"GoldenWok"},
    },
    Neighborhood = {
        Common = {"FlipFlop", "Bucket", "PottedPlant"},
        Uncommon = {"Kite", "Bicycle"},
        Epic = {"Mailbox"},
        Legendary = {"SatelliteDish", "Becak"},
        Mythic = {"WaterTower"},
        Secret = {"FlyingSaucer"},
    },
    Market = {
        Common = {"Watermelon", "Coconut", "BananaBunch"},
        Uncommon = {"WeighingScale", "FruitCrate"},
        Epic = {"VendorUmbrella"},
        Legendary = {"FoodCart", "GiantPineapple"},
        Mythic = {"GiantDurian"},
        Secret = {"MegaBaksoBowl"},
    },
    City = {
        Common = {"TrafficCone", "FireHydrant", "TrashBin"},
        Uncommon = {"StreetLamp", "BusStopSign"},
        Epic = {"VendingMachine"},
        Legendary = {"YellowTaxi", "TrafficLight"},
        Mythic = {"NeonSign"},
        Secret = {"MegaRingLight"},
    },
    ["Pak GM Studio"] = {
        Common = {"EnergyDrink", "GameController", "Headphones"},
        Uncommon = {"Microphone", "Webcam"},
        Epic = {"RGBKeyboard"},
        Legendary = {"GamingChair", "ArcadeCabinet"},
        Mythic = {"StreamingPC"},
        Secret = {"GoldenGamerCrown"},
    },
}
local rarityNames = {"Common", "Uncommon", "Epic", "Legendary", "Mythic", "Secret"}
local itemRarity, itemZone = {}, {}
for zone, rarityMap in pairs(itemGroups) do
    for rarity, items in pairs(rarityMap) do
        for _, itemName in ipairs(items) do
            itemRarity[itemName] = rarity
            itemZone[itemName] = zone
        end
    end
end
-- Multi-select filters: an empty selection means ALL.
local selectedZones, selectedRarities, selectedItems = {}, {}, {}
local function matchesSelection(selection, value)
    return next(selection) == nil or selection[value] == true
end
local function selectionArray(selection, options)
    local result = {}
    for _, name in ipairs(options) do
        if selection[name] then table.insert(result, name) end
    end
    return result
end
local function arraySelection(values, validOptions)
    local result, valid = {}, {}
    for _, name in ipairs(validOptions) do valid[name] = true end
    if type(values) == "table" then
        for _, name in ipairs(values) do
            if valid[name] then result[name] = true end
        end
    elseif type(values) == "string" and valid[values] then
        result[values] = true
    end
    return result
end

-- Approximate Z bands inferred from the supplied scan; adjust after live testing.
local function zoneForPosition(p)
    if p.Z < 420 then return "Kitchen" end
    if p.Z < 800 then return "Neighborhood" end
    if p.Z < 1240 then return "Market" end
    if p.Z < 1700 then return "City" end
    return "Pak GM Studio"
end

local function fmt(v)

          return v and string.format("%.1f, %.1f, %.1f",v.X,v.Y,v.Z) or "N/A"

end

local function posOf(o)

          if not o then return nil end

          if o:IsA("BasePart") then return o.Position end

          if o:IsA("Model") then

                    local ok, cf = pcall(function() return o:GetPivot() end)

                    if ok then return cf.Position end

          end

          return nil

end

local function findPan()
          -- Do not assume the thrown object is always named "Pan02".
          -- Search the game's local FX container for the current pan model/part.
          -- Prefer names that identify a pan, then fall back to a model/part child.
          local f = Workspace:FindFirstChild("PT_LocalFx")
          if not f then return nil end

          local fallback = nil
          for _, obj in ipairs(f:GetChildren()) do
                    local isTrackable = obj:IsA("Model") or obj:IsA("BasePart")
                    if isTrackable then
                              local n = string.lower(obj.Name)
                              if n == "pan02" or string.find(n, "pan", 1, true)
                                      or string.find(n, "wok", 1, true) then
                                        return obj
                              end
                              if not fallback then fallback = obj end
                    end
          end
          return fallback
end

local function log(s)

          table.insert(lines, os.date("%H:%M:%S") .. " " .. s)

          if #lines > 65 then table.remove(lines,1) end

end

local function send(key, down)

          if held[key] == down then return end

          held[key] = down

          pcall(function() VIM:SendKeyEvent(down, Enum.KeyCode[key], false, game) end)

end

local function releaseAll()

          for _, k in ipairs({"W","A","S","D"}) do send(k,false) end

end

local function stopAuto(reason)
          -- Explicit OFF / fatal stop: disable the persistent collector.
          running = false
          flightActive = false
          candidateFrames = 0
          releaseAll()
          target = nil
          if reason then log(reason) end
end

local function endFlight(reason)
          -- End only this throw's tracking session. Keep AUTO COLLECT enabled
          -- so the next throw is detected without pressing AUTO ON again.
          flightActive = false
          candidateFrames = 0
          lostSince = nil
          stoppedSince = nil
          target = nil
          collectedEstimate = 0
          flightCapped = false
          previousPan, previousPos, previousTime = nil, nil, nil
          releaseAll()
          if reason then log(reason) end
          if running then
              status.Text = "STATUS: WAITING FOR FLIGHT"
          else
              status.Text = "STATUS: OFF"
          end
end

_G.PAPAMAMIN_AUTO_COLLECT_STOP = function()

          alive = false

          stopAuto()

end



local gui = Instance.new("ScreenGui")
gui.Name = "PAPAMAMIN_UNIFIED_GUI"
gui.ResetOnSpawn = false
gui.DisplayOrder = 999
gui.Parent = pg

local frame = Instance.new("Frame")
frame.Name = "MainFrame"
frame.Size = UDim2.fromOffset(470, 680)
frame.Position = UDim2.new(0.5, -235, 0.5, -340)
frame.BackgroundColor3 = Color3.fromRGB(18, 18, 21)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui

local function round(o, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r)
    c.Parent = o
end
round(frame, 10)

-- Responsive sizing for desktop and mobile. All existing controls retain their
-- positions; UIScale scales the complete interface together to prevent clipping.
local frameScale = Instance.new("UIScale")
frameScale.Name = "ResponsiveScale"
frameScale.Scale = 1
frameScale.Parent = frame
local layoutMode = "AUTO"
local function applyLayoutMode()
    local camera = Workspace.CurrentCamera
    local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
    local safeWidth = math.max(240, viewport.X - 24)
    local safeHeight = math.max(320, viewport.Y - 48)
    local fitScale = math.min(safeWidth / 470, safeHeight / 680, 1)
    local scale = fitScale
    if layoutMode == "COMPACT" then
        scale = fitScale * 0.84
    elseif layoutMode == "LARGE" then
        scale = fitScale
    end
    -- Avoid a hard minimum that could make the panel exceed very small screens.
    frameScale.Scale = math.max(0.25, scale)
    frame.Position = UDim2.new(0.5, -(470 * frameScale.Scale) / 2,
                               0.5, -(680 * frameScale.Scale) / 2)
end
applyLayoutMode()

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(18, 18, 21)
stroke.Thickness = 0
stroke.Parent = frame

local titleBar = Instance.new("Frame")
titleBar.Name = "TitleBar"
titleBar.Size = UDim2.new(1, 0, 0, 40)
titleBar.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
titleBar.BorderSizePixel = 0
titleBar.Active = true
titleBar.Parent = frame
round(titleBar, 10)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -145, 1, 0)
title.Position = UDim2.fromOffset(12, 0)
title.BackgroundTransparency = 1
title.Text = "PaminHub"
title.TextColor3 = Color3.fromRGB(245, 245, 245)
title.TextSize = 17
title.Font = Enum.Font.GothamBold
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = titleBar

local function topButton(name, txt, x, color)
    local b = Instance.new("TextButton")
    b.Name = name
    b.Size = UDim2.fromOffset(30, 28)
    b.Position = UDim2.new(1, x, 0, 6)
    b.BackgroundColor3 = color
    b.Text = txt
    b.TextColor3 = Color3.new(1, 1, 1)
    b.TextSize = 16
    b.Font = Enum.Font.GothamBold
    b.Parent = titleBar
    round(b, 6)
    return b
end
local layoutButton = topButton("LayoutMode", "AUTO", -108, Color3.fromRGB(65, 90, 125))
layoutButton.Size = UDim2.fromOffset(36, 28)
layoutButton.Position = UDim2.new(1, -112, 0, 6)
layoutButton.TextSize = 10
local minimizeButton = topButton("Minimize", "−", -72, Color3.fromRGB(75, 75, 85))
local close = topButton("Close", "X", -36, Color3.fromRGB(190, 45, 45))
layoutButton.MouseButton1Click:Connect(function()
    if layoutMode == "AUTO" then
        layoutMode = "COMPACT"
    elseif layoutMode == "COMPACT" then
        layoutMode = "LARGE"
    else
        layoutMode = "AUTO"
    end
    layoutButton.Text = layoutMode
    applyLayoutMode()
end)
local function bindViewport(camera)
    if camera then
        camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyLayoutMode)
    end
end
bindViewport(Workspace.CurrentCamera)
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    bindViewport(Workspace.CurrentCamera)
    applyLayoutMode()
end)

local throwTab = Instance.new("TextButton")
throwTab.Name = "ThrowTab"
throwTab.Size = UDim2.fromOffset(215, 30)
throwTab.Position = UDim2.fromOffset(12, 45)
throwTab.BackgroundColor3 = Color3.fromRGB(255, 193, 91)
throwTab.TextColor3 = Color3.fromRGB(18, 18, 21)
throwTab.Text = "AUTO THROW"
throwTab.Font = Enum.Font.GothamBold
throwTab.TextSize = 13
throwTab.Parent = frame
round(throwTab, 6)

local collectTab = Instance.new("TextButton")
collectTab.Name = "CollectTab"
collectTab.Size = UDim2.fromOffset(215, 30)
collectTab.Position = UDim2.fromOffset(243, 45)
collectTab.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
collectTab.TextColor3 = Color3.new(1, 1, 1)
collectTab.Text = "AUTO COLLECT"
collectTab.Font = Enum.Font.GothamBold
collectTab.TextSize = 13
collectTab.Parent = frame
round(collectTab, 6)

local throwPage = Instance.new("Frame")
throwPage.Name = "ThrowPage"
throwPage.Position = UDim2.fromOffset(0, 80)
throwPage.Size = UDim2.new(1, 0, 1, -80)
throwPage.BackgroundTransparency = 1
throwPage.Visible = true
throwPage.Parent = frame

local collectPage = Instance.new("Frame")
collectPage.Name = "CollectPage"
collectPage.Position = UDim2.fromOffset(0, 80)
collectPage.Size = UDim2.new(1, 0, 1, -80)
collectPage.BackgroundTransparency = 1
collectPage.Visible = false
collectPage.Parent = frame

local function showTab(which)
    local showThrow = which == "throw"
    throwPage.Visible = showThrow
    collectPage.Visible = not showThrow
    throwTab.BackgroundColor3 = showThrow and Color3.fromRGB(255, 193, 91) or Color3.fromRGB(45, 45, 55)
    throwTab.TextColor3 = showThrow and Color3.fromRGB(18, 18, 21) or Color3.new(1, 1, 1)
    collectTab.BackgroundColor3 = not showThrow and Color3.fromRGB(255, 193, 91) or Color3.fromRGB(45, 45, 55)
    collectTab.TextColor3 = not showThrow and Color3.fromRGB(18, 18, 21) or Color3.new(1, 1, 1)
end
throwTab.MouseButton1Click:Connect(function() showTab("throw") end)
collectTab.MouseButton1Click:Connect(function() showTab("collect") end)
showTab("collect")

-- Drag the whole panel using its title bar.
local UserInputService = game:GetService("UserInputService")
local dragging, dragStart, startPos = false, nil, nil
 titleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = frame.Position
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

-- Minimized floating icon; it can also be dragged.
local miniButton = Instance.new("TextButton")
miniButton.Name = "MiniIcon"
miniButton.Size = UDim2.fromOffset(54, 54)
miniButton.Position = UDim2.new(0.5, -27, 0.25, 0)
miniButton.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
miniButton.Text = "🍳"
miniButton.TextSize = 25
miniButton.TextColor3 = Color3.fromRGB(255, 193, 91)
miniButton.Font = Enum.Font.GothamBold
miniButton.Visible = false
miniButton.Active = true
miniButton.Parent = gui
round(miniButton, 27)
local miniStroke = Instance.new("UIStroke")
miniStroke.Color = Color3.fromRGB(255, 193, 91)
miniStroke.Thickness = 2
miniStroke.Parent = miniButton

local function makeDraggable(target, handle)
    local isDragging, startInput, startPosition = false, nil, nil
    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            isDragging = true
            startInput = input.Position
            startPosition = target.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then isDragging = false end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if isDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - startInput
            target.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X, startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
        end
    end)
end
makeDraggable(miniButton, miniButton)


-- SECRET TAP V4: detect the real game button and send repeated mouse taps.
-- The helper never covers the game's button or invents a progress percentage.
local secretTapActive = false
local secretTapCount = 0
local secretTapLast = 0
local secretTapStarted = 0
local secretTapMissingSince = nil
local secretTapInterval = 0.035 -- 28 taps/s maximum; engine may rate-limit inputs
local secretTapStatus = Instance.new("TextLabel")
secretTapStatus.Name = "SecretTapStatusV4"
secretTapStatus.Size = UDim2.fromOffset(310, 34)
secretTapStatus.Position = UDim2.new(0.5, -155, 1, -190)
secretTapStatus.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
secretTapStatus.BackgroundTransparency = 0.12
secretTapStatus.TextColor3 = Color3.fromRGB(90, 255, 125)
secretTapStatus.TextSize = 15
secretTapStatus.Font = Enum.Font.GothamBold
secretTapStatus.Text = "SECRET TAP AUTO"
secretTapStatus.Visible = false
secretTapStatus.ZIndex = 100
secretTapStatus.Parent = gui
round(secretTapStatus, 8)

local function visibleInHierarchy(obj)
    local node = obj
    while node and node ~= pg do
        if node:IsA("GuiObject") and not node.Visible then return false end
        if node:IsA("ScreenGui") and not node.Enabled then return false end
        node = node.Parent
    end
    return obj.AbsoluteSize.X > 10 and obj.AbsoluteSize.Y > 10
end

local function findOriginalSecretButton()
    local best, bestScore = nil, -1
    for _, obj in ipairs(pg:GetDescendants()) do
        if obj:IsA("GuiButton") and not obj:IsDescendantOf(gui) and visibleInHierarchy(obj) then
            local text = obj:IsA("TextButton") and tostring(obj.Text or "") or ""
            local candidate = string.lower(text .. " " .. obj.Name)
            for _, child in ipairs(obj:GetDescendants()) do
                if child:IsA("TextLabel") then
                    candidate = candidate .. " " .. string.lower(child.Text or "")
                end
            end
            local score = 0
            if candidate:find("tap tap tap", 1, true) then score = 100 end
            if score == 0 and candidate:find("tap", 1, true) and candidate:find("secret", 1, true) then score = 60 end
            if score > bestScore and score > 0 then best, bestScore = obj, score end
        end
    end
    return best
end

local function updateSecretTapHelper()
    local original = findOriginalSecretButton()
    local now = os.clock()
    if not original then
        if secretTapActive then
            if not secretTapMissingSince then secretTapMissingSince = now end
            if now - secretTapMissingSince > 0.20 then
                secretTapActive = false
                secretTapStatus.Visible = false
                log("SECRET TAP finished/disappeared; taps=" .. secretTapCount)
            end
        end
        return
    end
    secretTapMissingSince = nil
    if not secretTapActive then
        secretTapActive = true
        secretTapStarted = now
        secretTapCount = 0
        secretTapLast = 0
        log("SECRET TAP detected: " .. original:GetFullName())
    end
    secretTapStatus.Visible = true
    secretTapStatus.Text = "SECRET AUTO TAP | " .. secretTapCount .. " taps"
    if now - secretTapStarted > 4.0 then
        -- Do not keep clicking an unrelated stale UI indefinitely.
        secretTapActive = false
        secretTapStatus.Visible = false
        return
    end
    if now - secretTapLast < secretTapInterval then return end
    local center = original.AbsolutePosition + original.AbsoluteSize * 0.5
    if center.X < 0 or center.Y < 0 then return end
    secretTapLast = now
    local ok = pcall(function()
        VIM:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
        VIM:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
    end)
    if ok then secretTapCount = secretTapCount + 1 end
end

minimizeButton.MouseButton1Click:Connect(function()
    frame.Visible = false
    miniButton.Visible = true
end)
miniButton.MouseButton1Click:Connect(function()
    frame.Visible = true
    miniButton.Visible = false
end)

-- AUTO COLLECT UI helpers: redesigned to match the compact PaminHub layout.
local function label(txt, y, h, color, size)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1, -20, 0, h)
    l.Position = UDim2.fromOffset(10, y)
    l.BackgroundTransparency = 1
    l.Text = txt
    l.TextColor3 = color
    l.TextSize = size
    l.Font = Enum.Font.GothamBold
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextWrapped = true
    l.Parent = collectPage
    return l
end

label("PAMIN HUB", 9, 24, Color3.fromRGB(255,193,91), 15)
status = label("STATUS: OFF", 34, 22, Color3.fromRGB(230,230,230), 11)
local info = label("PAN: N/A | TARGET: N/A", 56, 42, Color3.fromRGB(255,193,91), 9)

local filterTitle = Instance.new("TextLabel")
filterTitle.Size = UDim2.new(1, -20, 0, 22)
filterTitle.Position = UDim2.fromOffset(10, 100)
filterTitle.BackgroundTransparency = 1
filterTitle.Text = "TARGET FILTERS"
filterTitle.TextColor3 = Color3.fromRGB(255,193,91)
filterTitle.TextSize = 10
filterTitle.Font = Enum.Font.GothamBold
filterTitle.TextXAlignment = Enum.TextXAlignment.Left
filterTitle.Parent = collectPage

-- Small switch used by the GUI.
local function makeSwitch(name, y, initial, callback)
    local row = Instance.new("Frame")
    row.Name = name .. "_Row"
    row.Size = UDim2.new(1, -20, 0, 31)
    row.Position = UDim2.fromOffset(10, y)
    row.BackgroundTransparency = 1
    row.Parent = collectPage

    local textLabel = Instance.new("TextLabel")
    textLabel.Name = "Label"
    textLabel.Size = UDim2.new(1, -110, 1, 0)
    textLabel.BackgroundTransparency = 1
    textLabel.TextColor3 = Color3.fromRGB(245,245,245)
    textLabel.TextSize = 12
    textLabel.Font = Enum.Font.GothamBold
    textLabel.TextXAlignment = Enum.TextXAlignment.Left
    textLabel.Parent = row

    local track = Instance.new("TextButton")
    track.Name = "Switch"
    track.Size = UDim2.fromOffset(92, 28)
    track.Position = UDim2.new(1, -92, 0, 1)
    track.BackgroundColor3 = Color3.fromRGB(48,50,58)
    track.BorderSizePixel = 0
    track.Text = ""
    track.AutoButtonColor = false
    track.Parent = row
    round(track, 6)

    local knob = Instance.new("Frame")
    knob.Name = "State"
    knob.Size = UDim2.fromOffset(44, 26)
    knob.BackgroundColor3 = Color3.fromRGB(0,165,75)
    knob.BorderSizePixel = 0
    knob.Parent = track
    round(knob, 6)

    local state = initial and true or false
    local function render()
        textLabel.Text = name
        knob.BackgroundColor3 = state and Color3.fromRGB(0,165,75) or Color3.fromRGB(235,0,25)
        knob.Position = state and UDim2.new(1, -44, 0, 1) or UDim2.fromOffset(0, 1)
    end
    local function setState(value, fire)
        state = value and true or false
        render()
        if fire and callback then callback(state) end
    end
    track.MouseButton1Click:Connect(function() setState(not state, true) end)
    render()
    return {Row=row, Button=track, Set=setState, Get=function() return state end}
end

local function setAutoCollect(enabled)
    if enabled then
        running=true
        flightActive=false
        collectedEstimate=0
        previousPan,previousPos,previousTime=nil,nil,nil
        lastPanMove=0
        candidateFrames=0
        lostSince=nil
        stoppedSince=nil
        initialCamera=Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame.Position
        target=nil
        lastFieldRefresh=0
        log("AUTO ON: waiting for flying pan")
    else
        stopAuto("AUTO OFF")
    end
    refresh()
end
local autoSwitch = makeSwitch("AUTO COLLECT", 126, false, function(enabled)
    setAutoCollect(enabled)
end)

-- Keep the old zone-setting compatibility table, but the dropdown now controls targeting.
local zoneSwitches = {}
local function updateZoneButton(zone)
    local control = zoneSwitches[zone]
    if control then control.Set(zoneEnabled[zone], false) end
end
local allZonesButton = Instance.new("TextButton")
allZonesButton.Visible = false
allZonesButton.Parent = collectPage
local noZonesButton = Instance.new("TextButton")
noZonesButton.Visible = false
noZonesButton.Parent = collectPage
local function setAllZones(enabled)
    for _, zone in ipairs(zoneNames) do zoneEnabled[zone] = enabled end
    itemCache = scanItems()
    target = nil
    releaseAll()
    log(enabled and "ALL GROUPS = ON" or "ALL GROUPS = OFF")
    refresh()
end
allZonesButton.MouseButton1Click:Connect(function() setAllZones(true) end)
noZonesButton.MouseButton1Click:Connect(function() setAllZones(false) end)

local dropdowns = {}
local itemDropdown
local function sortedItemsForFilters()
    local list, seen = {}, {}
    for _, zone in ipairs(zoneNames) do
        if matchesSelection(selectedZones, zone) then
            for _, rarity in ipairs(rarityNames) do
                if matchesSelection(selectedRarities, rarity) then
                    for _, itemName in ipairs(itemGroups[zone][rarity] or {}) do
                        if not seen[itemName] then
                            seen[itemName] = true
                            table.insert(list, itemName)
                        end
                    end
                end
            end
        end
    end
    table.sort(list)
    return list
end

local function createDropdown(name, y, allText, getOptions, onSelect)
    local row = Instance.new("Frame")
    row.Name = name .. "Row"
    row.Size = UDim2.new(1, -20, 0, 32)
    row.Position = UDim2.fromOffset(10, y)
    row.BackgroundTransparency = 1
    row.Parent = collectPage

    local left = Instance.new("TextLabel")
    left.Size = UDim2.new(0, 112, 1, 0)
    left.BackgroundTransparency = 1
    left.Text = name
    left.TextColor3 = Color3.fromRGB(245,245,245)
    left.TextSize = 12
    left.Font = Enum.Font.GothamBold
    left.TextXAlignment = Enum.TextXAlignment.Left
    left.Parent = row

    local button = Instance.new("TextButton")
    button.Name = name .. "Button"
    button.Size = UDim2.new(1, -112, 0, 28)
    button.Position = UDim2.new(0, 112, 0, 2)
    button.BackgroundColor3 = Color3.fromRGB(45,45,55)
    button.BorderSizePixel = 0
    button.TextColor3 = Color3.new(1,1,1)
    button.TextSize = 11
    button.Font = Enum.Font.GothamBold
    button.TextTruncate = Enum.TextTruncate.AtEnd
    button.Parent = row
    round(button, 6)

    local popup = Instance.new("ScrollingFrame")
    popup.Name = name .. "Dropdown"
    popup.Size = UDim2.new(1, -112, 0, 144)
    popup.Position = UDim2.new(0, 112, 1, 1)
    popup.BackgroundColor3 = Color3.fromRGB(27,27,32)
    popup.BorderSizePixel = 0
    popup.ScrollBarThickness = 5
    popup.CanvasSize = UDim2.fromOffset(0,0)
    popup.Visible = false
    popup.ZIndex = 20
    popup.Parent = row
    round(popup, 6)
    local listLayout = Instance.new("UIListLayout")
    listLayout.Padding = UDim.new(0,2)
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Parent = popup
    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0,4)
    pad.PaddingBottom = UDim.new(0,4)
    pad.PaddingLeft = UDim.new(0,4)
    pad.PaddingRight = UDim.new(0,4)
    pad.Parent = popup

    local selected = {}
    local function getNames()
        local names = {}
        for _, option in ipairs(getOptions()) do
            if option ~= allText and selected[option] then
                table.insert(names, option)
            end
        end
        return names
    end
    local function renderButton()
        local names = getNames()
        local caption = #names == 0 and allText or table.concat(names, ", ")
        button.Text = caption .. (popup.Visible and "  ▲" or "  ▼")
    end
    local function rebuildOptions()
        for _, child in ipairs(popup:GetChildren()) do
            if child:IsA("TextButton") then child:Destroy() end
        end
        local options = getOptions()
        popup.CanvasSize = UDim2.fromOffset(0, #options * 30 + 8)
        for index, option in ipairs(options) do
            local active = option == allText and next(selected) == nil or selected[option] == true
            local opt = Instance.new("TextButton")
            opt.Name = "Option_" .. index
            opt.Size = UDim2.new(1, -4, 0, 28)
            opt.BackgroundColor3 = active and Color3.fromRGB(255,193,91) or Color3.fromRGB(45,45,55)
            opt.BorderSizePixel = 0
            opt.TextColor3 = active and Color3.fromRGB(18,18,21) or Color3.new(1,1,1)
            opt.TextSize = 11
            opt.Font = Enum.Font.Gotham
            opt.Text = (active and "☑ " or "☐ ") .. option
            opt.TextXAlignment = Enum.TextXAlignment.Left
            opt.LayoutOrder = index
            opt.ZIndex = 21
            opt.Parent = popup
            round(opt, 4)
            opt.MouseButton1Click:Connect(function()
                if option == allText then
                    selected = {}
                else
                    selected[option] = not selected[option] or nil
                end
                onSelect(getNames())
                rebuildOptions()
                renderButton()
            end)
        end
    end
    button.MouseButton1Click:Connect(function()
        if popup.Visible then
            popup.Visible = false
        else
            for _, dd in ipairs(dropdowns) do
                dd.Close()
            end
            rebuildOptions()
            popup.Visible = true
        end
        renderButton()
    end)
    table.insert(dropdowns, {Close=function()
        popup.Visible = false
        renderButton()
    end})
    renderButton()
    return {
        Set = function(values)
            selected = arraySelection(values, getOptions())
            renderButton()
            if popup.Visible then rebuildOptions() end
        end,
        Get = getNames,
        Refresh = function()
            local valid = {}
            for _, option in ipairs(getOptions()) do valid[option] = true end
            for option in pairs(selected) do
                if not valid[option] then selected[option] = nil end
            end
            if popup.Visible then rebuildOptions() end
            renderButton()
        end,
        Button = button,
    }
end

local zoneDropdown = createDropdown("ZONE", 164, "All Zones", function()
    local options = {"All Zones"}
    for _, zone in ipairs(zoneNames) do table.insert(options, zone) end
    return options
end, function(values)
    selectedZones = arraySelection(values, zoneNames)
    selectedItems = {}
    itemDropdown.Set({})
    itemDropdown.Refresh()
    itemCache = scanItems()
    target = nil
    releaseAll()
    log("ZONE FILTER = " .. (#values > 0 and table.concat(values, ", ") or "All Zones"))
    refresh()
end)
local rarityDropdown = createDropdown("RARITY", 202, "All Rarities", function()
    local options = {"All Rarities"}
    for _, rarity in ipairs(rarityNames) do table.insert(options, rarity) end
    return options
end, function(values)
    selectedRarities = arraySelection(values, rarityNames)
    selectedItems = {}
    itemDropdown.Set({})
    itemDropdown.Refresh()
    target = nil
    releaseAll()
    log("RARITY FILTER = " .. (#values > 0 and table.concat(values, ", ") or "All Rarities"))
    refresh()
end)
itemDropdown = createDropdown("TARGETING", 240, "All Items", function()
    local options = {"All Items"}
    for _, itemName in ipairs(sortedItemsForFilters()) do table.insert(options, itemName) end
    return options
end, function(values)
    selectedItems = arraySelection(values, sortedItemsForFilters())
    target = nil
    releaseAll()
    log("ITEM FILTER = " .. (#values > 0 and table.concat(values, ", ") or "All Items"))
    refresh()
end)

local modeControl = Instance.new("TextButton")
modeControl.Name = "ModeButton"
modeControl.Size = UDim2.fromOffset(92, 28)
modeControl.Position = UDim2.new(1, -102, 0, 278)
modeControl.BackgroundColor3 = Color3.fromRGB(255,193,91)
modeControl.TextColor3 = Color3.fromRGB(18,18,21)
modeControl.Text = "NEAREST"
modeControl.TextSize = 12
modeControl.Font = Enum.Font.GothamBold
modeControl.Parent = collectPage
round(modeControl, 6)

local modeLabel = label("MODE", 274, 30, Color3.fromRGB(245,245,245), 12)
modeLabel.Size = UDim2.fromOffset(120, 30)

local adControl = Instance.new("TextButton")
adControl.Name = "ADButton"
adControl.Size = UDim2.fromOffset(92, 28)
adControl.Position = UDim2.new(1, -102, 0, 316)
adControl.BackgroundColor3 = Color3.fromRGB(255,193,91)
adControl.TextColor3 = Color3.fromRGB(18,18,21)
adControl.Text = "NORMAL"
adControl.TextSize = 12
adControl.Font = Enum.Font.GothamBold
adControl.Parent = collectPage
round(adControl, 6)

local adLabel = label("A/D", 312, 30, Color3.fromRGB(245,245,245), 12)
adLabel.Size = UDim2.fromOffset(120, 30)

-- Log area is clipped inside its own frame so text can never spill outside GUI.
local logFrame = Instance.new("Frame")
logFrame.Name = "LogFrame"
logFrame.Size = UDim2.new(1, -20, 0, 88)
logFrame.Position = UDim2.fromOffset(10, 354)
logFrame.BackgroundColor3 = Color3.fromRGB(30,30,33)
logFrame.BorderSizePixel = 0
logFrame.ClipsDescendants = true
logFrame.Parent = collectPage
round(logFrame, 6)

local out = Instance.new("TextBox")
out.Name = "Log"
out.Size = UDim2.new(1, -10, 1, -8)
out.Position = UDim2.fromOffset(5, 4)
out.BackgroundTransparency = 1
out.TextColor3 = Color3.fromRGB(225,225,225)
out.Font = Enum.Font.Code
out.TextSize = 9
out.TextXAlignment = Enum.TextXAlignment.Left
out.TextYAlignment = Enum.TextYAlignment.Bottom
out.TextEditable = false
out.MultiLine = true
out.ClearTextOnFocus = false
out.TextWrapped = false
out.Text = "Ready. Press AUTO COLLECT to start."
out.ClipsDescendants = true
out.Parent = logFrame

local copy = Instance.new("TextButton")
copy.Name = "CopyLog"
copy.Size = UDim2.fromOffset(92, 28)
copy.Position = UDim2.new(0.5, -46, 0, 452)
copy.BackgroundColor3 = Color3.fromRGB(255,193,91)
copy.TextColor3 = Color3.fromRGB(18,18,18)
copy.Font = Enum.Font.GothamBold
copy.TextSize = 12
copy.Text = "COPY LOG"
copy.Parent = collectPage
round(copy, 6)

-- Compatibility controls for scripts that may still look for the old button names.
on = Instance.new("TextButton")
on.Name = "AutoOnCompat"
on.Visible = false
on.Parent = collectPage
off = Instance.new("TextButton")
off.Name = "AutoOffCompat"
off.Visible = false
off.Parent = collectPage

-- MODE button: toggles both the visible name and the target-selection behavior.
-- NEAREST = choose the closest suitable target.
-- RARE    = keep the same targeting logic, but give rare/high-priority items a score bonus.
modeControl.MouseButton1Click:Connect(function()
    if priorityMode == "NEAREST" then
        priorityMode = "RARE"
    else
        priorityMode = "NEAREST"
    end

    modeControl.Text = priorityMode
    log("MODE changed to: " .. priorityMode)
    refresh()
end)

-- A/D button: toggles both the visible name and the actual steering direction.
-- NORMAL   = A steers left / D steers right.
-- REVERSED = D steers left / A steers right.
adControl.MouseButton1Click:Connect(function()
    reverseAD = not reverseAD

    if reverseAD then
        adControl.Text = "REVERSED"
    else
        adControl.Text = "NORMAL"
    end

    -- Release the old direction immediately so no previous key remains held.
    releaseAll()
    log("A/D mode changed to: " .. (reverseAD and "REVERSED" or "NORMAL"))
    refresh()
end)

-- AUTO THROW UI.
local throwTitle = Instance.new("TextLabel")
throwTitle.Size = UDim2.new(1, -24, 0, 32)
throwTitle.Position = UDim2.fromOffset(12, 12)
throwTitle.BackgroundTransparency = 1
throwTitle.Text = "AUTO THROW SETTINGS"
throwTitle.TextColor3 = Color3.fromRGB(255,193,91)
throwTitle.TextSize = 18
throwTitle.Font = Enum.Font.GothamBold
throwTitle.TextXAlignment = Enum.TextXAlignment.Left
throwTitle.Parent = throwPage

local throwStatus = Instance.new("TextLabel")
throwStatus.Size = UDim2.new(1, -24, 0, 28)
throwStatus.Position = UDim2.fromOffset(12, 52)
throwStatus.BackgroundTransparency = 1
throwStatus.Text = "STATUS: OFF"
throwStatus.TextColor3 = Color3.fromRGB(255,100,100)
throwStatus.TextSize = 14
throwStatus.Font = Enum.Font.GothamBold
throwStatus.TextXAlignment = Enum.TextXAlignment.Left
throwStatus.Parent = throwPage

local delayLabel = Instance.new("TextLabel")
delayLabel.Size = UDim2.fromOffset(180, 32)
delayLabel.Position = UDim2.fromOffset(12, 96)
delayLabel.BackgroundTransparency = 1
delayLabel.Text = "ubah nilai menjadi 650 >>"
delayLabel.TextColor3 = Color3.new(1,1,1)
delayLabel.TextSize = 13
delayLabel.Font = Enum.Font.Gotham
 delayLabel.TextXAlignment = Enum.TextXAlignment.Left
delayLabel.Parent = throwPage

local delayBox = Instance.new("TextBox")
delayBox.Size = UDim2.fromOffset(150, 34)
delayBox.Position = UDim2.fromOffset(205, 95)
delayBox.Text = "1900"
delayBox.PlaceholderText = "Delay (ms)"
delayBox.BackgroundColor3 = Color3.fromRGB(45,45,55)
delayBox.TextColor3 = Color3.new(1,1,1)
delayBox.TextSize = 16
delayBox.Font = Enum.Font.GothamBold
delayBox.ClearTextOnFocus = false
delayBox.Parent = throwPage
round(delayBox, 6)

local throwInfo = Instance.new("TextLabel")
throwInfo.Size = UDim2.new(1, -24, 0, 55)
throwInfo.Position = UDim2.fromOffset(12, 140)
throwInfo.BackgroundTransparency = 1
throwInfo.Text = "Untuk uji coba, jangan disebar oke !!"
throwInfo.TextColor3 = Color3.fromRGB(190,190,200)
throwInfo.TextSize = 12
throwInfo.Font = Enum.Font.Gotham
throwInfo.TextWrapped = true
throwInfo.TextXAlignment = Enum.TextXAlignment.Left
throwInfo.Parent = throwPage

local throwStart = Instance.new("TextButton")
throwStart.Size = UDim2.fromOffset(205, 42)
throwStart.Position = UDim2.fromOffset(12, 215)
throwStart.BackgroundColor3 = Color3.fromRGB(30,155,75)
throwStart.Text = "START"
throwStart.TextColor3 = Color3.new(1,1,1)
throwStart.TextSize = 15
throwStart.Font = Enum.Font.GothamBold
throwStart.Parent = throwPage
round(throwStart, 7)
local throwStop = Instance.new("TextButton")
throwStop.Size = UDim2.fromOffset(205, 42)
throwStop.Position = UDim2.fromOffset(243, 215)
throwStop.BackgroundColor3 = Color3.fromRGB(190,55,55)
throwStop.Text = "STOP"
throwStop.TextColor3 = Color3.new(1,1,1)
throwStop.TextSize = 15
throwStop.Font = Enum.Font.GothamBold
throwStop.Parent = throwPage
round(throwStop, 7)

local throwState = { Running = false, Closed = false, Delay = 1.9, RoundDelay = 5, Token = 0 }
-- V5: pause throwing while BASE is open or a placement cycle is underway.
local placeState = { Enabled = false, Busy = false, Interval = 30, LastRun = os.clock(), Count = 0 }
local function basePanel()
    local hud = pg:FindFirstChild("PanThrowHUD")
    local root = hud and hud:FindFirstChild("Frame")
    return root and root:FindFirstChild("base")
end
local function baseOpen()
    local panel = basePanel()
    if not panel then return false end
    local node = panel
    while node and node ~= pg do
        if node:IsA("GuiObject") and not node.Visible then return false end
        if node:IsA("ScreenGui") and not node.Enabled then return false end
        node = node.Parent
    end
    return true
end
local function throwBlocked()
    return placeState.Busy or baseOpen() or secretTapActive
end

local placeTitle = Instance.new("TextLabel")
placeTitle.Name = "PlaceBestTitleV5"
placeTitle.Size = UDim2.new(1, -24, 0, 24)
placeTitle.Position = UDim2.fromOffset(12, 476)
placeTitle.BackgroundTransparency = 1
placeTitle.Text = "AUTO PLACE BEST ITEM"
placeTitle.TextColor3 = Color3.fromRGB(255, 193, 91)
placeTitle.Font = Enum.Font.GothamBold
placeTitle.TextSize = 14
placeTitle.TextXAlignment = Enum.TextXAlignment.Left
placeTitle.Parent = throwPage

local placeToggle = Instance.new("TextButton")
placeToggle.Name = "AutoPlaceBestToggleV5"
placeToggle.Size = UDim2.fromOffset(205, 36)
placeToggle.Position = UDim2.fromOffset(12, 504)
placeToggle.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
placeToggle.Text = "AUTO PLACE: OFF"
placeToggle.TextColor3 = Color3.new(1, 1, 1)
placeToggle.Font = Enum.Font.GothamBold
placeToggle.TextSize = 12
placeToggle.Parent = throwPage
round(placeToggle, 6)

local placeIntervalBox = Instance.new("TextBox")
placeIntervalBox.Name = "AutoPlaceIntervalV5"
placeIntervalBox.Size = UDim2.fromOffset(205, 36)
placeIntervalBox.Position = UDim2.fromOffset(243, 504)
placeIntervalBox.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
placeIntervalBox.TextColor3 = Color3.new(1, 1, 1)
placeIntervalBox.Font = Enum.Font.GothamBold
placeIntervalBox.TextSize = 12
placeIntervalBox.Text = "30"
placeIntervalBox.PlaceholderText = "Interval (detik)"
placeIntervalBox.ClearTextOnFocus = false
placeIntervalBox.Parent = throwPage
round(placeIntervalBox, 6)

local placeStatus = Instance.new("TextLabel")
placeStatus.Name = "AutoPlaceStatusV5"
placeStatus.Size = UDim2.new(1, -24, 0, 36)
placeStatus.Position = UDim2.fromOffset(12, 545)
placeStatus.BackgroundTransparency = 1
placeStatus.TextColor3 = Color3.fromRGB(185, 185, 195)
placeStatus.Font = Enum.Font.Gotham
placeStatus.TextSize = 11
placeStatus.TextWrapped = true
placeStatus.TextXAlignment = Enum.TextXAlignment.Left
placeStatus.Text = "BASE > PLACE BEST > CLOSE | interval 30 detik"
placeStatus.Parent = throwPage

local function setPlaceEnabled(enabled)
    placeState.Enabled = enabled == true
    placeState.LastRun = os.clock()
    placeToggle.Text = "AUTO PLACE: " .. (placeState.Enabled and "ON" or "OFF")
    placeToggle.BackgroundColor3 = placeState.Enabled and Color3.fromRGB(30, 145, 75) or Color3.fromRGB(80, 80, 90)
    placeStatus.Text = placeState.Enabled and "Menunggu interval berikutnya..." or "AUTO PLACE OFF"
end
placeToggle.MouseButton1Click:Connect(function() setPlaceEnabled(not placeState.Enabled) end)
placeIntervalBox.FocusLost:Connect(function()
    local n = tonumber(placeIntervalBox.Text)
    if not n then n = 30 end
    placeState.Interval = math.clamp(math.floor(n), 5, 3600)
    placeIntervalBox.Text = tostring(placeState.Interval)
    placeState.LastRun = os.clock()
end)


-- SETTINGS / REJOIN / AUTO EXECUTE (Delta-compatible when the executor exposes these APIs)
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local SETTINGS_FILE = "PaminHub_Settings.json"
local autoRejoin = false
local autoExecute = false
local autoExecuteUrl = ""

local function makeActionButton(name, text, x, y, width, color)
    local b = Instance.new("TextButton")
    b.Name = name
    b.Size = UDim2.fromOffset(width, 38)
    b.Position = UDim2.fromOffset(x, y)
    b.BackgroundColor3 = color
    b.Text = text
    b.TextColor3 = Color3.new(1, 1, 1)
    b.TextSize = 12
    b.Font = Enum.Font.GothamBold
    b.Parent = throwPage
    round(b, 7)
    return b
end

local saveSettingsButton = makeActionButton(
    "SaveSettings", "SAVE SETTINGS", 12, 280, 205, Color3.fromRGB(35, 125, 75)
)
local loadSettingsButton = makeActionButton(
    "LoadSettings", "LOAD SETTINGS", 243, 280, 205, Color3.fromRGB(55, 95, 155)
)
local rejoinButton = makeActionButton(
    "AutoRejoin", "AUTO REJOIN: OFF", 12, 326, 205, Color3.fromRGB(75, 75, 85)
)
local executeButton = makeActionButton(
    "AutoExecute", "AUTO EXECUTE: OFF", 243, 326, 205, Color3.fromRGB(75, 75, 85)
)

local executeUrlBox = Instance.new("TextBox")
executeUrlBox.Name = "AutoExecuteURL"
executeUrlBox.Size = UDim2.new(1, -24, 0, 34)
executeUrlBox.Position = UDim2.fromOffset(12, 372)
executeUrlBox.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
executeUrlBox.TextColor3 = Color3.new(1, 1, 1)
executeUrlBox.PlaceholderText = "GitHub RAW URL untuk script ini (opsional)"
executeUrlBox.Text = ""
executeUrlBox.TextSize = 11
executeUrlBox.Font = Enum.Font.Gotham
executeUrlBox.ClearTextOnFocus = false
executeUrlBox.Parent = throwPage
round(executeUrlBox, 6)

local settingsNote = Instance.new("TextLabel")
settingsNote.Name = "SettingsNote"
settingsNote.Size = UDim2.new(1, -24, 0, 62)
settingsNote.Position = UDim2.fromOffset(12, 414)
settingsNote.BackgroundTransparency = 1
settingsNote.Text = "SAVE/LOAD memakai filesystem executor. AUTO EXECUTE memerlukan URL RAW script yang dapat diakses. Rejoin tidak dapat memulihkan koneksi jika aplikasi/game ditutup paksa."
settingsNote.TextColor3 = Color3.fromRGB(190, 190, 200)
settingsNote.TextSize = 11
settingsNote.Font = Enum.Font.Gotham
settingsNote.TextWrapped = true
settingsNote.TextXAlignment = Enum.TextXAlignment.Left
settingsNote.TextYAlignment = Enum.TextYAlignment.Top
settingsNote.Parent = throwPage

local function executorFunction(...)
    for _, name in ipairs({...}) do
        local fn = getgenv and getgenv()[name] or _G[name]
        if typeof(fn) == "function" then return fn end
    end
    return nil
end

local function collectSettings()
    local zones = {}
    for _, zone in ipairs(zoneNames) do
        zones[zone] = zoneEnabled[zone] == true
    end
    return {
        version = 1,
        delayMs = tonumber(delayBox.Text) or 1900,
        priorityMode = priorityMode,
        reverseAD = reverseAD,
        zoneEnabled = zones,
        selectedZones = selectionArray(selectedZones, zoneNames),
        selectedRarities = selectionArray(selectedRarities, rarityNames),
        selectedItems = selectionArray(selectedItems, sortedItemsForFilters()),
        layoutMode = layoutMode,
        autoRejoin = autoRejoin,
        autoExecute = autoExecute,
        autoExecuteUrl = executeUrlBox.Text or "",
        autoPlaceBest = placeState.Enabled,
        autoPlaceInterval = placeState.Interval,
    }
end

local function saveSettings()
    local write = executorFunction("writefile")
    if not write then
        throwStatus.Text = "STATUS: EXECUTOR FILE API UNAVAILABLE"
        settingsNote.Text = "Delta tidak menyediakan writefile pada sesi ini. Pengaturan tidak dapat disimpan permanen."
        return
    end
    local ok, err = pcall(function()
        write(SETTINGS_FILE, HttpService:JSONEncode(collectSettings()))
    end)
    if ok then
        throwStatus.Text = "STATUS: SETTINGS SAVED"
        settingsNote.Text = "Pengaturan tersimpan ke " .. SETTINGS_FILE
    else
        throwStatus.Text = "STATUS: SAVE FAILED"
        settingsNote.Text = "Gagal menyimpan: " .. tostring(err)
    end
end

local function loadSettings()
    local read = executorFunction("readfile")
    local exists = executorFunction("isfile")
    if not read then
        throwStatus.Text = "STATUS: EXECUTOR FILE API UNAVAILABLE"
        settingsNote.Text = "Delta tidak menyediakan readfile pada sesi ini. Pengaturan tidak dapat dimuat."
        return
    end
    if exists then
        local okExists, found = pcall(exists, SETTINGS_FILE)
        if okExists and not found then
            throwStatus.Text = "STATUS: NO SAVED SETTINGS"
            return
        end
    end

    local ok, data = pcall(function()
        return HttpService:JSONDecode(read(SETTINGS_FILE))
    end)
    if not ok or type(data) ~= "table" then
        throwStatus.Text = "STATUS: LOAD FAILED"
        settingsNote.Text = "File pengaturan tidak ditemukan atau formatnya rusak."
        return
    end

    local placeSeconds = tonumber(data.autoPlaceInterval)
    if placeSeconds then
        placeState.Interval = math.clamp(math.floor(placeSeconds), 5, 3600)
        placeIntervalBox.Text = tostring(placeState.Interval)
    end
    setPlaceEnabled(data.autoPlaceBest == true)

    local ms = tonumber(data.delayMs)
    if ms and ms >= 100 then delayBox.Text = tostring(math.floor(ms)) end

    if data.priorityMode == "NEAREST" or data.priorityMode == "RARE" then
        priorityMode = data.priorityMode
        modeControl.Text = priorityMode
    end

    if type(data.reverseAD) == "boolean" then
        reverseAD = data.reverseAD
        adControl.Text = reverseAD and "REVERSED" or "NORMAL"
    end

    if type(data.zoneEnabled) == "table" then
        for _, zone in ipairs(zoneNames) do
            if type(data.zoneEnabled[zone]) == "boolean" then
                zoneEnabled[zone] = data.zoneEnabled[zone]
                updateZoneButton(zone)
            end
        end
        itemCache = scanItems()
        target = nil
        releaseAll()
    end

    selectedZones = arraySelection(data.selectedZones or data.selectedZone, zoneNames)
    selectedRarities = arraySelection(data.selectedRarities or data.selectedRarity, rarityNames)
    zoneDropdown.Set(selectionArray(selectedZones, zoneNames))
    rarityDropdown.Set(selectionArray(selectedRarities, rarityNames))
    selectedItems = arraySelection(data.selectedItems or data.selectedItem, sortedItemsForFilters())
    itemDropdown.Set(selectionArray(selectedItems, sortedItemsForFilters()))
    itemDropdown.Refresh()

    if data.layoutMode == "AUTO" or data.layoutMode == "COMPACT" or data.layoutMode == "LARGE" then
        layoutMode = data.layoutMode
        layoutButton.Text = layoutMode
        applyLayoutMode()
    end

    autoRejoin = data.autoRejoin == true
    autoExecute = data.autoExecute == true
    autoExecuteUrl = type(data.autoExecuteUrl) == "string" and data.autoExecuteUrl or ""
    executeUrlBox.Text = autoExecuteUrl
    rejoinButton.Text = "AUTO REJOIN: " .. (autoRejoin and "ON" or "OFF")
    executeButton.Text = "AUTO EXECUTE: " .. (autoExecute and "ON" or "OFF")
    rejoinButton.BackgroundColor3 = autoRejoin and Color3.fromRGB(30, 145, 75) or Color3.fromRGB(75, 75, 85)
    executeButton.BackgroundColor3 = autoExecute and Color3.fromRGB(30, 145, 75) or Color3.fromRGB(75, 75, 85)

    throwStatus.Text = "STATUS: SETTINGS LOADED"
    settingsNote.Text = "Pengaturan berhasil dimuat. Tekan SAVE SETTINGS setelah mengubah pilihan."
    refresh()
end

saveSettingsButton.MouseButton1Click:Connect(saveSettings)
loadSettingsButton.MouseButton1Click:Connect(loadSettings)

rejoinButton.MouseButton1Click:Connect(function()
    autoRejoin = not autoRejoin
    rejoinButton.Text = "AUTO REJOIN: " .. (autoRejoin and "ON" or "OFF")
    rejoinButton.BackgroundColor3 = autoRejoin and Color3.fromRGB(30, 145, 75) or Color3.fromRGB(75, 75, 85)
    settingsNote.Text = autoRejoin
        and "Auto Rejoin aktif untuk kegagalan teleport yang terdeteksi. Putus koneksi total mungkin tetap memerlukan reconnect manual."
        or "Auto Rejoin nonaktif."
end)

executeButton.MouseButton1Click:Connect(function()
    autoExecute = not autoExecute
    autoExecuteUrl = executeUrlBox.Text or ""
    executeButton.Text = "AUTO EXECUTE: " .. (autoExecute and "ON" or "OFF")
    executeButton.BackgroundColor3 = autoExecute and Color3.fromRGB(30, 145, 75) or Color3.fromRGB(75, 75, 85)
    if autoExecute and autoExecuteUrl == "" then
        settingsNote.Text = "Masukkan URL GitHub RAW script ini terlebih dahulu. Tanpa URL, script tidak dapat dijalankan ulang setelah teleport."
    else
        settingsNote.Text = autoExecute
            and "Auto Execute aktif; script akan diantrekan saat teleport jika API executor tersedia."
            or "Auto Execute nonaktif."
    end
end)

local function queueAutoExecute()
    if not autoExecute or autoExecuteUrl == "" then return end
    local queue = executorFunction("queue_on_teleport", "queueonteleport", "queueonteleport")
    if not queue then
        settingsNote.Text = "API queue_on_teleport tidak tersedia pada executor ini."
        return
    end
    local escapedUrl = string.format("%q", autoExecuteUrl)
    local payload = "loadstring(game:HttpGet(" .. escapedUrl .. "))()"
    pcall(queue, payload)
end

-- Queue the script for successful teleports. This does not guarantee recovery
-- from a hard disconnect or a closed Roblox app.
pcall(function()
    player.OnTeleport:Connect(function(state)
        if state == Enum.TeleportState.Started then
            queueAutoExecute()
        end
    end)
end)

local rejoinBusy = false
pcall(function()
    TeleportService.TeleportInitFailed:Connect(function(failedPlayer, result, message)
        if failedPlayer ~= player or not autoRejoin or rejoinBusy or throwState.Closed then return end
        rejoinBusy = true
        settingsNote.Text = "Teleport gagal; mencoba bergabung kembali..."
        task.delay(4, function()
            if not autoRejoin or throwState.Closed then rejoinBusy = false; return end
            pcall(function()
                TeleportService:Teleport(game.PlaceId, player)
            end)
            task.delay(8, function() rejoinBusy = false end)
        end)
    end)
end)

local function pressE()
    if throwState.Closed then return end
    pcall(function() VIM:SendKeyEvent(true, Enum.KeyCode.E, false, game) end)
    task.wait(0.06)
    pcall(function() VIM:SendKeyEvent(false, Enum.KeyCode.E, false, game) end)
end
local function stopThrow()
    throwState.Running = false
    throwState.Token = throwState.Token + 1
    throwStatus.Text = "STATUS: OFF"
    throwStatus.TextColor3 = Color3.fromRGB(255,100,100)
end
local function waitThrow(seconds, token)
    local finish = os.clock() + seconds
    while os.clock() < finish do
        if throwState.Closed or not throwState.Running or throwState.Token ~= token then return false end
        -- Preserve the remaining delay while the BASE menu/SECRET overlay blocks throwing.
        if throwBlocked() then
            local pauseStart = os.clock()
            repeat
                if throwState.Closed or not throwState.Running or throwState.Token ~= token then return false end
                task.wait(0.05)
            until not throwBlocked()
            finish = finish + (os.clock() - pauseStart)
        end
        task.wait(math.min(0.02, math.max(0, finish - os.clock())))
    end
    return true
end

-- Navigate to the game's ThrowZone before starting the existing throw cycle.
-- Uses normal Humanoid:MoveTo movement (not teleporting). If already inside, skip movement.
local function getCharacterRoot()
    local character = player.Character
    if not character then return nil, nil end
    return character:FindFirstChildOfClass("Humanoid"), character:FindFirstChild("HumanoidRootPart")
end

local function isInsideThrowZone(root, zone)
    if not root or not zone or not zone:IsA("BasePart") then return false end
    local localPos = zone.CFrame:PointToObjectSpace(root.Position)
    local half = zone.Size * 0.5
    return math.abs(localPos.X) <= half.X + 1.5
       and math.abs(localPos.Z) <= half.Z + 1.5
       and localPos.Y >= -half.Y - 5
       and localPos.Y <= half.Y + 8
end

local function moveToThrowZone(token)
    local map = Workspace:FindFirstChild("Map")
    local zone = map and map:FindFirstChild("ThrowZone")
    if not zone or not zone:IsA("BasePart") then
        log("THROW ZONE NOT FOUND: Workspace.Map.ThrowZone")
        throwStatus.Text = "STATUS: THROWZONE NOT FOUND"
        return false
    end
    local humanoid, root = getCharacterRoot()
    if not humanoid or not root then
        log("CHARACTER ROOT/HUMANOID NOT FOUND")
        throwStatus.Text = "STATUS: CHARACTER NOT READY"
        return false
    end
    if isInsideThrowZone(root, zone) then
        log("Already inside ThrowZone; skipping navigation")
        return true
    end
    throwStatus.Text = "STATUS: MOVING TO THROWZONE"
    log("Moving to ThrowZone")
    humanoid:MoveTo(Vector3.new(zone.Position.X, root.Position.Y, zone.Position.Z))
    local deadline = os.clock() + 18
    while os.clock() < deadline do
        if throwState.Closed or not throwState.Running or throwState.Token ~= token then return false end
        humanoid, root = getCharacterRoot()
        if humanoid and root and isInsideThrowZone(root, zone) then
            log("Reached ThrowZone")
            return true
        end
        task.wait(0.2)
    end
    log("Could not reach ThrowZone within 18 seconds; Auto Throw paused")
    throwStatus.Text = "STATUS: THROWZONE UNREACHED"
    return false
end

throwStart.MouseButton1Click:Connect(function()
    if throwState.Running or throwState.Closed then return end
    local ms = tonumber(delayBox.Text)
    if not ms or ms < 100 then ms = 1900; delayBox.Text = "1900" end
    throwState.Delay = ms / 1000
    throwState.Running = true
    throwState.Token = throwState.Token + 1
    local token = throwState.Token
    throwStatus.Text = "STATUS: CHECKING THROWZONE"
    throwStatus.TextColor3 = Color3.fromRGB(255,210,100)
    task.spawn(function()
        if not moveToThrowZone(token) then
            if throwState.Token == token and throwState.Running then
                throwState.Running = false
                throwStatus.TextColor3 = Color3.fromRGB(255,100,100)
            end
            return
        end
        throwStatus.Text = "STATUS: THROW ZONE >> SCAN ITEM >> THROW >> COLLECT"
        throwStatus.TextColor3 = Color3.fromRGB(80,255,130)
        while throwState.Running and not throwState.Closed and throwState.Token == token do
            while throwBlocked() and throwState.Running and throwState.Token == token do task.wait(0.05) end
            if not throwState.Running or throwState.Token ~= token then break end
            pressE()
            if not waitThrow(throwState.Delay, token) then break end
            while throwBlocked() and throwState.Running and throwState.Token == token do task.wait(0.05) end
            if not throwState.Running or throwState.Token ~= token then break end
            pressE()
            if not waitThrow(throwState.RoundDelay, token) then break end
        end
    end)
end)
throwStop.MouseButton1Click:Connect(stopThrow)

refresh = function()
          out.Text=table.concat(lines,"\n")
end

local function itemKind(name)
    local lowerName = string.lower(name)
    for _, fragment in ipairs(known) do
        if string.find(lowerName, string.lower(fragment), 1, true) then
            return fragment
        end
    end
    return nil
end

scanItems = function()
    local f = Workspace:FindFirstChild("PT_Field")
    if not f then
        log("SCAN: Workspace.PT_Field not found")
        return {}
    end
    local found, seen = {}, {}
    for _, o in ipairs(f:GetDescendants()) do
        local kind = itemKind(o.Name)
        if kind then
            local p = posOf(o)
            if p then
                local zone = zoneForPosition(p)
                if not seen[o] then
                    seen[o] = true
                    table.insert(found, {obj=o, pos=p, kind=kind, zone=zone})
                end
            end
        end
    end
    return found
end

local function chooseTarget(panPos, speed)

          local best, bestScore

          for _,item in ipairs(itemCache) do

                    local zoneMatch = matchesSelection(selectedZones, item.zone)
                    local rarityMatch = matchesSelection(selectedRarities, itemRarity[item.kind])
                    local itemMatch = matchesSelection(selectedItems, item.kind)
                    if item.obj.Parent and zoneMatch and rarityMatch and itemMatch then

                              local p=posOf(item.obj)

                              if p then

                                        local dz=p.Z-panPos.Z

                                        local dx=p.X-panPos.X

                                        local dy=p.Y-panPos.Y

                                        if dz > 8 and dz < 220 then

                                                  -- Penalize hard lateral/vertical changes and distant targets.

                                                  local reachTime=dz/math.max(speed,70)

                                                  local lateralRate=math.abs(dx)/math.max(reachTime,0.25)

                                                  local verticalRate=math.abs(dy)/math.max(reachTime,0.25)

                                                  local score=dz*.20 + math.abs(dx)*1.7 + math.abs(dy)*2.0

                                                  if lateralRate > 85 then score=score+180 end

                                                  if verticalRate > 45 then score=score+100 end

                                                  if priorityMode=="RARE" then

                                                            score=score-(priorities[item.kind] or 0)*1.4

                                                  end

                                                  if not bestScore or score<bestScore then

                                                            bestScore=score

                                                            best={obj=item.obj,kind=item.kind,zone=item.zone,pos=p}

                                                  end

                                        end

                              end

                    end

          end

          return best

end

on.MouseButton1Click:Connect(function()
          setAutoCollect(true)
          autoSwitch.Set(true, false)
end)

off.MouseButton1Click:Connect(function()
          setAutoCollect(false)
          autoSwitch.Set(false, false)
end)

-- The visible MODE and A/D controls are modeControl and adControl above.

copy.MouseButton1Click:Connect(function()
          if typeof(setclipboard)=="function" then
                    local ok=pcall(setclipboard,table.concat(lines,"\n"))
                    status.Text=ok and "STATUS: COPIED" or "STATUS: COPY FAILED"
          else
                    status.Text="STATUS: CLIPBOARD UNAVAILABLE"
          end
end)

close.MouseButton1Click:Connect(function()
    if not alive then return end
    alive = false
    stopThrow()
    throwState.Closed = true
    stopAuto("GUI CLOSED")
    releaseAll()
    if _G.PAPAMAMIN_AUTO_COLLECT_STOP then _G.PAPAMAMIN_AUTO_COLLECT_STOP = nil end
    gui:Destroy()
end)
_G.PAPAMAMIN_UNIFIED_CLOSE = function()
    if alive then
        alive = false
        stopThrow()
        throwState.Closed = true
        stopAuto()
        releaseAll()
        if gui.Parent then gui:Destroy() end
    end
    _G.PAPAMAMIN_UNIFIED_CLOSE = nil
end



-- V5 placement driver: click real GUI targets observed in the user's activity scan.
-- No remote calls, no guessed item rarity logic, and no clicks on other players' UI.
local function getBaseParts()
    local hud = pg:FindFirstChild("PanThrowHUD")
    local root = hud and hud:FindFirstChild("Frame")
    local side = root and root:FindFirstChild("OptionalHUD")
    side = side and side:FindFirstChild("SideButtons")
    local opener = side and side:FindFirstChild("BASE")
    local panel = root and root:FindFirstChild("base")
    local main = panel and panel:FindFirstChild("Main")
    local body = main and main:FindFirstChild("Body")
    local actions = body and body:FindFirstChild("Frame")
    return opener, panel, actions
end
local function guiClickable(button)
    if not button or not button:IsA("GuiButton") or not button.Parent then return false end
    local node = button
    while node and node ~= pg do
        if node:IsA("GuiObject") and not node.Visible then return false end
        if node:IsA("ScreenGui") and not node.Enabled then return false end
        node = node.Parent
    end
    return button.AbsoluteSize.X > 2 and button.AbsoluteSize.Y > 2
end
local function clickGameButton(button)
    if not guiClickable(button) then return false end
    local center = button.AbsolutePosition + button.AbsoluteSize * 0.5
    local camera = Workspace.CurrentCamera
    local viewport = camera and camera.ViewportSize
    if viewport and (center.X < 0 or center.Y < 0 or center.X >= viewport.X or center.Y >= viewport.Y) then return false end
    -- V5 GUI is hidden briefly so its own window cannot intercept mouse events.
    local previous = gui.Enabled
    gui.Enabled = false
    local ok = pcall(function()
        VIM:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
        task.wait(0.06)
        VIM:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
    end)
    gui.Enabled = previous
    return ok
end
local function waitBaseState(expected, timeout)
    local untilTime = os.clock() + timeout
    repeat
        if baseOpen() == expected then return true end
        task.wait(0.08)
    until os.clock() >= untilTime or not alive
    return baseOpen() == expected
end
local function closeBaseSafely()
    if not baseOpen() then return true end
    local opener, panel = getBaseParts()
    local closeButton = panel and panel:FindFirstChild("Close")
    for attempt = 1, 3 do
        if not alive or not baseOpen() then break end
        if guiClickable(closeButton) then
            clickGameButton(closeButton)
        elseif guiClickable(opener) then
            clickGameButton(opener)
        else
            break
        end
        if waitBaseState(false, 0.8) then break end
    end
    return not baseOpen()
end
local function performPlaceBest()
    if placeState.Busy or secretTapActive or not alive then return end
    placeState.Busy = true
    local ok, err = pcall(function()
        local opener, panel, actions = getBaseParts()
        if not opener or not panel or not actions then error("Menu BASE belum ditemukan") end
        if not baseOpen() then
            placeStatus.Text = "Membuka BASE..."
            if not clickGameButton(opener) or not waitBaseState(true, 1.2) then
                error("BASE tidak terbuka")
            end
        end
        -- The user's scan identifies the first action Button at X338 Y636 as PLACE BEST.
        -- Identify by the observed relative order, not a fixed screen coordinate.
        local candidates = {}
        for _, child in ipairs(actions:GetChildren()) do
            if child:IsA("TextButton") and child.Name == "Button" then
                table.insert(candidates, child)
            end
        end
        table.sort(candidates, function(a,b) return a.AbsolutePosition.X < b.AbsolutePosition.X end)
        local placeButton = candidates[1]
        if not placeButton or not guiClickable(placeButton) then
            error("PLACE BEST tidak ditemukan / tidak terlihat")
        end
        placeStatus.Text = "Menekan PLACE BEST..."
        if not clickGameButton(placeButton) then error("Gagal mengirim klik PLACE BEST") end
        task.wait(0.30)
        placeState.Count = placeState.Count + 1
        log("AUTO PLACE BEST: click sent (" .. placeState.Count .. ")")
    end)
    -- Always attempt to close BASE, including when placement fails.
    local closed = closeBaseSafely()
    if not closed then
        placeStatus.Text = "PERINGATAN: BASE belum tertutup, THROW dijeda"
        log("AUTO PLACE: failed to close BASE; throwing remains blocked")
    elseif not ok then
        placeStatus.Text = "AUTO PLACE ERROR: " .. tostring(err)
        log("AUTO PLACE ERROR: " .. tostring(err))
    else
        placeStatus.Text = "PLACE BEST diklik; BASE tertutup | total " .. placeState.Count
    end
    placeState.Busy = false
end

task.spawn(function()
    while alive do
        if placeState.Enabled and not placeState.Busy and not secretTapActive
            and os.clock() - placeState.LastRun >= placeState.Interval then
            placeState.LastRun = os.clock()
            performPlaceBest()
        end
        task.wait(0.15)
    end
end)

-- Independent fast polling, since the collector loop runs only at ~10 Hz.
task.spawn(function()
    while alive do
        local ok, err = pcall(updateSecretTapHelper)
        if not ok then
            secretTapStatus.Text = "SECRET TAP ERROR"
        end
        task.wait(0.025)
    end
end)

-- Main loop: updates ~10 times per second.

task.spawn(function()

          while alive do

                    local ok,err=pcall(function()

                              if not running then

                                        status.Text="STATUS: OFF"

                                        return

                              end

                              local now=os.clock()

                              local pan=findPan()

                              local p=posOf(pan)

                              local cam=Workspace.CurrentCamera

                              local camPos=cam and cam.CFrame.Position

                              local camDist=(p and camPos) and (p-camPos).Magnitude or math.huge

                              local speed=0

                              if pan and pan==previousPan and p and previousPos and previousTime then

                                        local dt=now-previousTime

                                        if dt>0 then speed=(p-previousPos).Magnitude/dt end

                              end

                              previousPan,previousPos,previousTime=pan,p,now

                              -- Ignore a temporary local pan FX object until real forward movement is confirmed.

                              -- A flying pan must move forward and remain near the follow camera.

                              local moving = p and speed > 18 and camDist < 35

                              local launched = moving and p.Z > 12

                              if moving then lastPanMove=now end

                              if not flightActive then

                                        releaseAll()

                                        status.Text="STATUS: WAITING FOR FLIGHT"

                                        if launched then

                                                  candidateFrames=candidateFrames+1

                                        else

                                                  candidateFrames=0

                                        end

                                        if candidateFrames>=2 then

                                                  flightActive=true
                                                  flightCapped=false
                                                  collectedEstimate=0

                                                  flightStart=now

                                                  lostSince=nil

                                                  stoppedSince=nil

                                                  itemCache=scanItems()

                                                  lastFieldRefresh=now

                                                  collectedEstimate=0
                                                  log("FLIGHT START CONFIRMED: "..fmt(p).." | enabled-group items="..#itemCache)

                                                  refresh()

                                        end

                                        return

                              end

                              -- A missing or replaced local FX object is not an instant flight end.

                              local trackGood = p and camDist < 38

                              if not trackGood then

                                        releaseAll()

                                        lostSince=lostSince or now

                                        status.Text="STATUS: REACQUIRING PAN"

                                        if now-lastReasonLog>0.8 then

                                                  log(string.format("TRACK GAP: pan=%s camDist=%s gap=%.1fs",

                                                            tostring(p~=nil), camDist==math.huge and "N/A" or string.format("%.1f",camDist), now-lostSince))

                                                  lastReasonLog=now

                                                  refresh()

                                        end

                                        if now-lostSince>1.5 then

                                                  endFlight("FLIGHT END: tracking unavailable >1.5s; collector remains ON")

                                                  refresh()

                                        end

                                        return

                              end

                              if lostSince then

                                        log(string.format("TRACK RECOVERED after %.1fs",now-lostSince))

                                        lostSince=nil

                                        refresh()

                              end

                              if speed<2 then

                                        stoppedSince=stoppedSince or now

                              else

                                        stoppedSince=nil

                              end

                              if stoppedSince and now-stoppedSince>1.7 then

                                        endFlight("FLIGHT END: pan stationary >1.7s; collector remains ON")

                                        refresh()

                                        return

                              end

                              -- The follow camera returning to the launch area ends the flight.

                              if initialCamera and camPos and (camPos-initialCamera).Magnitude<9

                                       and p.Z>30 and now-flightStart>1.2 then

                                        endFlight("FLIGHT END: camera returned to launch; collector remains ON")

                                        refresh()

                                        return

                              end

                              if flightCapped then
                                        releaseAll()
                                        status.Text="STATUS: LIMIT REACHED | WAITING FOR NEXT THROW"
                                        return
                              end

                              if now-lastFieldRefresh>1.5 then

                                        itemCache=scanItems()

                                        lastFieldRefresh=now

                              end

                              if target and (not target.obj.Parent or not posOf(target.obj)) then

                                        log("TARGET DISAPPEARED: "..target.kind.." (not confirmed collected)")

                                        collectedEstimate=collectedEstimate+1

                                        target=nil

                                        releaseAll()

                                        refresh()

                              end

                              if collectedEstimate>=maxCollect then
                                        flightCapped=true
                                        target=nil
                                        releaseAll()
                                        log("Reached target limit; steering paused until this throw ends")
                                        refresh()
                                        return
                              end

                              if target then

                                        target.pos=posOf(target.obj)

                                        if not target.pos or target.pos.Z<p.Z-4 then

                                                  target=nil

                                                  releaseAll()

                                        end

                              end

                              if not target then

                                        target=chooseTarget(p,math.max(speed,70))

                                        if target then

                                                  log("TARGET: "..target.kind.." ["..target.zone.."] @ "..fmt(target.pos))

                                                  refresh()

                                        end

                              end

                              status.Text = "STATUS: AUTO ACTIVE | LOST="..collectedEstimate.."/"..maxCollect

status.TextColor3 = Color3.fromRGB(0, 255, 0) -- Warna hijau
status.TextSize = 18 -- Ukuran tulisan
status.Font = Enum.Font.GothamBold -- Tulisan tebal

                              if not target then

                                        releaseAll()

                                        info.Text="PAN: "..fmt(p).."\nTARGET: NONE"

                                        return

                              end

                              local dx=target.pos.X-p.X

                              local dy=target.pos.Y-p.Y

                              local dz=target.pos.Z-p.Z

                              -- In this game log, MARK A correlated with +X; MARK D with -X.

                              -- These are assumptions, reversible from the GUI.

                              local leftKey=reverseAD and "D" or "A"

                              local rightKey=reverseAD and "A" or "D"

                              local horizontal=math.abs(dx)>3 and dz>2

                              send(leftKey,horizontal and dx>0)

                              send(rightKey,horizontal and dx<0)

                              send("W",dy>2 and dz>2)

                              send("S",dy< -2 and dz>2)

                              info.Text=string.format("PAN: %s | %.0f studs/s\nTARGET: %s | dX=%.1f dY=%.1f dZ=%.1f",

                                        fmt(p),speed,target.kind.."/"..target.zone,dx,dy,dz)

                              if now-lastLog>2 then

                                        log(string.format("STEER %s dx=%.1f dy=%.1f dz=%.1f",target.kind,dx,dy,dz))

                                        lastLog=now

                                        refresh()

                              end

                    end)

                    if not ok then

                              stopAuto("ERROR: "..tostring(err))

                              refresh()

                    end

                    task.wait(0.1)

          end

end)
