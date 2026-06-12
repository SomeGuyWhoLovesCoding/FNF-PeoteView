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
		"1K",
		"2K",
		"3K",
		"4K",
		"5K",
		"6K",
		"7K",
		"8K",
		"9K"
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
	static var alphabet(default, null):FreeplayAlphabet;

	var bindingIndex:Int = -1;
	var binding:Bool = false;
	var processingBinding:Bool = false;
	var bindingMania:Bool = false;
	var maniaBindNum:Int = 0;
	var lastBindingTime:Float = 0;

	var xLerp:Float = 0.0;
	var curSelectedLerp:Float = 0.0;
	var curSelectedTarget:Float = 0.0;
	var alphaLerp:Float = 0.0;

	static var maniaKeybindTxt(default, null):Text;
	static var instructionsTxt(default, null):Text;
	var maniaKeybindsWillShow:Bool;

    var closed:Bool;
	/*var isManiaKeybindSection(set, default):Bool;
	inline function set_isManiaKeybindSection(value:Bool) {
		return is
	}*/

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

		if (maniaKeybindTxt == null) {
			maniaKeybindTxt = new Text("FUNKIN_VIEW_KEYBIND_TXT", 0, 300, alphabet.display, "KEYBINDS\nNONE", "vcr");
			maniaKeybindTxt.multiline = true;
			maniaKeybindTxt.alignment = RIGHT;
			maniaKeybindTxt.alpha = 0;
			maniaKeybindTxt.outlineColor = Color.BLACK;
			maniaKeybindTxt.outlineSize = 1.4;
			maniaKeybindTxt.x = Main.VARIABLE_WIDTH - (maniaKeybindTxt.width + 4);
		}

		if (instructionsTxt == null) {
			instructionsTxt = new Text("FUNKIN_VIEW_CONTROLS_INSTRUCTIONS_TXT", 4, 3, alphabet.display, "Press TAB to begin binding\nPress ESC to cancel binding.", "vcr");
			instructionsTxt.alpha = 0;
			instructionsTxt.multiline = true;
			instructionsTxt.alignment = RIGHT;
			instructionsTxt.outlineColor = Color.BLACK;
			instructionsTxt.outlineSize = 1.4;
			instructionsTxt.x = Main.VARIABLE_WIDTH - (instructionsTxt.width + 4);
		}

		if (!OptionsMenu.optionsDisplay.closed) showTexts();
        
        // Reset state when reloading
        resetHostState();
        
        // Reset binding state
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
		if (bindingIndex >= controlFields.length) {
			bindingMania = true;
		} else binding = true;

		// Temporarily disable parent events while binding
		parent.removeEvents();
		Application.current.window.onKeyDown.add(onKeyDown);
		
		Main.current.playConfirmSound();
	}

	function update(deltaTime:Float) {
		if (alphabet == null || closed) return;

		var ratio = Math.max(Math.min(deltaTime * 0.015, 1), 0.00001);
		if (ratio == 1) ratio = (1 / lime.app.Application.current.window.frameRate) * 0.015;

		alphaLerp = Tools.lerp(alphaLerp, parent.opened ? 1.0 : 0.0, ratio);
		curSelectedTarget = parent.optionsNav.value();
		curSelectedLerp = Tools.lerp(curSelectedLerp, curSelectedTarget, ratio);
		xLerp = 20 - (curSelectedLerp * 20);

		maniaKeybindTxt.alpha = Tools.lerp(maniaKeybindTxt.alpha, curSelectedTarget >= controlFields.length ? 1.0 : 0.0, ratio);
		if (bindingMania) {
			var str = "KEYBINDS\n\n";
			var keybindArr = SaveData.state.controls.game.keybindArray;
			for (maniaBind in keybindArr[Std.int(curSelectedTarget) - (controlFields.length - 1)]) {
				str += "[ ";
				for (i in 0...maniaBind.length) {
					str += KeyCodeConverter.getSimpleKeyName(maniaBind[i]);
					if (i != maniaBind.length - 1) str += ", ";
				}
				str += " ]";
				str += "\n";
			}
			maniaKeybindTxt.text = str;
			maniaKeybindTxt.y = 300 - ((maniaKeybindTxt.height - 20) * 0.3);
		} else maniaKeybindTxt.text = "KEYBINDS\n...";
		maniaKeybindTxt.x = Main.VARIABLE_WIDTH - (maniaKeybindTxt.width + 4);
		instructionsTxt.alpha = alphaLerp;

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
			
			// Re-enable parent events
			if (parent != null && parent.opened) {
				parent.addEvents();
				Application.current.window.onKeyDown.remove(onKeyDown);
			}
			
			Main.current.playCancelSound();
		}
	}

	function onKeyDown(keyCode:KeyCode, keyModifier:KeyModifier) {
		if (closed) return;
		
		var BIND_KEY = KeyCode.TAB;

		// Handle escape first - always cancel binding
		if (keyCode == KeyCode.ESCAPE && binding) {
			cancelBinding();
			return;
		}

		// Start binding with TAB
		if (keyCode == BIND_KEY && !binding && !processingBinding && !closed) {
			tab();
			return;
		}

		if (bindingMania) {

		}

		// Apply binding if we're in binding mode
		if (binding && !processingBinding && bindingMania && !closed) {
			// Don't bind the TAB key itself or ESCAPE
			if (keyCode == BIND_KEY || keyCode == KeyCode.ESCAPE) return;
			
			// Debounce - prevent multiple rapid bindings
			var now = haxe.Timer.stamp();
			if (now - lastBindingTime < 0.5) return;
			lastBindingTime = now;
			
			applyBinding(keyCode);
		}
	}

	function onKeyUp(keyCode:KeyCode, keyModifier:KeyModifier) {
		// Not needed
	}

	function applyBinding(keyCode:KeyCode) {
		// Prevent duplicate processing
		if (processingBinding) return;
		processingBinding = true;
		
		if (bindingIndex < 0 || bindingIndex >= controlFields.length) {
			cancelBinding();
			processingBinding = false;
			return;
		}
		
		var field = controlFields[bindingIndex];
		var parts = field.split(".");

		if (parts.length < 2) {
			cancelBinding();
			processingBinding = false;
			return;
		}

		var category = parts[0];
		var name = parts[1];

		if (category == "ui") {
			Reflect.setProperty(SaveData.state.controls.ui, name, keyCode);
		} else if (category == "game") {
			Reflect.setProperty(SaveData.state.controls.game, name, keyCode);
		}

		// Clear binding state BEFORE saving to prevent event loops
		binding = false;
		bindingIndex = -1;
		
		SaveData.save();
		
		// Reload controls AFTER clearing binding state
		Main.current.controls.reload();
		
		// Update the display to show the new key
		if (alphabet != null && !closed) {
			alphabet.updateBuffer();
		}
		
		// Re-enable parent events after binding is complete
		if (parent != null && parent.opened) {
			parent.addEvents();
			Application.current.window.onKeyDown.remove(onKeyDown);
		}
		
		Main.current.playConfirmSound();
		
		// Reset processing flag
		processingBinding = false;
	}

	function destroyOptions() {
		if (closed) return;
		
		closed = true;

		removeTexts();
		
		// Cancel any active binding first
		if (binding) {
			cancelBinding();
		}
		
		// Reset host state before disposing alphabet
		resetHostState();
		
		if (alphabet != null) {
			// First remove from display, then dispose
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
		if (index < controlFields.length) {
			return controlLabels[index] + " - " + keyNameForIndex(index);
		}
		return controlLabels[index];
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