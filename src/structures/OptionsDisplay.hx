package structures;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import elements.text.TextCharSprite;
import structures.options.*;

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

	var closed:Bool;

	function new(parent:OptionsMenu) {
		this.parent = parent;
		preferencesDisplay = new PreferencesDisplay(parent);
		graphicsDisplay = new GraphicsDisplay(parent);
		controlsDisplay = new ControlsDisplay(parent);
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
	}
}

/**
	Enum abstract of the option selection.
**/
enum abstract OptionsCategorySelection(Int) from Int to Int {
	var CONTROLS;
	var PREFERENCES;
	var GAMEPLAY;
}