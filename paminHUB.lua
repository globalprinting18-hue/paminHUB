PAMINHUB SAVE/LOAD FIX

Catatan: File ini berisi blok pengganti untuk memperbaiki penyimpanan/pemulihan status Auto Collect dan Auto Throw pada script yang sudah kamu punya. Ini bukan keseluruhan script GUI karena sumber lengkap script tidak tersedia sebagai file di sesi ini.

1) Tambahkan deklarasi sebelum fungsi collectSettings() dan loadSettings():

local startThrow
local stopThrow

2) Ganti collectSettings() dengan:

local function collectSettings()
    local zones = {}

    for _, zone in ipairs(zoneNames) do
        zones[zone] = zoneEnabled[zone] == true
    end

    return {
        version = 2,
        delayMs = tonumber(delayBox.Text) or 1900,
        autoThrowEnabled = throwState.Running == true,
        autoCollectEnabled = running == true,
        priorityMode = priorityMode,
        reverseAD = reverseAD,
        zoneEnabled = zones,
        layoutMode = layoutMode,
        autoRejoin = autoRejoin,
        autoExecute = autoExecute,
        autoExecuteUrl = executeUrlBox.Text or "",
    }
end

3) Di dalam loadSettings(), setelah pengaturan lain dipulihkan, tambahkan blok berikut. Sesuaikan letaknya sebelum refresh() jika fungsi loadSettings() kamu memiliki susunan berbeda:

    -- Restore Auto Collect; settings lama tanpa field ini default OFF.
    local collectEnabled = data.autoCollectEnabled == true
    autoSwitch.Set(collectEnabled, true)

    -- Restore Auto Throw; settings lama tanpa field ini default OFF.
    if data.autoThrowEnabled == true then
        if startThrow then
            startThrow()
        else
            throwStatus.Text = "STATUS: START FUNCTION UNAVAILABLE"
        end
    else
        if stopThrow then
            stopThrow()
        end
    end

4) Ganti fungsi stopThrow() lama dengan:

stopThrow = function()
    throwState.Running = false
    throwState.Token = throwState.Token + 1
    throwStatus.Text = "STATUS: OFF"
    throwStatus.TextColor3 = Color3.fromRGB(255, 100, 100)
end

5) Ganti blok throwStart.MouseButton1Click:Connect(function() ... end) lama dengan:

startThrow = function()
    if throwState.Running or throwState.Closed then
        return
    end

    local ms = tonumber(delayBox.Text)
    if not ms or ms < 100 then
        ms = 1900
        delayBox.Text = "1900"
    end

    throwState.Delay = ms / 1000
    throwState.Running = true
    throwState.Token = throwState.Token + 1
    local token = throwState.Token

    throwStatus.Text = "STATUS: CHECKING THROWZONE"
    throwStatus.TextColor3 = Color3.fromRGB(255, 210, 100)

    task.spawn(function()
        if not moveToThrowZone(token) then
            if throwState.Token == token and throwState.Running then
                throwState.Running = false
                throwStatus.TextColor3 = Color3.fromRGB(255, 100, 100)
            end
            return
        end

        throwStatus.Text = "STATUS: THROW ZONE >> SCAN ITEM >> THROW >> COLLECT"
        throwStatus.TextColor3 = Color3.fromRGB(80, 255, 130)

        while throwState.Running
            and not throwState.Closed
            and throwState.Token == token do

            pressE()
            if not waitThrow(throwState.Delay, token) then
                break
            end

            pressE()
            if not waitThrow(throwState.RoundDelay, token) then
                break
            end
        end
    end)
end

throwStart.MouseButton1Click:Connect(startThrow)
throwStop.MouseButton1Click:Connect(stopThrow)

PENTING:
- Pertahankan fungsi moveToThrowZone(), pressE(), waitThrow(), dan kode GUI lain yang sudah ada.
- Letakkan deklarasi local startThrow dan local stopThrow sebelum loadSettings() didefinisikan.
- Letakkan definisi startThrow setelah moveToThrowZone(), pressE(), dan waitThrow() sudah didefinisikan.
- Pertahankan koneksi tombol SAVE/LOAD yang sudah ada.
- Setelah Load, Auto Throw hanya akan berhasil berjalan jika karakter dan ThrowZone tersedia.
