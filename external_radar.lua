--[[
    @title
        external radar

    @author
        Moyo

    @description
        sends game data to the external radar
]]
local json         = require("json")     -- lib_json
local modules      = require("modules")  -- lib_modules
local lib_players  = require("players")  -- lib_players
local lib_entities = require("entities") -- lib_entities

local external_radar = {

    -- time to wait until fetching game data in milliseconds
    entity_refresh_delay = 100,
    data_refresh_delay = 20,

    -- cached data
    cache = {
        -- refresh timestamp
        next_data_refresh = 0,
        -- cached data for external radar
        game_data = {}
    },

    -- nade types
    nade_types = {
        C_SmokeGrenadeProjectile = "smoke",
        C_HEGrenadeProjectile = "frag",
        C_FlashbangProjectile = "flashbang",
        C_MolotovProjectile = "firebomb",
        C_Inferno = "inferno",
    }
}

function external_radar.on_scripts_loaded()

    -- setup entity refreshing
    local requested_classes = {
        "C_PlantedC4",
        "C_C4",
        "C_SmokeGrenadeProjectile",
        "C_HEGrenadeProjectile",
        "C_FlashbangProjectile",
        "C_MolotovProjectile",
        "C_Inferno"
    }

    lib_entities.add_entities("external_radar", requested_classes, external_radar.entity_refresh_delay)
end

function external_radar.on_solution_calibrated(data)
    -- check if calibrated game is CS2
    if data.gameid ~= GAME_CS2 then return false end
end

function external_radar.on_worker(is_calibrated, game_id)
    if not is_calibrated then return end

    -- check if we're ingame
    local globals = modules.source2:get_globals()
    if not globals or globals.map == "<empty>" then
        external_radar.cache.game_data = {}
        return
    end

    -- get current time
    local time = fantasy.time()

    -- check if game data cache should get updated
    if time < external_radar.cache.next_data_refresh then return end
    external_radar.cache.next_data_refresh = time + external_radar.data_refresh_delay

    -- get localplayer
    local localplayer = modules.entity_list:get_localplayer()
    if not localplayer then return end

    -- get localplayer pawn and index
    local local_pawn = localplayer:get_pawn()
    local local_index = localplayer:get_index()

    -- get globals
    local globals = modules.source2:get_globals()

    -- Check if local player is spectating someone
    local observer_target_pawn = nil
    local observer_services = local_pawn:read(MEM_ADDRESS, modules.source2:get_schema("C_BasePlayerPawn", "m_pObserverServices"))
    if observer_services and observer_services:is_valid() then
        local hObserverTarget = observer_services:read(MEM_INT, modules.source2:get_schema("CPlayer_ObserverServices", "m_hObserverTarget"))
        if hObserverTarget and hObserverTarget ~= -1 then
            observer_target_pawn = modules.entity_list:from_handle(hObserverTarget)
        end
    end

    -- get cached entity data
    local planted_bomb, carried_bomb, projectile_entities = nil, nil, {}
    for class_name, entity_table in pairs(lib_entities.get_entities("external_radar")) do
        if class_name == "C_PlantedC4" then
            planted_bomb = entity:new(entity_table[1])
        elseif class_name == "C_C4" then
            carried_bomb = entity:new(entity_table[1])
        else
            local nade_type = external_radar.nade_types[class_name]
            for _, nade_address in pairs(entity_table) do
                table.insert(projectile_entities, {
                    nade_id = string.sub(tostring(nade_address), -8),
                    type = nade_type,
                    entity = entity:new(nade_address)
                })
            end
        end
    end

    -- bomb related variables
    local bomb_carrier_entity = nil
    local bomb_state = "carried"
    local bomb_pos = { x = 0, y = 0, z = 0 }

    -- check if bomb is planted
    if planted_bomb then
        -- get planted bomb origin
        local gameSceneNode = planted_bomb:read(MEM_ADDRESS, modules.source2:get_schema("C_BaseEntity", "m_pGameSceneNode"))
        if gameSceneNode == nil or not gameSceneNode:is_valid() then goto skip_planted_bomb end
        local bomb_origin = gameSceneNode:read(MEM_VECTOR, modules.source2:get_schema("CGameSceneNode", "m_vecAbsOrigin"))
        if bomb_origin == nil or bomb_origin.x == 0.0 then goto skip_planted_bomb end
        bomb_pos = {
            x = bomb_origin.x,
            y = bomb_origin.y,
            z = bomb_origin.z
        }

        bomb_state = "planted"
        if planted_bomb:read(MEM_BOOL, modules.source2:get_schema("C_PlantedC4", "m_bHasExploded")) then
            bomb_state = "exploded"
        elseif planted_bomb:read(MEM_BOOL, modules.source2:get_schema("C_PlantedC4", "m_bBombDefused")) then
            bomb_state = "defused"
        elseif planted_bomb:read(MEM_BOOL, modules.source2:get_schema("C_PlantedC4", "m_bBeingDefused")) then
            bomb_state = "defusing"
        end
        ::skip_planted_bomb::

    -- check if bomb is dropped or getting carried
    elseif carried_bomb then
        -- get the handle of the bomb carrier
        local hOwner = carried_bomb:read(MEM_INT, modules.source2:get_schema("C_BaseEntity", "m_hOwnerEntity"))
        if hOwner == nil then goto skip_carried_bomb end
        -- check if handle is valid
        if hOwner ~= -1 then
            -- get the bomb carrier pawn
            bomb_carrier_entity = modules.entity_list:from_handle(hOwner)
        else
            local gameSceneNode = carried_bomb:read(MEM_ADDRESS, modules.source2:get_schema("C_BaseEntity", "m_pGameSceneNode"))
            if gameSceneNode == nil or not gameSceneNode:is_valid() then goto skip_carried_bomb end
            local bomb_origin = gameSceneNode:read(MEM_VECTOR, modules.source2:get_schema("CGameSceneNode", "m_vecAbsOrigin"))
            if bomb_origin == nil or bomb_origin.x == 0.0 then goto skip_carried_bomb end
            bomb_state = "dropped"
            bomb_pos = {
                x = bomb_origin.x,
                y = bomb_origin.y,
                z = bomb_origin.z
            }
        end
        ::skip_carried_bomb::
    end

    -- table for storing player info
    local player_array = {}

    -- loop over player entities
    for _, player in pairs(modules.entity_list:get_players()) do
        -- convert to lib_players class
        player = lib_players.to_player(player)
        if not player then goto skip_player end

        -- get origin (position)
        local origin = player:get_origin()
        if not origin then goto skip_player end

        -- get viewangles
        local view = player:get_eye_angles()
        if not view then goto skip_player end

        -- check if player is flashed
        local pawn = player:get_pawn()
        local flashed_value = pawn:read(MEM_FLOAT, modules.source2:get_schema("C_CSPlayerPawnBase", "m_flFlashOverlayAlpha"))

        -- check if player has bomb
        local has_bomb = false
        if not planted_bomb and bomb_carrier_entity and carried_bomb then
            if bomb_carrier_entity.address == pawn.address then
                has_bomb = true
            end
        end

        -- get player index
        local player_index = player:get_index()

        -- get player name
        local player_name = player:get_name()
        if not player_name or #player_name == 0 then player_name = "?" end

        -- convert player name to bytes
        local player_name_bytes = string.gsub(player_name,"(.)",function (x) return string.format("%%%02X",string.byte(x)) end)

        -- insert to player table
        table.insert(player_array, {
            index = player_index,
            team = player:get_team(),
            health = player:get_health(),
            active = player_index == local_index or (observer_target_pawn and pawn.address == observer_target_pawn.address),
            name = player_name_bytes,
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

        ::skip_player::
    end

    -- table for storing projectile info
    local projectile_array = {}

    -- loop over projectile entities
    for _, nade in pairs(projectile_entities) do
        local ent = nade.entity
        local team = ""
        local effect_time = 0
        local fire_positions = {}

        -- check if HE already exploded
        if nade.type == "frag" then
            local bExplodeEffectBegan = ent:read(MEM_BOOL, modules.source2:get_schema("C_BaseCSGrenadeProjectile", "m_bExplodeEffectBegan"))
            if bExplodeEffectBegan then goto skip_nade end
        end

        -- get fire positions
        if nade.type == "inferno" then
            local is_burning = ent:read(MEM_BOOL, modules.source2:get_schema( "C_Inferno", "m_bFireIsBurning" ))
            if not is_burning then goto skip_nade end
            local fire_amount = ent:read(MEM_INT, modules.source2:get_schema( "C_Inferno", "m_fireCount" ))
            for i = 0, fire_amount - 1 do
                local fire_pos = ent:read(MEM_VECTOR, modules.source2:get_schema( "C_Inferno", "m_firePositions" ) + i * 0xC)
                table.insert(fire_positions, {
                    x = fire_pos.x,
                    y = fire_pos.y,
                    z = fire_pos.z
                })
            end
        end

        -- get gamescene node and nade origin
        local game_scene_node = ent:read(MEM_ADDRESS, modules.source2:get_schema("C_BaseEntity", "m_pGameSceneNode"))
        if not game_scene_node or not game_scene_node:is_valid() then goto skip_nade end
        local nade_origin = game_scene_node:read(MEM_VECTOR, modules.source2:get_schema("CGameSceneNode", "m_vecAbsOrigin"))
        if not nade_origin or nade_origin.x == 0.0 then goto skip_nade end

        -- check if nade is dormant
        local bDormant = game_scene_node:read(MEM_BOOL, modules.source2:get_schema("CGameSceneNode", "m_bDormant"))
        if bDormant then goto skip_nade end

        -- get nade owner team
        if nade.type ~= "inferno" then
            local owner_pawn_handle = ent:read(MEM_INT, modules.source2:get_schema("C_BaseEntity", "m_hOwnerEntity"))
            if not owner_pawn_handle or owner_pawn_handle == -1 then goto skip_nade end
            local owner_pawn = modules.entity_list:get_entity(owner_pawn_handle)
            if not owner_pawn then goto skip_nade end
            local owner_entity = modules.source2:to_controller(owner_pawn)
            if not owner_entity then goto skip_nade end
            local team_num = owner_entity:read(MEM_INT, modules.source2:get_schema("C_BaseEntity", "m_iTeamNum"))
            if team_num == 2 then
                team = "T"
            elseif team_num == 3 then
                team = "CT"
            end
        end

        -- get effect time
        if nade.type == "smoke" then
            local bDid_smoke_effect = ent:read(MEM_BOOL, modules.source2:get_schema("C_SmokeGrenadeProjectile", "m_bDidSmokeEffect"))
            if bDid_smoke_effect then
                local effect_tick_begin = ent:read(MEM_INT, modules.source2:get_schema("C_SmokeGrenadeProjectile", "m_nSmokeEffectTickBegin"))
                effect_time = (globals.tick_count - effect_tick_begin) * 0.015625
            end
        end

        table.insert(projectile_array, {
            id = nade.nade_id,
            type = nade.type,
            position = {
                x = nade_origin.x,
                y = nade_origin.y,
                z = nade_origin.z
            },
            team = team,
            effecttime = effect_time,
            flames_pos = fire_positions
        })

        ::skip_nade::
    end

    -- cache game data
    external_radar.cache.game_data = {
        -- map = globals.map,
        localplayer = {
            index = local_index
        },
        players = player_array,
        grenades = projectile_array,
        bomb = {
            state = bomb_state,
            pos = bomb_pos
        }
    }

end

function external_radar.on_http_request(data)
    -- only respond to requests for external radar
    if data["script"] ~= "external_radar.lua" then return end
    if data["path"] ~= "/luar" then return end

    -- return cached data encoded as JSON
    return json.encode(external_radar.cache.game_data)
end

return external_radar