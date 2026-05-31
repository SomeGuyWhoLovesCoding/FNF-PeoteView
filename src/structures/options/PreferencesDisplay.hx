package structures.options;

/**
	Handles the display and interaction for preferences options in the options menu.
	Manages rendering and updating of preference-related UI elements.
	@since Development
**/
@:publicFields
class PreferencesDisplay {
	public static var prefsStr(default, null):Array<String> = [
		"downScroll",
		"hideHUD",
		"smoothHealthbar",
		"ratingPopup",
		"scoreTxtBopping",
		"cameraZooming",
		"iconBopping"
	];

	var parent(default, null):OptionsMenu;
	var options(default, null):Array<OptionsSprite> = [];

	function new(parent:OptionsMenu) {
		this.parent = parent;
	}

	function reload() {
		destroyOptions();

		for (i in 0...7) {
			var option = new OptionsSprite();
			option.type = PREFERENCE_OPTION;
			option.changeID(i);
			option.x = 400;
			option.y = 125 + (option.h * i);
			options.push(option);
			OptionsMenu.optionsBuf.addElement(option);
		}
	}

	function enter() {
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
	}

	function update(deltaTime:Float) {
		for (i in 0...options.length) {
			var option = options[i];
			option.c.aF = parent.alphaLerp;
			option.c.luminanceF = parent.alphaLerp;
			
			var optionChecked = Reflect.getProperty(SaveData.state.preferences, prefsStr[i]);
			if (i == parent.optionsNav.value()) {
				option.c.rF = !optionChecked ? parent.alphaLerp : 0.0;
				option.c.gF = optionChecked ? parent.alphaLerp : 0.0;
				option.c.bF = 0.0;
			} else {
				option.c.luminanceF = parent.alphaLerp;
			}
			//option.c.luminanceF = (i == parent.optionsNav.value()) ? (optionChecked ? parent.alphaLerp * 0.5 : 0.0) : parent.alphaLerp;
			
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