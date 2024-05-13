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

local external_radar = {}

function external_radar.on_http_request( data )

    -- only focus on our script.
    if data["script"] ~= "external_radar.lua" then return end

    -- luar (lua return) request only.
    if data["path"] ~= "/luar" then return end

    -- get localplayer
    local localplayer = modules.entity_list:get_localplayer()
    if not localplayer then return end

    -- the json content we're going to send back to the server. first put it in a table.
    local output = {
        players = {},
        bomb = {}
        -- map = modules.source2:get_globals().map,
    }

    -- get all players
    for _, player in pairs( modules.entity_list:get_players() ) do

        -- convert to lib_players class
        player = players.to_player( player )
        if not player then goto skip end

        -- get origin (position)
        local origin = player:get_origin()
        if not origin then goto skip end

        -- don't show disconnected players
        if origin["x"] == 0 and origin["y"] == 0 then goto skip end

        -- get viewangles
        local view = player:get_eye_angles()

        -- insert to output table
        table.insert( output.players, {
            index = player:get_index(),
            team = player:get_team(),
            health = player:get_health(),
            name = player:get_name(),
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