package structures.options;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;

/**
	Handles the display and interaction for the controls options in the options menu.
	Uses the shared FreeplayAlphabet instance for the list and a combined Text element
	for instructions and keybind info at the top-right.
	@since 0.94
**/
@:publicFields
class ControlsDisplay implements IAlphabetScrollHost {
	public static var controlLabels(default, null):Array<String> = [
		"UI Left",
		"UI Down",
		"UI Up",
		"UI Right",
		"UI Accept",
		"UI Back",
		"Pause",
		"Reset",
		"Debug",
		"Mania"
	];

	public static var controlFields(default, null):Array<String> = [
		"ui.left",
		"ui.down",
		"ui.up",
		"ui.right",
		"ui.accept",
		"ui.back",
		"game.pause",
		"game.reset",
		"game.debug"
	];

	// Descriptions for each control label (matching order)
	static var controlDescriptions:Array<String> = [
		"Move cursor left in menus.",
		"Move cursor down in menus.",
		"Move cursor up in menus.",
		"Move cursor right in menus.",
		"Select / confirm an option.",
		"Go back to previous menu.",
		"Pause the game during gameplay.",
		"Instantly blueball in the current song.",
		"Enter the gameplay's play area (debug mode).",
		"Unique keybinds per key count (Mania mode)."
	];

	inline static var INSTRUCTIONS_TEXT = "KEYBINDING Instructions:\nPress TAB to begin binding\nPress ESC to cancel binding\n\n"
		+ "MANIA Instructions:\nPress DEBUG to swap between #M1#KEY1#M1# and #M2#KEY2#M2# modes\n"
		+ "\nWhile you bind your mania, you press each key in order\nWhen you bind:\nPress CTRL+Left or CTRL+Right to change MANIA\n"
		+ "Press ALT+Up or ALT+Down to switch slot\nPress BACK to reset current MANIA\n"
		+ "Press RESET to remove binding (#M2#KEY2#M2# only)";

	var parent(default, null):OptionsMenu;
	var options(default, null):Array<OptionsSprite> = [];
	var alphabet(default, null):FreeplayAlphabet; // shared instance
	var infoText(default, null):Text; // shared description/instruction text

	var bindingIndex:Int = -1;
	var binding:Bool = false;
	var processingBinding:Bool = false;

	@:isVar var curManiaNum(get, set):Int = 3;

	inline function get_curManiaNum()
		return curManiaNum;

	inline function set_curManiaNum(value:Int) {
		if (value >= 9)
			value = 0;
		if (value < 0)
			value = 8;
		return curManiaNum = value;
	}

	var bindingMania:Bool = false;
	var maniaBindNum(default, null):Int = 0;
	var maniaSubBindNum(default, null):Int = 0;
	var lastBindingTime:Float = 0;

	var alertDupebind:Bool = false;
	var alertDupebindKeyName:String = "";
	var alertDupebindConflictName:String = "";
	var alertKeybindReset:Bool = false;

	var _lastInfoText:String = null; // last string pushed to the shared infoText

	var xLerp:Float = 0.0;
	var curSelectedLerp:Float = 0.0;
	var curSelectedTarget:Float = 0.0;
	var alphaLerp:Float = 0.0;

	var closed:Bool;

	function new(parent:OptionsMenu, alphabet:FreeplayAlphabet, infoText:Text) {
		this.parent = parent;
		this.alphabet = alphabet;
		this.infoText = infoText;

		// Set marker pairs on the shared infoText (only needed once)
		var subBindMarkup = [
			new TextFormatMarkerPair('#M1#', Color.CYAN),
			new TextFormatMarkerPair('#M2#', 0xFF5353FF),
			new TextFormatMarkerPair('#M3#', 0xFFFF5353)
		];
		infoText.setMarkerPairs(subBindMarkup);
	}

	function reload() {
		destroyOptions();
		alphabet.setHost(this);
		alphabet.reload();
		closed = false;
		_lastInfoText = null;

		resetHostState();
		binding = false;
		bindingIndex = -1;
		processingBinding = false;
	}

	function resetHostState() {
		xLerp = 0.0;
		curSelectedLerp = 0.0;
		curSelectedTarget = 0.0;
		alphaLerp = 0.0;
	}

	function tab() {
		if (binding || processingBinding || bindingMania || closed)
			return;

		bindingIndex = parent.optionsNav.value();
		if (bindingIndex >= controlFields.length)
			bindingMania = true;
		else
			binding = true;

		parent.removeEvents();
		Application.current.window.onKeyDown.add(onKeyDown);
		Main.current.playScrollSound();
	}

	function update(deltaTime:Float) {
		if (alphabet == null || closed)
			return;

		var ratio = Math.max(Math.min(deltaTime * 0.015, 1), 0.00001);
		if (ratio == 1)
			ratio = (1 / lime.app.Application.current.window.frameRate) * 0.015;

		alphaLerp = Tools.lerp(alphaLerp, parent.opened ? 1.0 : 0.0, ratio);
		curSelectedTarget = parent.optionsNav.value();
		curSelectedLerp = Tools.lerp(curSelectedLerp, curSelectedTarget, ratio);
		xLerp = 20 - (curSelectedLerp * 20);

		// Build the combined text for the info box
		var combined = "";
		var selectedIndex = Math.round(curSelectedTarget);

		// Add description of the selected item (if not in mania or binding)
		if (!bindingMania && !binding && selectedIndex >= 0 && selectedIndex < controlLabels.length) {
			var desc = controlDescriptions[selectedIndex] != null ? controlDescriptions[selectedIndex] : "";
			if (desc != "") {
				combined += controlLabels[selectedIndex] + ": " + desc + "\n\n";
			}
		}

		// Append instructions and dynamic binding info
		combined += INSTRUCTIONS_TEXT + "\n\n";
		if (bindingMania) {
			var str = "KEYBINDS\nUSING " + (maniaSubBindNum == 1 ? "#M2#KEY2#M2#" : "#M1#KEY1#M1#") + "\n";
			if (alertDupebind) {
				str += '#M3#${alertDupebindKeyName} is already bound to:\n${alertDupebindConflictName}\nTry a different key.#M3#\n';
			} else if (alertKeybindReset) {
				str += '#M3#Successfully reset current MANIA.#M3#\n';
			} else {
				str += "#M3#Currently binding...#M3#\n";
			}
			var keybindArr = SaveData.state.controls.game.keybindArray[curManiaNum];
			for (k in 0...keybindArr.length) {
				var maniaBinds = keybindArr[k];
				str += (maniaBindNum == k && maniaSubBindNum == 0) ? "#M1#[ #M1#" : "[ ";
				for (i in 0...maniaBinds.length) {
					if (maniaSubBindNum == i)
						str += '#M${maniaSubBindNum + 1}#';
					str += KeyCodeConverter.getSimpleKeyName(maniaBinds[i]);
					if (maniaSubBindNum == i)
						str += '#M${maniaSubBindNum + 1}#';
					if (i != maniaBinds.length - 1)
						str += ", ";
				}
				str += (maniaBindNum == k && maniaSubBindNum == 1) ? "#M2# ]#M2#" : " ]";
				str += "\n";
			}
			combined += str;
		} else {
			if (alertDupebind) {
				combined += '#M3#${alertDupebindKeyName} is already bound to:\n${alertDupebindConflictName}\nTry a different key.#M3#\n';
			} else {
				combined += "KEYBINDS\n";
				combined += binding ? "#M3#Currently binding...#M3#\n" : "...";
			}
		}

		//BOTTLENECK: high per-frame info-text rebuild: string concat allocations + set_text() full compare/relayout every frame | FIX: only rebuild when selection/binding/mania state changed; cache last built string
		if (combined != _lastInfoText) {
			_lastInfoText = combined;
			infoText.text = combined;
			// Position at top-right (align right by setting x = width‑4)
			infoText.x = Main.INITIAL_WIDTH - infoText.width - 4;
			infoText.y = 4;
		}

		// Show/hide based on conditions
		var show = parent.opened
			&& ((curSelectedTarget >= 0 && curSelectedTarget < controlFields.length + 1) || alertDupebind || binding || bindingMania);
		infoText.alpha = Tools.lerp(infoText.alpha, show ? 1.0 : 0.0, ratio);

		alphabet.setDeltaTime(deltaTime);
		var incrementBest = controlLabels.length > 7 ? Math.floor(Math.min(Math.max(curSelectedLerp - 3, 0), controlLabels.length - 7)) : 0;

		for (i in 0...7) {
			alphabet.updateRowText(i, incrementBest);
		}
		alphabet.buffer.update();
	}

	function cancelBinding() {
		var removeEvents = false;
		if (binding) {
			binding = false;
			bindingIndex = -1;
			processingBinding = false;
			removeEvents = true;
		}
		if (bindingMania) {
			bindingMania = false;
			maniaBindNum = 0;
			removeEvents = true;
		}
		if (parent != null && parent.opened && removeEvents) {
			parent.addEvents();
			Application.current.window.onKeyDown.remove(onKeyDown);
			Main.current.playCancelSound();
		}
		SaveData.save();
	}

	function onKeyDown(keyCode:KeyCode, keyModifier:KeyModifier) {
		if (closed)
			return;

		var BIND_KEY = KeyCode.TAB;

		if (keyCode == KeyCode.ESCAPE) {
			cancelBinding();
			return;
		}
		if (keyCode == BIND_KEY && !binding && !processingBinding && !closed) {
			tab();
			return;
		}

		if (bindingMania) {
			if (keyCode == BIND_KEY || keyCode == KeyCode.ESCAPE)
				return;
			if ((keyModifier == KeyModifier.LEFT_CTRL || keyModifier == KeyModifier.RIGHT_CTRL)) {
				switch (keyCode) {
					case KeyCode.LEFT:
						curManiaNum--;
						Main.current.playScrollSound();
					case KeyCode.RIGHT:
						curManiaNum++;
						Main.current.playScrollSound();
					default:
				}
				return;
			}
			if ((keyModifier == KeyModifier.LEFT_ALT || keyModifier == KeyModifier.RIGHT_ALT)) {
				var keybindsArr = SaveData.state.controls.game.keybindArray[curManiaNum];
				switch (keyCode) {
					case KeyCode.UP:
						maniaBindNum = Std.int(Math.max(0, maniaBindNum - 1));
						Main.current.playScrollSound();
					case KeyCode.DOWN:
						maniaBindNum = Std.int(Math.min(keybindsArr.length - 1, maniaBindNum + 1));
						Main.current.playScrollSound();
					default:
				}
				return;
			}
			applyManiaBinding(keyCode);
			return;
		}

		if (binding && !processingBinding && !closed) {
			if (keyCode == BIND_KEY || keyCode == KeyCode.ESCAPE)
				return;
			var now = haxe.Timer.stamp();
			if (now - lastBindingTime < 0.5)
				return;
			lastBindingTime = now;
			applyBinding(keyCode);
		}
	}

	function findManiaConflict(keyCode:KeyCode, maniaId:Int, currentSlot:Int, currentSub:Int):String {
		var keybindsArr = SaveData.state.controls.game.keybindArray[maniaId];
		for (s in 0...keybindsArr.length) {
			var slot = keybindsArr[s];
			for (sub in 0...slot.length) {
				if (slot[sub] == keyCode && !(s == currentSlot && sub == currentSub)) {
					return 'Slot ${s + 1} ${sub == 0 ? "KEY1" : "KEY2"}';
				}
			}
		}
		return "";
	}

	function findConflict(keyCode:KeyCode, currentIndex:Int, alertOnUI:Bool = true):String {
		var ui = SaveData.state.controls.ui;
		var game = SaveData.state.controls.game;

		if (game.pause == keyCode && 6 != currentIndex)
			return controlLabels[6];
		if (game.reset == keyCode && 7 != currentIndex)
			return controlLabels[7];
		if (game.debug == keyCode && 8 != currentIndex)
			return controlLabels[8];

		if (!alertOnUI)
			return "";
		if (ui.left == keyCode && 0 != currentIndex)
			return controlLabels[0];
		if (ui.down == keyCode && 1 != currentIndex)
			return controlLabels[1];
		if (ui.up == keyCode && 2 != currentIndex)
			return controlLabels[2];
		if (ui.right == keyCode && 3 != currentIndex)
			return controlLabels[3];
		if (ui.accept == keyCode && 4 != currentIndex)
			return controlLabels[4];
		if (ui.back == keyCode && 5 != currentIndex)
			return controlLabels[5];

		return "";
	}

	function applyBinding(keyCode:KeyCode) {
		if (isInvalidKey(keyCode))
			return;
		if (processingBinding)
			return;
		processingBinding = true;

		if (bindingIndex < 0 || bindingIndex >= controlFields.length) {
			cancelBinding();
			processingBinding = false;
			return;
		}

		var field = controlFields[bindingIndex];
		var parts = field.split(".");
		var conflictName = findConflict(keyCode, bindingIndex);
		if (parts.length < 2 || conflictName != "") {
			cancelBinding();
			processingBinding = false;
			if (conflictName != "") {
				alertDupebind = true;
				alertDupebindKeyName = KeyCodeConverter.getSimpleKeyName(keyCode);
				alertDupebindConflictName = conflictName;
				haxe.Timer.delay(() -> {
					alertDupebind = false;
					alertDupebindKeyName = "";
					alertDupebindConflictName = "";
				}, 7000);
			}
			return;
		}

		var category = parts[0];
		var name = parts[1];
		if (category == "ui") {
			Reflect.setProperty(SaveData.state.controls.ui, name, keyCode);
		} else if (category == "game") {
			Reflect.setProperty(SaveData.state.controls.game, name, keyCode);
		}

		binding = false;
		bindingIndex = -1;
		SaveData.save();
		Main.current.controls.reload();

		if (alphabet != null && !closed) {
			alphabet.buffer.update();
		}

		if (parent != null && parent.opened) {
			parent.addEvents();
			Application.current.window.onKeyDown.remove(onKeyDown);
		}

		Main.current.playConfirmSound();
		processingBinding = false;
	}

	inline function isInvalidKey(keyCode:KeyCode) {
		var result = false;
		result = (keyCode >= 0x4000003A && keyCode < 0x40000045)
			|| (keyCode >= 0x40000068 && keyCode < 0x40000073)
			|| (keyCode >= 0x400000E0 && keyCode < 0x400000E7)
			|| (keyCode >= 0x40000074 && keyCode < 0x4000007F);
		switch (keyCode) {
			case KeyCode.VOLUME_DOWN | KeyCode.VOLUME_UP | KeyCode.INSERT | KeyCode.DELETE | KeyCode.PRINT_SCREEN | KeyCode.CAPS_LOCK | KeyCode.HOME | KeyCode.END | KeyCode.SCROLL_LOCK | KeyCode.PAUSE | KeyCode.BRIGHTNESS_DOWN | KeyCode.BRIGHTNESS_UP | KeyCode.BACKLIGHT_DOWN | KeyCode.BACKLIGHT_UP:
				result = true;
			default:
		}
		return result;
	}

	function applyManiaBinding(keyCode:KeyCode) {
		if (isInvalidKey(keyCode))
			return;

		var controls = SaveData.state.controls;
		if (keyCode == controls.game.debug) {
			Main.current.playCancelSound();
			maniaSubBindNum++;
			maniaSubBindNum %= 2;
			return;
		}

		var id = curManiaNum;
		var keybindsArr = controls.game.keybindArray[id];
		var keybindArr = keybindsArr[maniaBindNum];

		if (keyCode == controls.ui.back) {
			var defaults = SaveData.getDefaultState();
			controls.game.keybindArray[id] = defaults.controls.game.keybindArray[id];
			alertKeybindReset = true;
			haxe.Timer.delay(() -> {
				alertKeybindReset = false;
			}, 3000);
			maniaBindNum = 0;
			SaveData.save();
			Main.current.playCancelSound();
		} else {
			if (keyCode == controls.game.reset && maniaSubBindNum == 1) {
				keybindArr[maniaSubBindNum] = KeyCode.UNKNOWN;
			} else {
				var maniaConflict = findManiaConflict(keyCode, id, maniaBindNum, maniaSubBindNum);
				if (maniaConflict != "") {
					alertDupebind = true;
					alertDupebindKeyName = KeyCodeConverter.getSimpleKeyName(keyCode);
					alertDupebindConflictName = maniaConflict;
					haxe.Timer.delay(() -> {
						alertDupebind = false;
						alertDupebindKeyName = "";
						alertDupebindConflictName = "";
					}, 7000);
					Main.current.playCancelSound();
					return;
				}
				var uiGameConflict = findConflict(keyCode, -1, false);
				if (uiGameConflict != "") {
					alertDupebind = true;
					alertDupebindKeyName = KeyCodeConverter.getSimpleKeyName(keyCode);
					alertDupebindConflictName = uiGameConflict;
					haxe.Timer.delay(() -> {
						alertDupebind = false;
						alertDupebindKeyName = "";
						alertDupebindConflictName = "";
					}, 7000);
					Main.current.playCancelSound();
					return;
				}
				keybindArr[maniaSubBindNum] = keyCode;
			}
			maniaBindNum++;
			Main.current.playScrollSound();
		}

		var playField = Main.current.playField;
		if (playField != null) {
			if (playField.mania == curManiaNum + 1) {
				var noteSystem = playField.noteSystem;
				if (noteSystem != null) {
					var strumlines = noteSystem.strumlines;
					for (i in 0...strumlines.length) {
						strumlines[i].updateKeybinds();
					}
				}
			}
		}

		if (maniaBindNum <= keybindsArr.length - 1) {
			return;
		}

		bindingMania = false;
		maniaBindNum = 0;
		fixMania();
		SaveData.save();
		Main.current.controls.reload();

		if (parent != null && parent.opened) {
			parent.addEvents();
			Application.current.window.onKeyDown.remove(onKeyDown);
		}
	}

	function fixMania() {
		var id = curManiaNum;
		var keybindsArr = SaveData.state.controls.game.keybindArray[id];
		for (i in 0...keybindsArr.length) {
			for (j in 0...keybindsArr[i].length) {
				if (keybindsArr[i][j] == KeyCode.UNKNOWN)
					keybindsArr[i].remove(keybindsArr[i][j]);
			}
		}
	}

	function destroyOptions() {
		if (closed)
			return;
		closed = true;

		if (binding)
			cancelBinding();
		resetHostState();

		while (options.length != 0) {
			var option = options.pop();
			try {
				OptionsMenu.optionsBuf.removeElement(option);
			} catch (e) {}
		}
	}

	function dispose() {
		destroyOptions();
		// Do not dispose infoText or alphabet – they are shared.
	}

	function alphabetListLength():Int {
		return controlLabels.length;
	}

	function alphabetItemTitle(index:Int):String {
		if (index < 0 || index >= controlLabels.length)
			return "";
		if (index < controlLabels.length) {
			var str = controlLabels[index];
			for (i in 0...16 - str.length)
				str += " ";
			if (binding && bindingIndex == index) {
				str += "listening...";
			} else if (controlLabels[index] != "Mania") {
				str += keyNameForIndex(index);
			} else {
				str += '${curManiaNum + 1}K';
			}
			return str;
		}
		return controlLabels[index];
	}

	function alphabetItemDisabled(index:Int):Bool {
		return false;
	}

	function keyNameForIndex(index:Int):String {
		var rawKey:KeyCode = 0;
		switch (index) {
			case 0:
				rawKey = SaveData.state.controls.ui.left;
			case 1:
				rawKey = SaveData.state.controls.ui.down;
			case 2:
				rawKey = SaveData.state.controls.ui.up;
			case 3:
				rawKey = SaveData.state.controls.ui.right;
			case 4:
				rawKey = SaveData.state.controls.ui.accept;
			case 5:
				rawKey = SaveData.state.controls.ui.back;
			case 6:
				rawKey = SaveData.state.controls.game.pause;
			case 7:
				rawKey = SaveData.state.controls.game.reset;
			case 8:
				rawKey = SaveData.state.controls.game.debug;
			default:
				rawKey = 0;
		}
		return KeyCodeConverter.getSimpleKeyName(rawKey);
	}
}
