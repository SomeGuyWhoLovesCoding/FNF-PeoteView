package structures.options;

import data.SaveData;
import structures.FreeplayAlphabet;
import structures.IAlphabetScrollHost;
import structures.OptionsMenu;

/**
	Handles the display and interaction for preferences options in the options menu.
	Now uses FreeplayAlphabet scrolling system for consistent UI.
	@since Development
**/
@:publicFields
class PreferencesDisplay implements IAlphabetScrollHost {
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
	var alphabet(default, null):FreeplayAlphabet;
	
	var xLerp:Float = 0.0;
	var curSelectedLerp:Float = 0.0;
	var curSelectedTarget:Float = 0.0;
	var alphaLerp:Float = 0.0;
	
	var closed:Bool;
	
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
		
		// Reset state when reloading
		resetHostState();
	}
	
	function resetHostState() {
		xLerp = 0.0;
		curSelectedLerp = 0.0;
		curSelectedTarget = 0.0;
		alphaLerp = 0.0;
	}
	
	function update(deltaTime:Float) {
		if (alphabet == null || closed) return;
		
		var ratio = Math.max(Math.min(deltaTime * 0.015, 1), 0.00001);
		if (ratio == 1) ratio = (1 / lime.app.Application.current.window.frameRate) * 0.015;
		
		alphaLerp = Tools.lerp(alphaLerp, parent.opened ? 1.0 : 0.0, ratio);
		curSelectedTarget = parent.optionsNav.value();
		curSelectedLerp = Tools.lerp(curSelectedLerp, curSelectedTarget, ratio);
		xLerp = 20 - (curSelectedLerp * 20);
		
		alphabet.setDeltaTime(deltaTime);
		var incrementBest = prefsStr.length > 7
			? Math.floor(Math.min(Math.max(curSelectedLerp - 3, 0), prefsStr.length - 7))
			: 0;
		
		for (i in 0...7) {
			alphabet.updateRowText(i, incrementBest);
		}
		alphabet.updateBuffer();
	}
	
	function enter() {
		if (closed || alphabet == null) return;
		
		var field = prefsStr[Math.floor(curSelectedTarget)];
		var optionChecked = Reflect.getProperty(SaveData.state.preferences, field);
		Reflect.setProperty(SaveData.state.preferences, field, !optionChecked);
		
		// Apply preference changes immediately
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
					// No immediate effect needed
			}
		}
		
		// Force update the display to show new ON/OFF state
		if (alphabet != null && !closed) {
			alphabet.updateBuffer();
		}
		
		Main.current.playCancelSound();
	}
	
	function destroyOptions() {
		if (closed) return;
		
		closed = true;
		
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
	
	// IAlphabetScrollHost implementation
	public function alphabetListLength():Int {
		return prefsStr.length;
	}
	
	public function alphabetItemTitle(index:Int):String {
		if (index < 0 || index >= prefsStr.length) return "";
		var prefName = prefsStr[index];
		var isOn = Reflect.getProperty(SaveData.state.preferences, prefName);
		var displayText = getDisplayName(prefName);
		return displayText + (isOn ? " ON" : " OFF");
	}
	
	// Convert internal preference names to user-friendly display names
	function getDisplayName(prefName:String):String {
		switch (prefName) {
			case "downScroll": return "Down Scroll";
			case "hideHUD": return "Hide HUD";
			case "smoothHealthbar": return "Smooth Healthbar";
			case "ratingPopup": return "Rating Popup";
			case "scoreTxtBopping": return "Score Text Bop";
			case "cameraZooming": return "Camera Zoom";
			case "iconBopping": return "Icon Bop";
			default: return prefName;
		}
	}
}