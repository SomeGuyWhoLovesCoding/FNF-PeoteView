package structures;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import elements.text.TextCharSprite;

/**
	The options submenu's display.
	This is an internal structure and should only be used inside of the menu NOT to be touched with.
	It is used to display the options available to the player, such as controls, preferences, and gameplay options.
	It is responsible for rendering the options and updating them based on the player's input and game state.
	@since Development
**/
@:publicFields
class OptionsDisplay {
	private static var prefsStr(default, null):Array<String> = [
		"downScroll",
		"hideHUD",
		"smoothHealthbar",
		"ratingPopup",
		"scoreTxtBopping",
		"cameraZooming",
		"iconBopping"
	];

	private static var display(get, never):CustomDisplay;

	inline private static function get_display() {
		return OptionsMenu.display;
	}

	var parent(default, null):OptionsMenu;

	var options(default, null):Array<OptionsSprite> = [];

	function new(parent:OptionsMenu) {
		this.parent = parent;
	}

	function reload(selection:OptionsCategorySelection) {
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
				for (i in 0...7) {
					var option = new OptionsSprite();
					option.type = PREFERENCE_OPTION;
					option.changeID(i);
					option.x = 400;
					option.y = 125 + (option.h * i);
					options.push(option);
					OptionsMenu.optionsBuf.addElement(option);
				}
			case GAMEPLAY:
				// TODO
		}
	}

	function enter() {
		switch ((parent.categoryNav.value():OptionsCategorySelection)) {
			case PREFERENCES:
				var field = prefsStr[parent.optionsNav.value()];
				var optionChecked = Reflect.getProperty(SaveData.state.preferences, field);
				Reflect.setProperty(SaveData.state.preferences, field, !optionChecked);
				var pf = Main.current.playField;
				if (pf != null) {
					switch (field) {
						case "downScroll":
							pf.downScroll = !optionChecked;
						case "hideHUD" | "ratingPopup":
							pf.resetHUD();
						case "smoothHealthbar":
							var hud = pf.hud;
							if (hud != null) {
								var healthBar = hud.healthBar;
								if (healthBar != null) healthBar.update(0);
							}
						default:
					}
				}
			default:
		}
	}

	function update(deltaTime:Float) {
		for (i in 0...options.length) {
			var option = options[i];
			option.c.aF = parent.alphaLerp;
			option.c.luminanceF = parent.alphaLerp;
			switch ((parent.categoryNav.value():OptionsCategorySelection)) {
				case PREFERENCES:
					var optionChecked = Reflect.getProperty(SaveData.state.preferences, prefsStr[i]);
					if (i == parent.optionsNav.value()) {
						option.c.rF = !optionChecked ? parent.alphaLerp : 0.0;
						option.c.gF = optionChecked ? parent.alphaLerp : 0.0;
						option.c.bF = 0.0;
					} else {
						option.c.luminanceF = parent.alphaLerp;
					}
				case GAMEPLAY:
					// todo
				case CONTROLS:
					// todo
			}
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

/**
	Enum abstract of the option selection.
**/
enum abstract OptionsCategorySelection(Int) from Int to Int {
	var CONTROLS;
	var PREFERENCES;
	var GAMEPLAY;
}