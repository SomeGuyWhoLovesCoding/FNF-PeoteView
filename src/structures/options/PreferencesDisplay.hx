package structures.options;

import data.SaveData;
import structures.FreeplayAlphabet;
import structures.IAlphabetScrollHost;
import structures.OptionsMenu;
import lime.ui.MouseButton;

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
	static var alphabet(default, null):FreeplayAlphabet;
	
	var xLerp:Float = 0.0;
	var curSelectedLerp:Float = 0.0;
	var curSelectedTarget:Float = 0.0;
	var alphaLerp:Float = 0.0;
	
	var closed:Bool;
	
	//////////////////////// SCROLL (LIKE PHONE) ////////////////////////
	var isDragging:Bool = false;
	var dragStartY:Float = 0.0;
	var lastDragY:Float = 0.0;
	var dragAccum:Float = 0.0;
	
	// fling impl
	var dragVelocity:Float = 0.0;
	var lastDragTime:Float = 0.0;
	
	private static inline var DRAG_THRESHOLD:Float = 1.0; // pixels per nav tick
	
	function new(parent:OptionsMenu) {
		this.parent = parent;
	}
	
	function reload() {
		destroyOptions();
		if (alphabet == null) {
			alphabet = new FreeplayAlphabet(this, OptionsMenu.display);
			alphabet.ensurePrograms();
			alphabet.reload();
		}
		alphabet.addPrograms();
		closed = false;
		
		// Reset state when reloading
		resetHostState();
		resetDragState();
		
		// Register input handlers
		registerInputHandlers();
	}
	
	function resetHostState() {
		xLerp = 0.0;
		curSelectedLerp = 0.0;
		curSelectedTarget = 0.0;
		alphaLerp = 0.0;
	}
	
	function resetDragState() {
		isDragging = false;
		dragAccum = 0.0;
		dragVelocity = 0.0;
	}
	
	function registerInputHandlers() {
		var window = lime.app.Application.current.window;
		Main.current.mouseDown = mousePress;
		window.onMouseUp.add(mouseRelease);
		window.onMouseMove.add(mouseDrag);
	}
	
	function unregisterInputHandlers() {
		var window = lime.app.Application.current.window;
		if (Main.current.mouseDown == mousePress) {
			Main.current.mouseDown = null;
		}
		window.onMouseUp.remove(mouseRelease);
		window.onMouseMove.remove(mouseDrag);
	}
	
	function update(deltaTime:Float) {
		if (alphabet == null || closed) return;
		
		var ratio = Math.max(Math.min(deltaTime * 0.015, 1), 0.00001);
		if (ratio == 1) ratio = (1 / lime.app.Application.current.window.frameRate) * 0.015;
		
		alphaLerp = Tools.lerp(alphaLerp, parent.opened ? 1.0 : 0.0, ratio);
		
		// Handle fling inertia
		if (!isDragging && Math.abs(dragVelocity) > 0.01) {
			curSelectedTarget += (dragVelocity * deltaTime) / (156.0 / (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT));
			curSelectedTarget = Math.max(0, Math.min(prefsStr.length - 1, curSelectedTarget));
			parent.optionsNav.setTo(Math.round(curSelectedTarget));
			
			dragVelocity *= Math.pow(0.92, deltaTime * 0.04); // exponential decay
			if (Math.abs(dragVelocity) < 0.01) dragVelocity = 0.0;
		}
		
		// Only update from parent nav when not dragging and no inertia
		if (!isDragging && dragVelocity == 0.0) {
			curSelectedTarget = parent.optionsNav.value();
		}
		
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
	
	function mousePress(x:Float = 0.0, y:Float = 0.0, button:MouseButton) {
		if (closed || alphabet == null) return;
		
		switch (button) {
			case LEFT:
				isDragging = true;
				dragStartY = y;
				lastDragY = y;
				dragAccum = 0.0;
				dragVelocity = 0.0;
				lastDragTime = haxe.Timer.stamp();
				curSelectedTarget = curSelectedLerp;
			case RIGHT:
			default:
		}
	}
	
	function mouseRelease(x:Float = 0.0, y:Float = 0.0, button:MouseButton) {
		if (button != LEFT) return;
		if (closed || alphabet == null) return;
		
		// If it was a click (not a drag), trigger enter
		if (isDragging && Math.abs(dragStartY - y) < 4.0) {
			curSelectedTarget += 0.3;
			enter();
			curSelectedTarget -= 0.3;
		} else if (isDragging) {
			// Snap to the nearest option after dragging
			var nearestIndex = Math.round(curSelectedTarget);
			curSelectedTarget = nearestIndex;
			parent.optionsNav.setTo(nearestIndex);
			
			// Optionally trigger enter immediately on drag release
			// Uncomment the next line if you want to toggle on release
			// enter();
		}
		
		isDragging = false;
		dragAccum = 0.0;
		// Reset drag start position for next interaction
		dragStartY = 0.0;
		lastDragY = 0.0;
		// velocity carries over into update for fling inertia
	}
	
	function mouseDrag(x:Float, y:Float) {
		if (!isDragging || closed || alphabet == null) return;
		
		var delta = lastDragY - y;
		lastDragY = y;
		
		var now = haxe.Timer.stamp();
		var dt = now - lastDragTime;
		lastDragTime = now;
		
		var _delta = (delta / (156.0 / (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT)));
		
		// Calculate velocity for fling
		if (dt > 0) dragVelocity = _delta / 3;
		
		curSelectedTarget += _delta;
		curSelectedTarget = Math.max(0, Math.min(prefsStr.length - 1, curSelectedTarget/* - 0.5*/));
		parent.optionsNav.setTo(Math.round(curSelectedTarget));
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
		
		// Unregister input handlers before cleanup
		unregisterInputHandlers();
		
		// Reset host state before disposing alphabet
		resetHostState();
		resetDragState();
		
		if (alphabet != null) {
			// First remove from display, then dispose
			alphabet.shutDown();
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
		if (alphabet != null) {
			// First remove from display, then dispose
			alphabet.dispose();
		}
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
		var str = displayText;
		var strLen = isOn ? 18 : 17;
		for (i in 0...Math.floor((strLen - displayText.length) * 1.3) - 3)
			str += " ";
		if (isOn) str += "ON"; else str += "OFF";
		return str;
	}
	
	// Convert internal preference names to user-friendly display names
	function getDisplayName(prefName:String):String {
		switch (prefName) {
			case "downScroll": return "Down Scroll";
			case "hideHUD": return "Hide HUD";
			case "smoothHealthbar": return "Smooth Health";
			case "ratingPopup": return "Rating Popup";
			case "scoreTxtBopping": return "Score Bop";
			case "cameraZooming": return "Camera Zoom";
			case "iconBopping": return "Icon Bop";
			default: return prefName;
		}
	}
}
