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
	var infoText(default, null):Text; // shared description text

	// Points to the currently active sub‑display
	var activeDisplay:{ function update(deltaTime:Float):Void; };

	var closed:Bool = true;

	function new(parent:OptionsMenu) {
		this.parent = parent;

		// Create the shared alphabet once and add its program.
		sharedAlphabet = new FreeplayAlphabet(null, display);
		sharedAlphabet.ensurePrograms();
		sharedAlphabet.addPrograms();

		// Create the shared info text and add it once.
		infoText = new Text("FUNKIN_OPTIONS_INFO", 0, 0, display, "", "vcr");
		infoText.multiline = true;
		infoText.alignment = RIGHT;
		infoText.alpha = 0; // initially hidden
		infoText.outlineColor = Color.BLACK;
		infoText.outlineSize = 1.4;
		infoText.scale = 0.75;
		infoText.addProgram();

		// Pass the shared alphabet and infoText to all sub‑displays.
		preferencesDisplay = new PreferencesDisplay(parent, sharedAlphabet, infoText);
		graphicsDisplay = new GraphicsDisplay(parent, sharedAlphabet, infoText);
		controlsDisplay = new ControlsDisplay(parent, sharedAlphabet, infoText);
	}

	function reload(selection:OptionsCategorySelection) {
		destroyOptions();

		// Activate the corresponding display and set it as the active one.
		switch (selection) {
			case CONTROLS:
				controlsDisplay.reload();
				activeDisplay = controlsDisplay;
			case PREFERENCES:
				preferencesDisplay.reload();
				activeDisplay = preferencesDisplay;
			case GAMEPLAY:
				graphicsDisplay.reload();
				activeDisplay = graphicsDisplay;
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
				// ControlsDisplay does not handle enter for toggling; it uses TAB.
		}
	}

	function update(deltaTime:Float) {
		// Update any generic OptionsSprites (currently none, but keep for future)
		for (i in 0...options.length) {
			var option = options[i];
			option.c.aF = parent.alphaLerp;
			option.c.luminanceF = parent.alphaLerp;
			OptionsMenu.optionsBuf.updateElement(option);
		}
		
		// Only update the active display – this prevents text/alpha conflicts.
		if (activeDisplay != null) {
			activeDisplay.update(deltaTime);
		}
	}

	function destroyOptions() {
		while (options.length != 0) {
			var option = options.pop();
			try {
				OptionsMenu.optionsBuf.removeElement(option);
			} catch (e) {}
		}
		
		// Each display will clean up its own sprites and reset its state.
		controlsDisplay.destroyOptions();
		preferencesDisplay.destroyOptions();
		graphicsDisplay.destroyOptions();
	}

	function dispose() {
		destroyOptions();
		controlsDisplay.dispose();
		preferencesDisplay.dispose();
		graphicsDisplay.dispose();
		
		// Remove shared infoText
		if (infoText != null) {
			infoText.removeProgram();
			infoText = null;
		}
		// Do not dispose sharedAlphabet – it is reused.
	}
}

enum abstract OptionsCategorySelection(Int) from Int to Int {
	var CONTROLS;
	var PREFERENCES;
	var GAMEPLAY;
}