--[[
    @title
        external radar

    @author
        Moyo

    @description
        sends game data to the external radar
]]
local json = require("json")       -- lib_json
local modules = require("modules") -- lib_modules
local players = require("players") -- lib_players

local external_radar = {

    -- time to wait until fetching game data in milliseconds
    entity_refresh_delay = 100,
    data_refresh_delay = 20,

    -- cached data
    cache = {
        -- refresh timestamps
        next_data_refresh = 0,
        next_entity_refresh = 0,
        -- cached data for external radar
        game_data = {},
        -- cached entity data
        planted_bomb = nil,
        carried_bomb = nil,
        projectile_entities = {},
    }
}

function external_radar.on_solution_calibrated(data)
    -- check if calibrated game is CS2
    if data.gameid ~= GAME_CS2 then return false end
end

function external_radar.on_worker(is_calibrated, game_id)
    if not is_calibrated then return end

    -- get current time
    local time = fantasy.time()

    -- check if entity cache should get updated
    if time > external_radar.cache.next_entity_refresh then
        -- bomb & projectile variables
        local planted_bomb = nil
        local carried_bomb = nil
        local projectile_entities = {}

        -- loop over entity list to find the bomb and projectile entities
        for i = 65, modules.entity_list:get_highest_entity_index() do
            local ent = modules.entity_list:get_entity(i)
            if not ent then goto continue end

            -- get entity class name
            local pEntity = ent:read(MEM_ADDRESS, modules.source2:get_schema("CEntityInstance", "m_pEntity"))
            if not pEntity or not pEntity:is_valid() then goto continue end

            local entity_classinfo = pEntity:read(MEM_ADDRESS, 0x8)
            if not entity_classinfo or not entity_classinfo:is_valid() then goto continue end

            local ptr1 = entity_classinfo:read(MEM_ADDRESS, 0x28)
            if not ptr1 or not ptr1:is_valid() then goto continue end

            local ptr2 = ptr1:read(MEM_ADDRESS, 0x8)
            if not ptr2 or not ptr2:is_valid() then goto continue end

            local class_name = ptr2:read(MEM_STRING, 0, 32)
            if not class_name or class_name == "" then goto continue end

            -- check if entity is the planted bomb
            if class_name == "C_PlantedC4" then
                planted_bomb = ent
                goto continue
            end

            -- check if entity is the carried bomb
            if class_name == "C_C4" then
                carried_bomb = ent
                goto continue
            end

            -- check if entity is a thrown smoke grenade
            if class_name == "C_SmokeGrenadeProjectile" then
                table.insert(projectile_entities, {
                    nade_id = i,
                    type = "smoke",
                    entity = ent
                })
                goto continue
            end

            -- check if entity is a thrown HE grenade
            if class_name == "C_HEGrenadeProjectile" then
                table.insert(projectile_entities, {
                    nade_id = i,
                    type = "frag",
                    entity = ent
                })
                goto continue
            end

            -- check if entity is a thrown flashbang
            if class_name == "C_FlashbangProjectile" then
                table.insert(projectile_entities, {
                    nade_id = i,
                    type = "flashbang",
                    entity = ent
                })
                goto continue
            end

            -- check if entity is a thrown molotov/incendiary
            if class_name == "C_MolotovProjectile" then
                table.insert(projectile_entities, {
                    nade_id = i,
                    type = "firebomb",
                    entity = ent
                })
                goto continue
            end

            -- check if entity is a landed molotov/incendiary
            if class_name == "C_Inferno" then
                table.insert(projectile_entities, {
                    nade_id = i,
                    type = "inferno",
                    entity = ent
                })
                goto continue
            end

            ::continue::
        end

        -- save new entity data
        external_radar.cache.planted_bomb = planted_bomb
        external_radar.cache.carried_bomb = carried_bomb
        external_radar.cache.projectile_entities = projectile_entities

        -- setting next timestamp AFTER getting entities
        external_radar.cache.next_entity_refresh = fantasy.time() + external_radar.entity_refresh_delay
    end

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
    local planted_bomb = external_radar.cache.planted_bomb
    local carried_bomb = external_radar.cache.carried_bomb
    local projectile_entities = external_radar.cache.projectile_entities

    -- bomb related variables
    local bomb_carrier_entity = nil
    local bomb_state = "carried"
    local bomb_pos = { x = 0, y = 0, z = 0 }

    -- check if bomb is planted
    if planted_bomb then
        -- get planted bomb origin
        local gameSceneNode = planted_bomb:read(MEM_ADDRESS, modules.source2:get_schema("C_BaseEntity", "m_pGameSceneNode"))
        local bomb_origin = gameSceneNode:read(MEM_VECTOR, modules.source2:get_schema("CGameSceneNode", "m_vecAbsOrigin"))
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

    -- check if bomb is dropped or getting carried
    elseif carried_bomb then
        -- get the handle of the bomb carrier
        local hOwner = carried_bomb:read(MEM_INT, modules.source2:get_schema("C_BaseEntity", "m_hOwnerEntity"))
        -- check if handle is valid
        if hOwner ~= -1 then
            -- get the bomb carrier pawn
            bomb_carrier_entity = modules.entity_list:from_handle(hOwner)
        else
            local gameSceneNode = carried_bomb:read(MEM_ADDRESS, modules.source2:get_schema("C_BaseEntity", "m_pGameSceneNode"))
            local bomb_origin = gameSceneNode:read(MEM_VECTOR, modules.source2:get_schema("CGameSceneNode", "m_vecAbsOrigin"))
            bomb_state = "dropped"
            bomb_pos = {
                x = bomb_origin.x,
                y = bomb_origin.y,
                z = bomb_origin.z
            }
        end
    end

    -- table for storing player info
    local player_array = {}

    -- loop over player entities
    for _, player in pairs(modules.entity_list:get_players()) do
        -- convert to lib_players class
        player = players.to_player(player)
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
        if not nade_origin then goto skip_nade end

        -- check if nade is dormant
        local bDormant = game_scene_node:read(MEM_BOOL, modules.source2:get_schema("CGameSceneNode", "m_bDormant"))
        if bDormant then goto skip_nade end

        -- get velocity
        local velocity = ent:read(MEM_VECTOR, modules.source2:get_schema("C_BaseEntity", "m_vecVelocity"))
        if not velocity then goto skip_nade end

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
            velocity = {
                x = velocity.x,
                y = velocity.y,
                z = velocity.z
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