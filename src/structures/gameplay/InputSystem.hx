package structures.gameplay;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;

/**
	The input system for the playfield.
	This class handles the input for the playfield, including key presses, releases, and mouse clicks.
	It maps key codes to receptor IDs and manages the strumline for different mania modes.
	But! It is very important to note that this class is integrated onto the playfield.
	@since Development
**/
@:publicFields
class InputSystem {
	// i just realized that this change absolutely feels good.
	private static var MANIA_CONFIGS(default, null):Array<Null<{receptorIds:Array<Int>, xOffset:Int, scale:Float}>> = [
		null,                                                                                              // 0 - unused
		{ receptorIds: [0],                                                   xOffset: 0,   scale: 1.05   }, // 1
		{ receptorIds: [0, 3],                                                xOffset: 111, scale: 1.0    }, // 2
		{ receptorIds: [0, 2, 3],                                             xOffset: 104, scale: 0.95   }, // 3
		{ receptorIds: [0, 1, 2, 3],                                          xOffset: 112, scale: 1.0    }, // 4
		{ receptorIds: [1, 2, 3, 3, 4],                                       xOffset: 97,  scale: 0.9    }, // 5
		{ receptorIds: [0, 1, 3, 0, 2, 3],                                    xOffset: 83,  scale: 0.83   }, // 6
		{ receptorIds: [0, 1, 3, 2, 0, 2, 3],                                xOffset: 75,  scale: 0.77   }, // 7
		{ receptorIds: [0, 1, 2, 3, 0, 1, 2, 3],                             xOffset: 70,  scale: 0.68   }, // 8
		{ receptorIds: [0, 1, 2, 3, 2, 0, 1, 2, 3],                          xOffset: 56,  scale: 0.64   }, // 9
		{ receptorIds: [0, 1, 2, 3, 1, 2, 0, 1, 2, 3],                       xOffset: 53,  scale: 0.59   }, // 10
		{ receptorIds: [0, 1, 2, 3, 0, 1, 3, 0, 1, 2, 3],                    xOffset: 50,  scale: 0.57   }, // 11
		{ receptorIds: [0, 1, 2, 3, 1, 0, 3, 2, 0, 1, 2, 3],                 xOffset: 47,  scale: 0.4777 }, // 12
		{ receptorIds: [0, 1, 2, 3, 1, 0, 2, 3, 2, 0, 1, 2, 3],              xOffset: 42,  scale: 0.432  }, // 13
		{ receptorIds: [0, 1, 2, 3, 0, 1, 3, 0, 2, 3, 0, 1, 2, 3],          xOffset: 41,  scale: 0.42   }, // 14
		{ receptorIds: [0, 1, 2, 3, 0, 1, 3, 2, 0, 2, 3, 0, 1, 2, 3],       xOffset: 39,  scale: 0.405  }, // 15
		{ receptorIds: [0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3],    xOffset: 37,  scale: 0.375  }, // 16
	];

	var keyMap:Array<Array<Int>>; // indexed by KeyCode, stores [index, lane]
	var receptorIds:Array<Int>;
	var strumline:Array<Float>;
	var strumlinePlayable:Array<Bool>;

	var parent:PlayField;

	function new(mania:Int, parent:PlayField) {
		this.parent = parent;

		keyMap = [];
		keyMap.resize(0x111A); // Refer to https://github.com/openfl/lime/blob/develop/src/lime/ui/KeyCode.hx#L251C14-L251C24 to see what I mean by this

		reloadKeybinds(mania);

		var config = (mania >= 1 && mania < MANIA_CONFIGS.length) ? MANIA_CONFIGS[mania] : MANIA_CONFIGS[4];
		if (config == null) config = MANIA_CONFIGS[4];

		receptorIds = config.receptorIds;
		strumline = [config.xOffset, config.scale];

		strumlinePlayable = [false, true];

		haxe.Timer.delay(addEvents, 1); // Just for a single millisecond the event doesn't get added until next frame
	}

	function reloadKeybinds(mania:Int = 4) {
		keyMap = [];

		var keybinds = SaveData.state.controls.game.keybindArray[mania - 1];
		for (i in 0...keybinds.length) {
			var keybind = keybinds[i];
			for (j in 0...keybind.length) {
				var keyCode = minimize(keybind[j]);
				keyMap[keyCode] = [i, 1];
			}
		}
	}

	function addEvents() {
		var window = lime.app.Application.current.window;
		#if !android
		window.onKeyDown.add(press);
		window.onKeyUp.add(release);
		#end
		Main.current.mouseDown = mousePress;
	}

	function removeEvents() {
		var window = lime.app.Application.current.window;
		#if !android
		window.onKeyDown.remove(press);
		window.onKeyUp.remove(release);
		#end
		Main.current.mouseDown = null;
	}

	function press(code:KeyCode, mod:KeyModifier)
	{
		var field = parent.field;
		var isInGameOver = field.isInGameOver;
		var controls = SaveData.state.controls;
		var game = controls.game;
		var ui = controls.ui;

		code = minimize(code);

		if (gameCondition(code)) return;

		if (parent.disposed || parent.botplay
			|| isInGameOver
			|| RenderingMode.enabled || parent.paused) {
			return;
		}

		var keyData = keyMap[code];
		if (keyData == null) {
			return;
		}

		var index = keyData[0];
		var lane = keyData[1];

		#if linc_luajit_funkinview
        parent.funkinviewlua.callFunction('keyPress', index, lane);
		#end

		var noteSystem = parent.noteSystem;

		if (noteSystem != null) {
			var strumline = noteSystem.strumlines[lane];
			if (!strumline.playerHitsToCheck[index]) {
				strumline.playerHitsToCheck[index] = true;
				strumline.press(index);
			}
		}

		parent.onKeyPress.dispatch(code);

		#if linc_luajit_funkinview
        parent.funkinviewlua.callFunction('keyPressPost', index, lane);
        parent.funkinviewlua.callFunction('postKeyPress', index, lane); // alternative syntax
		#end
	}

	function release(code:KeyCode, mod:KeyModifier)
	{
		if (parent.disposed || parent.botplay
			|| parent.field.isInGameOver
			|| RenderingMode.enabled || parent.paused) {
			return;
		}

		code = minimize(code);

		var keyData = keyMap[code];
		if (keyData == null) {
			return;
		}

		var index = keyData[0];
		var lane = keyData[1];

		#if linc_luajit_funkinview
        parent.funkinviewlua.callFunction('keyRelease', index, lane);
		#end

		var noteSystem = parent.noteSystem;

		if (noteSystem != null) {
			var strumline = noteSystem.strumlines[lane];
			if (strumline.playerHitsToCheck[index]) {
				strumline.playerHitsToCheck[index] = false;
				strumline.release(index);
			}
		}

		parent.onKeyRelease.dispatch(code);

		#if linc_luajit_funkinview
        parent.funkinviewlua.callFunction('keyReleasePost', index, lane);
        parent.funkinviewlua.callFunction('postKeyRelease', index, lane); // alternative syntax
		#end
	}

	function gameCondition(keyCode:KeyCode) {
		var returnValue = false;
		var game = SaveData.state.controls.game;

		var field = parent.field;
		var isInGameOver = field.isInGameOver;

		if (parent.ready && isInGameOver) {
			field.endGameOver(keyCode == SaveData.state.controls.ui.back);
			return true;
		}

		if (parent.ready && keyCode == game.pause
			&& !parent.songEnded) {
			if (!parent.paused) parent.pause();
			return true;
		}

		if (parent.ready && !parent.botplay
			&& !isInGameOver && !parent.songEnded
			&& !parent.paused && keyCode == game.reset && !RenderingMode.enabled) {
			parent.gameOver(Chart.header, 1);
			return true;
		}

		return false;
	}

	function mousePress(x:Float, y:Float, mouseButton:MouseButton) {
		if (mouseButton != MouseButton.LEFT) return;
		parent.pause();
	}

	// This is here to prevent invalid array index error because I chose to have an indexed two-dimensional array instead of a map.
	// Another dumb yet smart microoptimization for the fuck of it.
	function minimize(code:Int) {
		if (code > 0x40000000) {
			code -= 0x40000000;
			code += 0x1000;
		}
		return code;
	}

	function dispose() {
		removeEvents();

		while (keyMap.pop() != null) {}
		keyMap = null;
		receptorIds = null;
		strumline = null;
		strumlinePlayable = null;
	}
}
