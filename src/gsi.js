const http = require("http")
const config = require("./loadconfig")
const fetch = (...args) => import('node-fetch').then(({ default: fetch }) => fetch(...args));

let server = http.createServer(handleRequest)

server.on("error", err => {
	console.error("GSI server error:", err)
})

server.listen(config.game.networkPort, config.game.host, () => {
	console.info(`GSI input expected at http://${config.game.host}:${config.game.networkPort}`)
})

setInterval(async () => {

	// get game info
	let game_info = {};
	try {
		let res = await fetch('http://127.0.0.1:9283/luar?no_debug');
		game_info = await res.json();
	} catch (error) {
		return;
	}

	// check if returned info is valid
	if (!game_info || !game_info.players) return;

	// define empty array for players
	let playerArr = [];

	// loop over player info
	for (let i = 0; i < game_info.players.length; i++) {
		var player = game_info.players[i];

		// correct viewangle for radar
		player.viewangles.y = Math.round((player.viewangles.y = player.viewangles.y * -1 + 90) * 100) / 100
		if (player.viewangles.y < 0) player.viewangles.y += 360

		// skip spectators
		if (player.team != 2 && player.team != 3) continue;

		// add player to player array
		playerArr.push({
			id: player.name,
			num: player.index - 1,
			team: player.team == 3 ? 'CT' : 'T',
			health: player.health,
			active: true,
			flashed: 0,
			bomb: false,
			bombActive: false,
			angle: player.viewangles.y,
			ammo: { },
			position: {
				x: player.position.x,
				y: player.position.y,
				z: player.position.z
			}
		})
	}

	// send game data
	process.send({
		type: "players",
		data: {
			players: playerArr
		}
	})
}, config.fc2.refresh_delay);

function handleRequest(req, res) {
	if (req.method != "POST") {
		res.writeHead(405)
		return res.end("FC2observ running\nPlease POST GSI data here")
	}

	// Start with an enpty body
	let body = ""
	// Append incomming data to body
	req.on("data", data => body += data)

	// On end if packet data
	req.on("end", () => {
		// Send back empty response immediatly
		res.end("")

		// Patch incomming JSON to convert large integers to strings
		body = body.replace(/"owner": ([0-9]{10,})/g, '"owner": "$1"')
		// Parse JSON packet
		let game = JSON.parse(body)
		// console.log(game.allplayers)

		if (game.provider) {
			let connObject = {
				status: "up"
			}

			if (game.player) {
				if (game.player.activity != "playing") {
					connObject.player = game.player.name
				}
			}

			process.send({
				type: "connection",
				data: connObject
			})
		}

		if (game.map) {
			process.send({
				type: "map",
				data: game.map.name
			})
		}

	})
}