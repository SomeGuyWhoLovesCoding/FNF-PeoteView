package structures.options;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import elements.text.TextCharSprite;
import structures.options.*;
import structures.FreeplayAlphabet;

/**
	The options submenu's display.
	This is an internal structure and should only be used inside of the menu NOT to be touched with.
	It is used to display the options available to the player, such as controls, preferences, and gameplay options.
	It is responsible for rendering the options and updating them based on the player's input and game state.
	@since Development
**/
@:publicFields
class OptionsDisplay {
	private static var display(get, never):CustomDisplay;
	inline private static function get_display() {
		return OptionsMenu.display;
	}

	var parent(default, null):OptionsMenu;
	var options(default, null):Array<OptionsSprite> = [];

	var preferencesDisplay(default, null):PreferencesDisplay;
	var graphicsDisplay(default, null):GraphicsDisplay;
	var controlsDisplay(default, null):ControlsDisplay;

	var sharedAlphabet(default, null):FreeplayAlphabet;

	var closed:Bool = true;

	function new(parent:OptionsMenu) {
		this.parent = parent;

		// Create the shared alphabet once and add its program.
		sharedAlphabet = new FreeplayAlphabet(null, display); // host will be set later
		sharedAlphabet.ensurePrograms();
		sharedAlphabet.addPrograms();

		// Pass the shared alphabet to all sub‑displays.
		preferencesDisplay = new PreferencesDisplay(parent, sharedAlphabet);
		graphicsDisplay = new GraphicsDisplay(parent, sharedAlphabet);
		controlsDisplay = new ControlsDisplay(parent, sharedAlphabet);
	}

	function reload(selection:OptionsCategorySelection) {
		destroyOptions();

		switch (selection) {
			case CONTROLS:
				controlsDisplay.reload();
			case PREFERENCES:
				preferencesDisplay.reload();
			case GAMEPLAY:
				graphicsDisplay.reload();
		}
	}

	function enter() {
		if (closed) return;
		switch ((parent.categoryNav.value():OptionsCategorySelection)) {
			case PREFERENCES:
				preferencesDisplay.enter();
			case GAMEPLAY:
				graphicsDisplay.enter();
			default:
		}
	}

	function update(deltaTime:Float) {
		for (i in 0...options.length) {
			var option = options[i];
			option.c.aF = parent.alphaLerp;
			option.c.luminanceF = parent.alphaLerp;
			OptionsMenu.optionsBuf.updateElement(option);
		}
		
		controlsDisplay.update(deltaTime);
		preferencesDisplay.update(deltaTime);
		graphicsDisplay.update(deltaTime);
	}

	function destroyOptions() {
		while (options.length != 0) {
			var option = options.pop();
			try {
				OptionsMenu.optionsBuf.removeElement(option);
			} catch (e) {}
		}
		
		controlsDisplay.destroyOptions();
		preferencesDisplay.destroyOptions();
		graphicsDisplay.destroyOptions();
	}

	function dispose() {
		destroyOptions();
		controlsDisplay.dispose();
		preferencesDisplay.dispose();
		graphicsDisplay.dispose();
		// Do not dispose sharedAlphabet – it is reused.
	}
}

enum abstract OptionsCategorySelection(Int) from Int to Int {
	var CONTROLS;
	var PREFERENCES;
	var GAMEPLAY;
}