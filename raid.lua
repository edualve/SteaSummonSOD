-- Raid tracking
local _, addonData = ...

local raid = {
  inzone = {},
  caninvite = {},
  roster = {},
  rosterOld = {},
  clickers = {},

  init = function(_)
    addonData.debug:registerCategory("raid.event")
  end,

  callback = function(self, event, ...)
    db("raid.event", event, ...)

    self = addonData.raid

    if (event == "GROUP_ROSTER_UPDATE" or event == "RAID_ROSTER_UPDATE") then
      self:updateRaid()
    end

    if (event == "PARTY_LEADER_CHANGED") then
      if IsInGroup(LE_PARTY_CATEGORY_HOME) then
        self:updateRaid()
      end
    end
  end,

  updateRaid = function(self)
    self.roster, self.rosterOld = self.rosterOld, self.roster
    wipe(self.roster)

    if not IsInGroup(LE_PARTY_CATEGORY_HOME) then
      addonData.summon:listClear()
      addonData.gossip:raidLeft()
      wipe(self.rosterOld)
      return
    end

    for i = 1, GetNumGroupMembers() do
      local name, rank = GetRaidRosterInfo(i)
      if name ~= nil then
        self.roster[name] = 1

        if self.rosterOld[name] == nil then
          db("raid", name, "joined the raid.")
          local myName, _ = UnitName("player")
          if myName == name then
            addonData.gossip:raidJoined()
          end
        end

        if rank > 0 then
          self.caninvite[name] = true
        else
          self.caninvite[name] = false
        end
      end
    end

    -- remove old members who left
    for k, _ in pairs(self.rosterOld) do
      if not self.roster[k] then
        db("raid", k, " left the raid.")
        addonData.summon:remove(k)

        local name, _ = UnitName("player")
        if k == name then
          addonData.gossip:raidLeft()
          addonData.summon:listClear()
          wipe(self.rosterOld)
          addonData.raid.groupInit = true
        else
          addonData.gossip:raiderLeft(k)
        end

        self.inzone[k] = nil
      end
    end
  end,

  fishedClickers = function(self)
    return self.clickers
  end,

  fishArea = function(self)
    if not IsInGroup(LE_PARTY_CATEGORY_HOME) then
      return
    end

    wipe(self.clickers)

    for k, _ in pairs(self.roster) do
      if UnitInRange(k) then
        table.insert(self.clickers, k)
      end
    end

    addonData.gossip:setClicks()
  end,
}

addonData.raid = raid