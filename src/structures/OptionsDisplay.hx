package structures;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import elements.text.TextCharSprite;

/**
	The playfield's options display.
	This is an internal structure and should only be used inside of the playfield NOT to be touched with.
**/
@:publicFields
class OptionsDisplay {
	private static var display(get, never):CustomDisplay;

	inline private static function get_display() {
		return OptionsMenu.display;
	}

	var parent(default, null):OptionsMenu;

	var options(default, null):Array<OptionsSprite> = [];

	static var keybind1Txt(default, null):Text;
	static var keybind2Txt(default, null):Text;

	function new(parent:OptionsMenu) {
		this.parent = parent;

		if (keybind1Txt == null) {
			keybind1Txt = new Text("options_keybinds1", 520, 370, display, "  A       S     W      D       Enter   Backspace", "unispace");
			keybind1Txt.scale = 0.75;
			keybind1Txt.alpha = 0.0;
			keybind1Txt.color = Color.BLUE;
		}

		if (keybind2Txt == null) {
			keybind2Txt = new Text("options_keybinds2", 520, 470, display, "  A       S     W      D       Enter   Backspace", "unispace");
			keybind2Txt.scale = 0.75;
			keybind2Txt.alpha = 0.0;
			keybind2Txt.color = Color.BLUE;
		}
	}

	function reload(selection:OptionSelection) {
		destroyOptions();

		switch (selection) {
			case CONTROLS:
				var subCat1 = new OptionsSprite();
				subCat1.type = CONTROLS_SUBCAT;
				subCat1.changeID(0);
				subCat1.x = 400;
				subCat1.y = 300;
				options.push(subCat1);
				OptionsMenu.optionsBuf.addElement(subCat1);

				var subCat2 = new OptionsSprite();
				subCat2.type = CONTROLS_SUBCAT;
				subCat2.changeID(1);
				subCat2.x = 400;
				subCat2.y = 400;
				options.push(subCat2);
				OptionsMenu.optionsBuf.addElement(subCat2);
			case PREFERENCES:
				// TODO
			case GAMEPLAY:
				// TODO
		}
	}

	function update(deltaTime:Float) {
		for (i in 0...options.length) {
			var option = options[i];
			option.c.aF = parent.alphaLerp;
			OptionsMenu.optionsBuf.updateElement(option);
		}

		keybind1Txt.alpha = parent.alphaLerp;
		keybind2Txt.alpha = parent.alphaLerp;
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

/**
	Option display setups.
/
enum abstract OptionDisplaySetup(Int) {
	// 0 = subcategory, 1 = keybind, 2 = checkmark, 3 = slider, 4 = color, 5 = text
	var CONTROLS; //"10 11 21 31 41 51 61 20 11 21 31 41 51 61 71 30 13";
	var PREFERENCES; //"12 22 32 42 52 62 72";
	var GAMEPLAY; //"13 21 31 44 54 65";
}
*/

/**
	Enum abstract of the option selection.
**/
enum abstract OptionSelection(Int) {
	var CONTROLS;
	var PREFERENCES;
	var GAMEPLAY;
}