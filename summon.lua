local _, addonData = ...
local L = LibStub("AceLocale-3.0"):GetLocale("SteaSummon")
local g_self -- for callbacks

local summon = {
  waiting = {}, -- the summon list
  numwaiting = 0, -- the summon list length
  hasSummoned = false, -- when true we believe you more
  tainted = false, -- indicates player has cancelled something that's nothing to do with them
  myLocation = "", -- the location player is
  myZone = "", -- the zone player is
  location = "", -- area of zone summons are going to
  zone = "", -- the zone summons are going to
  summoningPlayer = "", -- the player currently being summoned
  shards = 0, -- the number of shards in our bag
  isWarlock = false,
  infoSend = false,
  me = "",
  dirty = true, -- waiting list changed flag, to begin we want to show load list so default dirty
  postInit = false,
  isCasting = false,
  buffLetter = {
    ["Warlock"] = L["W"],
    ["Buffed"] = L["B"],
    ["Normal"] = L["N"],
    ["Last"] = L["L"]
  },

  ---------------------------------
  init = function(self)
    g_self = self
    addonData.debug:registerCategory("summon.display")
    addonData.debug:registerCategory("summon.waitlist.record")
    addonData.debug:registerCategory("summon.tick")
    addonData.debug:registerCategory("summon.misc")
    addonData.debug:registerCategory("summon.spellcast")

    self.isWarlock = addonData.util:playerIsWarlock()
    self.me, _ = UnitName("player")
    self.me = strsplit("-", self.me)

    self.waiting = SteaSummonSave.waiting
    self.numwaiting = #self.waiting
    self.postInit = true

    -- there seems to be no good event/time to check if we are in a group
    -- group roster changes fail to tell us when we are NOT in a group
    -- so we're gonna bodge this one
    C_Timer.After(1, self.postInitSetup)
  end,

  ---------------------------------
  postInitSetup = function(self)
    if not self then
      self = addonData.summon
    end

    if not self.postInit then
      return
    end
    self.postInit = false

    -- sanity debug
    for i,v in pairs(SteaSummonSave.waiting) do
      db("waitlist", i, v)
    end

    local ts = GetTime()

    if not IsInGroup(LE_PARTY_CATEGORY_HOME)
        or SteaSummonSave.waitingKeepTime == 0
        or ts - SteaSummonSave.timeStamp > SteaSummonSave.waitingKeepTime * 60 then
      db("wiping wait list")
      db("saved ts", SteaSummonSave.timeStamp, "time", ts, "keep mins", SteaSummonSave.waitingKeepTime)
      db("group status:", IsInGroup(LE_PARTY_CATEGORY_HOME))
      self:listClear()
    end

    -- good time for a version check
    addonData.gossip:SteaSummonVersion()
  end,

  ---------------------------------
  listClear = function(self)
    wipe(self.waiting)
    self.numwaiting = 0
    self:listDirty(true)
  end,

  ---------------------------------
  listDirty = function(self, dirty)
    if dirty ~= nil then
      self.dirty = dirty
    end
    return self.dirty
  end,

  ---------------------------------
  waitRecord = function(self, player, time, status, prioReason)
    local rec
    rec = {player, time, status, prioReason, true}
    db("summon.waitlist.record","Created record {",
        self:recPlayer(rec), self:recTime(rec), self:recStatus(rec), self:recPrio(rec), true, "}")

    return rec
  end,

  ---------------------------------
  recMarshal = function(self, rec)
    return self:recPlayer(rec)
        .. "+" .. self:recTime(rec)
        .. "+" .. self:recStatus(rec)
        .. "+" .. self:recPrio(rec)
  end,

  ---------------------------------
  recUnMarshal = function(self, data)
    if data then
      local player, time, status, prio = strsplit("+", data)
      if player and time and status and prio then
        return self:waitRecord(player, time, status, prio)
      else
        db("summon.waitlist.record", "unmarshalled data contains nil", player, time, status, prio)
      end
    else
      db("summon.waitlist.record", "tried to unmarshal nil")
    end
  end,

  ---------------------------------
  recPlayer = function(self, rec, val)
    if val then
      self:listDirty(true)
      db("summon.waitlist.record","setting record player value:", val)
      rec[1] = val
    end
    return rec[1]
  end,

  ---------------------------------
  recTime = function(self, rec, val)
    if val then
      self:listDirty(true)
      db("summon.waitlist.record","setting record time value:", val)
      rec[2] = val
    end
    return rec[2]
  end,

  ---------------------------------
  recTimeIncr = function(self, rec)
    self:listDirty(true)
    rec[2] = rec[2] + 1
    db("summon.tick","setting record time value:", rec[2]) -- too verbose for summon.waitlist.record
    return rec[2]
  end,

  ---------------------------------
  recStatus = function(self, rec, val)
    if val then
      self:listDirty(true)
      db("summon.waitlist.record","setting record status value:", val)
      rec[3] = val
    end
    return rec[3]
  end,

  ---------------------------------
  recPrio = function(self, rec, val)
    if val then
      self:listDirty(true)
      db("summon.waitlist.record","setting record priority reason value:", val)
      rec[4] = val
    end
    return rec[4]
  end,

  ---------------------------------
  recNew = function(self, rec, val)
    if val ~= nil then
      self:listDirty(true)
      db("summon.waitlist.record","setting record new value:", val)
      rec[5] = val
    end
    return rec[5]
  end,

  ---------------------------------
  recRemove = function(self, player)
    local ret = false
    local idx = self:findWaitingPlayerIdx(player)
    if idx then
      ret = self:recRemoveIdx(idx)
    end
    return ret
  end,

  ---------------------------------
  recRemoveIdx = function(self, idx)
    local ret = false
    if idx and type(idx) == "string" then
      idx = tonumber(string)
    end
    if idx and idx <= self.numwaiting then
      self:listDirty(true)
      db("summon.waitlist.record", "removing", self:recPlayer(self.waiting[idx]), "from the waiting list")
      table.remove(self.waiting, idx)
      self.numwaiting = self.numwaiting - 1
      ret = true
    else
      db("summon.waitlist.record","invalid index for remove", idx, "max:", self.numwaiting)
    end
    return ret
  end,

  recAdd = function(self, rec, pos)
    self:listDirty(true)
    if not pos or pos > self.numwaiting then
      db("summon.waitlist.record","appending record to waiting list for", self:recPlayer(rec))
      table.insert(self.waiting, rec)
    else
      db("summon.waitlist.record","adding record to waiting list index", pos,"for", self:recPlayer(rec))
      table.insert(self.waiting, pos, rec)
    end
    self.numwaiting = self.numwaiting + 1
  end,

  ---------------------------------
  addWaiting = function(self, player, fromPlayer)
    player = strsplit("-", player)
    if not IsInGroup(player) then
      return nil
    end

    if (fromPlayer) then
      local isWaiting = self:findWaitingPlayer(player)
      if isWaiting then
        db("summon.waitlist", "Resetting status of player", player, "to requested")
        self:recStatus(isWaiting, "requested")-- allow those in summon queue to reset status when things go wrong
        return
      end
    else
      if self:findWaitingPlayer(player) then
        return nil
      end
    end
    db("summon.waitlist", "Making some space for ", player)

    -- priorities
    local inserted = false

    -- Prio warlock
    if SteaSummonSave.warlocks and addonData.util:playerCanSummon(player) then
      for k, wait in pairs(self.waiting) do
        if self:recPrio(wait) ~= "Warlock" then
          db("summon.waitlist", "Warlock", player, "gets prio")
          self:recAdd(self:waitRecord(player, 0, "requested", "Warlock"), k)
          inserted = true
          break
        end
      end
      if not inserted then
        db("summon.waitlist", "Warlock", player, "gets prio")
        self:recAdd(self:waitRecord(player, 0, "requested", "Warlock"))
        inserted = true
      end
    end

    -- Prio buffs
    local buffs = addonData.buffs:report(player) -- that's all for now, just observing
    if not inserted and SteaSummonSave.buffs == true and #buffs > 0 then
      for k, wait in pairs(self.waiting) do
        if not (self:recPrio(wait) == "Warlock" or self:recPrio(wait) == "Buffed") then
          self:recAdd(self:waitRecord(player, 0, "requested", "Buffed"), k)
          db("summon.waitlist", "Buffed " .. player .. " gets prio")
          inserted = true
          break
        end
      end
      if not inserted then
        self:recAdd(self:waitRecord(player, 0, "requested", "Buffed"))
        db("summon.waitlist", "Buffed " .. player .. " gets prio")
        inserted = true
      end
    end

    -- Prio list
    if not inserted and addonData.settings:findPrioPlayer(player) ~= nil then
      for k, wait in pairs(self.waiting) do
        if not (self:recPrio(wait) == "Warlock" or self:recPrio(wait) == "Buffed"
            or addonData.settings:findPrioPlayer(self:recPlayer(wait))) then
          self:recAdd(self:waitRecord(player, 0, "requested", "Prioritized"), k)
          db("summon.waitlist", "Priority " .. player .. " gets prio")
          inserted = true
          break
        end
      end
      if not inserted then
        self:recAdd(self:waitRecord(player, 0, "requested", "Prioritized"))
        db("summon.waitlist", "Priority " .. player .. " gets prio")
        inserted = true
      end
    end

    -- Prio last
    if not inserted and addonData.settings:findShitlistPlayer(player) ~= nil then
      self:recAdd(self:waitRecord(player, 0, "requested", "Last"))
      inserted = true
    end

    -- Prio normal
    if not inserted then
      local i = self.numwaiting + 1
      while i > 1 and self:recPrio(self.waiting[i-1]) == "Last"
          and not (self:recPrio(self.waiting[i-1]) == "Buffed"
          or self:recPrio(self.waiting[i-1]) == "Warlock"
          or self:recPrio(self.waiting[i-1]) == "Prioritized") do
        db("summon.waitlist", self:recPlayer(self.waiting[i-1]), "on shitlist, finding a better spot")
        i = i - 1
      end
      self:recAdd(self:waitRecord(player, 0, "requested", "Normal"), i)
    end

    db("summon.waitlist", player .. " added to waiting list")
    self:showSummons()
  end,

  timerSecondTick = function(self)
    --- update timers
    -- yea this is dumb, but time doesnt really work in wow
    -- so we count (rough) second ticks for how long someone has been waiting
    -- and need to update each individually (a global would wrap)
    for _, wait in pairs(self.waiting) do
      self:recTimeIncr(wait)
    end
  end,

  ---------------------------------
  tick = function(self)
    --- detect arriving players
    local players = {}
    for _, wait in pairs(self.waiting) do
      local player = self:recPlayer(wait)
      if addonData.util:playerClose(player) then
        db("summon.tick", player .. " detected close by")
        table.insert(players, player) -- don't mess with tables while iterating on them
      end
    end

    for _, player in pairs(players) do
      local z, l = self:getCurrentLocation()
      if z == self.zone and l == self.location -- at destination, anyone can report
          or (self.zone == "" and self.location == "") -- no destination, anyone can report
          or player == self.summoningPlayer then -- summoner can report
        addonData.gossip:arrived(player) -- let everyone else know
      end
    end

    --- maintain gossip list
    addonData.gossip:offlineCheck() -- TODO: probably unnecessary

    --- update display
    self:showSummons()

    --- update our location
    self:setCurrentLocation()
  end,

  ---------------------------------
  getWaiting = function(self) return self.waiting end,

  ---------------------------------
  showSummons = function(self)
    if InCombatLockdown() then
      return
    end

    if not SteaSummonFrame then
      local f = CreateFrame("Frame", "SteaSummonFrame", UIParent, "AnimatedShineTemplate")
      f:SetPoint("CENTER")
      f:SetSize(300, 250)
      f:SetScale(SteaSummonSave.windowSize)

      local wpos = addonData.settings:getWindowPos()
      if wpos and #wpos > 0 then
        db("summon.display",  wpos[1], wpos[2], wpos[3], wpos[4], wpos[5], "width:", wpos["width"], "height:", wpos["height"])
        f:ClearAllPoints()
        f:SetPoint(wpos[1], wpos[2], wpos[3], wpos[4], wpos[5])
        --f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", wpos["left"], wpos["top"])
        f:SetSize(wpos["width"], wpos["height"])
      end

      f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\PVPFrame\\UI-Character-PVP-Highlight",
        edgeSize = 16,
        insets = { left = 8, right = 6, top = 8, bottom = 8 },
      })
      f:SetBackdropColor(.57, .47, .85, 0.5) -- (147, 112, 219) purple
      f:SetBackdropBorderColor(.57, .47, .85, 0.5)

      --- Movable
      f:SetMovable(true)
      f:SetClampedToScreen(true)
      f:SetScript("OnMouseDown", function(this, button)
        if button == "LeftButton" then
          this:StartMoving()
        end
      end)

      local movefunc = function()
        SteaSummonFrame:StopMovingOrSizing()
        SteaSummonFrame:SetUserPlaced(false)

        local p1, p2, p3, p4, p5 = SteaSummonFrame:GetPoint()
        local pos = {p1, p2, p3, p4, p5}
        pos["width"] = SteaSummonFrame:GetWidth()
        pos["height"] = SteaSummonFrame:GetHeight()

        addonData.settings:setWindowPos(pos)

        db("summon.display", pos[1], pos[2], pos[3], pos[4], pos[5], "width:", pos["width"], "height:", pos["height"])
        if pos["height"] < 65 then
          SteaSummonButtonFrame:Hide()
          SteaSummonScrollFrame:Hide()
        else
          SteaSummonScrollFrame:Show()
          SteaSummonButtonFrame:Show()
        end

        if pos["height"] < 42 then
          if SteaSummonShardIcon then SteaSummonShardIcon:Hide() end
        else
          if SteaSummonShardIcon then SteaSummonShardIcon:Show() end
        end

        if pos["height"] < 26 then
          if SteaSummonToButton then SteaSummonToButton:Hide() end
        else
          if SteaSummonToButton then SteaSummonToButton:Show() end
        end

        if pos["width"] < 140 then
          SteaSummonFrame.location:Hide()
          SteaSummonFrame.destination:Hide()
        else
          SteaSummonFrame.location:Show()
          SteaSummonFrame.destination:Show()
        end
      end

      f:SetScript("OnMouseUp", movefunc)

      --- SteaSummonScrollFrame
      local sf = CreateFrame("ScrollFrame", "SteaSummonScrollFrame", SteaSummonFrame, "UIPanelScrollFrameTemplate")
      sf:SetPoint("LEFT", 8, 0)
      sf:SetPoint("RIGHT", -40, 0)
      sf:SetPoint("TOP", 0, -84)
      sf:SetPoint("BOTTOM", 0, 30)
      sf:SetScale(0.5)

      addonData.buttonFrame = CreateFrame("Frame", "SteaSummonButtonFrame", SteaSummonFrame)
      local x, y = sf:GetSize()
      addonData.buttonFrame:SetSize(x-10, y)
      addonData.buttonFrame:SetScale(SteaSummonSave.listSize)
      sf:SetScrollChild(addonData.buttonFrame)

      --- Table of summon info
      addonData.buttons = {}
      for i=1, 38 do
        self:createButton(i)
      end

      --- Setup Next button
      addonData.buttons[38].Button:SetPoint("TOPLEFT","SteaSummonFrame","TOPLEFT", -10, 10)
      addonData.buttons[38].Button:SetText(L["Next"])


      --- Resizable
      f:SetResizable(true)
      f:SetMinResize(80, 25)
      f:SetClampedToScreen(true)

      local rb = CreateFrame("Button", "SteaSummonResizeButton", SteaSummonFrame)
      rb:SetPoint("BOTTOMRIGHT", -6, 7)
      rb:SetSize(8, 8)

      rb:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
      rb:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
      rb:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")

      rb:SetScript("OnMouseDown", function(this, button)
        if button == "LeftButton" then
          f:StartSizing("BOTTOMRIGHT")
          this:GetHighlightTexture():Hide() -- more noticeable
        end
      end)
      rb:SetScript("OnMouseUp", movefunc)

      if addonData.util:playerCanSummon() then
        local summonTo = function(_, button)
          if button == nil or button == "LeftButton" then
            if not self.infoSend then
              SteaSummonToButton:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-MOTD-Up")
              addonData.gossip:destination(self.myZone, self.myLocation)
            else
              SteaSummonToButton:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-MOTD-Disabled")
              addonData.gossip:destination("", "")
            end
          end
          self.infoSend = not self.infoSend
        end

        --- summon to button
        local place = CreateFrame("Button", "SteaSummonToButton", SteaSummonFrame, "SecureActionButtonTemplate")
        place:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-MOTD-Disabled")
        place:SetHighlightTexture("Interface\\Buttons\\UI-GuildButton-MOTD-Disabled")
        place:SetPushedTexture("Interface\\Buttons\\UI-GuildButton-MOTD-Disabled")
        place:SetPoint("TOPLEFT","SteaSummonFrame", "TOPLEFT", 42, -8)
        place:SetSize(16,16)
        place:RegisterForClicks("LeftButtonUp")
        place:SetAttribute("type", "macro")
        place:SetAttribute("macrotext", "")
        place:SetScript("OnMouseUp", summonTo)
        place:Hide()
      end

      if self.isWarlock then
        --- shard count icon
        f.shards = CreateFrame("Frame", "SteaSummonShardIcon", SteaSummonFrame)
        f.shards:SetBackdrop({
          bgFile = "Interface\\ICONS\\INV_Misc_Gem_Amethyst_02",
        })
        f.shards:SetPoint("TOPLEFT","SteaSummonFrame", "TOPLEFT", 45, -24)
        --shards:SetAlpha(0.5)
        f.shards:SetSize(12,12)

        f.shards.count = f.shards:CreateFontString(nil,"ARTWORK", nil, 7)
        f.shards.count:SetFont("Fonts\\ARIALN.ttf", 12, "BOLD")
        f.shards.count:SetPoint("CENTER","SteaSummonShardIcon", "CENTER", 5, -5)
        f.shards.count:SetText("0")
        f.shards.count:SetTextColor(1,1,1,1)
        f.shards.count:Show()
        self.shards = self:shardCount()
      end

      --- Text items

      f.location = f:CreateFontString(nil,"ARTWORK")
      f.location:SetFont("Fonts\\ARIALN.ttf", 8, "OUTLINE")
      f.location:SetPoint("TOPLEFT","SteaSummonFrame", "TOPLEFT", 70, -8)
      f.location:SetPoint("RIGHT", -20, 0)
      f.location:SetJustifyH("RIGHT")
      f.location:SetJustifyV("TOP")
      f.location:SetAlpha(.5)
      f.location:SetText("")

      f.destination = f:CreateFontString(nil,"ARTWORK")
      f.destination:SetFont("Fonts\\ARIALN.ttf", 8, "OUTLINE")
      f.destination:SetPoint("TOP", f.location, "BOTTOM", 0, 0)
      f.destination:SetPoint("LEFT", f.location)
      f.destination:SetPoint("RIGHT", -20, 0)
      f.destination:SetJustifyH("RIGHT")
      f.destination:SetJustifyV("TOP")
      f.destination:SetAlpha(.5)
      f.destination:SetText("")

      f.status = f:CreateFontString(nil,"ARTWORK")
      f.status:SetFont("Fonts\\ARIALN.ttf", 8, "OUTLINE")
      f.status:SetPoint("TOPLEFT","SteaSummonFrame", "TOPLEFT", 42, 10)
      f.status:SetAlpha(.5)
      f.status:SetText("")

      movefunc()

      db("summon.display","Screen Size (w/h):", GetScreenWidth(), GetScreenHeight() )
    end

    ------------------------------------------------------------
    --- Start of on tick visual updates
    ------------------------------------------------------------
    --- update buttons
    local next = false
    for i=1, 37 do
      local player
      local summonClick
      local cancelClick
      local r,g,b,_ = 0.5, 0.5, 0.5

      if self.waiting[i] ~= nil then
        player = self:recPlayer(self.waiting[i])
        self:enableButton(i, true, player)
        addonData.buttons[i].Button:SetText(player)

        addonData.buttons[i].Priority["FS"]:SetText(self.buffLetter[self:recPrio(self.waiting[i])])

        if self:offline(player) or self:dead(player) then
          addonData.buttons[i].Button:SetEnabled(false)
          addonData.buttons[i].Status["FS"]:SetTextColor(0.5,0.5,0.5, 1)
          addonData.buttons[i].Button:SetAttribute("macrotext", "")
          addonData.buttons[i].Button:SetScript("OnMouseUp", nil)
        elseif self:listDirty() then
          local _, class = UnitClass(player)
          r,g,b,_ = GetClassColor(class)
          addonData.buttons[i].Button:SetEnabled(true)
          addonData.buttons[i].Status["FS"]:SetTextColor(r,g,b, 1)
          if (addonData.util:playerCanSummon()) then
            local spell = GetSpellInfo(698) -- Ritual of Summoning
            if not self.isCasting then
              addonData.buttons[i].Button:SetAttribute("macrotext", "/target " .. player .. "\n/cast " .. spell)
            else
              addonData.buttons[i].Button:SetAttribute("macrotext", "")
            end
          end
          local z,l = self:getCurrentLocation()

          if (addonData.util:playerCanSummon()) then
            summonClick = function(_, button)
              if button == nil or button == "LeftButton" then
                if not self.isCasting then
                  if UnitPower("player") >= 300 then
                    self.isCasting = true
                    db("summon.display","summoning ", player)
                    addonData.gossip:status(player, "pending")
                    addonData.chat:raid(SteaSummonSave.raidchat, player)
                    addonData.chat:say(SteaSummonSave.saychat, player)
                    addonData.chat:whisper(SteaSummonSave.whisperchat, player)
                    self.summoningPlayer = player
                    addonData.gossip:destination(z, l)
                    self.hasSummoned = true
                  else
                    addonData.chat:whisper(L["Imagine not having enough mana."], self.me)
                  end
                end
              end
            end
            addonData.buttons[i].Button:SetScript("OnMouseUp", summonClick)
          end
        end
      else
        self:enableButton(i, false)
      end

      if self:listDirty() then
        -- skip the rest of the visual updates

        --- flare size
        addonData.buttons[i].flare:SetBackdrop( {
          bgFile = "Interface\\TradeFrame\\UI-TradeFrame-Highlight",
          tile = true, tileSize = SteaSummonButtonFrame:GetWidth(),
          edgeSize = 15, insets = { left = 1, right = 1, top = 1, bottom = 1 }
        });

        --- Cancel Button
        -- Can cancel from own UI
        -- Cancelling self sends msg to others
        -- If summoning warlock, can cancel and send msg to others
        cancelClick = function(_, button, worked)
          if button == "LeftButton" and worked then
            addonData.gossip:arrived(player)
            db("summon.display","cancelling", player)
          end
        end

        addonData.buttons[i].Cancel:SetScript("OnMouseUp", cancelClick)

        if self.waiting[i]  then
          --- Next Button
          if not next and self:recStatus(self.waiting[i]) == "requested" and addonData.util:playerCanSummon() then
            next = true
            if not self.isCasting then
              local spell = GetSpellInfo(698) -- Ritual of Summoning
              addonData.buttons[38].Button:SetAttribute("macrotext", "/target " .. player .. "\n/cast " .. spell)
            else
              addonData.buttons[38].Button:SetAttribute("macrotext", "")
            end
            addonData.buttons[38].Button:SetScript("OnMouseUp", summonClick)
            addonData.buttons[38].Button:Show()
          end

          --- Time
          local noSecs = false
          if tonumber(self:recTime(self.waiting[i])) > 59 then
            noSecs = true
          end
          addonData.buttons[i].Time["FS"]:SetText(string.format(SecondsToTime(self:recTime(self.waiting[i]), noSecs)))
          local strwd = addonData.buttons[i].Time["FS"]:GetStringWidth()
          if strwd < 70 then
            addonData.buttons[i].Time["FS"]:SetWidth(80)
          else
            addonData.buttons[i].Time:SetWidth(strwd+20)
            addonData.buttons[i].Time["FS"]:SetWidth(strwd+10)
          end

          --- Status
          addonData.buttons[i].Status["FS"]:SetText(L[self:recStatus(self.waiting[i])])

          --- New flare
          if self:recNew(self.waiting[i]) then
            addonData.buttons[i].flare.ag:Play()
            self:recNew(self.waiting[i],false)
          end
        end

        if not next then
          -- all summons left are pending, disable the next button
          addonData.buttons[38].Button:Hide()
        end
      end -- skip visual updates

      --- summonTo
      if SteaSummonToButton then
        if IsInGroup(LE_PARTY_CATEGORY_HOME) then
          SteaSummonToButton:Show()
        else
          SteaSummonToButton:Hide()
        end
      end
    end

    --- show summon window
    local show = false
    if addonData.settings:showWindow() or (addonData.settings:showActive() and self.numwaiting > 0) then
      show = true
    elseif addonData.settings:showJustMe() then
      if self:findWaitingPlayer(self.me) then
        show = true
      end
    end

    if self.numwaiting == 0 then
      self.hasSummoned = false
    end

    if show then
      SteaSummonFrame:Show()
      if self.numwaiting > 0 then
        addonData.monitor:start() -- start ui update tick
      end
    else
      SteaSummonFrame:Hide()
      addonData.monitor:stop() -- stop ui update tick
    end

    self:listDirty(false)
  end,

  ---------------------------------
  createButton = function(_, i)
    -- Summon Button
    local bw = 80
    local bh = 25
    local wpad = 30
    local hpad = 5

    local parent = addonData.buttonFrame
    if i == 38 then
      parent = SteaSummonFrame
    end

    local tex, texDisabled,texHighlight, texPushed, icon

    addonData.buttons[i] = {}
    addonData.buttons[i].Button = CreateFrame("Button", "SteaSummonButton"..i, parent, "SecureActionButtonTemplate");
    addonData.buttons[i].Button:SetPoint("TOPLEFT","SteaSummonButtonFrame","TOPLEFT", wpad,-(((i-1)*bh)+hpad))
    addonData.buttons[i].Button:SetText("Stea")
    addonData.buttons[i].Button:SetNormalFontObject("GameFontNormalSmall")
    tex = addonData.buttons[i].Button:CreateTexture()
    texHighlight = addonData.buttons[i].Button:CreateTexture()
    texPushed = addonData.buttons[i].Button:CreateTexture()
    texDisabled = addonData.buttons[i].Button:CreateTexture()
    if i < 38 then
      addonData.buttons[i].Button:SetWidth(bw)
      addonData.buttons[i].Button:SetHeight(bh)
      tex:SetTexture("Interface/Buttons/UI-Panel-Button-Up")
      tex:SetTexCoord(0, 0.625, 0, 0.6875)
      texHighlight:SetTexture("Interface/Buttons/UI-Panel-Button-Highlight")
      texHighlight:SetTexCoord(0, 0.625, 0, 0.6875)
      texPushed:SetTexture("Interface/Buttons/UI-Panel-Button-Down")
      texPushed:SetTexCoord(0, 0.625, 0, 0.6875)
      texDisabled:SetTexture("Interface/Buttons/UI-Panel-Button-Disabled")
      texDisabled:SetTexCoord(0, 0.625, 0, 0.6875)
    else
      addonData.buttons[i].Button:ClearAllPoints()
      addonData.buttons[i].Button:SetWidth(bw - 30)
      addonData.buttons[i].Button:SetHeight(bw - 30)
      tex:SetTexture("Interface/Buttons/UI-QuickSlot2")
      tex:SetTexCoord(0.2, 0.8, 0.2, 0.8)
      texPushed:SetTexture("Interface/Buttons/UI-QuickSlot")
      texPushed:SetTexCoord(0, 1, 0, 1)
      texDisabled:SetTexture("Interface/Buttons/UI-QuickSlotRed")
      texDisabled:SetTexCoord(0, 1, 0, 1)
      -- icon
      icon = addonData.buttons[i].Button:CreateTexture()
      icon:SetTexture("Interface/ICONS/Spell_Shadow_Twilight")
      icon:SetTexCoord(0, 1, 0, 1)
      icon:SetAllPoints()

      texHighlight:SetTexture("Interface/Buttons/UI-QuickSlot-Depress")
      texHighlight:SetTexCoord(0, 1, 0, 1)
    end

    tex:SetAllPoints()
    addonData.buttons[i].Button:SetNormalTexture(tex)

    texHighlight:SetAllPoints()
    addonData.buttons[i].Button:SetHighlightTexture(texHighlight)

    texPushed:SetAllPoints()
    addonData.buttons[i].Button:SetPushedTexture(texPushed)

    texDisabled:SetAllPoints()
    addonData.buttons[i].Button:SetDisabledTexture(texDisabled)

    addonData.buttons[i].Button:RegisterForClicks("LeftButtonUp")
    addonData.buttons[i].Button:SetAttribute("type", "macro");
    addonData.buttons[i].Button:SetAttribute("macrotext", "")

    if i < 38 then -- last button we use for next summon, so don't want these
      --- flare
      addonData.buttons[i].flare = CreateFrame("Frame", "SteaSummonFlare"..i, parent)
      addonData.buttons[i].flare:SetHeight(bh + hpad)
      addonData.buttons[i].flare:SetPoint("TOPLEFT","SteaSummonButtonFrame","TOPLEFT", 2,-((i-1)*(bh)+(hpad/2)))
      --addonData.buttons[i].flare:SetPoint("TOPRIGHT","SteaSummonButtonFrame","TOPRIGHT", 0,-(((i-1)*bh)+(hpad/2)))
      addonData.buttons[i].flare:SetWidth(320)
      addonData.buttons[i].flare.tex = addonData.buttons[i].flare:CreateTexture(nil, "BACKGROUND")
      addonData.buttons[i].flare.tex:SetAllPoints()
      addonData.buttons[i].flare.tex:SetColorTexture(1, 1, 1, 1)
      addonData.buttons[i].flare.tex:SetBlendMode("MOD")
      addonData.buttons[i].flare:SetAlpha(0)
      addonData.buttons[i].flare.ag = addonData.buttons[i].flare:CreateAnimationGroup()
      addonData.buttons[i].flare.ag.anim = addonData.buttons[i].flare.ag:CreateAnimation("Alpha")
      addonData.buttons[i].flare.ag.anim:SetFromAlpha(0.5)
      addonData.buttons[i].flare.ag.anim:SetToAlpha(1)
      addonData.buttons[i].flare.ag.anim:SetDuration(0.1)
      addonData.buttons[i].flare.ag.anim:SetSmoothing("IN")
      addonData.buttons[i].flare.ag.anim:SetOrder(1)
      addonData.buttons[i].flare.ag.anim2 = addonData.buttons[i].flare.ag:CreateAnimation("Alpha")
      addonData.buttons[i].flare.ag.anim2:SetFromAlpha(0.9)
      addonData.buttons[i].flare.ag.anim2:SetToAlpha(0)
      addonData.buttons[i].flare.ag.anim2:SetDuration(1)
      addonData.buttons[i].flare.ag.anim2:SetSmoothing("OUT")
      addonData.buttons[i].flare.ag.anim2:SetOrder(2)
      --addonData.buttons[i].flare.ag:SetScript("OnFinished", function() addonData.buttons[i].flare.ag:Stop() end)
      addonData.buttons[i].flare:Show()

      --- Cancel
      addonData.buttons[i].Cancel = CreateFrame("Button", "SteaSummonCancelButton"..i,
          parent, "UIPanelCloseButtonNoScripts")
      addonData.buttons[i].Cancel:SetWidth(bh)
      addonData.buttons[i].Cancel:SetHeight(bh)
      addonData.buttons[i].Cancel:SetText("X")
      addonData.buttons[i].Cancel:SetPoint("TOPLEFT","SteaSummonButtonFrame","TOPLEFT", 10,-(((i-1)*bh)+hpad))

      --- Wait Time
      addonData.buttons[i].Time = CreateFrame("Frame", "SteaSummonWaitTime"..i, addonData.buttonFrame)
      addonData.buttons[i].Time:SetWidth(bw)
      addonData.buttons[i].Time:SetHeight(bh)
      addonData.buttons[i].Time:SetPoint("TOPLEFT", addonData.buttonFrame, "TOPLEFT",bw + wpad + 108,-(((i-1)*bh)+hpad))
      addonData.buttons[i].Time:SetBackdrop( {
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 5, edgeSize = 15, insets = { left = 1, right = 1, top = 1, bottom = 1 }
      });

      addonData.buttons[i].Time["FS"] = addonData.buttons[i].Time:CreateFontString(
          "SteaSummonTimeText"..i,"ARTWORK", "ChatFontNormal")
      addonData.buttons[i].Time["FS"]:SetParent(addonData.buttons[i].Time)
      addonData.buttons[i].Time["FS"]:SetPoint("TOP",addonData.buttons[i].Time,"TOP",0,0)
      addonData.buttons[i].Time["FS"]:SetWidth(bw)
      addonData.buttons[i].Time["FS"]:SetHeight(bh)
      addonData.buttons[i].Time["FS"]:SetJustifyH("CENTER")
      addonData.buttons[i].Time["FS"]:SetJustifyV("CENTER")
      addonData.buttons[i].Time["FS"]:SetFontObject("GameFontNormalSmall")
      addonData.buttons[i].Time["FS"]:SetText(string.format(SecondsToTime(0)))

      --- Priority
      addonData.buttons[i].Priority = CreateFrame("Frame", "SteaSummonPriority"..i, addonData.buttonFrame)
      addonData.buttons[i].Priority:SetWidth(bh)
      addonData.buttons[i].Priority:SetHeight(bh)
      addonData.buttons[i].Priority:SetPoint("TOPLEFT", addonData.buttonFrame, "TOPLEFT",bw + wpad + 1,-(((i-1)*bh)+hpad))
      addonData.buttons[i].Priority:SetBackdrop( {
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 5, edgeSize = 15, insets = { left = 1, right = 1, top = 1, bottom = 1 }
      });
      addonData.buttons[i].Priority:SetScript("OnEnter", function(this)
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L["Reason for list placement"])
        GameTooltip:AddLine(L["[W]arlock, [B]uffs, [P]riority, [N]ormal, [L]ast"])
        GameTooltip:Show()
      end)
      addonData.buttons[i].Priority:SetScript("OnLeave", function()
        GameTooltip:Hide()
      end)
      addonData.buttons[i].Priority:EnableMouse(true)

      addonData.buttons[i].Priority["FS"] = addonData.buttons[i].Priority:CreateFontString(
          "SteaSummonStatusText"..i,"ARTWORK", "ChatFontNormal")
      addonData.buttons[i].Priority["FS"]:SetParent(addonData.buttons[i].Priority)
      addonData.buttons[i].Priority["FS"]:SetPoint("TOP",addonData.buttons[i].Priority,"TOP",0,0)
      addonData.buttons[i].Priority["FS"]:SetWidth(bh)
      addonData.buttons[i].Priority["FS"]:SetHeight(bh)
      addonData.buttons[i].Priority["FS"]:SetJustifyH("CENTER")
      addonData.buttons[i].Priority["FS"]:SetJustifyV("CENTER")
      addonData.buttons[i].Priority["FS"]:SetFontObject("GameFontNormalSmall")
      addonData.buttons[i].Priority["FS"]:SetTextColor(1,1,1)
      addonData.buttons[i].Priority["FS"]:SetText("N")

      --- Status
      addonData.buttons[i].Status = CreateFrame("Frame", "SteaSummonStatus"..i, addonData.buttonFrame)
      addonData.buttons[i].Status:SetWidth(bw)
      addonData.buttons[i].Status:SetHeight(bh)
      addonData.buttons[i].Status:SetPoint("TOPLEFT", addonData.buttonFrame, "TOPLEFT",bw + wpad + 27,-(((i-1)*bh)+hpad))
      addonData.buttons[i].Status:SetBackdrop( {
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 5, edgeSize = 15, insets = { left = 1, right = 1, top = 1, bottom = 1 }
      });
      addonData.buttons[i].Status["FS"] = addonData.buttons[i].Status:CreateFontString(
          "SteaSummonStatusText"..i,"ARTWORK", "ChatFontNormal")
      addonData.buttons[i].Status["FS"]:SetParent(addonData.buttons[i].Status)
      addonData.buttons[i].Status["FS"]:SetPoint("TOP",addonData.buttons[i].Status,"TOP",0,0)
      addonData.buttons[i].Status["FS"]:SetWidth(bw)
      addonData.buttons[i].Status["FS"]:SetHeight(bh)
      addonData.buttons[i].Status["FS"]:SetJustifyH("CENTER")
      addonData.buttons[i].Status["FS"]:SetJustifyV("CENTER")
      addonData.buttons[i].Status["FS"]:SetFontObject("GameFontNormalSmall")
      addonData.buttons[i].Status["FS"]:SetTextColor(1,1,1)
      addonData.buttons[i].Status["FS"]:SetText("Waiting")
    end
  end,

  ---------------------------------
  shardCount = function(_)
    local count = 0
    if SteaSummonShardIcon then
      local _, itemLink = GetItemInfo(6265) -- "Soul Shard"
      for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, GetContainerNumSlots(bag) do
          if(GetContainerItemLink(bag, slot) == itemLink) then
            count = count + 1
          end
        end
      end
      SteaSummonShardIcon.count:SetText(tostring(count))
    end
    return count
  end,

  ---------------------------------
  shardIncrementBy = function(self, incr)
    self.shards = self.shards + incr
    db("summon.display", "Shard count update", incr, self.shards)
    if SteaSummonShardIcon then
      SteaSummonShardIcon.count:SetText(tostring(self.shards))
    end
  end,

  ---------------------------------
  bagPushShardCheck = function(_, event, bag, iconFileID)
    db("summon.display", event, bag, iconFileID)
    if iconFileID == 134075 then -- "Soul Shard"
      g_self:shardIncrementBy(1)
    end
  end,

  ---------------------------------
  ClickNext = function()
    addonData.buttons[38].Button:Click("LeftButton")
  end,

  ClickSetDestination = function()
    if SteaSummonToButton then
      SteaSummonToButton:Click("LeftButton")
    end
  end,
  ---------------------------------
  enableButton = function(self, idx, enable, player)
    if enable == nil then
      enable = true
    end

    if enable then
      if not InCombatLockdown() then
        addonData.buttons[idx].Button:Show()
        if self.hasSummoned or player == self.me or (self:isAtDestination() and addonData.util:playerCanSummon()) then
          addonData.buttons[idx].Cancel:Show()
        else
          addonData.buttons[idx].Cancel:Hide()
        end
        addonData.buttons[idx].Time:Show()
        addonData.buttons[idx].Status:Show()
        addonData.buttons[idx].Priority:Show()
        addonData.buttons[idx].Button:Enable()
      end
    else
      if not InCombatLockdown() then
        addonData.buttons[idx].Button:Hide()
        addonData.buttons[idx].Cancel:Hide()
        addonData.buttons[idx].Time:Hide()
        addonData.buttons[idx].Status:Hide()
        addonData.buttons[idx].Priority:Hide()
        addonData.buttons[idx].Button:Enable()
      end
    end
  end,

  ---------------------------------
  enableButtons = function(self, enable)
    for i=1, 35 do
      self:enableButton(i, enable)
    end
  end,

  ---------------------------------
  findWaitingPlayerIdx = function(self, player)
    for i, wait in pairs(self.waiting) do
      if self:recPlayer(wait) == player then
        return i
      end
    end
    return nil
  end,

  ---------------------------------
  findWaitingPlayer = function(self, player)
    local idx = self:findWaitingPlayerIdx(player)
    if idx then
      return self.waiting[idx]
    end
    return nil
  end,

  ---------------------------------
  summoned = function(self, player)
    -- update status
    local waitEntry = self:findWaitingPlayer(player)
    if waitEntry ~= nil then
      db("summon.waitlist", "a summon is pending for " .. player)
      self:recStatus(waitEntry, "pending")
    end
  end,

  ---------------------------------
  status = function(self, player, status)
    -- update status
    local waitEntry = self:findWaitingPlayer(player)
    if waitEntry ~= nil then
      db("summon.waitlist", "status changed to", status, "for", player)
      self:recStatus(waitEntry, status)
    end
  end,

  ---------------------------------
  arrived = function(self, player)
    self:remove(player)
  end,

  ---------------------------------
  summonFail = function(self)
    db("summon.waitlist", "something went wrong, resetting status of " .. self.summoningPlayer .. " to requested")
    addonData.gossip:status(self.summoningPlayer, "requested")
    self.isCasting = false
  end,

  ---------------------------------
  summonSuccess = function(self)
    db("summon.waitlist", "summon succeeded, setting status of " .. self.summoningPlayer .. " to summoned")
    addonData.gossip:status(self.summoningPlayer, "summoned")
    self.isCasting = false
  end,

  offline = function(self, player)
    local offline = not UnitIsConnected(player)
    local idx = self:findWaitingPlayerIdx(player)
    if idx then
      local state = ""
      if offline and not self:recStatus(self.waiting[idx]) == "offline" then
        db("summon.waitlist", "setting status of " .. player .. " to offline")
        state = "offline"
      elseif not online and self:recStatus(self.waiting[idx]) == "offline" then
        db("summon.waitlist", "setting status of " .. player .. " from offline to requested")
        state = "requested"
      end
      if state ~= "" then
        self:recStatus(self.waiting[idx], state)
      end
    end
    return offline
  end,

  remove = function(self, player)
    local out
    if type(player) == "number" then
      out = self:recRemoveIdx(player)
    else
      out = self:recRemove(player)
    end
    return out
  end,

  dead = function(self, player)
    local dead = UnitIsDeadOrGhost(player)
    local idx = self:findWaitingPlayerIdx(player)
    if idx then
      local state = ""
      if dead and not self.waiting[idx][3] == "dead" then
        state = "dead"
        db("summon.waitlist", "setting status of", player, "to dead")
      elseif not dead and self.waiting[idx][3] == "dead" then
        db("summon.waitlist", "setting status of", player, "from dead to requested")
        state = "requested"
      end
      if state ~= "" then
        self:recStatus(self.waiting[idx], state)
      end
    end
    return dead
  end,

  ---------------------------------
  callback = function(_, event, ...)
    if event == "PLAYER_REGEN_DISABLED" then
      -- entered combat, stop everything or bad things happen
      if SteaSummonFrame then
        SteaSummonFrame:Hide()
      end
    end
    if event == "PLAYER_REGEN_ENABLED" then
      -- start things up again, nothing to do
    end
  end,

  ---------------------------------
  getCurrentLocation = function(self)
    return self.myZone, self.myLocation
  end,

  ---------------------------------
  setCurrentLocation = function(self)
    local oldZone, oldLocation = self.myZone, self.myLocation
    self.myZone, self.myLocation = GetZoneText(), GetMinimapZoneText()

    if self:isAtDestination() then
      if SteaSummonFrame then
        SteaSummonFrame.destination:SetTextColor(0,1,0,.5)
        SteaSummonFrame.location:SetTextColor(0,1,0,.5)
      end
      if SteaSummonToButton then
        self.infoSend = true
        SteaSummonToButton:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-MOTD-Up")
      end

      if oldZone ~= self.myZone or oldLocation ~= self.myLocation then -- we changed location to destination
        addonData.gossip:atDestination(true)
      end
    else
      if SteaSummonFrame then
        SteaSummonFrame.destination:SetTextColor(1,1,1,.5)
        SteaSummonFrame.location:SetTextColor(0,1,0,.5)
      end
      if SteaSummonToButton then
        SteaSummonToButton:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-MOTD-Disabled")
      end

      if self.zone ~= "" and self.location ~= "" then -- destination is set
        if oldZone ~= self.myZone or oldLocation ~= self.myLocation then -- we changed location
          if oldZone == self.zone and oldLocation == self.location then -- from the destination
            addonData.gossip:atDestination(false)
          end
        end
      end
    end

    if SteaSummonFrame and oldZone ~= self.myZone or oldLocation ~= self.myLocation then
      local pat = {["%%zone"] = self.myZone, ["%%subzone"] = self.myLocation}
      local s = L["Location: %subzone, %zone"]
      s = tstring(s, pat)
      SteaSummonFrame.location:SetText(s)
    end
  end,

  ---------------------------------
  setDestination = function(self, zone, location)
    if location == nil or zone == nil then
      db("summon.misc", "bad inputs to setDestination", zone, location)
      return
    end
    if self.zone == zone and self.location == location then
      return
    end
    self.location = location
    self.zone = zone

    db("summon.misc", "setting destination: ", location, " in ", zone)
    if location and location ~= "" and zone and zone ~= "" then
      if SteaSummonFrame then
        local pat = {["%%zone"] = self.zone, ["%%subzone"] = self.location}
        local s = L["Destination: %subzone, %zone"]
        s = tstring(s, pat)
        SteaSummonFrame.destination:SetText(s)
      end
      if self:isAtDestination() then
        if SteaSummonToButton then
          self.infoSend = true
          SteaSummonToButton:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-MOTD-Up")
        end
        addonData.gossip:atDestination(true)
      end
    else
      if SteaSummonFrame then
        SteaSummonFrame.destination:SetText("")
      end
    end
  end,

  ---------------------------------
  isAtDestination= function(self)
    return self.zone == self.myZone and self.location == self.myLocation
  end,

  ---------------------------------
  usesSoulShard = {
    [27565] = 1, -- Banish
    [8994] = 1, -- banish (again)
    [12890] = 1, -- deep slumber, probably not in game
    [1098] = 1, -- enslave demon rank 1
    [11725] = 1, -- enslave demon rank 2
    [11726] = 1, -- enslave demon rank 3
    [17877] = 1, -- ["Shadowburn"] = 1, -- Rank 1
    [18867] = 1, -- shadowburn rank 2
    [18868] = 1, -- shadowburn rank 3
    [18869] = 1, -- shadowburn rank 4
    [18870] = 1, -- shadowburn rank 5
    [18871] = 1, -- shadowburn rank 6
    [20755] = 1, -- ["Create Soulstone"] = 1,
    [20752] = 1, -- ["Create Soulstone (Lesser)"] = 1,
    [693] = 1, -- ["Create Soulstone (Minor)"] = 1,
    [20756] = 1, -- ["Create Soulstone (Greater)"] = 1,
    [20757] = 1, -- ["Create Soulstone (Major)"] = 1,
    [2362] = 1, -- ["Create Spellstone"] = 1,
    [17727] = 1, -- ["Create Spellstone (Greater)"] = 1,
    [17728] = 1, -- ["Create Spellstone (Major)"] = 1,
    [691] = 1, -- ["Summon Felhunter"] = 1,
    [712] = 1, -- ["Summon Succubus"] = 1, 8722 used by npcs
    [8722] = 1, -- just in case
    [697] = 1, -- ["Summon Voidwalker"] = 1, 12746 used by npcs
    [12746] = 1, -- just in case
    [6353] = 1, -- ["Soul Fire"] = 1, rank 1
    [17924] = 1, -- soul fire rank 2
    [6366] = 1, -- ["Create Firestone (Lesser)"] = 1,
    [17952] = 1, -- ["Create Firestone (Greater)"] = 1,
    [17953] = 1, -- ["Create Firestone (Major)"] = 1,
    [17951] = 1, -- ["Create Firestone"] = 1,
    [5699] = 1, --["Create Healthstone"] = 1, level 34
    [6202] = 1, -- ["Create Healthstone (Lesser)"] = 1,
    [6201] = 1, -- ["Create Healthstone (Minor)"] = 1,
    [11729] = 1, -- ["Create Healthstone (Greater)"] = 1,
    [208023] = 1, -- ["Create Healthstone"] = 1, level 10
    [11730] = 1, -- ["Create Healthstone (Major)"] = 1,
  },

  ---------------------------------
  lastCast = "",

  castWatch = function(_, event, target, castUID, spellId, ...)
    db("summon.spellcast", event, " ", target, castUID, spellId, ...)

    -- these events can get posted up to 3 times (at least testing on myself) player, raid1 (me), target
    -- observed:
    -- when target is you, get target message. otherwise no
    -- guesses:
    -- you get target if target is casting
    -- you get player if you are casting
    -- you get raid1 if there is a raid (not party) if someone in your raid is casting (even if it is you) *** if true this is very cool

    -- only interested in summons cast by player for now
    if target ~= "player" then
      return
    end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
      -- this is the place to find out if a non-channelled spell used a soul shard
      if g_self.isWarlock and g_self.usesSoulShard[spellId] then
        g_self:shardIncrementBy(-1)
      end
    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
      if g_self.isWarlock then
        local oldCount = g_self.shards
        g_self.shards = addonData.summon.shardCount(g_self)
        if spellId == 698 then -- "Ritual of Summoning"
          --- update shards (if shard count decreased then the summon went through!)
          if oldCount > g_self.shards then
            addonData.summon.summonSuccess(g_self)
          else
            addonData.summon.summonFail(g_self)
          end
        end
      end
    elseif event == "UNIT_SPELLCAST_INTERRUPTED"
        or event == "UNIT_SPELLCAST_FAILED" then
      -- we can get this multiple times for "player" for the same cast, we only want to act once
      if spellId == 698 and g_self.lastCast ~= castUID then -- "Ritual of Summoning"
        g_self.lastCast = castUID
        addonData.summon.summonFail(g_self)
      end
    end
  end,
}

addonData.summon = summon
