--[[
  Early Warning Radar Script - 2.0.0 - created 07/11/2016
  Last Update by Apple 30/11/2023

  New update:
  Fixed some issues with error due to dcs latest object.getCategory.
  Custom messages output.
  Last update by Leka 2025-05-03
  
  
  Requires MOOSE to run: https://github.com/FlightControl-Master
  
  Allows use of units with radars to provide Bearing Range and Altitude information via text display to player aircraft
  
  Features:
    - Uses in-game radar information to detect targets so terrain masking, beaming, low altitude flying, etc is effective for avoiding detection
    - Dynamic. If valid units with radar are created during a mission (eg. via chopper with CTLD), they will be added to the EWRS radar network
    - Can allow / disable BRA messages to fighters or sides
    - Uses player aircraft or mission bullseye for BRA reference, can be changed via F10 radio menu or restricted to one reference in the script settings
    - Can switch between imperial (feet, knots, NM) or metric (meters, km/h, km) measurements using F10 radio menu
    - Ability to change the message display time and automated update interval
    - Can choose to disable automated messages and allow players to request BRA from F10 menu
    - Can allow players to request Bogey Dope at any time through F10 radio menu

    
  At the moment, because of limitations within DCS to not show messages to individual units, the reference, measurements, and messages
  are done per group. So a group of 4 fighters will each receive 4 BRA messages. Each message however, will have the player's name
  in it, that its refering to. Its unfortunate, but nothing I can do about it.

  Changes:
  - 2.0 - Updated to use Moose. Removed airplane and radar type name dependencies.
  - 1.3 - Added Option to allow picture report to be requested thru F10 menu instead of an automated display
      - Fixed bug where a known unit type would sometimes still display as ???
  - 1.4 - Added setting to be able to limit the amount of threats displayed in a picture report
      - Added option to enable Bogey Dopes
        * Mission designer can turn on / off in script settings
        * Pilots can request thru the F10 menu and it will show the BRA to the nearest hostile aircraft that has
        been detected. It will always reference the requesting pilot's own aircraft.
      - Finally implemented a cleaner workaround for some ground units being detected and listed in picture report
  - 1.4.1 - Added some ships to search radar list, you will need to remove the comment markers (--) at the start of the line to activate
  - 1.5 - Added ability to request picture of friendly aircraft positions referencing your own aircraft - Mission designer chooses if this feature is active or not
  - 1.5.1 - Added Gazelle to acCategories
  - 1.5.2 - Added F5E to acCategories
  - 1.5.3 - Fixed bug with maxThreatDisplay set at 0 not displaying any threats
      - Added Mistral Gazelle
      - Added C-101CC
]]

ewrs = {} --DO NOT REMOVE
ewrs.HELO = 1
ewrs.ATTACK = 2
ewrs.FIGHTER = 3
ewrs.version = "2.0.0"

----SCRIPT OPTIONS----

ewrs.messageUpdateInterval = 60 --How often EWRS will update automated BRA messages (seconds)
ewrs.messageDisplayTime = 15 --How long EWRS BRA messages will show for (seconds)
ewrs.restrictToOneReference = false -- Disables the ability to change the BRA calls from pilot's own aircraft or bullseye. If this is true, set ewrs.defaultReference to the option you want to restrict to.
ewrs.defaultReference = "self" --The default reference for BRA calls - can be changed via f10 radio menu if ewrs.restrictToOneReference is false (self or bulls)
ewrs.defaultMeasurements = "imperial" --Default measurement units - can be changed via f10 radio menu (imperial or metric)
ewrs.disableFightersBRA = false -- disables BRA messages to fighters when true
ewrs.enableRedTeam = false -- enables / disables EWRS for the red team
ewrs.enableBlueTeam = true -- enables / disables EWRS for the blue team
ewrs.disableMessageWhenNoThreats = true -- disables message when no threats are detected - Thanks Rivvern - NOTE: If using ewrs.onDemand = true, this has no effect
ewrs.useImprovedDetectionLogic = true --this makes the messages more realistic. If the radar doesn't know the type or distance to the detected threat, it will be reflected in the picture report / BRA message
ewrs.onDemand = false --Setting to true will disable the automated messages to everyone and will add an F10 menu to get picture / BRA message.
ewrs.maxThreatDisplay = 5 -- Max amounts of threats to display on picture report (0 will display all)
ewrs.allowBogeyDope = true -- Allows pilots to request a bogey dope even with the automated messages running. It will display only the cloest threat, and will always reference the players own aircraft.
ewrs.allowFriendlyPicture = true -- Allows pilots to request picture of friendly aircraft
ewrs.maxFriendlyDisplay = 5 -- Limits the amount of friendly aircraft shown on friendly picture
ewrs.showType = true -- if true it will show the type of the unit

----END OF SCRIPT OPTIONS----


----INTERNAL FUNCTIONS ***** Be Careful changing things below here ***** ----


function ewrs.getDistance(obj1PosX, obj1PosZ, obj2PosX, obj2PosZ)
  local xDiff = obj1PosX - obj2PosX
  local yDiff = obj1PosZ - obj2PosZ
  return math.sqrt(xDiff * xDiff + yDiff * yDiff) -- meters
end

function ewrs.getBearing(obj1PosX, obj1PosZ, obj2PosX, obj2PosZ)
    local bearing = math.atan2(obj2PosZ - obj1PosZ, obj2PosX - obj1PosX)
    if bearing < 0 then
        bearing = bearing + 2 * math.pi
    end
    bearing = bearing * 180 / math.pi
    return bearing    -- degrees
end

function ewrs.getHeading(vec)
    local heading = math.atan2(vec.z,vec.x)
    if heading < 0 then
        heading = heading + 2 * math.pi
    end
    heading = heading * 180 / math.pi
    return heading -- degrees
end

function ewrs.getSpeed(velocity)
  local speed = math.sqrt(velocity.x^2 + velocity.y^2 + velocity.z^2) --m/s
  return speed -- m/s
end

function ewrs.update()
  timer.scheduleFunction(ewrs.update, nil, timer.getTime() + 5)
  ewrs.buildActivePlayers()
  ewrs.buildF10Menu()
end

function ewrs.getAspect(bearing,heading)
  local toRef=(bearing+180)%360
  local diff=math.abs(((heading-toRef+540)%360)-180)
  if diff<45 then return "hot" end
  if diff>135 then return "cold" end
  return "flanking"
end

function ewrs.buildThreatTable(activePlayer,bogeyDope)
  local function sortRanges(v1,v2)return v1.range<v2.range end
  local targets={}
  if activePlayer.side==2 then targets=ewrs.currentlyDetectedRedUnits else targets=ewrs.currentlyDetectedBlueUnits end
  local bogeyDope=bogeyDope or false
  local referenceX
  local referenceZ
  if ewrs.groupSettings[tostring(activePlayer.groupID)].reference=="self" or bogeyDope then
    local _self=Unit.getByName(activePlayer.unitname) if not _self then return {} end
    local selfpos=_self:getPosition()
    referenceX=selfpos.p.x
    referenceZ=selfpos.p.z
  else
    local bullseye=coalition.getMainRefPoint(activePlayer.side)
    referenceX=bullseye.x
    referenceZ=bullseye.z
  end
  local threatTable={}
  for k,v in pairs(targets) do
    local velocity=v["object"]:getVelocity()
    local bogeypos=v["object"]:getPosition()
    local bogeyType=nil
    local unit=UNIT:Find(v["object"]) if unit then bogeyType=unit:GetNatoReportingName() end
    local bearing=ewrs.getBearing(referenceX,referenceZ,bogeypos.p.x,bogeypos.p.z)
    local heading=ewrs.getHeading(velocity)
    local aspect=ewrs.getAspect(bearing,heading)
    local range=ewrs.getDistance(referenceX,referenceZ,bogeypos.p.x,bogeypos.p.z)
    local altitude=bogeypos.p.y
    local speed=ewrs.getSpeed(velocity)
    if ewrs.groupSettings[tostring(activePlayer.groupID)].measurements=="metric" then
      range=UTILS.Round(range/1000,-1)
      speed=UTILS.Round(UTILS.MpsToKmph(speed),-1)
      altitude=UTILS.Round(altitude,-1)
    else
      range=UTILS.Round(UTILS.MetersToNM(range),-1)
      speed=UTILS.Round(UTILS.MpsToKnots(speed),-1)
      altitude=UTILS.Round(UTILS.MetersToFeet(altitude),-3)
    end
    if ewrs.useImprovedDetectionLogic and not v["distance"] then range=ewrs.notAvailable end
    local j=#threatTable+1
    threatTable[j]={}
    threatTable[j].unitType=bogeyType
    threatTable[j].bearing=bearing
    threatTable[j].range=range
    threatTable[j].altitude=altitude
    threatTable[j].speed=speed
    threatTable[j].heading=heading
    threatTable[j].aspect=aspect
  end
  table.sort(threatTable,sortRanges)
  return threatTable
end


function ewrs.outText(activePlayer, threatTable, bogeyDope, greeting)
  local status, result = pcall(function()
    
    local message = {}
    local altUnits
    local speedUnits
    local rangeUnits
    local bogeyDope = bogeyDope or false
    if ewrs.groupSettings[tostring(activePlayer.groupID)].measurements == "metric" then
      altUnits = "m"
      speedUnits = "km/h"
      rangeUnits = "km"
    else
      altUnits = "ft"
      speedUnits = "kts"
      rangeUnits = "NM"
    end
    
    if #threatTable >= 1 then
      local maxThreats = nil
      local messageGreeting = nil
      if greeting == nil then
        if bogeyDope then
          maxThreats = 1
          messageGreeting = "EWRS Bogey Dope for: " .. activePlayer.player
        else
          if ewrs.maxThreatDisplay == 0 then
            maxThreats = 999
          else
            maxThreats = ewrs.maxThreatDisplay
          end
          messageGreeting = "EWRS Picture Report for: " .. activePlayer.player .. " | relative to " .. ewrs.groupSettings[tostring(activePlayer.groupID)].reference
        end
      else
        messageGreeting = greeting
        maxThreats = ewrs.maxFriendlyDisplay
      end
      
      --Display table
   table.insert(message,messageGreeting)
      table.insert(message,"\n")
      for k=1,maxThreats do
        if threatTable[k]==nil then break end
        local sd=""
        if threatTable[k].speed>500 then sd="\t\thighspeed" elseif threatTable[k].speed<200 then sd="\t\tslow" end
        if threatTable[k].range==ewrs.notAvailable then
          table.insert(message,string.format("%s Position: Unknown",threatTable[k].unitType))
        else
          table.insert(message,string.format("\n%s\t\tBRA\t\t%03d for %s,\t\t%s\t\t%s%s",
          (ewrs.showType and threatTable[k].unitType or "Unknown"),
          threatTable[k].bearing,
          threatTable[k].range..rangeUnits,
          threatTable[k].altitude..altUnits,
          string.upper(threatTable[k].aspect),
          sd))
        end
        if threatTable[k+1]~=nil then
          table.insert(message,"\n")
        end
      end
      trigger.action.outTextForGroup(activePlayer.groupID,table.concat(message),ewrs.messageDisplayTime)
    else
      if bogeyDope then
        trigger.action.outTextForGroup(activePlayer.groupID, "EWRS Bogey Dope for: " .. activePlayer.player .. "\nNo targets detected", ewrs.messageDisplayTime)
      elseif (not ewrs.disableMessageWhenNoThreats) and greeting == nil then
        trigger.action.outTextForGroup(activePlayer.groupID, "EWRS Picture Report for: " .. activePlayer.player .. "\nNo targets detected", ewrs.messageDisplayTime)
      end
      if greeting ~= nil then
        trigger.action.outTextForGroup(activePlayer.groupID, "EWRS Friendly Picture for: " .. activePlayer.player .. "\nNo friendlies detected", ewrs.messageDisplayTime)
      end
    end
  end)
  if not status then
    env.error(string.format("EWRS outText Error: %s", result))
  end
end

function ewrs.displayMessageToAll()
  local status, result = pcall(function()
    timer.scheduleFunction(ewrs.displayMessageToAll, nil, timer.getTime() + ewrs.messageUpdateInterval)
    ewrs.findRadarUnits()
    ewrs.getDetectedTargets()
    for i = 1, #ewrs.activePlayers do
      if ewrs.groupSettings[tostring(ewrs.activePlayers[i].groupID)].messages then
        if ewrs.activePlayers[i].side == 1 and #ewrs.redEwrUnits > 0 or ewrs.activePlayers[i].side == 2 and #ewrs.blueEwrUnits > 0 then
          ewrs.outText(ewrs.activePlayers[i], ewrs.buildThreatTable(ewrs.activePlayers[i]))
        end -- if ewrs.activePlayers[i].side == 1 and #ewrs.redEwrUnits > 0 or ewrs.activePlayers[i].side == 2 and #ewrs.blueEwrUnits > 0 then
      end -- if ewrs.groupSettings[tostring(ewrs.activePlayers[i].groupID)].messages then
    end -- for i = 1, #ewrs.activePlayers do
  end)
  if not status then
    env.error(string.format("EWRS displayMessageToAll Error: %s", result))
  end
end

function ewrs.onDemandMessage(args)
  local status, result = pcall(function()
    ewrs.findRadarUnits()
    ewrs.getDetectedTargets()
    for i = 1, #ewrs.activePlayers do
      if ewrs.activePlayers[i].groupID == args[1] then
        ewrs.outText(ewrs.activePlayers[i], ewrs.buildThreatTable(ewrs.activePlayers[i],args[2]),args[2])
      end
    end
  end)
  if not status then
    env.error(string.format("EWRS onDemandMessage Error: %s", result))
  end
end

function ewrs.buildFriendlyTable(friendlyNames,activePlayer)
  local function sortRanges(v1,v2) return v1.range<v2.range end

  local units={}
  for i=1,#friendlyNames do
    local unit=Unit.getByName(friendlyNames[i])
    if unit and unit:isActive() then table.insert(units,unit) end
  end

  local _self=Unit.getByName(activePlayer.unitname)
  local selfpos=_self:getPosition()
  local referenceX=selfpos.p.x
  local referenceZ=selfpos.p.z

  local friendlyTable={}

  for k,v in pairs(units) do
    local velocity=v:getVelocity()
    local pos=v:getPosition()
    local unit=UNIT:Find(v)
    if unit then                                           -- << guard >>
      local bogeyType=unit:GetNatoReportingName()
      if pos.p.x~=selfpos.p.x and pos.p.z~=selfpos.p.z then
        local bearing=ewrs.getBearing(referenceX,referenceZ,pos.p.x,pos.p.z)
        local heading=ewrs.getHeading(velocity)
        local range=ewrs.getDistance(referenceX,referenceZ,pos.p.x,pos.p.z)
        local altitude=pos.p.y
        local speed=ewrs.getSpeed(velocity)

        if ewrs.groupSettings[tostring(activePlayer.groupID)].measurements=="metric" then
          range=UTILS.Round(range/1000,-1)
          speed=UTILS.Round(UTILS.MpsToKmph(speed),-1)
          altitude=UTILS.Round(altitude,-1)
        else
          range=UTILS.Round(UTILS.MetersToNM(range),-1)
          speed=UTILS.Round(UTILS.MpsToKnots(speed),-1)
          altitude=UTILS.Round(UTILS.MetersToFeet(altitude),-3)
        end

        local j=#friendlyTable+1
        friendlyTable[j]={}
        friendlyTable[j].unitType=bogeyType
        friendlyTable[j].bearing=bearing
        friendlyTable[j].range=range
        friendlyTable[j].altitude=altitude
        friendlyTable[j].speed=speed
        friendlyTable[j].heading=heading
      end
    end
  end
  table.sort(friendlyTable,sortRanges)
  return friendlyTable
end

function ewrs.friendlyPicture(args)
  local status, result = pcall(function()
    for i = 1, #ewrs.activePlayers do
      if ewrs.activePlayers[i].groupID == args[1] then
        local sideString = nil
        if  ewrs.activePlayers[i].side == 1 then
          sideString = "[red]"
        else
          sideString = "[blue]"
        end
        --local filter = {sideString.."[helicopter]", sideString.."[plane]"}
        --local friendlies = mist.makeUnitTable(filter) --find a way to do this only once if there is more then 1 person in a group
        local friendlies = SET_UNIT:New():FilterCoalitions(sideString):FilterTypes({"helicopter","plane"}):FilterOnce()
        local friendlyTable = ewrs.buildFriendlyTable(friendlies:GetSetNames(),ewrs.activePlayers[i])
        local greeting = "EWRS Friendly Picture for: " .. ewrs.activePlayers[i].player
        ewrs.outText(ewrs.activePlayers[i],friendlyTable,false,greeting)
      end
    end
  end)
  if not status then
    env.error(string.format("EWRS friendlyPicture Error: %s", result))
  end
end

function ewrs.buildActivePlayers()
  local status, result = pcall(function()
    local all_units = SET_CLIENT:New():FilterActive(true):FilterOnce()
    local all_vecs = all_units:GetSetNames()
    --UTILS.PrintTableToLog(all_vecs,1)
    ewrs.activePlayers = {}
    for i = 1, #all_vecs do
      local vec = Unit.getByName(all_vecs[i])
      if vec and vec:isActive() then
        local playerName = Unit.getPlayerName(vec)    -- static call is OK
        local groupID    = ewrs.getGroupId(vec)
        if playerName then
          -- use colon again when you need the coalition of THAT unit
          if ewrs.enableBlueTeam and vec:getCoalition() == 2 then
            ewrs.addPlayer(playerName, groupID, vec)
          elseif ewrs.enableRedTeam and vec:getCoalition() == 1 then
            ewrs.addPlayer(playerName, groupID, vec)
          end
        end
      end
    end
  end) -- pcall
  
  if not status then
    env.error(string.format("EWRS buildActivePlayers Error: %s", result))
  end
end

function ewrs.getGroupId(_unit)
  if not _unit then return nil end
  local unit = UNIT:Find(_unit)
  if unit and unit:GetGroup() then
    return unit:GetGroup():GetID()
  end
  return nil
end

function ewrs.getGroupCategory(unit)
  if not unit then return nil end
  local unit = UNIT:Find(unit)
  local category = "none"

  if unit and unit:IsAirPlane() then category = "plane" end
  if unit and unit:IsHelicopter() then category = "helicopter" end
  return category
end


function ewrs.addPlayer(playerName, groupID, unit )
  if not playerName or not groupID or not unit then return end
  local status, result = pcall(function()
    local i = #ewrs.activePlayers + 1
    ewrs.activePlayers[i] = {}
    ewrs.activePlayers[i].player = playerName
    ewrs.activePlayers[i].groupID = groupID
    ewrs.activePlayers[i].unitname = unit:getName()
    ewrs.activePlayers[i].side = unit:getCoalition() 
  
    -- add default settings to settings table if it hasn't been done yet
    if ewrs.groupSettings[tostring(groupID)] == nil then
      ewrs.addGroupSettings(tostring(groupID))
    end
  end)
  if not status then
    env.error(string.format("EWRS addPlayer Error: %s", result))
  end
end

-- filters units so ones detected by multiple radar sites still only get listed once
-- Filters out anything that isn't a plane or helicopter
function ewrs.filterUnits(units)
  env.info("filterUnits")
  local newUnits={}
  for k,v in pairs(units) do
    local valid=true
    local obj=v["object"]

    if not obj or not obj:isExist() or Object.getCategory(obj)~=Object.Category.UNIT then
      valid=false
    end

    if valid then
      local category=ewrs.getGroupCategory(obj)
      env.info(tostring(category))
      if category~="plane" and category~="helicopter" then valid=false end
    end

    if valid then
      for nk,nv in pairs(newUnits) do
        if obj:getName()==nv["object"]:getName() then
          valid=false
          if v["type"]     then nv["type"]=true end
          if v["distance"] then nv["distance"]=true end
        end
      end
    end

    if valid then table.insert(newUnits,v) end
  end
  return newUnits
end

function ewrs.getDetectedTargets()
  if #ewrs.blueEwrUnits > 0 then
    ewrs.currentlyDetectedRedUnits = ewrs.findDetectedTargets("red")
  end
  if #ewrs.redEwrUnits > 0 then
    ewrs.currentlyDetectedBlueUnits = ewrs.findDetectedTargets("blue")
  end
end

function ewrs.findDetectedTargets(side)
  env.info("findDetectedTargets "..side)
  local units = {}
  local ewrUnits = {}

  if side == "red" then
    ewrUnits = ewrs.blueEwrUnits
  elseif side == "blue" then
    ewrUnits = ewrs.redEwrUnits
  end

  for n = 1, #ewrUnits do
    local ewrUnit = Unit.getByName(ewrUnits[n])
    if ewrUnit ~= nil then
      local ewrControl = ewrUnit:getGroup():getController()
      local detectedTargets = ewrControl:getDetectedTargets(Controller.Detection.RADAR)
      for k,v in pairs (detectedTargets) do
        table.insert(units, v)
      end
    end
  end
  --UTILS.PrintTableToLog(units,1)
  return ewrs.filterUnits(units)
end

function ewrs.findRadarUnits()
  local allunitsB = SET_UNIT:New():FilterHasSEAD():FilterCategories({"plane","ground","ship"}):FilterCoalitions("blue"):FilterOnce()
  local allunitsR = SET_UNIT:New():FilterHasSEAD():FilterCategories({"plane","ground","ship"}):FilterCoalitions("red"):FilterOnce()
  
  if ewrs.enableBlueTeam then
    ewrs.blueEwrUnits = allunitsB:GetSetNames()
    --UTILS.PrintTableToLog(ewrs.blueEwrUnits ,indent)
  end
  if ewrs.enableRedTeam then
    ewrs.redEwrUnits = allunitsR:GetSetNames()
    --UTILS.PrintTableToLog(ewrs.redEwrUnits ,indent)
  end
end

function ewrs.addGroupSettings(groupID)
  ewrs.groupSettings[groupID] = {}
  ewrs.groupSettings[groupID].reference = ewrs.defaultReference
  ewrs.groupSettings[groupID].measurements = ewrs.defaultMeasurements
  ewrs.groupSettings[groupID].messages = true
end

function ewrs.setGroupReference(args)
  local groupID = args[1]
  ewrs.groupSettings[tostring(groupID)].reference = args[2]
  trigger.action.outTextForGroup(groupID,"Reference changed to "..args[2],ewrs.messageDisplayTime)
end

function ewrs.setGroupMeasurements(args)
  local groupID = args[1]
  ewrs.groupSettings[tostring(groupID)].measurements = args[2]
  trigger.action.outTextForGroup(groupID,"Measurement units changed to "..args[2],ewrs.messageDisplayTime)
end

function ewrs.setGroupMessages(args)
  local groupID = args[1]
  local onOff
  if args[2] then onOff = "on" else onOff = "off" end
  ewrs.groupSettings[tostring(groupID)].messages = args[2]
  trigger.action.outTextForGroup(groupID,"Picture reports for group turned "..onOff,ewrs.messageDisplayTime)
end

function ewrs.buildF10Menu()
  local status, result = pcall(function()
    for i = 1, #ewrs.activePlayers do
      local groupID = ewrs.activePlayers[i].groupID
      local stringGroupID = tostring(groupID)
      if ewrs.builtF10Menus[stringGroupID] == nil then
        local rootPath = missionCommands.addSubMenuForGroup(groupID, "EWRS")
        
        if ewrs.allowBogeyDope then
          missionCommands.addCommandForGroup(groupID, "Request Bogey Dope",rootPath,ewrs.onDemandMessage,{groupID,true})
        end
        
        if ewrs.onDemand then
          missionCommands.addCommandForGroup(groupID, "Request Picture",rootPath,ewrs.onDemandMessage,{groupID})
        end
        
        if ewrs.allowFriendlyPicture then
          missionCommands.addCommandForGroup(groupID, "Request Friendly Picture",rootPath,ewrs.friendlyPicture,{groupID})
        end
        
        if not ewrs.restrictToOneReference then
          local referenceSetPath = missionCommands.addSubMenuForGroup(groupID,"Set GROUP's reference point", rootPath)
          missionCommands.addCommandForGroup(groupID, "Set to Bullseye",referenceSetPath,ewrs.setGroupReference,{groupID, "bulls"})
          missionCommands.addCommandForGroup(groupID, "Set to Self",referenceSetPath,ewrs.setGroupReference,{groupID, "self"})
        end
      
        local measurementsSetPath = missionCommands.addSubMenuForGroup(groupID,"Set GROUP's measurement units",rootPath)
        missionCommands.addCommandForGroup(groupID, "Set to Imperial (feet, knts)",measurementsSetPath,ewrs.setGroupMeasurements,{groupID, "imperial"})
        missionCommands.addCommandForGroup(groupID, "Set to Metric (meters, km/h)",measurementsSetPath,ewrs.setGroupMeasurements,{groupID, "metric"})

        if not ewrs.onDemand then
          local messageOnOffPath = missionCommands.addSubMenuForGroup(groupID, "Turn Picture Report On/Off",rootPath)
          missionCommands.addCommandForGroup(groupID, "Message ON", messageOnOffPath, ewrs.setGroupMessages, {groupID, true})
          missionCommands.addCommandForGroup(groupID, "Message OFF", messageOnOffPath, ewrs.setGroupMessages, {groupID, false})
        end

        ewrs.builtF10Menus[stringGroupID] = true
      end
    end
  end)
  
  if not status then
    env.error(string.format("EWRS buildF10Menu Error: %s", result))
  end
end


--SCRIPT INIT
ewrs.currentlyDetectedRedUnits = {}
ewrs.currentlyDetectedBlueUnits = {}
ewrs.redEwrUnits = {}
ewrs.blueEwrUnits = {}
ewrs.activePlayers = {}
ewrs.groupSettings = {}
ewrs.builtF10Menus = {}
ewrs.notAvailable = 999999

ewrs.update()
if not ewrs.onDemand then
  timer.scheduleFunction(ewrs.displayMessageToAll, nil, timer.getTime() + ewrs.messageUpdateInterval)
end
--trigger.action.outText("EWRS by Steggles is now running",15)
env.info("EWRS "..ewrs.version.." Running")
