package structures;

import elements.Text;
import lime.ui.KeyCode;

/**
	Options → Controls list (VCR text). Up/down selects a row; enter acts on it.
**/
@:publicFields
class OptionsControlsText {
	public static inline var ROW_COUNT:Int = 16;

	static var UI_FIELDS:Array<String> = ["left", "down", "up", "right", "accept", "back"];
	static var UI_NAMES:Array<String> = ["UI Left", "UI Down", "UI Up", "UI Right", "UI Accept", "UI Back"];
	static var cachedLines(default, null):Array<Text> = [];

	var parent(default, null):OptionsMenu;
	var lines(default, null):Array<Text> = [];
	var active(default, null):Bool = false;
	var waitingForKey(default, null):Bool = false;

	// Keybind editing state
	var state(default, null):OptionsControlsState = CONTROLS_MAIN;
	var editingMania:Int = 4;
	var editingLane:Int = 0;
	var editingKeyIndex:Int = 0;
	var currentKeyBuffer:Array<KeyCode> = [];
	var inputMode:Bool = false;

	function new(parent:OptionsMenu) {
		this.parent = parent;
	}

	static function initCachedLines() {
		if (cachedLines.length == 0) {
			var startY = 105.0;
			for (i in 0...ROW_COUNT) {
				var line = new Text('optionsControls$i', 400, startY + (i * 28), OptionsMenu.display, "", "vcr");
				line.outlineColor = 0x000000FF;
				line.outlineSize = 1.25;
				cachedLines.push(line);
			}
		}
	}

	static function resetCachedLines() {
		for (line in cachedLines) {
			line.text = "";
			line.alpha = 0.0;
		}
	}

	function show() {
		if (active) return;
		active = true;
		waitingForKey = false;

		initCachedLines();
		lines = cachedLines;
		resetCachedLines();
		refresh();
	}

	function hardResetInput() {
		inputMode = false;
		waitingForKey = false;

		state = CONTROLS_MAIN;

		editingMania = SaveData.state.controls.game.mania;
		editingLane = 0;
		editingKeyIndex = 0;

		currentKeyBuffer = [];
		active = false;
	}

	function hide() {
		hardResetInput();
		resetCachedLines();
	}

	function refresh() {
		if (!active) return;
		
		switch (state) {
			case CONTROLS_MAIN:
				var sel = parent.controlsNav.value();
				for (i in 0...lines.length) {
					var line = lines[i];
					line.alpha = parent.alphaLerp;
					var prefix = i == sel ? "> " : "  ";
					if (waitingForKey && i == sel) {
						line.text = '${prefix}PRESS KEY...';
					} else {
						line.text = prefix + rowLabel(i);
					}
				}
			case MANIA_SELECTION:
				renderManiaSelection();
			case KEYBIND_EDITING:
				renderKeybindEditMode();
		}
	}

	function rowLabel(index:Int):String {
		switch (index) {
			case 0:
				return 'Game Keybinds...';
			case 1, 2, 3, 4, 5, 6:
				var uiIdx = index - 1;
				var code:Int = Reflect.field(SaveData.state.controls.ui, UI_FIELDS[uiIdx]);
				return '${UI_NAMES[uiIdx]}: ${formatKey(code)}';
			case 7:
				return 'Pause: ${formatKey(SaveData.state.controls.game.pause)}';
			case 8:
				return 'Reset: ${formatKey(SaveData.state.controls.game.reset)}';
			case 9:
				return 'Debug: ${formatKey(SaveData.state.controls.game.debug)}';
			default:
				return "";
		}
	}

	function onEnter() {
		switch (state) {
			case CONTROLS_MAIN:
				var idx = parent.controlsNav.value();

				if (idx == 0) {
					enterManiaSelection();
					return;
				}

				if (idx >= 1 && idx <= 15) {
					waitingForKey = true;
				}
			case MANIA_SELECTION:
				// Enter selected mania to edit keybinds
				enterKeybindEditMode(editingMania);
			case KEYBIND_EDITING:
				// Enter a lane to start editing its keybinds
				startKeyInput();
		}
	}

	function cancelRebind() {
		waitingForKey = false;
		refresh();
	}

	function navigateDown() {
		switch (state) {
			case CONTROLS_MAIN:
				parent.controlsNav.scroll(1);
				parent.controlsNav.resetIfOver(OptionsControlsText.ROW_COUNT);
			case MANIA_SELECTION:
				editingMania += 1;
				if (editingMania > 16) editingMania = 1;
				renderManiaSelection();
			case KEYBIND_EDITING:
				editingLane += 1;
				var maxLanes = SaveData.state.controls.game.keybindArray[editingMania - 1].length;
				if (editingLane >= maxLanes) editingLane = 0;
				renderKeybindEditMode();
		}
		Main.current.playScrollSound();
	}

	function navigateUp() {
		switch (state) {
			case CONTROLS_MAIN:
				parent.controlsNav.scroll(-1);
				parent.controlsNav.resetIfUnder(OptionsControlsText.ROW_COUNT - 1);
			case MANIA_SELECTION:
				editingMania -= 1;
				if (editingMania < 1) editingMania = 16;
				renderManiaSelection();
			case KEYBIND_EDITING:
				editingLane -= 1;
				if (editingLane < 0) {
					var maxLanes = SaveData.state.controls.game.keybindArray[editingMania - 1].length;
					editingLane = maxLanes - 1;
				}
				renderKeybindEditMode();
		}
		Main.current.playScrollSound();
	}

	function navigateBack() {
		if (inputMode) {
			cancelKeyInput();
			Main.current.playCancelSound();
			return;
		}

		switch (state) {
			case CONTROLS_MAIN:
				// Already handled by OptionsMenu
				return;
			case MANIA_SELECTION:
				exitManiaSelection();
				Main.current.playCancelSound();
			case KEYBIND_EDITING:
				exitKeybindEditMode();
				Main.current.playCancelSound();
		}
	}

	function applyKey(code:KeyCode) {
		if (!active) return;

		switch (state) {
			case CONTROLS_MAIN:
				if (waitingForKey) applyUIControlKey(code);

			case MANIA_SELECTION:
				// ignore

			case KEYBIND_EDITING:
				processKeybindInput(code);
		}
	}

	function isInvalidRebindKey(code:KeyCode):Bool {
		return switch (code) {
			case KeyCode.RETURN, KeyCode.ESCAPE:
				true;
			default:
				false;
		}
	}

	function applyUIControlKey(code:KeyCode) {
		if (code == KeyCode.TAB) return;
		if (!waitingForKey) return;
		var idx = parent.controlsNav.value();

		if (code == KeyCode.RETURN || code == KeyCode.ESCAPE) {
			cancelRebind();
			return;
		}

		switch (idx) {
			case 1, 2, 3, 4, 5, 6:
				Reflect.setField(SaveData.state.controls.ui, UI_FIELDS[idx - 1], code);
			case 7:
				SaveData.state.controls.game.pause = code;
			case 8:
				SaveData.state.controls.game.reset = code;
			case 9:
				SaveData.state.controls.game.debug = code;
			default:
		}

		waitingForKey = false;
		SaveData.save();
		if (Main.current.controls != null) Main.current.controls.reload();
		refresh();
	}

	function cycleMania() {
		var mania = SaveData.state.controls.game.mania;
		mania = mania >= 16 ? 1 : mania + 1;
		SaveData.state.controls.game.mania = mania;
	}

	function applyManiaToPlayfield() {
		var pf = Main.current.playField;
		if (pf != null && pf.inputSystem != null) {
			pf.inputSystem.reloadKeybinds(SaveData.state.controls.game.mania);
		}
	}

	function checkGameKeybindConflict(lane:Int, keys:Array<KeyCode>, mania:Int):Bool {
		if (mania < 1 || mania > 16) return false;
		var keybindArray = SaveData.state.controls.game.keybindArray;
		var maniaKeybinds = keybindArray[mania - 1];
		
		// Check each key in the buffer against all lanes except the current one
		for (key in keys) {
			for (i in 0...maniaKeybinds.length) {
				if (i == lane) continue; // Skip current lane
				for (existingKey in maniaKeybinds[i]) {
					if (existingKey == key) return true; // Conflict found
				}
			}
		}
		return false;
	}

	function checkUIKeybindConflict(keys:Array<KeyCode>):Bool {
		var ui = SaveData.state.controls.ui;
		var uiKeyCodes = [ui.left, ui.down, ui.up, ui.right, ui.accept, ui.back];
		
		for (key in keys) {
			for (uiKey in uiKeyCodes) {
				if (uiKey == key) return true; // Conflict found
			}
		}
		return false;
	}

	function checkPauseResetDebugConflict(keys:Array<KeyCode>):Bool {
		var game = SaveData.state.controls.game;
		var specialKeys = [game.pause, game.reset, game.debug];
		
		for (key in keys) {
			for (specialKey in specialKeys) {
				if (specialKey == key) return true; // Conflict found
			}
		}
		return false;
	}

	function formatKeybindsForDisplay(mania:Int, lane:Int = -1):String {
		if (mania < 1 || mania > 16) return "INVALID";
		var keybindArray = SaveData.state.controls.game.keybindArray;
		var maniaKeybinds = keybindArray[mania - 1];
		
		if (lane >= 0 && lane < maniaKeybinds.length) {
			// Format a single lane's keybinds
			var keybinds = maniaKeybinds[lane];
			var result = [];
			for (key in keybinds) {
				result.push(formatKey(key));
			}
			return result.length > 0 ? result.join(" / ") : "UNSET";
		} else {
			// Format all lanes for this mania
			var result = [];
			for (lane_keys in maniaKeybinds) {
				var lane_str = [];
				for (key in lane_keys) {
					lane_str.push(formatKey(key));
				}
				result.push(lane_str.join("/"));
			}
			return "[" + result.join("] [") + "]";
		}
	}

	function renderManiaSelection() {
		if (!active || state != MANIA_SELECTION) return;
		resetCachedLines();

		var sel = editingMania - 1; // editingMania is 1-16, but array is 0-15
		for (i in 0...lines.length) {
			var line = lines[i];
			line.alpha = parent.alphaLerp;
			var maniaNum = i + 1;
			var prefix = i == sel ? "> " : "  ";
			line.text = '${prefix}${maniaNum}K: ${formatKeybindsForDisplay(maniaNum)}';
		}
	}

	function renderKeybindEditMode() {
		if (!active || state != KEYBIND_EDITING) return;
		resetCachedLines();

		var keybindArray = SaveData.state.controls.game.keybindArray;
		var maniaKeybinds = keybindArray[editingMania - 1];
		var maxLanes = Std.int(Math.min(maniaKeybinds.length, lines.length));

		for (i in 0...maxLanes) {
			var line = lines[i];
			line.alpha = parent.alphaLerp;
			var prefix = i == editingLane ? "> " : "  ";
			var keybinds = formatKeybindsForDisplay(editingMania, i);
			
			if (inputMode && i == editingLane) {
				if (currentKeyBuffer.length == 0) {
					line.text = '${prefix}Lane ${i + 1}: [PRESS KEY 1...]';
				} else if (currentKeyBuffer.length == 1) {
					line.text = '${prefix}Lane ${i + 1}: [${formatKey(currentKeyBuffer[0])} | PRESS KEY 2 (or ESC)]';
				}
			} else {
				line.text = '${prefix}Lane ${i + 1}: ${keybinds}';
			}
		}

		// Fill remaining lines with empty text
		for (i in maxLanes...lines.length) {
			lines[i].alpha = 0.0;
			lines[i].text = "";
		}
	}

	function enterManiaSelection() {
		state = MANIA_SELECTION;
		editingMania = SaveData.state.controls.game.mania;
		editingLane = 0;
		editingKeyIndex = 0;
		currentKeyBuffer = [];
		inputMode = false;
		parent.controlsNav.setTo(0);
		renderManiaSelection();
	}

	function exitManiaSelection() {
		state = CONTROLS_MAIN;
		editingMania = SaveData.state.controls.game.mania;
		resetCachedLines();
		refresh();
	}

	function enterKeybindEditMode(mania:Int) {
		state = KEYBIND_EDITING;
		editingMania = mania;
		editingLane = 0;
		editingKeyIndex = 0;
		currentKeyBuffer = [];
		inputMode = false;
		parent.controlsNav.setTo(0);
		renderKeybindEditMode();
	}

	function exitKeybindEditMode() {
		state = MANIA_SELECTION;
		editingLane = 0;
		editingKeyIndex = 0;
		currentKeyBuffer = [];
		inputMode = false;
		renderManiaSelection();
	}

	function startKeyInput() {
		inputMode = true;
		currentKeyBuffer = [];
		editingKeyIndex = 0;
		renderKeybindEditMode();
	}

	function cancelKeyInput() {
		inputMode = false;
		currentKeyBuffer = [];
		editingKeyIndex = 0;
		renderKeybindEditMode();
	}

	function saveKeybind() {
		if (currentKeyBuffer.length == 0) {
			cancelKeyInput();
			return;
		}

		// Validate against all conflicts
		if (checkGameKeybindConflict(editingLane, currentKeyBuffer, editingMania)) {
			cancelKeyInput();
			Main.current.playCancelSound();
			return;
		}

		if (checkUIKeybindConflict(currentKeyBuffer)) {
			cancelKeyInput();
			Main.current.playCancelSound();
			return;
		}

		if (checkPauseResetDebugConflict(currentKeyBuffer)) {
			cancelKeyInput();
			Main.current.playCancelSound();
			return;
		}

		// Save the keybind
		var keybindArray = SaveData.state.controls.game.keybindArray;
		keybindArray[editingMania - 1][editingLane] = currentKeyBuffer;
		SaveData.save();
		
		// Apply changes to playfield if editing current mania
		if (editingMania == SaveData.state.controls.game.mania) {
			applyManiaToPlayfield();
		}

		inputMode = false;
		currentKeyBuffer = [];
		editingKeyIndex = 0;
		Main.current.playConfirmSound();
		
		// Auto-advance to next lane
		var maxLanes = SaveData.state.controls.game.keybindArray[editingMania - 1].length;
		editingLane += 1;
		
		if (editingLane >= maxLanes) {
			// Finished all lanes, exit to mania selection
			exitKeybindEditMode();
		} else {
			// Start input mode for next lane
			startKeyInput();
		}
	}

	function processKeybindInput(code:KeyCode) {
		if (!inputMode) return;

		// ESC cancels (already UI behavior)
		if (code == KeyCode.ESCAPE) {
			cancelKeyInput();
			Main.current.playCancelSound();
			return;
		}

		// BACK also cancels (your UI back key)
		if (code == SaveData.state.controls.ui.back) {
			cancelKeyInput();
			Main.current.playCancelSound();
			return;
		}

		// Only real keys go into buffer
		if (currentKeyBuffer.length < 2) {
			currentKeyBuffer.push(code);
			renderKeybindEditMode();

			if (currentKeyBuffer.length == 2) {
				haxe.Timer.delay(() -> saveKeybind(), 100);
			}
		}
	}

	static function formatKey(code:Int):String {
		return switch (code:KeyCode) {
			case KeyCode.BACKSPACE: "BKSP";
			case KeyCode.TAB: "TAB";
			case KeyCode.RETURN: "ENTER";
			case KeyCode.ESCAPE: "ESC";
			case KeyCode.SPACE: "SPACE";
			case KeyCode.LEFT: "LEFT";
			case KeyCode.UP: "UP";
			case KeyCode.RIGHT: "RIGHT";
			case KeyCode.DOWN: "DOWN";
			case KeyCode.A: "A";
			case KeyCode.B: "B";
			case KeyCode.C: "C";
			case KeyCode.D: "D";
			case KeyCode.E: "E";
			case KeyCode.F: "F";
			case KeyCode.G: "G";
			case KeyCode.H: "H";
			case KeyCode.I: "I";
			case KeyCode.J: "J";
			case KeyCode.K: "K";
			case KeyCode.L: "L";
			case KeyCode.M: "M";
			case KeyCode.N: "N";
			case KeyCode.O: "O";
			case KeyCode.P: "P";
			case KeyCode.Q: "Q";
			case KeyCode.R: "R";
			case KeyCode.S: "S";
			case KeyCode.T: "T";
			case KeyCode.U: "U";
			case KeyCode.V: "V";
			case KeyCode.W: "W";
			case KeyCode.X: "X";
			case KeyCode.Y: "Y";
			case KeyCode.Z: "Z";
			case KeyCode.NUMBER_0: "0";
			case KeyCode.NUMBER_1: "1";
			case KeyCode.NUMBER_2: "2";
			case KeyCode.NUMBER_3: "3";
			case KeyCode.NUMBER_4: "4";
			case KeyCode.NUMBER_5: "5";
			case KeyCode.NUMBER_6: "6";
			case KeyCode.NUMBER_7: "7";
			case KeyCode.NUMBER_8: "8";
			case KeyCode.NUMBER_9: "9";
			default: 'KEY $code';
		}
	}
}
