--[[
    @title
        external radar

    @author
        Moyo

    @description
        sends game data to the external radar
]]
local json = require("json") -- lib_json
local modules = require("modules") -- lib_modules
local players = require("players") -- lib_players

local external_radar = {
    cache = {
        client_dll = nil,
        dwPlantedC4 = nil,

        previous_bBombPlanted = nil,
        timestamp = 0,

        bomb_entity = nil,
    }
}

function external_radar.on_solution_calibrated(data)
    if data.gameid ~= GAME_CS2 then return false end
    if fantasy.os == "linux" then return false end

    external_radar.cache.client_dll = modules.process:get_module("client.dll")
    if not external_radar.cache.client_dll  then
      fantasy.log("client.dll could not be found")
      return false
    end

    external_radar.cache.dwPlantedC4 = external_radar.cache.client_dll:pattern({
        signature = "48 8B 15 ? ? ? ? 41 FF C0",
        offset = 3,
        x64 = true,
        relative = false,
        extra = 0
    })

    if not external_radar.cache.dwPlantedC4 then
        fantasy.log("dwPlantedC4 could not be found (outdated signature)")
        return false
    end

    -- turn dwPlantedC4 into address object
    external_radar.cache.dwPlantedC4 = address:new(external_radar.cache.dwPlantedC4)

    fantasy.log("dwPlantedC4 offset: {}", external_radar.cache.dwPlantedC4)

end

function external_radar.on_scripts_reloading( )
    if fantasy.os == "linux" then return false end

    external_radar.cache.client_dll = modules.process:get_module("client.dll")
    if not external_radar.cache.client_dll  then
      fantasy.log("client.dll could not be found")
      return false
    end

    external_radar.cache.dwPlantedC4 = external_radar.cache.client_dll:pattern({
        signature = "48 8B 15 ? ? ? ? 41 FF C0",
        offset = 3,
        x64 = true,
        relative = false,
        extra = 0
    })

    if not external_radar.cache.dwPlantedC4 then
        fantasy.log("dwPlantedC4 could not be found (outdated signature)")
        return false
    end

    -- turn dwPlantedC4 into address object
    external_radar.cache.dwPlantedC4 = address:new(external_radar.cache.dwPlantedC4)

    fantasy.log("dwPlantedC4: {}", external_radar.cache.dwPlantedC4)

end

function external_radar.on_worker( is_calibrated, game_id )

    if not is_calibrated then return end

    -- check if the bomb address in the script cache is valid
    if not external_radar.cache.dwPlantedC4 then
        -- if this gets spammed in console the sig is probably outdated
        -- if this appears once during startup or reload that's normal and can get ignored
        fantasy.log("dwPlantedC4 is nil. exiting...")
        return
    end

    -- get localplayer
    local localplayer = modules.entity_list:get_localplayer( )
    if not localplayer then return end

    local should_update = false

    -- check if bomb is planted
    local bBombPlanted = modules.process:read(MEM_BOOL, external_radar.cache.dwPlantedC4:subtract(0x8))
    if bBombPlanted ~= external_radar.cache.previous_bBombPlanted then
        external_radar.cache.previous_bBombPlanted = bBombPlanted
        should_update = true
    end

    -- otherwise only update once per second
    if external_radar.cache.timestamp ~= os.time() then
        external_radar.cache.timestamp = os.time()
        should_update = true
    end

    if not should_update then return end

    -- loop over entity list to find the bomb entity
    for i = 65, modules.entity_list:get_highest_entity_index( ) do
        local ent = modules.entity_list:get_entity( i )
        if not ent then goto continue end

        local pEntity = ent:read( MEM_ADDRESS, modules.source2:get_schema("CEntityInstance", "m_pEntity") )
        if not pEntity then goto continue end

        local namePointer = pEntity:read( MEM_ADDRESS, modules.source2:get_schema("CEntityIdentity", "m_designerName") )
        if not namePointer:is_valid( ) then goto continue end

        local designerName = namePointer:read( MEM_STRING, 0, 32 )
        if not designerName or designerName == "" then goto continue end

        if designerName == "weapon_c4" then
            external_radar.cache.bomb_entity = ent
            goto skip
        end

		::continue::
    end

    external_radar.cache.bomb_entity = nil

    ::skip::
end

function external_radar.on_http_request( data )

    -- only focus on our script.
    if data["script"] ~= "external_radar.lua" then return end

    -- luar (lua return) request only.
    if data["path"] ~= "/luar" then return end

    -- get localplayer
    local localplayer = modules.entity_list:get_localplayer()
    if not localplayer then return end

    -- get localplayer pawn and index
    local local_pawn = localplayer:get_pawn()
    local local_index = localplayer:get_index()

    -- define observer target variables to prevent a Lua error
    local hObserverTarget = -1
    local observer_target_pawn = nil

    -- check if localplayer is spectating someone
    local oberver_services = local_pawn:read( MEM_ADDRESS, modules.source2:get_schema("C_BasePlayerPawn", "m_pObserverServices") )
    if not oberver_services:is_valid() then goto skip_observer end
    hObserverTarget = oberver_services:read( MEM_INT, modules.source2:get_schema("CPlayer_ObserverServices", "m_hObserverTarget") )
    if not hObserverTarget or hObserverTarget == -1 then goto skip_observer end
    observer_target_pawn = modules.entity_list:from_handle( hObserverTarget )

    ::skip_observer::

    -- check if the bomb address in the script cache is valid
    if not external_radar.cache.dwPlantedC4 then
        -- if this gets spammed in console the sig is probably outdated
        -- if this appears once during startup or reload that's normal and can be ignored
        fantasy.log("dwPlantedC4 is nil. exiting...")
        return
    end

    -- the json content we're going to send back to the server. first put it in a table.
    local output = {
        localplayer = {
            index = local_index
        },
        players = {},
        bomb = {
            state = "carried",
            pos = { x = 0, y = 0, z = 0 }
        }
        -- map = modules.source2:get_globals().map,
    }

    -- variable to check for dropped bomb carrier
    local bomb_carrier_entity = nil

    -- check if bomb is planted
    local bBombPlanted = modules.process:read(MEM_BOOL, external_radar.cache.dwPlantedC4:subtract(0x8))

    if bBombPlanted then
        -- get planted bomb entity
        local pPlantedC4 = modules.process:read(MEM_ADDRESS, external_radar.cache.dwPlantedC4)
        local plantedC4 = pPlantedC4:read(MEM_ADDRESS, 0)

        -- get planted bomb origin
        local gameSceneNode = plantedC4:read(MEM_ADDRESS, modules.source2:get_schema("C_BaseEntity", "m_pGameSceneNode"))
        local bomb_origin = gameSceneNode:read(MEM_VECTOR, modules.source2:get_schema("CGameSceneNode", "m_vecAbsOrigin"))

        local state = "planted"
        if plantedC4:read(MEM_BOOL, modules.source2:get_schema("C_PlantedC4", "m_bHasExploded")) then
            state = "exploded"
        elseif plantedC4:read(MEM_BOOL, modules.source2:get_schema("C_PlantedC4", "m_bBombDefused")) then
            state = "defused"
        elseif plantedC4:read(MEM_BOOL, modules.source2:get_schema("C_PlantedC4", "m_bBeingDefused")) then
            state = "defusing"
        end

        output.bomb = {
            state = state,
            pos = {
                x = bomb_origin.x,
                y = bomb_origin.y,
                z = bomb_origin.z
            }
        }
    elseif external_radar.cache.bomb_entity then
        local state = "carried"
        local pos = { x = 0, y = 0, z = 0 }

        -- get the handle of the bomb carrier
        local hOwner = external_radar.cache.bomb_entity:read( MEM_INT, modules.source2:get_schema( "C_BaseEntity", "m_hOwnerEntity" ) )
        -- check if handle is valid
        if hOwner ~= -1 then
            -- get the bomb carrier pawn
            bomb_carrier_entity = modules.entity_list:from_handle( hOwner )
        else
            local gameSceneNode = external_radar.cache.bomb_entity:read(MEM_ADDRESS, modules.source2:get_schema("C_BaseEntity", "m_pGameSceneNode"))
            local bomb_origin = gameSceneNode:read(MEM_VECTOR, modules.source2:get_schema("CGameSceneNode", "m_vecAbsOrigin"))
            state = "dropped"
            pos = {
                x = bomb_origin.x,
                y = bomb_origin.y,
                z = bomb_origin.z
            }
        end

        output.bomb = {
            state = state,
            pos = pos
        }
    end

    -- get all players
    for _, player in pairs( modules.entity_list:get_players() ) do

        -- convert to lib_players class
        player = players.to_player( player )
        if not player then goto skip end

        -- get origin (position)
        local origin = player:get_origin()
        if not origin then goto skip end

        -- get viewangles
        local view = player:get_eye_angles()
        if not view then goto skip end

        -- check if player is flashed
        local pawn = player:get_pawn()
        local flashed_value = pawn:read(MEM_FLOAT, modules.source2:get_schema("C_CSPlayerPawnBase", "m_flFlashOverlayAlpha"))

        -- check if player has bomb
        local has_bomb = false
        if not bBombPlanted and bomb_carrier_entity and external_radar.cache.bomb_entity ~= nil then
            if bomb_carrier_entity.address == pawn.address then
                has_bomb = true
            end
        end

        -- get player index
        local player_index = player:get_index()

        -- insert to output table
        table.insert( output.players, {
            index = player_index,
            team = player:get_team(),
            health = player:get_health(),
            active = player_index == local_index or (observer_target_pawn ~= nil and pawn.address == observer_target_pawn.address),
            name = player:get_name(),
            flash_alpha = flashed_value,
            bomb = has_bomb,
            position = {
                x = origin["x"],
                y = origin["y"],
                z = origin["z"]
            },
            viewangles = {
                x = view["x"],
                y = view["y"]
            }
        })

        ::skip::
    end

    --[[
        on_http_request only accepts JSON strings as a return value.
 
        careful with this:
            fc2's lua module uses a lot of userdata and table types. this is why you see "position" broken down in table.insert earlier.
            if I didn't break that down, parsing will likely fail. JSON doesn't have support for Lua functions nor userdata.
    --]]
    return json.encode( output )
end

return external_radar