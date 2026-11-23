package underlying.overlay;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import underlying.overlay.OptionsSubDisplay;

/**
	Handles the display and interaction for the controls options in the options menu.
	Uses the shared FreeplayAlphabet instance. ENTER starts the key listen for the
	selected row (mania binding on the Mania row); TAB is owned by OptionsMenu and
	switches categories (the "tab" sprite at the top-right corner hints at it).
	@since 0.94
**/
@:publicFields
class ControlsDisplay extends OptionsSubDisplay {
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

	// Deep copy of every mania's keybind slots, taken when mania binding mode
	// is entered. Cancelling the session (the ui.back keybind or ESC) restores
	// it, so an aborted session leaves the old keybind settings that were in
	// use for the mania untouched; committing (TAB, the ENTER toggle, or
	// filling the last slot) discards it.
	var maniaBindingSnapshot:Array<Array<Array<KeyCode>>> = null;

	var alertDupebind:Bool = false;
	var alertDupebindKeyName:String = "";
	var alertDupebindConflictName:String = "";

	var _lastInfoText:String = null; // last string pushed to the shared infoText

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
		bindingMania = false;
		maniaBindNum = 0;
		maniaSubBindNum = 0;
		maniaBindingSnapshot = null;
		alphaMultiplier = 1.0;
	}

	function resetHostState() {
		xLerp = 0.0;
		curSelectedLerp = 0.0;
		curSelectedTarget = 0.0;
		alphaLerp = 0.0;
	}

	/**
		TAB while mania binding is active: exit mania binding. (TAB is owned
		by OptionsMenu everywhere else — it switches categories; the "tab"
		sprite at the top-right corner hints at it.)
	**/
	function tab() {
		if (binding || processingBinding || closed)
			return;
		if (bindingMania) {
			bindingMania = false;
			maniaBindNum = 0;
			maniaSubBindNum = 0;
			// TAB exits with the changes kept — the snapshot is only for a
			// cancelled session.
			maniaBindingSnapshot = null;
			Main.current.playCancelSound();
		}
	}

	/**
		ENTER on the controls list: starts the key listen for the selected
		control row. On the Mania row it toggles mania binding mode — the
		whole options display goes half-transparent to make room for the
		mania input readout (only the current mania key and the key number
		are colored in it).
	**/
	function enter() {
		if (closed || binding || processingBinding)
			return;
		var selected = parent.optionsNav.value();
		if (selected == controlFields.length) {
			bindingMania = !bindingMania;
			maniaBindNum = 0;
			maniaSubBindNum = 0;
			// Entering the session snapshots every mania's keybinds (the
			// session can switch manias with ui.left/right); toggling it off
			// with ENTER keeps the changes, like TAB does.
			maniaBindingSnapshot = bindingMania ? snapshotManiaKeybinds() : null;
			Main.current.playScrollSound();
		} else if (selected >= 0 && selected < controlFields.length) {
			binding = true;
			bindingIndex = selected;
			Main.current.playScrollSound();
		}
	}

	override function update(deltaTime:Float) {
		if (alphabet == null || closed)
			return;

		var ratio = Math.max(Math.min(deltaTime * 0.015, 1), 0.00001);
		if (ratio == 1)
			ratio = (1 / lime.app.Application.current.window.frameRate) * 0.015;

		alphaLerp = Tools.lerp(alphaLerp, parent.opened ? 1.0 : 0.0, ratio);
		curSelectedTarget = parent.optionsNav.value();
		curSelectedLerp = Tools.lerp(curSelectedLerp, curSelectedTarget, ratio);
		xLerp = 20 - (curSelectedLerp * 20);

		// The whole options display goes half-transparent while the player
		// edits mania bindings (the tab hint dims along with it — see
		// OptionsMenu.update); the mania readout below is the one thing that
		// stays at full strength.
		alphaMultiplier = bindingMania ? 0.5 : 1.0;

		// The shared infoText only ever shows the mania input readout and the
		// binding alerts — no browsing descriptions (the "tab" sprite replaced
		// the old instruction texts). In the mania readout the current mania
		// key (#M1#) and the key number (#M2#) are colored; the bottom line is
		// the red (#M3#) cancel hint, naming the configured cancel keybind
		// (ui.back — the UI_BACK action OptionsMenu routes to cancelBinding(),
		// BACKSPACE by default) rather than a hard-coded key.
		var combined = "";
		if (bindingMania) {
			var keybindsArr = maniaKeybindArray(curManiaNum);
			var keyName = "...";
			if (maniaBindNum >= 0 && maniaBindNum < keybindsArr.length) {
				var slot = keybindsArr[maniaBindNum];
				if (slot != null && maniaSubBindNum >= 0 && maniaSubBindNum < slot.length)
					keyName = KeyCodeConverter.getSimpleKeyName(slot[maniaSubBindNum]);
			}
			var cancelKeyName = KeyCodeConverter.getSimpleKeyName(cast SaveData.state.controls.ui.back);
			combined = 'MANIA ${curManiaNum + 1}K\nKEY #M2#${maniaBindNum + 1}#M2#\n#M1#${keyName}#M1#\n#M3#Make sure to press ${cancelKeyName} to cancel.#M3#';
		}
		if (alertDupebind)
			combined = '#M3#${alertDupebindKeyName} is already bound to:\n${alertDupebindConflictName}\nTry a different key.#M3#';

		if (combined != _lastInfoText) {
			_lastInfoText = combined;

			// The mania readout is a big centered block: real line breaks
			// (multiline), double size, centered lines (the Text class's
			// alignment), centered on the screen.
			infoText.multiline = true;
			infoText.scale = 2;
			infoText.alignment = CENTER;
			infoText.text = combined;
			infoText.screenCenter();
		}
		var show = parent.opened && combined != "";
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
			maniaSubBindNum = 0;
			removeEvents = true;
			// Cancelling resets back to the old keybind settings that were in
			// use before the session started: restore the entry snapshot (it
			// covers every mania, since ui.left/right can switch the target
			// mania mid-session).
			if (maniaBindingSnapshot != null) {
				SaveData.state.controls.game.keybindArray = [
					for (mania in maniaBindingSnapshot) mania == null ? null : [for (slot in mania) slot == null ? null : slot.copy()]
				];
				maniaBindingSnapshot = null;
				// Same refresh the mania completion path does: reload the
				// action bindings, re-focus the menu's actions onto the fresh
				// handle, and refresh any live strumlines so they drop the
				// half-bound session keys.
				Main.current.controls.reload();
				if (parent != null && parent.opened) {
					Main.current.stateMachine.setFocus(parent);
				}
				refreshLiveStrumlines();
			}
		}
		if (parent != null && parent.opened && removeEvents) {
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
			// TAB and ESC stay reserved (they exit / cancel). The ui.back
			// keybind — the cancel key named in the readout's bottom line —
			// cancels the session through the menu's UI_BACK action
			// (OptionsMenu routes it to cancelBinding()), so it must never
			// register as a mania key either.
			if (keyCode == BIND_KEY || keyCode == KeyCode.ESCAPE || keyCode == SaveData.state.controls.ui.back)
				return;

			// Use the configured UI binds, not hard-coded keycodes. The accept
			// key is what toggles mania binding on/off (see enter()), so it must
			// never register as a mania keybind — otherwise the very ENTER that
			// opened the listen would bind itself to the first slot.
			var ui = SaveData.state.controls.ui;
			if (keyCode == ui.accept)
				return;
			var keybindsArr = maniaKeybindArray(curManiaNum);
			if (keyCode == ui.left) {
				curManiaNum--;
				maniaBindNum = 0;
				Main.current.playScrollSound();
			} else if (keyCode == ui.right) {
				curManiaNum++;
				maniaBindNum = 0;
				Main.current.playScrollSound();
			} else if (keyCode == ui.up) {
				maniaBindNum = Std.int(Math.max(0, maniaBindNum - 1));
				Main.current.playScrollSound();
			} else if (keyCode == ui.down) {
				maniaBindNum = Std.int(Math.min(keybindsArr.length - 1, maniaBindNum + 1));
				Main.current.playScrollSound();
			} else {
				applyManiaBinding(keyCode);
			}
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

	/**
		Returns the mania keybind slot list for `maniaId`, or an empty list when the
		loaded save file predates / omits that mania so callers never dereference null.
	**/
	function maniaKeybindArray(maniaId:Int):Array<Array<KeyCode>> {
		var all = SaveData.state.controls.game.keybindArray;
		if (all == null || maniaId < 0 || maniaId >= all.length || all[maniaId] == null)
			return [];
		return all[maniaId];
	}

	/**
		Deep copy of every mania's keybind slots — the "old keybind settings"
		that cancelling a mania binding session resets back to.
	**/
	function snapshotManiaKeybinds():Array<Array<Array<KeyCode>>> {
		var all = SaveData.state.controls.game.keybindArray;
		if (all == null)
			return null;
		return [
			for (mania in all) mania == null ? null : [for (slot in mania) slot == null ? null : slot.copy()]
		];
	}

	/**
		Refresh any live playfield strumlines after mania keybinds changed
		underneath them — a key pressed mid-binding, or the snapshot restored
		on cancel — so live notes answer to the current binds.
	**/
	function refreshLiveStrumlines() {
		var playField = Main.current.playField;
		if (playField == null)
			return;
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

	function findManiaConflict(keyCode:KeyCode, maniaId:Int, currentSlot:Int, currentSub:Int):String {
		var keybindsArr = maniaKeybindArray(maniaId);
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
				}, 500);
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

		// controls.reload() replaces the input2action handle the state machine
		// bound to, so re-request focus to re-bind the menu's actions to the
		// fresh handle.
		if (parent != null && parent.opened) {
			Main.current.stateMachine.setFocus(parent);
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
		var keybindsArr = maniaKeybindArray(id);
		var keybindArr = keybindsArr[maniaBindNum];
		if (keybindArr == null) {
			// No slot list for this mania in the loaded save file; nothing to bind.
			Main.current.playCancelSound();
			return;
		}

		// (The ui.back keybind used to reset the mania to factory defaults
		// here; it now cancels the session instead — see the exclusion in
		// onKeyDown and the snapshot restore in cancelBinding().)
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
				}, 500);
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
				}, 500);
				Main.current.playCancelSound();
				return;
			}
			keybindArr[maniaSubBindNum] = keyCode;
		}
		maniaBindNum++;
		Main.current.playScrollSound();

		refreshLiveStrumlines();

		if (maniaBindNum <= keybindsArr.length - 1) {
			return;
		}

		bindingMania = false;
		maniaBindNum = 0;
		maniaBindingSnapshot = null;
		fixMania();
		SaveData.save();
		Main.current.controls.reload();

		// Re-bind the menu's actions to the fresh controls handle.
		if (parent != null && parent.opened) {
			Main.current.stateMachine.setFocus(parent);
		}
	}

	function fixMania() {
		var id = curManiaNum;
		var keybindsArr = maniaKeybindArray(id);
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

		if (binding || bindingMania)
			cancelBinding();
		resetHostState();
		alphaMultiplier = 1.0;

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

	override function alphabetListLength():Int {
		return controlLabels.length;
	}

	override function alphabetItemTitle(index:Int):String {
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

