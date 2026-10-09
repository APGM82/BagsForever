local ADDON, ns = ...

local PREFIX = "|cff66cc99Bags Forever:|r "
local WHITE = "Interface\\Buttons\\WHITE8X8"
local TITLE_FONT = "Fonts\\MORPHEUS.TTF"
local BACKPACK_ICON = "Interface\\Buttons\\Button-Backpack-Up"
local BANK_ICON = "Interface\\Icons\\INV_Box_02"
local EMPTY_BAG_ICON = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag"

local GetContainerNumSlots = C_Container.GetContainerNumSlots
local GetContainerItemInfo = C_Container.GetContainerItemInfo

-- medidas en pixeles
local PAD, GAP = 8, 3
local SLOT = 36
local HEADER, SEARCH, BAGBAR, FOOTER = 24, 22, 30, 18
local MIN_WIDTH = 300

local DEFAULTS = {
    theme = ns.DEFAULT_THEME,
    columns = 12,
    scale = 1,
    itemLevel = true,
    qualityBorders = true,
    junk = true,
    newGlow = true,
    splitBags = false,
    showBags = false,
    showBankBags = true,
    sellJunk = true,
    repair = false,
    locked = false,
    replace = true,
    bank = true,
    keyring = false,
}

local db, theme
-- las bolsas y el banco
local bagsView, bankView, options
local holders = {}    -- un marco por bolsa, con su ID
local pending = {}    -- lo que espera a que acabe el combate

local UpdateAll, Queue

-- ---------------------------------------------------------------- utilidades

-- la clave es el ingles; lo que no este traducido se ve en ingles
local L = setmetatable({}, { __index = function(_, key) return key end })

for key, value in pairs(ns.L[(GetLocale and GetLocale()) or "enUS"] or {}) do
    L[key] = value
end

local function Say(text, ...)
    local message = L[text]
    if select("#", ...) > 0 then
        message = format(message, ...)
    end
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. message)
end

local function Money(copper)
    copper = copper or 0
    if GetMoneyString then return GetMoneyString(copper, true) end
    return format("%dg %ds %dc", math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

local function Clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function Sound(name)
    if PlaySound and SOUNDKIT and SOUNDKIT[name] then PlaySound(SOUNDKIT[name]) end
end

-- en combate no se pueden mover ni mostrar marcos protegidos
local function Blocked(view)
    return InCombatLockdown() and view.frame:IsProtected()
end

local function EachView(fn)
    if bagsView then fn(bagsView) end
    if bankView then fn(bankView) end
end

-- ---------------------------------------------------------------- temas

local skinned = {}
local displays = {}

-- Morpheus solo tiene letras latinas
local LATIN = { enUS = true, enGB = true, esES = true, esMX = true, deDE = true, frFR = true, itIT = true, ptBR = true }
local latin = LATIN[(GetLocale and GetLocale()) or "enUS"]

local function Paint(object)
    local color = theme[object.role]
    if object:GetObjectType() == "Texture" then
        object:SetColorTexture(color[1], color[2], color[3], (color[4] or 1) * (object.alpha or 1))
    else
        object:SetTextColor(color[1], color[2], color[3])
    end
end

local function Skin(object, role, alpha)
    if not object.role then table.insert(skinned, object) end
    object.role = role
    object.alpha = alpha
    Paint(object)
    return object
end

local function FindTheme(key)
    for _, entry in ipairs(ns.themes) do
        if entry.key == key then return entry end
    end
    return ns.themes[1]
end

local function Plain(parent, layer, sub)
    local t = parent:CreateTexture(nil, layer or "BORDER", nil, sub or 0)
    t:SetTexture(WHITE)
    return t
end

-- lineas de pixeles de verdad: con 1 a secas unas salen de uno y otras de dos

-- un pixel de la pantalla, en las unidades de ese marco
local function Pixel(region)
    local _, height = GetPhysicalScreenSize()
    local scale = region:GetEffectiveScale()
    if not height or height <= 0 or not scale or scale <= 0 then return 1 end
    return 768 / height / scale
end

local thinLines = {}   -- { textura, marco, pixeles }
local thinEdges = {}   -- bordes de cuatro lados

local function Snap(t)
    if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(true) end
    if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
end

-- linea horizontal de tantos pixeles de alto
local function Line(parent, layer, sub, pixels)
    local t = Plain(parent, layer, sub)
    Snap(t)
    thinLines[#thinLines + 1] = { t, parent, pixels or 1 }
    t:SetHeight((pixels or 1) * Pixel(parent))
    return t
end

local function FitEdges(edges)
    local size = edges.pixels * Pixel(edges.frame)
    local top, bottom, left, right = edges[1], edges[2], edges[3], edges[4]
    top:SetHeight(size)
    bottom:SetHeight(size)
    left:ClearAllPoints()
    left:SetPoint("TOPLEFT", 0, -size)
    left:SetPoint("BOTTOMLEFT", 0, size)
    left:SetWidth(size)
    right:ClearAllPoints()
    right:SetPoint("TOPRIGHT", 0, -size)
    right:SetPoint("BOTTOMRIGHT", 0, size)
    right:SetWidth(size)
end

-- borde por dentro del marco, de un pixel si no se dice otra cosa
local function Edges(frame, layer, sub, pixels)
    local edges = { Plain(frame, layer, sub), Plain(frame, layer, sub), Plain(frame, layer, sub), Plain(frame, layer, sub) }
    edges.frame, edges.pixels = frame, pixels or 1
    for _, t in ipairs(edges) do Snap(t) end
    edges[1]:SetPoint("TOPLEFT")
    edges[1]:SetPoint("TOPRIGHT")
    edges[2]:SetPoint("BOTTOMLEFT")
    edges[2]:SetPoint("BOTTOMRIGHT")
    FitEdges(edges)
    thinEdges[#thinEdges + 1] = edges
    return edges
end

-- al cambiar la escala
local function RefitLines()
    for _, edges in ipairs(thinEdges) do FitEdges(edges) end
    for _, line in ipairs(thinLines) do line[1]:SetHeight(line[3] * Pixel(line[2])) end
end

local function SkinEdges(edges, role, alpha)
    for _, t in ipairs(edges) do Skin(t, role, alpha) end
    return edges
end

local function ColorEdges(edges, r, g, b, a)
    for _, t in ipairs(edges) do t:SetColorTexture(r, g, b, a) end
end

local function Gradient(t, orientation, r1, g1, b1, a1, r2, g2, b2, a2)
    if t.SetGradient and CreateColor then
        t:SetGradient(orientation, CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2))
    elseif t.SetGradientAlpha then
        t:SetGradientAlpha(orientation, r1, g1, b1, a1, r2, g2, b2, a2)
    else
        t:SetVertexColor(r1, g1, b1, (a1 + a2) / 2)
    end
end

-- atlas del juego si existe; si no, el fichero de repuesto
local function SetIcon(t, atlas, file)
    if atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
        t:SetAtlas(atlas)
    else
        t:SetTexture(file)
    end
end

local function PaintDisplay(fs)
    if theme.forever and latin then
        fs:SetFont(TITLE_FONT, fs.displaySize, "")
    else
        fs:SetFont(fs.baseFont[1], fs.baseFont[2], fs.baseFont[3] or "")
    end
end

-- titulos con la letra de las misiones en el tema Forever
local function Display(fs, size)
    fs.baseFont = { fs:GetFont() }
    fs.displaySize = size
    table.insert(displays, fs)
    PaintDisplay(fs)
    return fs
end

local function FadeIn(frame)
    if not frame.fadeIn then
        local group = frame:CreateAnimationGroup()
        local alpha = group:CreateAnimation("Alpha")
        alpha:SetFromAlpha(0)
        alpha:SetToAlpha(1)
        alpha:SetDuration(0.15)
        alpha:SetSmoothing("OUT")
        frame.fadeIn = group
    end
    frame.fadeIn:Stop()
    frame.fadeIn:Play()
end

local function ApplyTheme(key)
    theme = FindTheme(key)
    db.theme = theme.key
    for _, object in ipairs(skinned) do
        Paint(object)
    end
    for _, fs in ipairs(displays) do
        PaintDisplay(fs)
    end
    EachView(function(view)
        local c = theme.title
        if theme.forever then
            Gradient(view.frame.glow, "VERTICAL", c[1], c[2], c[3], 0, c[1], c[2], c[3], 0.10)
            view.frame.glow:Show()
        else
            view.frame.glow:Hide()
        end
        if view.frame:IsShown() then UpdateAll(view) end
    end)
    if options and options:IsShown() then options:Refresh() end
end

-- ---------------------------------------------------------------- bolsas

-- la quinta ranura es para bolsas especiales y el llavero es la -1
local KEYRING_LABEL = type(KEYRING) == "string" and KEYRING or L["Keyring"]
local LAST_BAG = NUM_BAG_SLOTS or 4
local SPECIAL_BAG = LAST_BAG + 1
local KEYRING = -1

-- el banco son pestañas del 6 al 14: la primera es el banco y las demas, casillas de bolsa
local FIRST_BANK = Enum and Enum.BagIndex and Enum.BagIndex.CharacterBankTab_1 or 6
local CHARACTER_BANK = Enum and Enum.BankType and Enum.BankType.Character

-- bolsas ocultas, por personaje
local hiddenBags

local function IsHidden(bag)
    return hiddenBags and hiddenBags[bag] and true or false
end

-- todas, se vean o no
local function AllBags()
    local list = {}
    for bag = 0, SPECIAL_BAG do
        list[#list + 1] = bag
    end
    if db.keyring then
        list[#list + 1] = KEYRING
    end
    return list
end

-- las pestañas compradas del banco
local function BankTabs()
    local list = {}
    local ok, ids = false, nil
    if C_Bank and C_Bank.FetchPurchasedBankTabIDs and CHARACTER_BANK then
        ok, ids = pcall(C_Bank.FetchPurchasedBankTabIDs, CHARACTER_BANK)
    end
    if ok and type(ids) == "table" and #ids > 0 then
        for _, bag in ipairs(ids) do list[#list + 1] = bag end
    else
        for bag = FIRST_BANK, FIRST_BANK + 8 do
            if GetContainerNumSlots(bag) > 0 then list[#list + 1] = bag end
        end
    end
    table.sort(list)
    return list
end

-- la proxima casilla que se puede comprar, o nada
local function NextBankPurchase()
    if not (C_Bank and C_Bank.CanPurchaseBankTab and CHARACTER_BANK) then return nil end
    local ok, can = pcall(C_Bank.CanPurchaseBankTab, CHARACTER_BANK)
    if not ok or not can then return nil end
    local ok2, data = pcall(C_Bank.FetchNextPurchasableBankTabData, CHARACTER_BANK)
    return ok2 and type(data) == "table" and data or {}
end

local function Visible(list)
    local out = {}
    for _, bag in ipairs(list) do
        if not IsHidden(bag) then out[#out + 1] = bag end
    end
    return out
end

-- tambien las ocultas: abrirlas abre la ventana
local function IsOurBag(bag)
    return type(bag) == "number" and (bag == KEYRING or (bag >= 0 and bag <= SPECIAL_BAG))
end

-- la mochila y el banco no se pueden coger
local function IsBase(bag)
    return bag == 0 or bag == FIRST_BANK
end

local function InventorySlot(bag)
    if bag < 1 or bag == FIRST_BANK then return nil end
    local ok, slot = pcall(C_Container.ContainerIDToInventoryID, bag)
    return ok and slot or nil
end

local SORT_FLAG = Enum and Enum.BagSlotFlags and Enum.BagSlotFlags.DisableAutoSort

local function SortIgnored(bag)
    if bag == 0 then return C_Container.GetBackpackAutosortDisabled() and true or false end
    if not SORT_FLAG or bag < 1 or bag > SPECIAL_BAG then return false end
    local ok, value = pcall(C_Container.GetBagSlotFlag, bag, SORT_FLAG)
    return ok and value and true or false
end

local function SetSortIgnored(bag, value)
    if bag == 0 then
        C_Container.SetBackpackAutosortDisabled(value)
    elseif SORT_FLAG and bag > 0 and bag <= SPECIAL_BAG then
        pcall(C_Container.SetBagSlotFlag, bag, SORT_FLAG, value)
    end
end

local function BagName(bag)
    if bag == 0 then return L["Backpack"] end
    if bag == KEYRING then return KEYRING_LABEL end
    return C_Container.GetBagName(bag) or L["Empty bag slot"]
end

-- ---------------------------------------------------------------- objetos

-- texto donde busca el buscador: nombre, tipo, subtipo, hueco y calidad
local function SearchText(info)
    local name, _, _, _, _, itemType, itemSubType, _, equipLoc = C_Item.GetItemInfo(info.hyperlink)
    if not name then return nil end
    local slot = equipLoc and equipLoc ~= "" and _G[equipLoc] or ""
    local quality = info.quality and _G["ITEM_QUALITY" .. info.quality .. "_DESC"] or ""
    return table.concat({ name, itemType or "", itemSubType or "", slot, quality }, "\n"):lower()
end

-- solo armas y armaduras
local function ItemLevel(bag, slot, info)
    local _, _, _, equipLoc, _, classID = C_Item.GetItemInfoInstant(info.itemID)
    if (classID ~= 2 and classID ~= 4) or not equipLoc or equipLoc == "" or equipLoc == "INVTYPE_NON_EQUIP_IGNORE" then
        return nil
    end
    local level
    if ItemLocation and ItemLocation.CreateFromBagAndSlot then
        local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
        if location and location:IsValid() then
            level = C_Item.GetCurrentItemLevel(location)
        end
    end
    if not level and info.hyperlink then
        level = C_Item.GetDetailedItemLevelInfo(info.hyperlink)
    end
    if level and level > 1 then return level end
end

local function IsJunk(info)
    return info and info.quality == 0 and not info.hasNoValue
end

-- lo nuestro va en b.bf: si el juego lee un campo escrito por un addon, no deja usar el objeto

local function Dim(b)
    local d = b.bf
    local view = d.view
    local off = (view.query ~= "" and not (d.search and d.search:find(view.query, 1, true)))
        or (view.hoverBag ~= nil and view.hoverBag ~= d.bag)
    b:SetAlpha(off and 0.25 or 1)
    SetItemButtonDesaturated(b, (d.locked or off) and true or false)
end

local function EachButton(view, fn)
    for _, bag in ipairs(view.Bags()) do
        local list = view.buttons[bag]
        if list then
            for slot = 1, GetContainerNumSlots(bag) do
                if list[slot] then fn(list[slot]) end
            end
        end
    end
end

local function DimAll(view)
    EachButton(view, Dim)
end

-- la marca de nuevo del juego no se guarda en Forever: lo visto, por personaje
local seen

local function EachHeldItem(fn)
    for bag = KEYRING, SPECIAL_BAG do
        for slot = 1, GetContainerNumSlots(bag) do
            local info = GetContainerItemInfo(bag, slot)
            if info and info.itemID then fn(info.itemID) end
        end
    end
end

-- al cerrar todo queda visto; lo que ya no esta se olvida
local function MarkAllSeen()
    if not seen then return end
    for itemID in pairs(seen) do seen[itemID] = nil end
    EachHeldItem(function(itemID) seen[itemID] = true end)
end

local function StopGlow(b)
    local d = b.bf
    d.isNew = false
    d.pulse:Stop()
    d.new:Hide()
end

local function ClearNew(b)
    local d = b.bf
    if not d.isNew then return end
    seen[d.itemID] = true
    -- y los demas montones del mismo objeto
    EachButton(bagsView, function(other)
        if other.bf.isNew and other.bf.itemID == d.itemID then StopGlow(other) end
    end)
end

-- donde van los adornos de la plantilla que no queremos ver
local hidden = CreateFrame("Frame")
hidden:Hide()

local function NewButton(view, bag, slot)
    local holder = holders[bag]
    if not holder then
        -- la plantilla del juego saca la bolsa del ID del padre
        holder = CreateFrame("Frame", nil, view.grid)
        holder:SetID(bag)
        holder:SetAllPoints()
        holders[bag] = holder
    end

    local name = format("BagsForeverItem%d_%d", bag, slot)
    local ok, b = pcall(CreateFrame, "ItemButton", name, holder, "ContainerFrameItemButtonTemplate")
    if not ok then
        b = CreateFrame("Button", name, holder, "ContainerFrameItemButtonTemplate")
    end
    b:SetID(slot)
    b:SetSize(SLOT, SLOT)
    local d = { bag = bag, slot = slot, view = view }
    b.bf = d

    -- fuera los adornos de la plantilla, a un marco oculto: transparentes no basta
    local normal = b:GetNormalTexture()
    if normal then normal:SetAlpha(0) end
    -- BattlepayItemTexture es el marco azul de la tienda, Forever lo deja encendido
    for _, key in ipairs({ "IconBorder", "IconOverlay", "NewItemTexture", "flash", "JunkIcon", "IconQuestTexture", "BattlepayItemTexture" }) do
        if type(b[key]) == "table" and b[key].SetParent then b[key]:SetParent(hidden) end
    end

    d.bg = Skin(Plain(b, "BACKGROUND", -8), "box")
    d.bg:SetAllPoints()
    -- la bolsa especial y el llavero, con el fondo teñido
    if bag == SPECIAL_BAG or bag == KEYRING then
        Skin(Plain(b, "BACKGROUND", -7), "row"):SetAllPoints()
    end
    d.edges = Edges(b, "OVERLAY", 5)

    d.icon = b.icon or _G[name .. "IconTexture"]
    d.icon:ClearAllPoints()
    d.icon:SetPoint("TOPLEFT", 1, -1)
    d.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    d.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- degradado del color de la calidad por abajo
    d.tint = Plain(b, "BORDER", 7)
    d.tint:SetPoint("BOTTOMLEFT", 1, 1)
    d.tint:SetPoint("BOTTOMRIGHT", -1, 1)
    d.tint:SetHeight(SLOT * 0.5)
    d.tint:Hide()

    local font = (NumberFontNormal and NumberFontNormal:GetFont()) or STANDARD_TEXT_FONT
    local count = b.Count or _G[name .. "Count"]
    if count then
        count:ClearAllPoints()
        count:SetPoint("BOTTOMRIGHT", -2, 2)
        count:SetFont(font, 12, "OUTLINE")
    end

    -- nivel arriba a la izquierda; la cantidad se queda abajo a la derecha
    d.level = b:CreateFontString(nil, "OVERLAY")
    d.level:SetFont(font, 11, "OUTLINE")
    d.level:SetPoint("TOPLEFT", 2, -2)

    d.junk = b:CreateTexture(nil, "OVERLAY", nil, 2)
    d.junk:SetTexture("Interface\\Buttons\\UI-GroupLoot-Coin-Up")
    d.junk:SetSize(13, 13)
    d.junk:SetPoint("TOPRIGHT", -1, -1)
    d.junk:Hide()

    d.quest = b:CreateTexture(nil, "OVERLAY", nil, 1)
    d.quest:SetTexture(TEXTURE_ITEM_QUEST_BANG or "Interface\\ContainerFrame\\UI-Icon-QuestBang")
    d.quest:SetPoint("TOPLEFT", 1, -1)
    d.quest:SetPoint("BOTTOMRIGHT", -1, 1)
    d.quest:Hide()

    -- brillo de nuevo, en un marco propio encima del boton
    d.new = CreateFrame("Frame", nil, b)
    d.new:SetAllPoints()
    d.new:SetFrameLevel(b:GetFrameLevel() + 3)
    d.new:Hide()
    d.glow = d.new:CreateTexture(nil, "OVERLAY", nil, 3)
    d.glow:SetAllPoints()
    SetIcon(d.glow, "bags-glow-white", WHITE)
    d.glow:SetBlendMode("ADD")
    -- sin el atlas seria un cuadro blanco
    if d.glow:GetAtlas() == nil then d.glow:SetAlpha(0.3) end
    d.newEdges = Edges(d.new, "OVERLAY", 4, 2)
    d.pulse = d.new:CreateAnimationGroup()
    d.pulse:SetLooping("BOUNCE")
    local pulse = d.pulse:CreateAnimation("Alpha")
    pulse:SetFromAlpha(0.45)
    pulse:SetToAlpha(1)
    pulse:SetDuration(0.6)
    pulse:SetSmoothing("IN_OUT")

    b:SetHighlightTexture(WHITE, "ADD")
    local highlight = b:GetHighlightTexture()
    highlight:SetVertexColor(1, 1, 1, 0.12)
    highlight:ClearAllPoints()
    highlight:SetPoint("TOPLEFT", 1, -1)
    highlight:SetPoint("BOTTOMRIGHT", -1, 1)

    d.cooldown = b.Cooldown or _G[name .. "Cooldown"]
    if d.cooldown then
        d.cooldown:ClearAllPoints()
        d.cooldown:SetPoint("TOPLEFT", 1, -1)
        d.cooldown:SetPoint("BOTTOMRIGHT", -1, 1)
    end

    if view.kind == "bags" then b:HookScript("OnEnter", ClearNew) end
    return b
end

local function UpdateButton(b)
    local d = b.bf
    local info = GetContainerItemInfo(d.bag, d.slot)
    d.locked = info and info.isLocked
    SetItemButtonTexture(b, info and info.iconFileID)
    -- vacio, la plantilla pone su fondo en el icono
    d.icon:SetShown(info ~= nil)
    SetItemButtonCount(b, info and info.stackCount or 0)

    local quality = info and info.quality
    local quest = info and C_Container.GetContainerItemQuestInfo(d.bag, d.slot)
    local isQuest = quest and (quest.isQuestItem or quest.questID)
    d.quest:SetShown(quest and quest.questID and not quest.isActive and true or false)

    -- oro para mision, calidad de poco comun para arriba
    local r, g, bl
    if isQuest then
        r, g, bl = 1, 0.82, 0
    elseif db.qualityBorders and quality and quality >= 2 then
        r, g, bl = C_Item.GetItemQualityColor(quality)
    end
    if r then
        ColorEdges(d.edges, r, g, bl, 1)
        Gradient(d.tint, "VERTICAL", r, g, bl, 0.30, r, g, bl, 0)
        d.tint:Show()
    else
        local c = theme.border
        ColorEdges(d.edges, c[1], c[2], c[3], info and 0.6 or 0.25)
        d.tint:Hide()
    end

    d.junk:SetShown(db.junk and IsJunk(info) and true or false)

    local level = info and db.itemLevel and ItemLevel(d.bag, d.slot, info)
    if level then
        local lr, lg, lb = 1, 1, 1
        if quality then lr, lg, lb = C_Item.GetItemQualityColor(quality) end
        d.level:SetText(level)
        d.level:SetTextColor(lr, lg, lb)
    else
        d.level:SetText("")
    end

    if d.cooldown then
        if info then
            CooldownFrame_Set(d.cooldown, C_Container.GetContainerItemCooldown(d.bag, d.slot))
        elseif d.cooldown.Clear then
            d.cooldown:Clear()
        end
    end

    -- lo nuevo solo brilla en las bolsas
    d.itemID = info and info.itemID
    if d.view.kind == "bags" and db.newGlow and d.itemID and seen and not seen[d.itemID] then
        -- dorado para lo comun, en blanco apenas se ve
        local nr, ng, nb = 1, 0.82, 0.25
        if quality and quality >= 2 then nr, ng, nb = C_Item.GetItemQualityColor(quality) end
        d.glow:SetVertexColor(nr, ng, nb)
        ColorEdges(d.newEdges, nr, ng, nb, 1)
        d.new:Show()
        if not d.pulse:IsPlaying() then d.pulse:Play() end
        d.isNew = true
    else
        StopGlow(b)
    end

    d.search = info and SearchText(info)
    if info and not d.search then d.view.waiting = true end
    Dim(b)
end

-- ---------------------------------------------------------------- colocacion

-- la posicion se guarda por la esquina de arriba
local function SavePosition(view)
    local left, top = view.frame:GetLeft(), view.frame:GetTop()
    if left and top then
        db[view.pointKey] = { "TOPLEFT", "BOTTOMLEFT", left, top }
    end
end

-- crece hacia abajo, que la cabecera no se vaya de debajo del raton
local function Resize(view)
    local frame = view.frame
    local width = math.max(view.grid:GetWidth() + PAD * 2, MIN_WIDTH)
    local height = PAD + HEADER + 6 + SEARCH + 6
        + (db[view.barKey] and (BAGBAR + 6) or 0)
        + view.grid:GetHeight() + 8 + FOOTER + PAD
    -- la primera vez aun no tiene tamaño
    local left, top = frame:GetLeft(), frame:GetTop()
    local placed = left and top and (frame:GetHeight() or 0) > 0
    frame:SetSize(width, height)
    if placed then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        SavePosition(view)
    end
end

local function PlaceGrid(view)
    view.grid:ClearAllPoints()
    if db[view.barKey] then
        view.grid:SetPoint("TOP", view.bagBar, "BOTTOM", 0, -6)
    else
        view.grid:SetPoint("TOP", view.searchBox, "BOTTOM", 0, -6)
    end
end

-- entre bolsas separadas, una linea en medio del hueco
local SEPARATION = 9
local SEPARATOR_PIXELS = 2

local function Separator(view, index)
    local line = view.separators[index]
    if not line then
        line = Skin(Line(view.grid, "BORDER", nil, SEPARATOR_PIXELS), "border", 0.7)
        view.separators[index] = line
    end
    return line
end

local function Layout(view)
    local bags = view.Bags()
    local key = { db.columns, db.splitBags and 1 or 0 }
    for _, bag in ipairs(bags) do
        key[#key + 1] = bag .. ":" .. GetContainerNumSlots(bag)
    end
    key = table.concat(key, ",")
    if key == view.layoutKey then return end
    if Blocked(view) then
        pending.layout = true
        return
    end
    view.layoutKey = key

    for _, list in pairs(view.buttons) do
        for _, b in ipairs(list) do b:Hide() end
    end

    for _, line in ipairs(view.separators) do line:Hide() end

    local grid = view.grid
    local step = SLOT + GAP
    local width = db.columns * step - GAP
    local col, y, placed, lines = 0, 0, false, 0
    for _, bag in ipairs(bags) do
        local n = GetContainerNumSlots(bag)
        if n > 0 and placed and view.OwnRow(bag) then
            if col > 0 then
                col = 0
                y = y + step
            end
            -- de y - GAP a y + SEPARATION, centrada
            lines = lines + 1
            local line = Separator(view, lines)
            local middle = y - GAP + (GAP + SEPARATION) / 2
            line:ClearAllPoints()
            line:SetPoint("TOPLEFT", grid, "TOPLEFT", 0, -(middle - SEPARATOR_PIXELS * Pixel(grid) / 2))
            line:SetWidth(width)
            line:Show()
            y = y + SEPARATION
        end
        view.buttons[bag] = view.buttons[bag] or {}
        for slot = 1, n do
            local b = view.buttons[bag][slot] or NewButton(view, bag, slot)
            view.buttons[bag][slot] = b
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", grid, "TOPLEFT", col * step, -y)
            b:Show()
            placed = true
            col = col + 1
            if col == db.columns then
                col = 0
                y = y + step
            end
        end
    end
    if col > 0 then y = y + step end

    grid:SetSize(width, math.max(y - GAP, SLOT))
    PlaceGrid(view)
    Resize(view)
end

-- ---------------------------------------------------------------- barra de bolsas

-- por encima, por debajo tapaba los objetos
local function BagTooltip(view, b)
    GameTooltip:SetOwner(b, "ANCHOR_TOP")
    local slot = InventorySlot(b.bag)
    if IsBase(b.bag) then
        GameTooltip:AddLine(BagName(b.bag), 1, 1, 1)
    elseif slot and GetInventoryItemTexture("player", slot) then
        GameTooltip:SetInventoryItem("player", slot)
    else
        GameTooltip:AddLine(L["Empty bag slot"], 1, 1, 1)
    end
    if IsHidden(b.bag) then
        GameTooltip:AddLine(L["Hidden in the window"], 1, 0.6, 0.2)
    end
    local bags = view.kind == "bags"
    if bags and SortIgnored(b.bag) then
        GameTooltip:AddLine(L["Ignored when sorting"], 1, 0.3, 0.3)
    end
    GameTooltip:AddLine(" ")
    if not IsBase(b.bag) then
        GameTooltip:AddLine(L["Click: pick up the bag"], 0.6, 0.6, 0.6)
    end
    if bags then
        if SortIgnored(b.bag) then
            GameTooltip:AddLine(L["Right click: sort it again"], 0.6, 0.6, 0.6)
        else
            GameTooltip:AddLine(L["Right click: ignore it when sorting"], 0.6, 0.6, 0.6)
        end
    end
    if IsHidden(b.bag) then
        GameTooltip:AddLine(L["Shift-click: show it again"], 0.6, 0.6, 0.6)
    else
        GameTooltip:AddLine(L["Shift-click: hide it in the window"], 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end

local function PutInBag(bag)
    if bag == 0 then
        PutItemInBackpack()
    elseif InventorySlot(bag) then
        PutItemInBag(InventorySlot(bag))
    end
end

local function NewBagButton(view, bag)
    local b = CreateFrame("Button", nil, view.bagBar)
    b.bag = bag
    b:SetSize(BAGBAR - 2, BAGBAR - 2)
    Skin(Plain(b, "BACKGROUND"), "box"):SetAllPoints()
    b.edges = SkinEdges(Edges(b, "OVERLAY"), "border")

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 2, -2)
    b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    b.ignored = b:CreateTexture(nil, "OVERLAY", nil, 2)
    b.ignored:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    b.ignored:SetSize(12, 12)
    b.ignored:SetPoint("TOPRIGHT", 1, 1)

    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    b.count:SetPoint("BOTTOMRIGHT", -1, 2)

    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            if view.kind ~= "bags" then return end
            SetSortIgnored(self.bag, not SortIgnored(self.bag))
            view.UpdateBar()
            BagTooltip(view, self)
        elseif IsShiftKeyDown() then
            if Blocked(view) then return end
            hiddenBags[self.bag] = not IsHidden(self.bag) or nil
            view.hoverBag = nil
            view.layoutKey = nil
            UpdateAll(view)
            BagTooltip(view, self)
        elseif CursorHasItem() then
            PutInBag(self.bag)
        elseif InventorySlot(self.bag) then
            PickupBagFromSlot(InventorySlot(self.bag))
        end
    end)
    b:SetScript("OnDragStart", function(self)
        if InventorySlot(self.bag) then PickupBagFromSlot(InventorySlot(self.bag)) end
    end)
    b:SetScript("OnReceiveDrag", function(self)
        PutInBag(self.bag)
    end)
    b:SetScript("OnEnter", function(self)
        view.hoverBag = not IsHidden(self.bag) and self.bag or nil
        ColorEdges(self.edges, theme.title[1], theme.title[2], theme.title[3], 1)
        DimAll(view)
        BagTooltip(view, self)
    end)
    b:SetScript("OnLeave", function(self)
        view.hoverBag = nil
        for _, t in ipairs(self.edges) do Paint(t) end
        DimAll(view)
        GameTooltip:Hide()
    end)
    return b
end

-- uno detras de otro
local function UpdateBagBar(view)
    for _, b in pairs(view.bagButtons) do b:Hide() end
    local previous
    for _, bag in ipairs(view.BarBags()) do
        local b = view.bagButtons[bag] or NewBagButton(view, bag)
        view.bagButtons[bag] = b
        b:ClearAllPoints()
        if previous then
            -- la especial, un poco aparte
            b:SetPoint("LEFT", previous, "RIGHT", bag == SPECIAL_BAG and 12 or 4, 0)
        else
            b:SetPoint("LEFT", 0, 0)
        end
        previous = b

        local texture
        if bag == 0 then
            texture = BACKPACK_ICON
        elseif bag == FIRST_BANK then
            texture = BANK_ICON
        else
            local slot = InventorySlot(bag)
            texture = slot and GetInventoryItemTexture("player", slot)
        end
        b.icon:SetTexture(texture or EMPTY_BAG_ICON)
        b.icon:SetDesaturated(not texture or IsHidden(bag))
        b.icon:SetAlpha(IsHidden(bag) and 0.35 or 1)
        b.ignored:SetShown(view.kind == "bags" and SortIgnored(bag))
        local n = GetContainerNumSlots(bag)
        b.count:SetText(n > 0 and n or "")
        b:Show()
    end
    if view.AfterBar then view.AfterBar(previous) end
end

-- ---------------------------------------------------------------- pie

-- al lado de la ventana, para no tapar los objetos
local function SideTooltip(owner, frame)
    GameTooltip:SetOwner(owner, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    local x = frame:GetCenter()
    if x and x * frame:GetEffectiveScale() > UIParent:GetWidth() * UIParent:GetEffectiveScale() / 2 then
        GameTooltip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", -4, 0)
    else
        GameTooltip:SetPoint("BOTTOMLEFT", frame, "BOTTOMRIGHT", 4, 0)
    end
end

-- oro de todos los personajes si esta Alters Forever
local function MoneyTooltip(view, owner)
    local chars = type(AltersForeverDB) == "table" and AltersForeverDB.chars
    if type(chars) ~= "table" then return end
    local me = UnitGUID("player")
    local list = {}
    for guid, c in pairs(chars) do
        if type(c) == "table" and c.name then
            local money = guid == me and GetMoney() or c.money or 0
            list[#list + 1] = { name = c.name, class = c.class, money = money }
        end
    end
    if #list < 2 then return end
    table.sort(list, function(a, b) return a.money > b.money end)

    SideTooltip(owner, view.frame)
    GameTooltip:AddLine(L["Total gold"], theme.title[1], theme.title[2], theme.title[3])
    local total = 0
    for _, c in ipairs(list) do
        total = total + c.money
        local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class or ""]
        if color then
            GameTooltip:AddDoubleLine(c.name, Money(c.money), color.r, color.g, color.b, 1, 1, 1)
        else
            GameTooltip:AddDoubleLine(c.name, Money(c.money), 1, 1, 1, 1, 1, 1)
        end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine(L["Total"], Money(total), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:Show()
end

-- como el juego: solo cuentan las bolsas normales, no las especiales
local function FreeSlots(view)
    local free, total = 0, 0
    for _, bag in ipairs(view.AllBags()) do
        local empty, family = C_Container.GetContainerNumFreeSlots(bag)
        if (family or 0) == 0 and bag ~= KEYRING then
            total = total + GetContainerNumSlots(bag)
            free = free + (empty or 0)
        end
    end
    return free, total
end

local function FreeTooltip(view, owner)
    local free, total = FreeSlots(view)
    SideTooltip(owner, view.frame)
    GameTooltip:AddLine(format(L["Free slots: %d of %d"], free, total), 1, 1, 1)
    GameTooltip:AddLine(" ")
    for _, bag in ipairs(view.AllBags()) do
        local size = GetContainerNumSlots(bag)
        if size > 0 then
            local empty, family = C_Container.GetContainerNumFreeSlots(bag)
            local name = BagName(bag)
            local r, g, b = 0.8, 0.8, 0.8
            if (family or 0) ~= 0 or bag == KEYRING then r, g, b = theme.title[1], theme.title[2], theme.title[3] end
            if IsHidden(bag) then
                name = name .. " (" .. L["hidden"] .. ")"
                r, g, b = 0.5, 0.5, 0.5
            end
            GameTooltip:AddDoubleLine(name, format("%d / %d", empty or 0, size), r, g, b, 1, 1, 1)
        end
    end
    GameTooltip:Show()
end

local function UpdateMoney(view)
    local footer = view.footer
    footer.money:SetText(Money(GetMoney()))
    footer.moneyFrame:SetWidth(footer.money:GetStringWidth() + 4)
end

local function UpdateCurrencies(view)
    if view.kind ~= "bags" then return end
    local parts = {}
    if C_CurrencyInfo and C_CurrencyInfo.GetBackpackCurrencyInfo then
        for i = 1, 3 do
            local c = C_CurrencyInfo.GetBackpackCurrencyInfo(i)
            if not c then break end
            local amount = BreakUpLargeNumbers and BreakUpLargeNumbers(c.quantity) or c.quantity
            parts[#parts + 1] = format("%s |T%s:13:13:0:0:64:64:5:59:5:59|t", amount, c.iconFileID)
        end
    end
    view.footer.currency:SetText(table.concat(parts, "  "))
end

local function UpdateFooter(view)
    local free, total = FreeSlots(view)
    local text = tostring(free)
    if free == 0 then
        text = "|cffff4040" .. text .. "|r"
    elseif free <= 4 then
        text = "|cffffb040" .. text .. "|r"
    end
    view.footer.free:SetText(text .. " / " .. total)
    UpdateMoney(view)
    UpdateCurrencies(view)
end

-- ---------------------------------------------------------------- refresco

UpdateAll = function(view)
    Layout(view)
    view.waiting = false
    -- la primera vez con este personaje, lo que ya lleva no es nuevo
    if view.kind == "bags" and not seen then
        local guid = UnitGUID("player")
        db.seen = db.seen or {}
        db.seen[guid] = db.seen[guid] or {}
        seen = db.seen[guid]
        if not next(seen) then MarkAllSeen() end
    end
    EachButton(view, UpdateButton)
    UpdateFooter(view)
    if db[view.barKey] then UpdateBagBar(view) end
end

Queue = function(view)
    if view.queued then return end
    view.queued = true
    C_Timer.After(0.05, function()
        view.queued = false
        if view.frame:IsShown() then UpdateAll(view) end
    end)
end

-- ---------------------------------------------------------------- abrir y cerrar las bolsas

local function Open(opener)
    local main = bagsView.frame
    if main:IsShown() then return end
    if Blocked(bagsView) then
        pending.open = true
        return
    end
    main.openedBy = opener
    main:Show()
end

-- como el juego: si las abrio el mercader, solo las cierra el mercader
local function Close(opener)
    local main = bagsView.frame
    if not main:IsShown() then return end
    if opener and main.openedBy ~= opener then return end
    if Blocked(bagsView) then
        pending.close = true
        return
    end
    main:Hide()
end

local function Toggle()
    if bagsView.frame:IsShown() then
        bagsView.frame.openedBy = nil
        Close()
    else
        Open()
    end
end

-- las funciones del juego no se sustituyen, solo se escuchan: si no, el banco no deja comprar
local BAG_FUNCTIONS = {
    "ToggleAllBags", "OpenAllBags", "CloseAllBags",
    "ToggleBackpack", "OpenBackpack", "CloseBackpack",
    "ToggleBag", "OpenBag", "CloseBag",
}

local function TakeOver()
    for i = 1, NUM_CONTAINER_FRAMES or 13 do
        local frame = _G["ContainerFrame" .. i]
        if frame then frame:SetParent(hidden) end
    end
    if ContainerFrameCombinedBags then ContainerFrameCombinedBags:SetParent(hidden) end

    -- ToggleAllBags llama a OpenBag por cada bolsa: vale la ultima
    local last
    local function Resolve()
        local name, arg = last[1], last[2]
        last = nil
        if name:find("^Toggle") then
            Toggle()
        elseif name:find("^Open") then
            Open(name == "OpenAllBags" and arg or nil)
        else
            Close(name == "CloseAllBags" and arg or nil)
        end
    end
    for _, name in ipairs(BAG_FUNCTIONS) do
        if type(_G[name]) == "function" then
            -- las de una bolsa, solo si es nuestra
            local single = name:find("Bag$") ~= nil
            hooksecurefunc(name, function(arg)
                if single and not IsOurBag(arg) then return end
                if not last then C_Timer.After(0, Resolve) end
                last = { name, arg }
            end)
        end
    end
end

-- ---------------------------------------------------------------- el banco

-- el banco del juego no se puede esconder (corta la conversacion): se aparta
local stash = {}

local function MoveBankAway()
    stash.moving = true
    BankFrame:ClearAllPoints()
    BankFrame:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", -2000, -2000)
    stash.moving = false
end

local function StashBank()
    if not stash.active then
        stash.clamped = BankFrame:IsClampedToScreen()
    end
    stash.active = true
    BankFrame:SetClampedToScreen(false)
    BankFrame:SetAlpha(0)
    MoveBankAway()
end

-- si no hay boton seguro, se compra en la del juego
local function ShowGameBank()
    stash.active = false
    BankFrame:SetAlpha(1)
    BankFrame:SetClampedToScreen(stash.clamped and true or false)
    stash.moving = true
    BankFrame:ClearAllPoints()
    local p = stash.point
    if p and p[1] then
        BankFrame:SetPoint(p[1], p[2] or UIParent, p[3] or p[1], p[4] or 0, p[5] or 0)
    else
        BankFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)
    end
    stash.moving = false
    if not Blocked(bankView) then bankView.frame:Hide() end
    Say("Buy the slot in the game's bank window. Bags Forever's bank comes back when you buy it.")
end

local function CloseBank()
    if C_Bank and C_Bank.CloseBankFrame then
        C_Bank.CloseBankFrame()
    elseif CloseBankFrame then
        CloseBankFrame()
    end
end

local function HookBank()
    if not BankFrame then return end
    -- con el boton seguro dentro, en combate se queda el del juego
    BankFrame:HookScript("OnShow", function()
        if not db.bank or Blocked(bankView) then return end
        StashBank()
        bankView.frame:Show()
    end)
    BankFrame:HookScript("OnHide", function()
        stash.active = false
        BankFrame:SetAlpha(1)
        if Blocked(bankView) then
            pending.bankClose = true
        else
            bankView.frame:Hide()
        end
    end)
    -- el juego coloca sus ventanas al abrirlas y al abrir otras
    hooksecurefunc(BankFrame, "SetPoint", function(_, ...)
        if stash.active and not stash.moving then
            stash.point = { ... }
            MoveBankAway()
        end
    end)
end

-- tras comprar una casilla, el banco de Bags Forever vuelve
local function BankTabsChanged()
    if db.bank and BankFrame and BankFrame:IsShown() and not stash.active and not Blocked(bankView) then
        StashBank()
        bankView.frame:Show()
    end
    if bankView.frame:IsShown() then
        bankView.layoutKey = nil
        Queue(bankView)
    end
end

-- ---------------------------------------------------------------- ordenar

local sorting
local function SortBags()
    if sorting then return end
    sorting = true
    Sound("UI_BAG_SORTING_01")
    C_Container.SortBags()
    bagsView.sortButton.spin:Play()
    C_Timer.After(1, function() sorting = false end)
end

local function SortBank()
    if sorting then return end
    sorting = true
    Sound("UI_BAG_SORTING_01")
    local ok = CHARACTER_BANK and C_Container.SortBank and pcall(C_Container.SortBank, CHARACTER_BANK)
    if not ok and C_Container.SortBankBags then pcall(C_Container.SortBankBags) end
    bankView.sortButton.spin:Play()
    C_Timer.After(1, function() sorting = false end)
end

-- ---------------------------------------------------------------- mercader

-- valor de la chatarra y donde esta
local function FindJunk()
    local value, junk = 0, {}
    for bag = 0, SPECIAL_BAG do
        for slot = 1, GetContainerNumSlots(bag) do
            local info = GetContainerItemInfo(bag, slot)
            if IsJunk(info) then
                local price = select(11, C_Item.GetItemInfo(info.itemID)) or 0
                value = value + price * (info.stackCount or 1)
                junk[#junk + 1] = { bag, slot }
            end
        end
    end
    return value, junk
end

local function SellOneByOne(junk)
    for i, item in ipairs(junk) do
        C_Timer.After(i * 0.15, function()
            if MerchantFrame and MerchantFrame:IsShown() then
                C_Container.UseContainerItem(item[1], item[2])
            end
        end)
    end
end

-- el aviso sale con lo vendido de verdad, no con lo que habia
local function ReportSold(before, wait)
    C_Timer.After(wait, function()
        local sold = before - FindJunk()
        if sold > 0 then Say("Sold junk for %s.", Money(sold)) end
    end)
end

local function SellJunk()
    local value, junk = FindJunk()
    if #junk == 0 then return end

    local merchant = C_MerchantFrame
    if merchant and merchant.SellAllJunkItems and (merchant.GetNumJunkItems() or 0) > 0
        and (not merchant.IsSellAllJunkEnabled or merchant.IsSellAllJunkEnabled()) then
        merchant.SellAllJunkItems()
        -- si el juego no ha vendido nada, uno a uno
        C_Timer.After(1, function()
            local left, rest = FindJunk()
            if left == value and #rest > 0 then SellOneByOne(rest) end
        end)
        ReportSold(value, 1 + #junk * 0.15 + 1)
    else
        SellOneByOne(junk)
        ReportSold(value, #junk * 0.15 + 1)
    end
end

local function Repair()
    if not (CanMerchantRepair and CanMerchantRepair()) then return end
    local cost, canRepair = GetRepairAllCost()
    if not canRepair or not cost or cost <= 0 then return end
    if GetMoney() < cost then
        Say("Not enough money to repair (%s).", Money(cost))
        return
    end
    RepairAllItems()
    Say("Repaired for %s.", Money(cost))
end

-- ---------------------------------------------------------------- piezas de la ventana

local function FlatButton(parent, width, height, template)
    local b = CreateFrame("Button", nil, parent, template)
    b:SetSize(width, height)
    b.bg = Skin(Plain(b, "BACKGROUND"), "button")
    b.bg:SetAllPoints()
    b.edges = SkinEdges(Edges(b, "BORDER"), "border")
    b:SetScript("OnEnter", function(self)
        Skin(self.bg, "hover")
        if self.tip then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(self.tip, 1, 1, 1)
            if self.tip2 then GameTooltip:AddLine(self.tip2, 0.6, 0.6, 0.6) end
            if self.tip3 then GameTooltip:AddLine(self.tip3, 0.6, 0.6, 0.6) end
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function(self)
        Skin(self.bg, self.active and "selected" or "button")
        GameTooltip:Hide()
    end)
    function b:SetActive(active)
        self.active = active
        Skin(self.bg, active and "selected" or "button")
    end
    return b
end

local function IconButton(parent, atlas, file, tip)
    local b = FlatButton(parent, HEADER - 2, HEADER - 2)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("CENTER")
    b.icon:SetSize(HEADER - 8, HEADER - 8)
    SetIcon(b.icon, atlas, file)
    b.tip = tip
    return b
end

local function TextButton(parent, text, tip)
    local b = FlatButton(parent, HEADER - 2, HEADER - 2)
    b.text = Skin(b:CreateFontString(nil, "OVERLAY", "GameFontHighlight"), "text")
    b.text:SetPoint("CENTER", 0, 1)
    b.text:SetText(text)
    b.tip = tip
    return b
end

local function Place(view)
    local frame = view.frame
    frame:ClearAllPoints()
    local p = db[view.pointKey]
    if p then
        frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        frame:SetPoint(unpack(view.defaultPoint))
    end
end

local ShowOptions

local function BuildHeader(view, spec)
    local frame = view.frame
    local header = CreateFrame("Frame", nil, frame)
    header:SetPoint("TOPLEFT", PAD, -PAD)
    header:SetPoint("TOPRIGHT", -PAD, -PAD)
    header:SetHeight(HEADER)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function()
        if not db.locked then frame:StartMoving() end
    end)
    header:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        SavePosition(view)
    end)
    view.header = header

    frame.title = Skin(header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"), "title")
    frame.title:SetPoint("LEFT", 2, 0)
    frame.title:SetText(spec.title)
    Display(frame.title, 18)

    local close = TextButton(header, "×", spec.closeTip)
    close:SetPoint("RIGHT")
    close:SetScript("OnClick", spec.Close)
    local previous = close

    if spec.options then
        local gear = IconButton(header, "QuestLog-icon-setting", "Interface\\Buttons\\UI-OptionsButton", L["Options"])
        gear:SetPoint("RIGHT", previous, "LEFT", -4, 0)
        gear:SetScript("OnClick", function() ShowOptions() end)
        view.optionsButton = gear
        previous = gear
    end

    local bags = IconButton(header, nil, spec.barIcon, L["Show bags"])
    bags:SetPoint("RIGHT", previous, "LEFT", -4, 0)
    bags:SetActive(db[view.barKey])
    bags:SetScript("OnClick", function(self)
        if Blocked(view) then return end
        db[view.barKey] = not db[view.barKey]
        self:SetActive(db[view.barKey])
        view.bagBar:SetShown(db[view.barKey])
        PlaceGrid(view)
        Resize(view)
        if db[view.barKey] then UpdateBagBar(view) end
    end)

    -- el boton de ordenar, con su escoba y su texto
    local sort = FlatButton(header, 10, HEADER - 2)
    sort.icon = sort:CreateTexture(nil, "ARTWORK")
    sort.icon:SetPoint("LEFT", 4, 0)
    sort.icon:SetSize(HEADER - 8, HEADER - 8)
    SetIcon(sort.icon, "bags-button-autosort-up", "Interface\\Icons\\INV_Pet_Broom")
    sort.text = Skin(sort:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), "text")
    sort.text:SetPoint("LEFT", sort.icon, "RIGHT", 4, 0)
    sort.text:SetText(L["Sort"])
    sort:SetWidth(sort.text:GetStringWidth() + HEADER + 6)
    sort:SetPoint("RIGHT", bags, "LEFT", -4, 0)
    sort.tip = spec.sortTip
    sort.tip2 = spec.sortTip2
    sort:SetScript("OnClick", spec.Sort)
    sort.spin = sort.icon:CreateAnimationGroup()
    local spin = sort.spin:CreateAnimation("Rotation")
    spin:SetDegrees(-360)
    spin:SetDuration(0.6)
    spin:SetSmoothing("IN_OUT")
    view.sortButton = sort

    local line = Skin(Line(frame, "BORDER"), "border", 0.5)
    line:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
    line:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -2)
end

local function BuildSearch(view, name)
    local box = CreateFrame("EditBox", name, view.frame)
    box:SetHeight(SEARCH)
    box:SetPoint("TOPLEFT", view.header, "BOTTOMLEFT", 0, -6)
    box:SetPoint("TOPRIGHT", view.header, "BOTTOMRIGHT", 0, -6)
    box:SetAutoFocus(false)
    box:SetFontObject(ChatFontNormal)
    box:SetTextInsets(22, 20, 0, 0)
    Skin(box, "text")
    Skin(Plain(box, "BACKGROUND"), "box"):SetAllPoints()
    box.edges = SkinEdges(Edges(box, "BORDER"), "border")

    local glass = box:CreateTexture(nil, "OVERLAY")
    glass:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    glass:SetSize(14, 14)
    glass:SetPoint("LEFT", 6, -1)
    glass:SetVertexColor(0.7, 0.7, 0.7)

    box.hint = Skin(box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), "dim")
    box.hint:SetPoint("LEFT", 22, 0)
    box.hint:SetText(L["Search"])

    local clear = CreateFrame("Button", nil, box)
    clear:SetSize(SEARCH - 4, SEARCH - 4)
    clear:SetPoint("RIGHT", -2, 0)
    clear.text = Skin(clear:CreateFontString(nil, "OVERLAY", "GameFontHighlight"), "dim")
    clear.text:SetPoint("CENTER", 0, 1)
    clear.text:SetText("×")
    clear:SetScript("OnEnter", function(self) Skin(self.text, "text") end)
    clear:SetScript("OnLeave", function(self) Skin(self.text, "dim") end)
    clear:SetScript("OnClick", function()
        box:SetText("")
        box:ClearFocus()
    end)
    clear:Hide()

    box:SetScript("OnTextChanged", function(self)
        local text = self:GetText()
        view.query = text:lower():match("^%s*(.-)%s*$")
        self.hint:SetShown(text == "" and not self:HasFocus())
        clear:SetShown(text ~= "")
        DimAll(view)
    end)
    box:SetScript("OnEditFocusGained", function(self)
        self.hint:Hide()
        for _, t in ipairs(self.edges) do Skin(t, "selected") end
    end)
    box:SetScript("OnEditFocusLost", function(self)
        self.hint:SetShown(self:GetText() == "")
        for _, t in ipairs(self.edges) do Skin(t, "border") end
    end)
    box:SetScript("OnEscapePressed", function(self)
        if self:GetText() ~= "" then self:SetText("") else self:ClearFocus() end
    end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    view.searchBox = box
end

local function BuildBagBar(view)
    local bagBar = CreateFrame("Frame", nil, view.frame)
    bagBar:SetHeight(BAGBAR)
    bagBar:SetPoint("TOPLEFT", view.searchBox, "BOTTOMLEFT", 0, -6)
    bagBar:SetPoint("TOPRIGHT", view.searchBox, "BOTTOMRIGHT", 0, -6)
    bagBar:SetShown(db[view.barKey])
    view.bagBar = bagBar
end

-- el llavero, al final de la barra
local function BuildKeyring(view)
    local key = FlatButton(view.bagBar, BAGBAR - 2, BAGBAR - 2)
    key:SetPoint("RIGHT")
    key.icon = key:CreateTexture(nil, "ARTWORK")
    key.icon:SetPoint("TOPLEFT", 2, -2)
    key.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    key.icon:SetTexture("Interface\\Icons\\INV_Misc_Key_03")
    key.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    key.tip = KEYRING_LABEL
    key.tip2 = L["Click: show or hide it"]
    key:SetActive(db.keyring)
    key:HookScript("OnEnter", function()
        if db.keyring then
            view.hoverBag = KEYRING
            DimAll(view)
        end
    end)
    key:HookScript("OnLeave", function()
        view.hoverBag = nil
        DimAll(view)
    end)
    key:SetScript("OnClick", function(self)
        if Blocked(view) then return end
        db.keyring = not db.keyring
        self:SetActive(db.keyring)
        view.hoverBag = db.keyring and KEYRING or nil
        view.layoutKey = nil
        UpdateAll(view)
    end)
end

-- comprar esta protegido: un boton seguro hace clic en el de comprar del juego
local function BuildBuyButton(view)
    local target = BankPanel and BankPanel.PurchaseButton
    local buy
    if target then
        buy = FlatButton(view.bagBar, BAGBAR - 2, BAGBAR - 2, "SecureActionButtonTemplate")
        buy:RegisterForClicks("AnyUp", "AnyDown")
        buy:SetAttribute("type", "click")
        buy:SetAttribute("clickbutton", target)
        buy.tip3 = L["The game asks you to confirm."]
    else
        buy = FlatButton(view.bagBar, BAGBAR - 2, BAGBAR - 2)
        buy:SetScript("OnClick", ShowGameBank)
        buy.tip3 = L["Opens the game's bank to buy it."]
    end
    buy.text = Skin(buy:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge"), "title")
    buy.text:SetPoint("CENTER", 0, 1)
    buy.text:SetText("+")
    buy.tip = L["Buy a bank slot"]
    buy:Hide()
    view.AfterBar = function(previous)
        -- un boton seguro no se puede mover ni esconder en combate
        if InCombatLockdown() and buy:IsProtected() then return end
        local data = NextBankPurchase()
        if not data then
            buy:Hide()
            return
        end
        buy.tip2 = data.tabCost and format(L["Cost: %s"], Money(data.tabCost)) or nil
        -- en rojo si no llega el oro
        if buy.tip2 and data.canAfford == false then
            buy.tip2 = "|cffff4040" .. buy.tip2 .. "  " .. L["Not enough gold"] .. "|r"
        end
        buy:ClearAllPoints()
        if previous then
            buy:SetPoint("LEFT", previous, "RIGHT", 12, 0)
        else
            buy:SetPoint("LEFT")
        end
        buy:Show()
    end
end

local function BuildFooter(view)
    local footer = CreateFrame("Frame", nil, view.frame)
    footer:SetHeight(FOOTER)
    footer:SetPoint("BOTTOMLEFT", PAD, PAD)
    footer:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    view.footer = footer

    local freeFrame = CreateFrame("Frame", nil, footer)
    freeFrame:SetPoint("LEFT")
    freeFrame:SetSize(90, FOOTER)
    local bag = freeFrame:CreateTexture(nil, "ARTWORK")
    bag:SetTexture(view.kind == "bank" and BANK_ICON or BACKPACK_ICON)
    bag:SetSize(14, 14)
    bag:SetPoint("LEFT", 2, 0)
    footer.free = Skin(freeFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), "text")
    footer.free:SetPoint("LEFT", bag, "RIGHT", 5, 0)
    freeFrame:SetScript("OnEnter", function(self) FreeTooltip(view, self) end)
    freeFrame:SetScript("OnLeave", GameTooltip_Hide)

    footer.moneyFrame = CreateFrame("Frame", nil, footer)
    footer.moneyFrame:SetPoint("RIGHT")
    footer.moneyFrame:SetHeight(FOOTER)
    footer.money = footer.moneyFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footer.money:SetPoint("RIGHT")
    footer.moneyFrame:SetScript("OnEnter", function(self) MoneyTooltip(view, self) end)
    footer.moneyFrame:SetScript("OnLeave", GameTooltip_Hide)

    footer.currency = footer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footer.currency:SetPoint("RIGHT", footer.moneyFrame, "LEFT", -12, 0)
end

-- ---------------------------------------------------------------- opciones

local function CycleTheme(step)
    local index = 1
    for i, entry in ipairs(ns.themes) do
        if entry.key == theme.key then index = i end
    end
    index = (index - 1 + step) % #ns.themes + 1
    ApplyTheme(ns.themes[index].key)
end

local function Relayout()
    EachView(function(view)
        view.layoutKey = nil
        if view.frame:IsShown() then UpdateAll(view) end
    end)
end

local function Refresh()
    EachView(function(view)
        if view.frame:IsShown() then UpdateAll(view) end
    end)
end

local function BuildOptions()
    local p = CreateFrame("Frame", nil, bagsView.frame)
    p:SetWidth(250)
    p:EnableMouse(true)
    p:Hide()
    Skin(Plain(p, "BACKGROUND", -8), "background"):SetAllPoints()
    SkinEdges(Edges(p, "BORDER"), "border")

    local title = Skin(p:CreateFontString(nil, "OVERLAY", "GameFontNormal"), "title")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText(L["Options"])
    Display(title, 16)

    local rows = {}
    local y = -32

    local function Section(text)
        y = y - 6
        local fs = Skin(p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), "header")
        fs:SetPoint("TOPLEFT", 12, y)
        fs:SetText(L[text])
        local line = Skin(Line(p, "BORDER"), "border", 0.4)
        line:SetPoint("LEFT", fs, "RIGHT", 6, 0)
        line:SetPoint("RIGHT", p, "RIGHT", -12, 0)
        y = y - 18
    end

    local function Row(label)
        local row = CreateFrame("Button", nil, p)
        row:SetPoint("TOPLEFT", 8, y)
        row:SetPoint("TOPRIGHT", -8, y)
        row:SetHeight(22)
        row.hl = Skin(Plain(row, "BACKGROUND"), "row")
        row.hl:SetAllPoints()
        row.hl:Hide()
        row:SetScript("OnEnter", function(self) self.hl:Show() end)
        row:SetScript("OnLeave", function(self) self.hl:Hide() end)
        row.label = Skin(row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), "text")
        row.label:SetPoint("LEFT", 6, 0)
        row.label:SetText(L[label])
        y = y - 22
        rows[#rows + 1] = row
        return row
    end

    local function Small(row, text, onClick)
        local b = FlatButton(row, 18, 18)
        b.text = Skin(b:CreateFontString(nil, "OVERLAY", "GameFontHighlight"), "text")
        b.text:SetPoint("CENTER", 0, 1)
        b.text:SetText(text)
        b:HookScript("OnEnter", function() row.hl:Show() end)
        b:HookScript("OnLeave", function() row.hl:Hide() end)
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:SetScript("OnClick", onClick)
        return b
    end

    -- [-] valor [+], tambien con la rueda
    local function Stepper(label, valueWidth, get, set)
        local row = Row(label)
        local plus = Small(row, "+", function() set(1); p:Refresh() end)
        plus:SetPoint("RIGHT", -4, 0)
        row.value = Skin(row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), "title")
        row.value:SetPoint("RIGHT", plus, "LEFT", -4, 0)
        row.value:SetWidth(valueWidth)
        row.value:SetJustifyH("CENTER")
        local minus = Small(row, "-", function() set(-1); p:Refresh() end)
        minus:SetPoint("RIGHT", row.value, "LEFT", -4, 0)
        row:EnableMouseWheel(true)
        row:SetScript("OnMouseWheel", function(_, delta) set(delta); p:Refresh() end)
        row.Refresh = function(self) self.value:SetText(get()) end
    end

    local function Check(label, get, set)
        local row = Row(label)
        local box = CreateFrame("Frame", nil, row)
        box:SetSize(14, 14)
        box:SetPoint("LEFT", 6, 0)
        Skin(Plain(box, "BACKGROUND"), "box"):SetAllPoints()
        SkinEdges(Edges(box, "BORDER"), "border")
        row.mark = Skin(Plain(box, "ARTWORK"), "title")
        row.mark:SetPoint("TOPLEFT", 3, -3)
        row.mark:SetPoint("BOTTOMRIGHT", -3, 3)
        row.label:ClearAllPoints()
        row.label:SetPoint("LEFT", box, "RIGHT", 8, 0)
        row:SetScript("OnClick", function()
            set(not get())
            p:Refresh()
        end)
        row.Refresh = function(self) self.mark:SetShown(get() and true or false) end
    end

    local function Option(key, after)
        return function() return db[key] end, function(value)
            db[key] = value
            if after then after() end
        end
    end

    Section("Window")
    Stepper("Theme", 100, function() return L[theme.name] end, CycleTheme)
    Stepper("Columns", 40, function() return db.columns end, function(step)
        if Blocked(bagsView) then return end
        db.columns = Clamp(db.columns + step, 6, 24)
        Relayout()
    end)
    Stepper("Scale", 40, function() return format("%d%%", db.scale * 100 + 0.5) end, function(step)
        if Blocked(bagsView) then return end
        db.scale = Clamp(math.floor((db.scale + step * 0.05) * 100 + 0.5) / 100, 0.6, 1.5)
        EachView(function(view) view.frame:SetScale(db.scale) end)
        RefitLines()
    end)
    Check("Separate each bag", Option("splitBags", function()
        if not Blocked(bagsView) then Relayout() end
    end))
    Check("Lock window", Option("locked"))
    Check("Replace the game bags", Option("replace", function()
        Say("Reload the interface to apply this.")
    end))
    Check("Replace the game bank", Option("bank"))

    Section("Items")
    Check("Item level", Option("itemLevel", Refresh))
    Check("Quality borders", Option("qualityBorders", Refresh))
    Check("Mark junk", Option("junk", Refresh))
    Check("Glow on new items", Option("newGlow", Refresh))
    Check("Sort the other way round",
        function() return C_Container.GetSortBagsRightToLeft() end,
        function(value) C_Container.SetSortBagsRightToLeft(value) end)

    Section("Vendors")
    Check("Sell junk at vendors", Option("sellJunk"))
    Check("Repair at vendors", Option("repair"))

    p:SetHeight(-y + 10)

    function p:Refresh()
        for _, row in ipairs(rows) do
            if row.Refresh then row:Refresh() end
        end
    end
    return p
end

ShowOptions = function(show)
    local main = bagsView.frame
    if show == nil then show = not (options and options:IsShown()) end
    if show and not options then options = BuildOptions() end
    if not options then return end
    if show then
        -- al lado que tenga sitio
        options:ClearAllPoints()
        local x = main:GetCenter()
        if x and x * main:GetEffectiveScale() > UIParent:GetWidth() * UIParent:GetEffectiveScale() / 2 then
            options:SetPoint("TOPRIGHT", main, "TOPLEFT", -4, 0)
        else
            options:SetPoint("TOPLEFT", main, "TOPRIGHT", 4, 0)
        end
        options:Refresh()
        options:Show()
    else
        options:Hide()
    end
    bagsView.optionsButton:SetActive(show)
end

-- ---------------------------------------------------------------- ventanas

local function NewView(spec)
    local view = {
        kind = spec.kind,
        Bags = spec.Bags, AllBags = spec.AllBags, BarBags = spec.BarBags, OwnRow = spec.OwnRow,
        barKey = spec.barKey, pointKey = spec.pointKey, defaultPoint = spec.defaultPoint,
        buttons = {}, bagButtons = {}, separators = {},
        query = "",
    }
    view.UpdateBar = function() UpdateBagBar(view) end

    local frame = CreateFrame("Frame", spec.name, UIParent)
    frame:Hide()
    frame:SetFrameStrata("MEDIUM")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetScale(db.scale)
    view.frame = frame

    Skin(Plain(frame, "BACKGROUND", -8), "background"):SetAllPoints()
    frame.glow = Plain(frame, "BACKGROUND", -7)
    frame.glow:SetPoint("TOPLEFT", 1, -1)
    frame.glow:SetPoint("TOPRIGHT", -1, -1)
    frame.glow:SetHeight(80)
    SkinEdges(Edges(frame, "BORDER"), "border")

    BuildHeader(view, spec)
    BuildSearch(view, spec.search)
    BuildBagBar(view)
    view.grid = CreateFrame("Frame", nil, frame)
    view.grid:SetSize(SLOT, SLOT)
    BuildFooter(view)
    PlaceGrid(view)
    Place(view)

    frame:SetScript("OnShow", function(self)
        UpdateAll(view)
        FadeIn(self)
        if spec.OnShow then spec.OnShow() end
    end)
    frame:SetScript("OnHide", function(self)
        view.hoverBag = nil
        view.searchBox:SetText("")
        view.searchBox:ClearFocus()
        if spec.OnHide then spec.OnHide(self) end
    end)
    return view
end

local function Build()
    bagsView = NewView({
        kind = "bags", name = "BagsForeverFrame", search = "BagsForeverSearch",
        title = "Bags Forever", closeTip = L["Close"], options = true,
        barIcon = BACKPACK_ICON, barKey = "showBags",
        pointKey = "point", defaultPoint = { "BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -60, 110 },
        Bags = function() return Visible(AllBags()) end,
        AllBags = AllBags,
        BarBags = function()
            local list = {}
            for bag = 0, SPECIAL_BAG do list[#list + 1] = bag end
            return list
        end,
        OwnRow = function(bag) return db.splitBags or bag == SPECIAL_BAG or bag == KEYRING end,
        Sort = SortBags, sortTip = L["Sort bags"],
        sortTip2 = L["Right click a bag in the bag bar to leave it out."],
        Close = function() Toggle() end,
        OnShow = function() Sound("IG_BACKPACK_OPEN") end,
        OnHide = function(self)
            Sound("IG_BACKPACK_CLOSE")
            self.openedBy = nil
            MarkAllSeen()
            -- y que el juego tambien los de por vistos
            if C_NewItems and C_NewItems.ClearAll then C_NewItems.ClearAll() end
        end,
    })
    BuildKeyring(bagsView)

    bankView = NewView({
        kind = "bank", name = "BagsForeverBankFrame", search = "BagsForeverBankSearch",
        title = L["Bank"], closeTip = L["Close the bank"],
        barIcon = BANK_ICON, barKey = "showBankBags",
        pointKey = "bankPoint", defaultPoint = { "TOPLEFT", UIParent, "TOPLEFT", 20, -110 },
        Bags = function() return Visible(BankTabs()) end,
        AllBags = BankTabs,
        BarBags = BankTabs,
        OwnRow = function() return db.splitBags end,
        Sort = SortBank, sortTip = L["Sort bank"],
        Close = CloseBank,
    })
    BuildBuyButton(bankView)

    -- Escape; el banco lo cierra el juego
    table.insert(UISpecialFrames, "BagsForeverFrame")
    ApplyTheme(db.theme)
end

-- ---------------------------------------------------------------- eventos

local events = CreateFrame("Frame")
local handlers = {}

local function Watch(event, handler)
    -- un evento que este cliente no tenga no debe romper nada
    if pcall(events.RegisterEvent, events, event) then
        handlers[event] = handler
    end
end

local function WhenShown()
    EachView(function(view)
        if view.frame:IsShown() then Queue(view) end
    end)
end

events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")

handlers.ADDON_LOADED = function(name)
    if name ~= ADDON then return end
    BagsForeverDB = BagsForeverDB or {}
    db = BagsForeverDB
    for key, value in pairs(DEFAULTS) do
        if db[key] == nil then db[key] = value end
    end
    theme = FindTheme(db.theme)
end

handlers.PLAYER_LOGIN = function()
    local guid = UnitGUID("player")
    db.hiddenBags = db.hiddenBags or {}
    db.hiddenBags[guid] = db.hiddenBags[guid] or {}
    hiddenBags = db.hiddenBags[guid]
    Build()
    if db.replace then TakeOver() end
    HookBank()

    Watch("BAG_UPDATE", WhenShown)
    Watch("BAG_UPDATE_DELAYED", WhenShown)
    Watch("BAG_CONTAINER_UPDATE", WhenShown)
    Watch("BAG_UPDATE_COOLDOWN", WhenShown)
    Watch("BAG_NEW_ITEMS_UPDATED", WhenShown)
    Watch("BAG_SLOT_FLAGS_UPDATED", WhenShown)
    Watch("QUEST_ACCEPTED", WhenShown)
    Watch("QUEST_REMOVED", WhenShown)
    Watch("UNIT_INVENTORY_CHANGED", WhenShown)
    Watch("PLAYERBANKSLOTS_CHANGED", WhenShown)
    Watch("PLAYERBANKBAGSLOTS_CHANGED", WhenShown)
    Watch("BANK_TAB_SETTINGS_UPDATED", WhenShown)
    Watch("BANK_TABS_CHANGED", BankTabsChanged)
    Watch("ITEM_LOCK_CHANGED", function(bag, slot)
        if not slot then return end
        EachView(function(view)
            local b = view.frame:IsShown() and view.buttons[bag] and view.buttons[bag][slot]
            if b and b:IsShown() then UpdateButton(b) end
        end)
    end)
    Watch("GET_ITEM_INFO_RECEIVED", function()
        EachView(function(view)
            if view.frame:IsShown() and view.waiting then Queue(view) end
        end)
    end)
    Watch("PLAYER_MONEY", function()
        EachView(function(view)
            if view.frame:IsShown() then UpdateMoney(view) end
        end)
    end)
    Watch("CURRENCY_DISPLAY_UPDATE", function()
        if bagsView.frame:IsShown() then UpdateCurrencies(bagsView) end
    end)
    Watch("MERCHANT_SHOW", function()
        if db.repair then Repair() end
        if db.sellJunk then SellJunk() end
    end)
    Watch("PLAYER_ENTERING_WORLD", RefitLines)
    Watch("UI_SCALE_CHANGED", RefitLines)
    Watch("DISPLAY_SIZE_CHANGED", RefitLines)
    Watch("PLAYER_REGEN_ENABLED", function()
        local todo = pending
        pending = {}
        if todo.layout then Relayout() end
        if todo.close then bagsView.frame:Hide() end
        if todo.bankClose then bankView.frame:Hide() end
        if todo.open and not todo.close then Open() end
    end)
end

events:SetScript("OnEvent", function(_, event, ...)
    local handler = handlers[event]
    if handler then handler(...) end
end)

-- ---------------------------------------------------------------- comandos

SLASH_BAGSFOREVER1 = "/bf"
SLASH_BAGSFOREVER2 = "/bagsforever"
SlashCmdList.BAGSFOREVER = function(message)
    local command = (message or ""):lower():match("^%s*(%S*)")
    if command == "sort" then
        SortBags()
    elseif command == "options" or command == "config" then
        Open()
        ShowOptions(true)
    elseif command == "reset" then
        db.point, db.bankPoint = nil, nil
        db.scale = 1
        EachView(function(view)
            view.frame:SetScale(1)
            Place(view)
        end)
        RefitLines()
    elseif command == "help" then
        Say("Commands: /bf (open), /bf sort, /bf options, /bf reset")
    else
        Toggle()
    end
end
