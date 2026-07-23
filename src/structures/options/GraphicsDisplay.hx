package structures.options;

import structures.FreeplayAlphabet;
import structures.OptionsMenu;

/**
	Handles the display and interaction for graphics options in the options menu.
	Manages rendering and updating of graphics-related UI elements.
	@since Development
**/
@:publicFields
class GraphicsDisplay {
	public static var graphicsStr(default, null):Array<String> = [
		"resolution",
		"fullscreen",
		"vsync",
		"antiAliasing",
		"frameRate",
		"shaders"
	];

	var parent(default, null):OptionsMenu;
	var alphabet(default, null):FreeplayAlphabet; // shared instance (unused for now)
	var options(default, null):Array<OptionsSprite> = [];

	function new(parent:OptionsMenu, alphabet:FreeplayAlphabet) {
		this.parent = parent;
		this.alphabet = alphabet;
	}

	function reload() {
		destroyOptions();
		// TODO: Load and display graphics options sprites
		// Optionally set alphabet.host = this if GraphicsDisplay implements IAlphabetScrollHost
	}

	function enter() {
		// TODO: Handle graphics option selection/change
	}

	function update(deltaTime:Float) {
		for (i in 0...options.length) {
			var option = options[i];
			option.c.aF = parent.alphaLerp;
			option.c.luminanceF = parent.alphaLerp;
			// TODO: Update graphics option display based on current settings
			OptionsMenu.optionsBuf.updateElement(option);
		}
	}

	function destroyOptions() {
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
}