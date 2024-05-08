// Shared render object
//
// Provides shared variables and functions for all renderers.

global = {
	// Config loaded from disk
	config: {},
	// Effects triggered by key-binds
	effects: {},
	mapData: {},
	currentMap: "none",
	// The last known game phase
	gamePhase: "freezetime",

	playerPos: [],
	playerBuffers: [],
	playerSplits: [],
	playerDots: [],
	playerLabels: [],
	playerAmmos: [],
	playerHealths: [],

	projectilePos: {},
	projectileBuffer: {},

	/**
	 * Convert in-game position units to radar percentages
	 * @param  {Array}  positionObj In-game position object with X and Y, and an optional Z
	 * @param  {String} axis        The axis to calculate position for
	 * @param  {Number} playerNum   An optional player number to wipe location buffer on split switch
	 * @return {Number}             Relative radar percentage
	 */
	positionToPerc: (positionObj, axis, playerNum) => {
		let gamePosition = positionObj[axis] + global.mapData.offset[axis];
		let pixelPosition = gamePosition / global.mapData.resolution;
		let precPosition = pixelPosition / 1024 * 100;
		let currentSplit = -1;
	
		if (global.mapData.splits.length > 0 && typeof positionObj.z === "number") {
			for (let i in global.mapData.splits) {
				let split = global.mapData.splits[i];
				if (positionObj.z > split.bounds.bottom && positionObj.z < split.bounds.top) {
					precPosition += split.offset[axis];
					currentSplit = parseInt(i);
					break;
				}
			}
		}
	
		if (typeof playerNum === "number" && playerNum >= 0 && playerNum < global.playerPos.length) {
			if (global.playerSplits[playerNum] !== currentSplit) {
				global.playerBuffers[playerNum] = [];
			}
			global.playerSplits[playerNum] = currentSplit;
			if (global.playerPos[playerNum]) {
				if (typeof global.playerPos[playerNum].split === "undefined") {
					global.playerPos[playerNum].split = currentSplit;
				}
			}
		}
	
		return precPosition;
	}	
}

// Fill position and buffer arrays
for (var i = 0; i < 10; i++) {
	global.playerPos.push({
		x: null,
		y: null,
		alive: false
	})

	global.playerSplits.push(-1)
	global.playerBuffers.push([])
	global.playerDots.push(document.getElementById("dot" + i))
	global.playerLabels.push(document.getElementById("label" + i))
	global.playerAmmos.push({})
	global.playerHealths.push(0)
}
