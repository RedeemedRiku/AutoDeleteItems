-- AutoDeleteItems: Automatically delete specified items on loot
-- Compatible with WoW 3.3.5 WotLK

local ADDON_NAME = "AutoDeleteItems"
local VERSION = "1.0"

-- Saved variables (don't reset on load)
AutoDeleteItemsDB = AutoDeleteItemsDB or {}
AutoDeleteItemsSettings = AutoDeleteItemsSettings or {}

-- Forge values (const)
local FORGE_VALUES = {
    TITANFORGED = 4096,
    WARFORGED = 8192,
    LIGHTFORGED = 12288
}

-- Forge hierarchy (const)
local FORGE_HIERARCHY = {
    [0] = 0,
    [FORGE_VALUES.TITANFORGED] = 1,
    [FORGE_VALUES.WARFORGED] = 2,
    [FORGE_VALUES.LIGHTFORGED] = 3
}

-- Frame for events
local frame = CreateFrame("Frame", "AutoDeleteItemsFrame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("CHAT_MSG_LOOT")

-- Timer frame for delayed deletion (3.3.5 compatible)
local deleteTimerFrame = CreateFrame("Frame")
local pendingDeletions = {}

-- Main GUI frame
local mainFrame

-- Store reusable frames for the list (prevents memory leaks)
local itemFramePool = {}
local maxVisibleItems = 12 -- Number of visible items at once
local allItems = {} -- Cache of all filtered/sorted items
local scrollOffset = 0 -- Current scroll position

-- Determine forge level from uniqueId
local function GetForgeLevel(uniqueId)
    if not uniqueId or uniqueId == 0 then
        return 0
    end
    
    -- Check lightforged first (highest value)
    if uniqueId >= FORGE_VALUES.LIGHTFORGED then
        return FORGE_HIERARCHY[FORGE_VALUES.LIGHTFORGED]
    elseif uniqueId >= FORGE_VALUES.WARFORGED then
        return FORGE_HIERARCHY[FORGE_VALUES.WARFORGED]
    elseif uniqueId >= FORGE_VALUES.TITANFORGED then
        return FORGE_HIERARCHY[FORGE_VALUES.TITANFORGED]
    end
    
    return 0
end

-- Get forge name for display
local function GetForgeName(forgeLevel)
    if forgeLevel == FORGE_HIERARCHY[FORGE_VALUES.LIGHTFORGED] then
        return "Lightforged"
    elseif forgeLevel == FORGE_HIERARCHY[FORGE_VALUES.WARFORGED] then
        return "Warforged"
    elseif forgeLevel == FORGE_HIERARCHY[FORGE_VALUES.TITANFORGED] then
        return "Titanforged"
    else
        return "Regular"
    end
end

-- Check if item is a melee weapon (subject to affix-ignore rule)
local function IsMeleeWeapon(itemId)
    local _, _, _, _, _, _, _, _, equipSlot = GetItemInfo(itemId)
    if not equipSlot then return false end
    
    -- Weapon slots that ignore affixes
    local meleeSlots = {
        INVTYPE_WEAPON = true,
        INVTYPE_2HWEAPON = true,
        INVTYPE_WEAPONMAINHAND = true,
        INVTYPE_WEAPONOFFHAND = true,
    }
    
    return meleeSlots[equipSlot] == true
end

-- Parse itemLink to extract all components
local function ParseItemLink(itemLink)
    if not itemLink then return nil end
    
    local itemString = itemLink:match("item:([%-?%d:]+)")
    if not itemString then return nil end
    
    local parts = {strsplit(":", itemString)}
    
    local itemId = tonumber(parts[1])
    if not itemId then return nil end
    
    local suffixId = tonumber(parts[7]) or 0
    local uniqueId = tonumber(parts[8]) or 0
    
    local itemName = itemLink:match("%[(.+)%]")
    local isMelee = IsMeleeWeapon(itemId)
    
    return {
        itemId = itemId,
        suffixId = suffixId,
        uniqueId = uniqueId,
        itemName = itemName,
        itemLink = itemLink,
        isMeleeWeapon = isMelee
    }
end

-- Check if item has a bounty using custom game data
local function HasBounty(itemId)
    if not itemId then return false end
    
    local gold = GetCustomGameData(31, itemId)
    
    -- If gold is nil or 0, no bounty
    return gold and gold > 0
end

-- Add item to database
local function AddItem(itemLink)
    local itemData = ParseItemLink(itemLink)
    if not itemData then
        print("|cffff0000[AutoDelete]|r Invalid item link")
        return false
    end
    
    local forgeLevel = GetForgeLevel(itemData.uniqueId)
    
    -- Create unique key
    local key
    if itemData.isMeleeWeapon then
        key = string.format("%d_weapon_%d", itemData.itemId, forgeLevel)
    else
        key = string.format("%d_%d_%d", itemData.itemId, itemData.suffixId, forgeLevel)
    end
    
    -- Check if already exists
    if AutoDeleteItemsDB[key] then
        print("|cffff0000[AutoDelete]|r Item already in list: " .. itemData.itemLink)
        return false
    end
    
    -- Store item data
    AutoDeleteItemsDB[key] = {
        itemId = itemData.itemId,
        suffixId = itemData.suffixId,
        uniqueId = itemData.uniqueId,
        forgeLevel = forgeLevel,
        itemName = itemData.itemName,
        itemLink = itemData.itemLink,
        isMeleeWeapon = itemData.isMeleeWeapon
    }
    
    local weaponNote = itemData.isMeleeWeapon and " (all affixes)" or ""
    print("|cff00ff00[AutoDelete]|r Added: " .. itemData.itemLink .. " (" .. GetForgeName(forgeLevel) .. ")" .. weaponNote)
    
    -- Refresh display if window is open
    if mainFrame and mainFrame:IsShown() then
        RefreshItemList()
    end
    
    return true
end

-- Remove item from database
local function RemoveItem(key)
    if AutoDeleteItemsDB[key] then
        local itemLink = AutoDeleteItemsDB[key].itemLink
        AutoDeleteItemsDB[key] = nil
        print("|cff00ff00[AutoDelete]|r Removed: " .. itemLink)
        return true
    end
    return false
end

-- Clear all items with confirmation
local function ClearAllItems()
    StaticPopup_Show("AUTODELETE_CLEAR_ALL")
end

-- Check if looted item should be deleted
local function ShouldDeleteItem(lootedItemLink)
    local lootedData = ParseItemLink(lootedItemLink)
    if not lootedData then return false end
    
    local lootedForgeLevel = GetForgeLevel(lootedData.uniqueId)
    
    -- Check all stored items
    for _, storedItem in pairs(AutoDeleteItemsDB) do
        if storedItem.itemId == lootedData.itemId then
            local suffixMatches = storedItem.isMeleeWeapon or (storedItem.suffixId == lootedData.suffixId)
            
            if suffixMatches and lootedForgeLevel <= storedItem.forgeLevel then
                return true
            end
        end
    end
    
    return false
end

-- Check if an item still exists in bags
local function ItemExistsInBags(itemData)
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local bagItemLink = GetContainerItemLink(bag, slot)
            if bagItemLink then
                local bagItemData = ParseItemLink(bagItemLink)
                if bagItemData and bagItemData.itemId == itemData.itemId then
                    local suffixMatches = itemData.isMeleeWeapon or (bagItemData.suffixId == itemData.suffixId)
                    if suffixMatches then
                        local bagForgeLevel = GetForgeLevel(bagItemData.uniqueId)
                        local targetForgeLevel = GetForgeLevel(itemData.uniqueId)
                        if bagForgeLevel <= targetForgeLevel then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

-- Delete item from bags (single attempt)
local function DeleteItemFromBags(itemLink)
    local itemData = ParseItemLink(itemLink)
    if not itemData then return false, 0 end
    
    local deletedCount = 0
    
    -- Search through all bags and delete ALL matching items
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local bagItemLink = GetContainerItemLink(bag, slot)
            if bagItemLink then
                local bagItemData = ParseItemLink(bagItemLink)
                if bagItemData and bagItemData.itemId == itemData.itemId then
                    local suffixMatches = itemData.isMeleeWeapon or (bagItemData.suffixId == itemData.suffixId)
                    
                    if suffixMatches then
                        local bagForgeLevel = GetForgeLevel(bagItemData.uniqueId)
                        local targetForgeLevel = GetForgeLevel(itemData.uniqueId)
                        
                        if bagForgeLevel <= targetForgeLevel then
                            -- Check if item has a bounty
                            if HasBounty(bagItemData.itemId) then
                                print("|cffff9900[AutoDelete]|r Not deleted (has bounty): " .. bagItemLink)
                            else
                                -- Pick up and delete the item
                                PickupContainerItem(bag, slot)
                                DeleteCursorItem()
                                deletedCount = deletedCount + 1
                            end
                        end
                    end
                end
            end
        end
    end
    
    return deletedCount > 0, deletedCount
end

-- Timer frame OnUpdate handler (defined once, reused)
local function TimerOnUpdate(self, elapsed)
    for i = #pendingDeletions, 1, -1 do
        local pending = pendingDeletions[i]
        pending.timeLeft = pending.timeLeft - elapsed
        
        if pending.timeLeft <= 0 then
            -- Attempt deletion
            local deleted, count = DeleteItemFromBags(pending.itemLink)
            
            if deleted then
                -- Success - show message and remove from queue
                if count == 1 then
                    print("|cffff9900[AutoDelete]|r Deleted: " .. pending.itemLink)
                else
                    print("|cffff9900[AutoDelete]|r Deleted " .. count .. "x: " .. pending.itemLink)
                end
                table.remove(pendingDeletions, i)
            else
                -- Failed - check if item still exists and we have retries left
                local itemData = ParseItemLink(pending.itemLink)
                if itemData and ItemExistsInBags(itemData) and pending.attempts < 3 then
                    -- Item still exists, schedule retry
                    pending.attempts = pending.attempts + 1
                    pending.timeLeft = 0.15
                else
                    -- Either item is gone or we're out of retries
                    table.remove(pendingDeletions, i)
                end
            end
        end
    end
    
    -- Stop the OnUpdate if no pending deletions
    if #pendingDeletions == 0 then
        self:SetScript("OnUpdate", nil)
    end
end

-- Schedule a delayed deletion with retry logic (3.3.5 compatible)
local function ScheduleDeletion(itemLink, delay)
    table.insert(pendingDeletions, {
        itemLink = itemLink,
        timeLeft = delay,
        attempts = 1
    })
    
    -- Start the timer if not already running
    if not deleteTimerFrame:GetScript("OnUpdate") then
        deleteTimerFrame:SetScript("OnUpdate", TimerOnUpdate)
    end
end

-- Scan bags and delete all items on the list
local function ScanAndDeleteItems()
    local totalDeleted = 0
    local itemsDeleted = {}
    
    -- Scan through all bags
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local bagItemLink = GetContainerItemLink(bag, slot)
            if bagItemLink then
                local bagItemData = ParseItemLink(bagItemLink)
                if bagItemData then
                    -- Check if this item should be deleted
                    if ShouldDeleteItem(bagItemLink) then
                        -- Check if it has a bounty
                        if not HasBounty(bagItemData.itemId) then
                            -- Delete it
                            PickupContainerItem(bag, slot)
                            DeleteCursorItem()
                            
                            -- Track what we deleted
                            local itemKey = bagItemData.itemLink
                            if not itemsDeleted[itemKey] then
                                itemsDeleted[itemKey] = 0
                            end
                            itemsDeleted[itemKey] = itemsDeleted[itemKey] + 1
                            totalDeleted = totalDeleted + 1
                        end
                    end
                end
            end
        end
    end
    
    -- Report results
    if totalDeleted > 0 then
        print("|cffff9900[AutoDelete]|r Bag scan complete. Deleted " .. totalDeleted .. " item(s):")
        for itemLink, count in pairs(itemsDeleted) do
            if count == 1 then
                print("  " .. itemLink)
            else
                print("  " .. itemLink .. " x" .. count)
            end
        end
    else
        print("|cff00ff00[AutoDelete]|r Bag scan complete. No items to delete.")
    end
end

-- Create main GUI
local function CreateMainFrame()
    if mainFrame then return end
    
    mainFrame = CreateFrame("Frame", "AutoDeleteItemsMainFrame", UIParent)
    mainFrame:SetWidth(450)
    mainFrame:SetHeight(500)
    mainFrame:SetPoint("CENTER")
    mainFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
    mainFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Save position
        local point, _, relativePoint, xOfs, yOfs = self:GetPoint()
        AutoDeleteItemsSettings.windowPosition = {
            point = point,
            relativePoint = relativePoint,
            xOffset = xOfs,
            yOffset = yOfs
        }
    end)
    
    -- Set higher frame strata and level
    mainFrame:SetFrameStrata("HIGH")
    mainFrame:SetFrameLevel(100)
    mainFrame:EnableMouseWheel(true)
    
    mainFrame:Hide()
    
    -- Restore saved position if it exists
    if AutoDeleteItemsSettings.windowPosition and AutoDeleteItemsSettings.windowPosition.point then
        mainFrame:ClearAllPoints()
        mainFrame:SetPoint(
            AutoDeleteItemsSettings.windowPosition.point,
            UIParent,
            AutoDeleteItemsSettings.windowPosition.relativePoint,
            AutoDeleteItemsSettings.windowPosition.xOffset,
            AutoDeleteItemsSettings.windowPosition.yOffset
        )
    end
    
    -- Title
    local title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -20)
    title:SetText("Auto Delete Items")
    
    -- Close button
    local closeBtn = CreateFrame("Button", nil, mainFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -5, -5)
    
    -- Add item instruction
    local instruction = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    instruction:SetPoint("TOP", 0, -45)
    instruction:SetText("Shift-click an item while this window is open to add it to the list.")
    
    -- Search label
    local searchLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    searchLabel:SetPoint("TOP", -150, -75)
    searchLabel:SetText("Search:")
    
    -- Search box
    local searchBox = CreateFrame("EditBox", "AutoDeleteSearchBox", mainFrame, "InputBoxTemplate")
    searchBox:SetWidth(300)
    searchBox:SetHeight(30)
    searchBox:SetPoint("LEFT", searchLabel, "RIGHT", 5, 0)
    searchBox:SetAutoFocus(false)
    searchBox:SetScript("OnTextChanged", function(self)
        RefreshItemList(self:GetText())
    end)
    searchBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    
    -- Store reference to search box so we can access it later
    mainFrame.searchBox = searchBox
    
    -- Scroll frame for item list
    local scrollFrame = CreateFrame("ScrollFrame", "AutoDeleteScrollFrame", mainFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 20, -110)
    scrollFrame:SetPoint("BOTTOMRIGHT", -40, 80)
    
    -- Hook scroll events to update visible items
    scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
        RenderVisibleItems()
    end)
    
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(380)
    scrollChild:SetHeight(1)
    scrollFrame:SetScrollChild(scrollChild)
    
    mainFrame.scrollChild = scrollChild
    
    -- Clear all button
    local clearAllBtn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    clearAllBtn:SetWidth(120)
    clearAllBtn:SetHeight(30)
    clearAllBtn:SetPoint("BOTTOM", 0, 20)
    clearAllBtn:SetText("Clear All")
    clearAllBtn:SetScript("OnClick", ClearAllItems)
    
    -- Item count
    local itemCount = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    itemCount:SetPoint("BOTTOM", 0, 50)
    mainFrame.itemCount = itemCount
    
    RefreshItemList()
end

-- Refresh item list display with virtual scrolling
function RefreshItemList(searchText)
    if not mainFrame then return end
    
    local scrollChild = mainFrame.scrollChild
    
    -- Hide all existing frames
    for i = 1, #itemFramePool do
        itemFramePool[i]:Hide()
    end
    
    -- Build filtered list and cache it
    allItems = {}
    for key, itemData in pairs(AutoDeleteItemsDB) do
        if not searchText or searchText == "" or 
           string.lower(itemData.itemName):find(string.lower(searchText), 1, true) then
            table.insert(allItems, {key = key, data = itemData})
        end
    end
    
    -- Sort by name
    table.sort(allItems, function(a, b)
        return a.data.itemName < b.data.itemName
    end)
    
    -- Reset scroll offset when list changes
    scrollOffset = 0
    
    -- Update scroll child height based on total items
    local totalHeight = #allItems * 35
    scrollChild:SetHeight(math.max(1, totalHeight))
    
    -- Render visible items
    RenderVisibleItems()
    
    -- Update count
    if mainFrame.itemCount then
        mainFrame.itemCount:SetText(string.format("Items in list: %d", #allItems))
    end
end

-- Render only the visible items (virtual scrolling)
function RenderVisibleItems()
    if not mainFrame then return end
    
    local scrollChild = mainFrame.scrollChild
    local scrollFrame = scrollChild:GetParent()
    
    -- Calculate which items should be visible
    local verticalScroll = scrollFrame:GetVerticalScroll()
    local startIndex = math.floor(verticalScroll / 35) + 1
    local endIndex = math.min(startIndex + maxVisibleItems - 1, #allItems)
    
    -- Only create frames we need
    local numFramesNeeded = math.min(maxVisibleItems, #allItems)
    
    -- Create frames if needed (only up to maxVisibleItems)
    for i = 1, numFramesNeeded do
        if not itemFramePool[i] then
            local entry = CreateFrame("Frame", nil, scrollChild)
            entry:SetWidth(360)
            entry:SetHeight(30)
            
            local bg = entry:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetTexture(0, 0, 0, 0.3)
            
            local itemLink = CreateFrame("Button", nil, entry)
            itemLink:SetWidth(280)
            itemLink:SetHeight(20)
            itemLink:SetPoint("LEFT", 5, 0)
            itemLink:SetNormalFontObject("GameFontNormal")
            entry.itemLink = itemLink
            
            local deleteBtn = CreateFrame("Button", nil, entry, "UIPanelButtonTemplate")
            deleteBtn:SetWidth(60)
            deleteBtn:SetHeight(20)
            deleteBtn:SetPoint("RIGHT", -5, 0)
            deleteBtn:SetText("Delete")
            entry.deleteBtn = deleteBtn
            
            itemFramePool[i] = entry
        end
    end
    
    -- Update visible frames with data
    local frameIndex = 1
    for i = startIndex, endIndex do
        local item = allItems[i]
        if item and itemFramePool[frameIndex] then
            local entry = itemFramePool[frameIndex]
            
            -- Position frame based on its index in the full list
            local yOffset = -5 - ((i - 1) * 35)
            entry:SetPoint("TOPLEFT", 5, yOffset)
            entry:Show()
            
            local forgeName = GetForgeName(item.data.forgeLevel)
            local displayText = item.data.itemLink
            if forgeName ~= "Regular" then
                displayText = displayText .. " |cff00ccff(" .. forgeName .. ")|r"
            end
            if item.data.isMeleeWeapon then
                displayText = displayText .. " |cffffaa00[All Affixes]|r"
            end
            
            entry.itemLink:SetText(displayText)
            
            -- Clear old handlers to prevent leaks
            entry.itemLink:SetScript("OnClick", nil)
            entry.deleteBtn:SetScript("OnClick", nil)
            
            -- Set new handlers with local references
            local itemLinkRef = item.data.itemLink
            local keyRef = item.key
            
            entry.itemLink:SetScript("OnClick", function()
                if IsShiftKeyDown() then
                    local chatBox = ChatEdit_GetActiveWindow()
                    if chatBox then
                        chatBox:Insert(itemLinkRef)
                    end
                end
            end)
            
            entry.deleteBtn:SetScript("OnClick", function()
                StaticPopup_Show("AUTODELETE_REMOVE_ITEM", itemLinkRef, nil, keyRef)
            end)
            
            frameIndex = frameIndex + 1
        end
    end
    
    -- Hide any extra frames
    for i = frameIndex, #itemFramePool do
        itemFramePool[i]:Hide()
    end
end

-- Static popups
StaticPopupDialogs["AUTODELETE_REMOVE_ITEM"] = {
    text = "Delete %s from the list?",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function(self, key)
        RemoveItem(key)
        -- Refresh with current search text
        if mainFrame and mainFrame.searchBox then
            RefreshItemList(mainFrame.searchBox:GetText())
        else
            RefreshItemList()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["AUTODELETE_CLEAR_ALL"] = {
    text = "Delete ALL items from the list?",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        AutoDeleteItemsDB = {}
        print("|cff00ff00[AutoDelete]|r List cleared")
        -- Refresh with current search text
        if mainFrame and mainFrame.searchBox then
            RefreshItemList(mainFrame.searchBox:GetText())
        else
            RefreshItemList()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- Event handler
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == ADDON_NAME then
            -- Initialize settings if needed
            if not AutoDeleteItemsSettings then
                AutoDeleteItemsSettings = {}
            end
            if not AutoDeleteItemsSettings.windowPosition then
                AutoDeleteItemsSettings.windowPosition = {}
            end
            
            print("|cff00ff00[AutoDelete]|r Loaded. Type /autodelete to open")
        end
        
    elseif event == "CHAT_MSG_LOOT" then
        local message = ...
        local itemLink = message:match("|c%x+|Hitem:.-|h%[.-%]|h|r")
        
        if itemLink and (message:find("You receive") or message:find("You create") or message:find("You loot")) then
            if ShouldDeleteItem(itemLink) then
                ScheduleDeletion(itemLink, 0.15)
            end
        end
    end
end)

-- Test if an item would be deleted
local function TestItemDeletion(itemLink)
    if not itemLink or not itemLink:find("item:") then
        print("|cffff0000[AutoDelete]|r Invalid item link")
        return
    end
    
    local itemData = ParseItemLink(itemLink)
    if not itemData then
        print("|cffff0000[AutoDelete]|r Could not parse item")
        return
    end
    
    -- Check if item is on the list
    if not ShouldDeleteItem(itemLink) then
        print("|cff00ff00[AutoDelete Test]|r " .. itemLink .. " |cffffffffwill NOT be destroyed:|r Not on the destroy list")
        return
    end
    
    -- Check if it has a bounty
    if HasBounty(itemData.itemId) then
        print("|cff00ff00[AutoDelete Test]|r " .. itemLink .. " |cffffffffwill NOT be destroyed:|r On the destroy list but has a bounty")
        return
    end
    
    -- It would be destroyed
    local itemForgeLevel = GetForgeLevel(itemData.uniqueId)
    local forgeName = GetForgeName(itemForgeLevel)
    print("|cffff0000[AutoDelete Test]|r " .. itemLink .. " |cffffffffWILL be destroyed:|r On list, matches criteria (" .. forgeName .. ")")
end

-- Hook into chat frame to capture shift-clicked items
local origChatEdit_InsertLink = ChatEdit_InsertLink
function ChatEdit_InsertLink(link)
    if mainFrame and mainFrame:IsShown() and link and link:find("item:") then
        AddItem(link)
        return true
    end
    return origChatEdit_InsertLink(link)
end

-- Slash commands
SLASH_AUTODELETE1 = "/autodelete"
SLASH_AUTODELETE2 = "/ad"
SlashCmdList["AUTODELETE"] = function(msg)
    local command, rest = msg:match("^(%S*)%s*(.-)$")
    command = command:lower()
    
    if command == "t" or command == "test" then
        local itemLink = rest:match("(|c%x+|Hitem:.-|h%[.-%]|h|r)")
        if itemLink then
            TestItemDeletion(itemLink)
        else
            print("|cffff9900[AutoDelete]|r Usage: /ad test [Shift-click item]")
        end
    elseif command == "scan" then
        ScanAndDeleteItems()
    else
        CreateMainFrame()
        if mainFrame:IsShown() then
            mainFrame:Hide()
        else
            -- Restore position before showing if saved
            if AutoDeleteItemsSettings.windowPosition and AutoDeleteItemsSettings.windowPosition.point then
                mainFrame:ClearAllPoints()
                mainFrame:SetPoint(
                    AutoDeleteItemsSettings.windowPosition.point,
                    UIParent,
                    AutoDeleteItemsSettings.windowPosition.relativePoint,
                    AutoDeleteItemsSettings.windowPosition.xOffset,
                    AutoDeleteItemsSettings.windowPosition.yOffset
                )
            end
            mainFrame:Show()
        end
    end
end