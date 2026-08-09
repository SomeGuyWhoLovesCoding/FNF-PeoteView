package structures.options;

/**
	Handles the display and interaction for graphics options in the options menu.
	Manages rendering and updating of graphics-related UI elements.
	@since Development
**/
@:publicFields
class GraphicsDisplay {
	public static var graphicsStr(default, null):Array<String> = ["resolution", "fullscreen", "vsync", "antiAliasing", "frameRate", "shaders"];

	// Descriptions for each graphics option (placeholder, modify as needed)
	static var graphicsDescriptions:Array<String> = [
		"Set the game window resolution.",
		"Toggle fullscreen mode.",
		"Enable vertical sync (limit frame rate to monitor refresh).",
		"Toggle anti-aliasing for smoother edges.",
		"Set the maximum frame rate.",
		"Enable/disable shader effects."
	];

	var parent(default, null):OptionsMenu;
	var alphabet(default, null):FreeplayAlphabet; // shared instance
	var infoText(default, null):Text; // shared description text
	var options(default, null):Array<OptionsSprite> = [];

	var closed:Bool;

	function new(parent:OptionsMenu, alphabet:FreeplayAlphabet, infoText:Text) {
		this.parent = parent;
		this.alphabet = alphabet;
		this.infoText = infoText;
	}

	function reload() {
		destroyOptions();
		// TODO: Load and display graphics options sprites
		// Optionally set alphabet.host = this if GraphicsDisplay implements IAlphabetScrollHost
		closed = false;
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

		// Update description text for the selected option.
		var ratio = Math.min(deltaTime * 0.015, 1.0);
		var selectedIndex = parent.optionsNav.value();
		if (selectedIndex >= 0 && selectedIndex < graphicsStr.length) {
			var name = graphicsStr[selectedIndex];
			var desc = graphicsDescriptions[selectedIndex];
			// For now, show placeholder value; replace with actual setting when implemented.
			var value = "N/A";
			infoText.text = '$name: $desc\nCurrent: $value\n(Not yet implemented)';
		} else {
			infoText.text = "";
		}
		infoText.x = Main.INITIAL_WIDTH - infoText.width - 4;
		infoText.y = 4;

		var show = parent.opened && selectedIndex >= 0 && selectedIndex < graphicsStr.length;
		infoText.alpha = Tools.lerp(infoText.alpha, show ? 1.0 : 0.0, ratio);
	}

	function destroyOptions() {
		if (closed)
			return;
		closed = true;
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
}
