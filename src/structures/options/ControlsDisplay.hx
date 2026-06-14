package structures.options;

import data.SaveData;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import structures.FreeplayAlphabet;
import structures.IAlphabetScrollHost;
import structures.OptionsMenu;

/**
	Handles the display and interaction for the controls options in the options menu.
	Provides a simple vertical keybind list and live binding flow.
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
		"Mania"  // Single unified entry
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
		"game.debug",
		"game.mania"  // Special marker
	];

	inline static var INSTRUCTIONS_TEXT = "Press TAB to begin binding\nPress ESC to cancel binding\n\n" +
		"During Mania binding:\nPress CTRL+LEFT/RIGHT to change key count (1K-9K)\n" +
		"Press DEBUG to swap between #M1#PRIMARY#M1# and #M2#SECONDARY#M2# keys\n" +
		"Press RESET to clear current key\nPress BACK to reset all keys for current Mania mode";
	inline static var DUPLICATE_BIND_ALERT_TEXT = 'Either it\'s the same key you entered, or\nanother keybind was already registered as\n' +
		'the key you attempted to bind on.\nTry a different key first.';
	inline static var RESET_BIND_ALERT_TEXT = 'Successfully reset $maniaKeyCountK Mania mode.';

	var parent(default, null):OptionsMenu;
	var options(default, null):Array<OptionsSprite> = [];
	static var alphabet(default, null):FreeplayAlphabet;

	var bindingIndex:Int = -1;
	var binding:Bool = false;
	var processingBinding:Bool = false;
	var bindingMania:Bool = false;
	var maniaKeyCount:Int = 4;  // Session-persistent, starts at 4K
	var maniaCurrentLane:Int = 0;  // Which lane we're binding (0 to maniaKeyCount-1)
	var maniaSubBindNum:Int = 0;  // 0 for primary key, 1 for secondary
	var lastBindingTime:Float = 0;

	var alertDupebind:Bool = false;
	var alertKeybindReset:Bool = false;

	var xLerp:Float = 0.0;
	var curSelectedLerp:Float = 0.0;
	var curSelectedTarget:Float = 0.0;
	var alphaLerp:Float = 0.0;

	static var maniaKeybindTxt(default, null):Text;
	static var instructionsTxt(default, null):Text;
	static var bindBox(default, null):Text;

    var closed:Bool;

	function new(parent:OptionsMenu) {
		this.parent = parent;
	}

	function reload() {
		destroyOptions();
        if (alphabet == null) {
            alphabet = new FreeplayAlphabet(this, OptionsMenu.display);
        }
        alphabet.ensurePrograms();
        alphabet.reload();
        alphabet.addPrograms();
        closed = false;

		var subBindMarkup = [new TextFormatMarkerPair('#M1#', Color.CYAN), new TextFormatMarkerPair('#M2#', 0xFF5353FF), new TextFormatMarkerPair('#M3#', 0xFFFF5353)];

		if (maniaKeybindTxt == null) {
			maniaKeybindTxt = new Text("FUNKIN_VIEW_KEYBIND_TXT", 0, 300, alphabet.display, "KEYBINDS\nNONE", "vcr");
			maniaKeybindTxt.multiline = true;
			maniaKeybindTxt.alignment = RIGHT;
			maniaKeybindTxt.alpha = 0;
			maniaKeybindTxt.outlineColor = Color.BLACK;
			maniaKeybindTxt.outlineSize = 1.4;
			maniaKeybindTxt.x = Main.VARIABLE_WIDTH - (maniaKeybindTxt.width + 4);
			maniaKeybindTxt.setMarkerPairs(subBindMarkup);
		}

		if (instructionsTxt == null) {
			instructionsTxt = new Text("FUNKIN_VIEW_CONTROLS_INSTRUCTIONS_TXT", 4, 3, alphabet.display, "", "vcr");
			instructionsTxt.alpha = 0;
			instructionsTxt.multiline = true;
			instructionsTxt.alignment = RIGHT;
			instructionsTxt.outlineColor = Color.BLACK;
			instructionsTxt.outlineSize = 1.4;
			instructionsTxt.setMarkerPairs(subBindMarkup);
			instructionsTxt.text = INSTRUCTIONS_TEXT;
			instructionsTxt.x = Main.VARIABLE_WIDTH - (instructionsTxt.width + 4);
		}

		if (bindBox == null) {
			bindBox = new Text("FUNKIN_BIND_BOX", 0, 0, alphabet.display, "", "vcr");
			bindBox.multiline = true;
			bindBox.alignment = CENTER;
			bindBox.alpha = 0;
			bindBox.outlineColor = Color.BLACK;
			bindBox.outlineSize = 1.6;
			bindBox.x = (Main.VARIABLE_WIDTH * 0.5) - (bindBox.width * 0.5);
			bindBox.y = (Main.VARIABLE_HEIGHT * 0.5) - (bindBox.height * 0.5);
		}

		if (!OptionsMenu.optionsDisplay.closed) showTexts();
        
		resetHostState();
		
		binding = false;
		bindingIndex = -1;
		processingBinding = false;
	}

	function showTexts() {
		if (maniaKeybindTxt != null) maniaKeybindTxt.addProgram();
		if (instructionsTxt != null) instructionsTxt.addProgram();
	}

	function removeTexts() {
		if (maniaKeybindTxt != null) maniaKeybindTxt.removeProgram();
		if (instructionsTxt != null) instructionsTxt.removeProgram();
		if (bindBox != null) bindBox.removeProgram();
	}
	
	function resetHostState() {
		xLerp = 0.0;
		curSelectedLerp = 0.0;
		curSelectedTarget = 0.0;
		alphaLerp = 0.0;
	}

	function tab() {
		if (binding || processingBinding || bindingMania || closed) return;
		
		bindingIndex = parent.optionsNav.value();
		if (bindingIndex >= controlFields.length - 1) {
			bindingMania = true;
			maniaCurrentLane = 0;
			maniaSubBindNum = 0;
		} else binding = true;

		parent.removeEvents();
		Application.current.window.onKeyDown.add(onKeyDown);
		
		if (bindBox != null) {
			if (bindingMania) {
				bindBox.text = "Mania Mode: $maniaKeyCountK\nBinding Lane ${maniaCurrentLane + 1}/$maniaKeyCount\n" +
					"Press CTRL+LEFT/RIGHT to change key count\nPress ESC to cancel";
			} else bindBox.text = "Press a key to bind\nPress ESC to cancel";
			bindBox.addProgram();
		}
		
		Main.current.playScrollSound();
	}

	function update(deltaTime:Float) {
		if (alphabet == null || closed) return;

		var ratio = Math.max(Math.min(deltaTime * 0.015, 1), 0.00001);
		if (ratio == 1) ratio = (1 / lime.app.Application.current.window.frameRate) * 0.015;

		alphaLerp = Tools.lerp(alphaLerp, parent.opened ? 1.0 : 0.0, ratio);
		curSelectedTarget = parent.optionsNav.value();
		curSelectedLerp = Tools.lerp(curSelectedLerp, curSelectedTarget, ratio);
		xLerp = 20 - (curSelectedLerp * 20);

		var isManiaSelected = (curSelectedTarget >= controlFields.length - 1);
		maniaKeybindTxt.alpha = Tools.lerp(maniaKeybindTxt.alpha, (isManiaSelected || alertDupebind) ? 1.0 : 0.0, ratio);
		
		if (isManiaSelected) {
			var str = 'MANIA $maniaKeyCountK\n';
			str += 'Editing: #M${maniaSubBindNum + 1}#${maniaSubBindNum == 0 ? "PRIMARY" : "SECONDARY"}#M${maniaSubBindNum + 1}#\n\n';
			if (alertKeybindReset) str += '#M3#' + RESET_BIND_ALERT_TEXT + '#M3#\n\n';
			else str += "\n";
			
			var keybinds = SaveData.state.controls.game.keybindArray[maniaKeyCount - 1];
			for (lane in 0...keybinds.length) {
				var laneNum = lane + 1;
				str += 'LANE $laneNum: [ ';
				
				for (i in 0...keybinds[lane].length) {
					if (maniaCurrentLane == lane && maniaSubBindNum == i && bindingMania) {
						str += '#M${i + 1}#';
					}
					str += KeyCodeConverter.getSimpleKeyName(keybinds[lane][i]);
					if (maniaCurrentLane == lane && maniaSubBindNum == i && bindingMania) {
						str += '#M${i + 1}#';
					}
					if (i < keybinds[lane].length - 1) str += ', ';
				}
				str += ' ]\n';
			}
			maniaKeybindTxt.text = str;
		} else {
			if (alertDupebind) maniaKeybindTxt.text = '#M3#$DUPLICATE_BIND_ALERT_TEXT#M3#\n\n\n\n\n';
			else maniaKeybindTxt.text = "KEYBINDS\n...";
		}
		
		maniaKeybindTxt.x = Main.VARIABLE_WIDTH - (maniaKeybindTxt.width + 4);
		maniaKeybindTxt.y = (Main.VARIABLE_HEIGHT * 0.5) - (maniaKeybindTxt.height * 0.5);
		instructionsTxt.alpha = alphaLerp;

		if (bindBox != null) {
			bindBox.x = (Main.VARIABLE_WIDTH * 0.5) - (bindBox.width * 0.5);
			bindBox.y = (Main.VARIABLE_HEIGHT * 0.5) - (bindBox.height * 0.5);
			if (binding || bindingMania || alertDupebind) bindBox.alpha = Tools.lerp(bindBox.alpha, 1.0, ratio);
			else bindBox.alpha = Tools.lerp(bindBox.alpha, 0.0, ratio);
		}

		alphabet.setDeltaTime(deltaTime);
		var incrementBest = controlLabels.length > 7
			? Math.floor(Math.min(Math.max(curSelectedLerp - 3, 0), controlLabels.length - 7))
			: 0;

		for (i in 0...7) {
			alphabet.updateRowText(i, incrementBest);
		}
		alphabet.updateBuffer();
	}

	function cancelBinding() {
		if (binding) {
			binding = false;
			bindingIndex = -1;
			processingBinding = false;
		}

		if (bindingMania) {
			bindingMania = false;
			maniaCurrentLane = 0;
			maniaSubBindNum = 0;
		}

		if (bindBox != null) bindBox.removeProgram();

		if (parent != null && parent.opened) {
			parent.addEvents();
			Application.current.window.onKeyDown.remove(onKeyDown);
		}
		
		Main.current.playCancelSound();
	}

	function onKeyDown(keyCode:KeyCode, keyModifier:KeyModifier) {
		if (closed) return;
		
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
			if (keyCode == BIND_KEY || keyCode == KeyCode.ESCAPE) return;
			
			// Change mania key count with CTRL+LEFT/RIGHT
			if (keyModifier.ctrl) {
				if (keyCode == KeyCode.LEFT) {
					maniaKeyCount = Math.max(1, maniaKeyCount - 1);
					maniaCurrentLane = 0;
					maniaSubBindNum = 0;
					Main.current.playScrollSound();
					if (bindBox != null) bindBox.text = "Mania Mode: $maniaKeyCountK\nBinding Lane ${maniaCurrentLane + 1}/$maniaKeyCount\nPress ESC to cancel";
				} else if (keyCode == KeyCode.RIGHT) {
					maniaKeyCount = Math.min(9, maniaKeyCount + 1);
					maniaCurrentLane = 0;
					maniaSubBindNum = 0;
					Main.current.playScrollSound();
					if (bindBox != null) bindBox.text = "Mania Mode: $maniaKeyCountK\nBinding Lane ${maniaCurrentLane + 1}/$maniaKeyCount\nPress ESC to cancel";
				}
				return;
			}
			
			applyManiaBinding(keyCode);
			return;
		}
	
		if (binding && !processingBinding && !closed) {
			if (keyCode == BIND_KEY || keyCode == KeyCode.ESCAPE) return;
			
			var now = haxe.Timer.stamp();
			if (now - lastBindingTime < 0.5) return;
			lastBindingTime = now;
			
			if (bindBox != null) bindBox.text = "Binding: " + KeyCodeConverter.getSimpleKeyName(keyCode) + "\nPress ESC to cancel";
			
			applyBinding(keyCode);
		}
	}

	function ui_isSameKeyOrDupe(keyCode:KeyCode) {
		var ui = SaveData.state.controls.ui;
		return (ui.left == keyCode || ui.down == keyCode || ui.up == keyCode || ui.right == keyCode) ||
			(ui.accept == keyCode || ui.back == keyCode);
	}

	function game_isSameKeyOrDupe(keyCode:KeyCode) {
		var game = SaveData.state.controls.game;
		return (game.pause == keyCode || game.reset == keyCode || game.debug == keyCode);
	}

	function applyBinding(keyCode:KeyCode) {
		if (processingBinding) return;
		processingBinding = true;
		
		if (bindingIndex < 0 || bindingIndex >= controlFields.length - 1) {
			cancelBinding();
			processingBinding = false;
			return;
		}
		
		var field = controlFields[bindingIndex];
		var parts = field.split(".");

		var category = parts[0];
		var name = parts[1];
		
		var isDupeBind = category == "game" ? game_isSameKeyOrDupe(keyCode) : ui_isSameKeyOrDupe(keyCode);
		if (parts.length < 2 || isDupeBind) {
			cancelBinding();
			processingBinding = false;
			if (isDupeBind) {
				alertDupebind = true;
				haxe.Timer.delay(() -> {alertDupebind = false;}, 7000);
			}
			return;
		}
		
		if (category == "ui") {
			Reflect.setProperty(SaveData.state.controls.ui, name, keyCode);
		} else if (category == "game") {
			Reflect.setProperty(SaveData.state.controls.game, name, keyCode);
		}
		
		if (bindBox != null) bindBox.removeProgram();
		
		binding = false;
		bindingIndex = -1;
		
		SaveData.save();
		Main.current.controls.reload();
		
		if (parent != null && parent.opened) {
			parent.addEvents();
			Application.current.window.onKeyDown.remove(onKeyDown);
		}
		
		Main.current.playConfirmSound();
		processingBinding = false;
	}

	function applyManiaBinding(keyCode:KeyCode) {
		var game = SaveData.state.controls.game;
		
		// DEBUG key toggles between primary/secondary
		if (keyCode == game.debug) {
			Main.current.playCancelSound();
			maniaSubBindNum = (maniaSubBindNum + 1) % 2;
			if (bindBox != null) {
				bindBox.text = "Mania Mode: $maniaKeyCountK\nBinding Lane ${maniaCurrentLane + 1}/$maniaKeyCount\n" +
					"Editing ${maniaSubBindNum == 0 ? "PRIMARY" : "SECONDARY"} key\nPress ESC to cancel";
			}
			return;
		}
		
		var keybindsForCount = game.keybindArray[maniaKeyCount - 1];
		
		// BACK key resets all lanes for current mania count
		if (keyCode == SaveData.state.controls.ui.back) {
			Main.current.playCancelSound();
			var defaultState = SaveData.getDefaultState();
			game.keybindArray[maniaKeyCount - 1] = defaultState.controls.game.keybindArray[maniaKeyCount - 1];
			alertKeybindReset = true;
			haxe.Timer.delay(() -> {alertKeybindReset = false;}, 3000);
			SaveData.save();
			cancelBinding();
			return;
		}
		
		// RESET key clears current key
		if (keyCode == game.reset) {
			Main.current.playScrollSound();
			keybindsForCount[maniaCurrentLane][maniaSubBindNum] = KeyCode.UNKNOWN;
			cleanManiaKeys();
			SaveData.save();
			
			// Move to next lane after reset
			maniaCurrentLane++;
			if (maniaCurrentLane >= maniaKeyCount) {
				cancelBinding();
				Main.current.playConfirmSound();
			} else {
				if (bindBox != null) {
					bindBox.text = "Mania Mode: $maniaKeyCountK\nBinding Lane ${maniaCurrentLane + 1}/$maniaKeyCount\n" +
						"Editing ${maniaSubBindNum == 0 ? "PRIMARY" : "SECONDARY"} key\nPress ESC to cancel";
				}
			}
			return;
		}
		
		// Bind the key
		keybindsForCount[maniaCurrentLane][maniaSubBindNum] = keyCode;
		cleanManiaKeys();
		SaveData.save();
		
		// Move to next lane
		maniaCurrentLane++;
		if (maniaCurrentLane >= maniaKeyCount) {
			// Finished all lanes
			cancelBinding();
			Main.current.playConfirmSound();
		} else {
			Main.current.playScrollSound();
			if (bindBox != null) {
				bindBox.text = "Mania Mode: $maniaKeyCountK\nBinding Lane ${maniaCurrentLane + 1}/$maniaKeyCount\n" +
					"Editing ${maniaSubBindNum == 0 ? "PRIMARY" : "SECONDARY"} key\nPress ESC to cancel";
			}
		}
	}
	
	function cleanManiaKeys() {
		var keybinds = SaveData.state.controls.game.keybindArray;
		for (i in 0...keybinds.length) {
			for (j in 0...keybinds[i].length) {
				// Remove UNKNOWN keys from arrays
				for (k in 0...keybinds[i][j].length) {
					if (keybinds[i][j][k] == KeyCode.UNKNOWN) {
						keybinds[i][j].splice(k, 1);
						k--;
					}
				}
				// Ensure each lane has at least one key (add UNKNOWN if empty)
				if (keybinds[i][j].length == 0) {
					keybinds[i][j].push(KeyCode.UNKNOWN);
				}
			}
		}
	}

	function destroyOptions() {
		if (closed) return;
		
		closed = true;
		removeTexts();
		
		if (binding) cancelBinding();
		
		resetHostState();
		
		if (alphabet != null) {
			alphabet.shutDown();
			alphabet.dispose();
			alphabet = null;
		}
		
		while (options.length != 0) {
			var option = options.pop();
			try {
				OptionsMenu.optionsBuf.removeElement(option);
			} catch (e) {}
		}
	}

	function dispose() {
		destroyOptions();
	}

	function alphabetListLength():Int {
		return controlLabels.length;
	}

	function alphabetItemTitle(index:Int):String {
		if (index < 0 || index >= controlLabels.length) return "";
		if (index < controlFields.length - 1) {
			return controlLabels[index] + " - " + keyNameForIndex(index);
		}
		return controlLabels[index] + " - " + maniaKeyCount + "K (Current Mode)";
	}

	function keyNameForIndex(index:Int):String {
		var rawKey:KeyCode = 0;
		switch (index) {
			case 0: rawKey = SaveData.state.controls.ui.left;
			case 1: rawKey = SaveData.state.controls.ui.down;
			case 2: rawKey = SaveData.state.controls.ui.up;
			case 3: rawKey = SaveData.state.controls.ui.right;
			case 4: rawKey = SaveData.state.controls.ui.accept;
			case 5: rawKey = SaveData.state.controls.ui.back;
			case 6: rawKey = SaveData.state.controls.game.pause;
			case 7: rawKey = SaveData.state.controls.game.reset;
			case 8: rawKey = SaveData.state.controls.game.debug;
			default: rawKey = 0;
		}
		return KeyCodeConverter.getSimpleKeyName(rawKey);
	}
}
