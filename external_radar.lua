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

    -- time to wait between entity loops in ms
    entity_refresh_delay = 10,

    -- cached data
    cache = {
        timestamp = 0,

        carried_bomb = nil,
        planted_bomb = nil,

        projectiles = {},
    }
}

function external_radar.on_solution_calibrated(data)
    -- check if calibrated game is CS2
    if data.gameid ~= GAME_CS2 then return false end
end

function external_radar.on_worker(is_calibrated, game_id)
    if not is_calibrated then return end

    -- get localplayer
    local localplayer = modules.entity_list:get_localplayer()
    if not localplayer then return end

    -- check if entities should get updated
    if fantasy.time() < external_radar.cache.timestamp then return end
    external_radar.cache.timestamp = fantasy.time() + external_radar.entity_refresh_delay

    local planted_bomb = nil
    local carried_bomb = nil
    local projectiles = {}

    -- loop over entity list to find the bomb entity
    for i = 65, modules.entity_list:get_highest_entity_index() do
        local ent = modules.entity_list:get_entity(i)
        if not ent then goto continue end

        -- get entity class name
        local pEntity = ent:read(MEM_ADDRESS, modules.source2:get_schema("CEntityInstance", "m_pEntity"))
        if not pEntity:is_valid() then goto continue end

        local entity_classinfo = pEntity:read(MEM_ADDRESS, 0x8)
        if not entity_classinfo:is_valid() then goto continue end

        local ptr1 = entity_classinfo:read(MEM_ADDRESS, 0x28)
        if not ptr1:is_valid() then goto continue end

        local ptr2 = ptr1:read(MEM_ADDRESS, 0x8)
        if not ptr2:is_valid() then goto continue end

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
            table.insert(projectiles, {
                nade_id = i,
                type = "smoke",
                entity = ent
            })
            goto continue
        end

        -- check if entity is a thrown HE grenade
        if class_name == "C_HEGrenadeProjectile" then
            table.insert(projectiles, {
                nade_id = i,
                type = "frag",
                entity = ent
            })
            goto continue
        end

        -- check if entity is a thrown flashbang
        if class_name == "C_FlashbangProjectile" then
            table.insert(projectiles, {
                nade_id = i,
                type = "flashbang",
                entity = ent
            })
            goto continue
        end

        -- check if entity is a thrown molotov/incendiary
        if class_name == "C_MolotovProjectile" then
            table.insert(projectiles, {
                nade_id = i,
                type = "firebomb",
                entity = ent
            })
            goto continue
        end

        -- check if entity is a landed molotov/incendiary
        if class_name == "C_Inferno" then
            table.insert(projectiles, {
                nade_id = i,
                type = "inferno",
                entity = ent
            })
            goto continue
        end

        ::continue::
    end

    external_radar.cache.carried_bomb = carried_bomb
    external_radar.cache.planted_bomb = planted_bomb
    external_radar.cache.projectiles = projectiles
end

function external_radar.on_http_request(data)
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

    -- get globals
    local globals = modules.source2:get_globals()

    -- define observer target variables to prevent a Lua error
    local hObserverTarget = -1
    local observer_target_pawn = nil

    -- check if localplayer is spectating someone
    local oberver_services = local_pawn:read(MEM_ADDRESS, modules.source2:get_schema("C_BasePlayerPawn", "m_pObserverServices"))
    if not oberver_services:is_valid() then goto skip_observer end
    hObserverTarget = oberver_services:read(MEM_INT, modules.source2:get_schema("CPlayer_ObserverServices", "m_hObserverTarget"))
    if not hObserverTarget or hObserverTarget == -1 then goto skip_observer end
    observer_target_pawn = modules.entity_list:from_handle(hObserverTarget)

    ::skip_observer::

    -- the json content we're going to send back to the server. first put it in a table.
    local output = {
        localplayer = {
            index = local_index
        },
        players = {},
        bomb = {
            state = "carried",
            pos = { x = 0, y = 0, z = 0 }
        },
        grenades = {}
        -- map = modules.source2:get_globals().map,
    }

    -- variable to check for dropped bomb carrier
    local bomb_carrier_entity = nil

    -- check if bomb is planted
    if external_radar.cache.planted_bomb then
        -- get planted bomb entity
        local plantedC4 = external_radar.cache.planted_bomb

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
    elseif external_radar.cache.carried_bomb then
        local state = "carried"
        local pos = { x = 0, y = 0, z = 0 }

        -- get the handle of the bomb carrier
        local hOwner = external_radar.cache.carried_bomb:read(MEM_INT, modules.source2:get_schema("C_BaseEntity", "m_hOwnerEntity"))
        -- check if handle is valid
        if hOwner ~= -1 then
            -- get the bomb carrier pawn
            bomb_carrier_entity = modules.entity_list:from_handle(hOwner)
        else
            local gameSceneNode = external_radar.cache.carried_bomb:read(MEM_ADDRESS, modules.source2:get_schema("C_BaseEntity", "m_pGameSceneNode"))
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
    for _, player in pairs(modules.entity_list:get_players()) do
        -- convert to lib_players class
        player = players.to_player(player)
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
        if not external_radar.cache.planted_bomb and bomb_carrier_entity and external_radar.cache.carried_bomb then
            if bomb_carrier_entity.address == pawn.address then
                has_bomb = true
            end
        end

        -- get player index
        local player_index = player:get_index()

        -- insert to output table
        table.insert(output.players, {
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

    for _, nade in pairs(external_radar.cache.projectiles) do
        local ent = nade.entity
        local team = ""
        local effect_time = 0
        local fire_positions = {}

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

        local game_scene_node = ent:read(MEM_ADDRESS, modules.source2:get_schema("C_BaseEntity", "m_pGameSceneNode"))
        if not game_scene_node or not game_scene_node:is_valid() then goto skip_nade end
        local nade_origin = game_scene_node:read(MEM_VECTOR, modules.source2:get_schema("CGameSceneNode", "m_vecAbsOrigin"))

        -- get velocity
        local velocity = ent:read(MEM_VECTOR, modules.source2:get_schema("C_BaseEntity", "m_vecVelocity"))

        -- get spawn time (why does this always return 0? GameTime_t)
        -- local spawn_time = ent:read(MEM_FLOAT, modules.source2:get_schema("C_BaseCSGrenadeProjectile", "m_flSpawnTime"))

        -- get smoke owner team
        if nade.type == "smoke" or nade.type == "flashbang" or nade.type == "frag" or nade.type == "firebomb" then
            local owner_pawn_handle = ent:read(MEM_INT, modules.source2:get_schema("C_BaseEntity", "m_hOwnerEntity"))
            local owner_pawn = modules.entity_list:get_entity(owner_pawn_handle)
            if not owner_pawn then goto skip_nade end
            local owner_entity = modules.source2:to_controller(owner_pawn)
            if not owner_entity then goto skip_nade end
            -- print(fantasy.time() .. " - " .. tostring(owner_pawn.address) .. " - " .. tostring(owner_entity.address))
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

        table.insert(output.grenades, {
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

    return json.encode(output)
end

return external_radar