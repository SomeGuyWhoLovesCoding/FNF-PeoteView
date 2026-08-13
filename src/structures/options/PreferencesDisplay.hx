package structures.options;

import lime.ui.MouseButton;
import structures.options.OptionsDisplay.OptionsSubDisplay;

/**
	Handles the display and interaction for preferences options in the options menu.
	Now uses a shared FreeplayAlphabet instance for consistent UI.
	@since Development
**/
@:publicFields
class PreferencesDisplay implements OptionsSubDisplay {
	public static var prefsStr(default, null):Array<String> = [
		"downScroll",
		"hideHUD",
		"smoothHealthbar",
		"ratingPopup",
		"scoreTxtBopping",
		"cameraZooming",
		"iconBopping"
	];

	// Descriptions for each preference, in the same order.
	static var prefDescriptions:Array<String> = [
		"Flips your strumline direction upside down.",
		"Might help your gameplay be seen clearer...",
		"Applies real time interpolation to the moving character icons.",
		"Show 'Sick' or 'Good' when hitting notes.",
		"Bounces your score text whenever you hit a Sick or better.",
		"Applies a slow bounce to the camera per measure.",
		"Applies a snappy bounce to your character icons."
	];

	var parent(default, null):OptionsMenu;
	var options(default, null):Array<OptionsSprite> = [];
	var alphabet(default, null):FreeplayAlphabet; // shared instance
	var infoText(default, null):Text; // shared description text (owned by OptionsDisplay)

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
	var dragVelocity:Float = 0.0;
	var lastDragTime:Float = 0.0;

	private static inline var DRAG_THRESHOLD:Float = 1.0;

	// Cached last pushed info string (avoid per-frame string build + Text relayout).
	var _lastInfoText:String = null;

	// Cached rendered list-row titles; rebuilt only when a value changes.
	var _titleCache:Array<String> = [];

	// Constructor now accepts the shared infoText
	function new(parent:OptionsMenu, alphabet:FreeplayAlphabet, infoText:Text) {
		this.parent = parent;
		this.alphabet = alphabet;
		this.infoText = infoText;
	}

	function reload() {
		destroyOptions();
		alphabet.setHost(this); // set this display as the host
		alphabet.reload();
		closed = false;

		resetHostState();
		resetDragState();
		_lastInfoText = null;
		_titleCache = [];
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

	function update(deltaTime:Float) {
		if (alphabet == null || closed)
			return;

		var ratio = Math.max(Math.min(deltaTime * 0.015, 1), 0.00001);
		if (ratio == 1)
			ratio = (1 / lime.app.Application.current.window.frameRate) * 0.015;

		alphaLerp = Tools.lerp(alphaLerp, parent.opened ? 1.0 : 0.0, ratio);

		if (!isDragging && Math.abs(dragVelocity) > 0.01) {
			curSelectedTarget += (dragVelocity * deltaTime) / (156.0 / (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT));
			curSelectedTarget = Math.max(0, Math.min(prefsStr.length - 1, curSelectedTarget));
			parent.optionsNav.setTo(Math.round(curSelectedTarget));
			dragVelocity *= Math.pow(0.92, deltaTime * 0.04);
			if (Math.abs(dragVelocity) < 0.01)
				dragVelocity = 0.0;
		}

		if (!isDragging && dragVelocity == 0.0) {
			curSelectedTarget = parent.optionsNav.value();
		}

		curSelectedLerp = Tools.lerp(curSelectedLerp, curSelectedTarget, ratio);
		xLerp = 20 - (curSelectedLerp * 20);

		// Update description text (shared infoText)
		var index = Math.round(curSelectedTarget);
		if (index >= 0 && index < prefsStr.length) {
			var prefName = prefsStr[index];
			var desc = prefDescriptions[index];
			var isOn = Reflect.getProperty(SaveData.state.preferences, prefName);
			var status = isOn ? "ON" : "OFF";
			var combined = '${getDisplayName(prefName)}: $desc\nStatus: $status\nPress ENTER to toggle.';
			if (combined != _lastInfoText) {
				_lastInfoText = combined;
				infoText.text = combined;
			}
		} else if (_lastInfoText != "") {
			_lastInfoText = "";
			infoText.text = "";
		}
		// Position at top-right
		infoText.x = Main.INITIAL_WIDTH - infoText.width - 4;
		infoText.y = 4;

		// Fade text based on menu alpha
		var show = parent.opened && index >= 0 && index < prefsStr.length;
		infoText.alpha = Tools.lerp(infoText.alpha, show ? 1.0 : 0.0, ratio);

		alphabet.setDeltaTime(deltaTime);
		var incrementBest = prefsStr.length > 7 ? Math.floor(Math.min(Math.max(curSelectedLerp - 3, 0), prefsStr.length - 7)) : 0;

		for (i in 0...7) {
			alphabet.updateRowText(i, incrementBest);
		}
		alphabet.buffer.update();
	}

	// -------------------- MOUSE HANDLERS (routed by OptionsMenu) --------------------

	public function onMouseDown(x:Float, y:Float, button:MouseButton):Bool {
		if (closed || alphabet == null)
			return false;
		switch (button) {
			case LEFT:
				isDragging = true;
				dragStartY = y;
				lastDragY = y;
				dragAccum = 0.0;
				dragVelocity = 0.0;
				lastDragTime = haxe.Timer.stamp();
				curSelectedTarget = curSelectedLerp;
				return true;
			default:
		}
		return false;
	}

	public function onMouseUp(x:Float, y:Float, button:MouseButton):Bool {
		if (button != LEFT)
			return false;
		if (closed || alphabet == null)
			return false;

		if (isDragging && Math.abs(dragStartY - y) < 4.0) {
			curSelectedTarget += 0.3;
			enter();
			curSelectedTarget -= 0.3;
		} else if (isDragging) {
			var nearestIndex = Math.round(curSelectedTarget);
			curSelectedTarget = nearestIndex;
			parent.optionsNav.setTo(nearestIndex);
		}

		isDragging = false;
		dragAccum = 0.0;
		dragStartY = 0.0;
		lastDragY = 0.0;
		return true;
	}

	public function onMouseMove(x:Float, y:Float):Bool {
		if (!isDragging || closed || alphabet == null)
			return false;

		var delta = lastDragY - y;
		lastDragY = y;

		var now = haxe.Timer.stamp();
		var dt = now - lastDragTime;
		lastDragTime = now;

		var _delta = (delta / (156.0 / (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT)));
		if (dt > 0)
			dragVelocity = _delta / 3;

		curSelectedTarget += _delta;
		curSelectedTarget = Math.max(0, Math.min(prefsStr.length - 1, curSelectedTarget));
		parent.optionsNav.setTo(Math.round(curSelectedTarget));
		return true;
	}

	// -------------------- END MOUSE HANDLERS --------------------

	function enter() {
		if (closed || alphabet == null)
			return;

		var field = prefsStr[Math.floor(curSelectedTarget)];
		var optionChecked = Reflect.getProperty(SaveData.state.preferences, field);
		Reflect.setProperty(SaveData.state.preferences, field, !optionChecked);
		_titleCache = [];

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
						if (healthBar != null)
							healthBar.update(0);
					}
				default:
			}
		}

		if (alphabet != null && !closed) {
			alphabet.buffer.update();
		}

		Main.current.playCancelSound();
	}

	function destroyOptions() {
		if (closed)
			return;
		closed = true;

		resetHostState();
		resetDragState();

		// Remove only our own OptionsSprites, not the shared alphabet or infoText.
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

	// IAlphabetScrollHost implementation
	public function alphabetListLength():Int {
		return prefsStr.length;
	}

	public function alphabetItemTitle(index:Int):String {
		if (index < 0 || index >= prefsStr.length)
			return "";
		if (index >= _titleCache.length || _titleCache[index] == null) {
			var prefName = prefsStr[index];
			var isOn = Reflect.getProperty(SaveData.state.preferences, prefName);
			var displayText = getDisplayName(prefName);
			var str = displayText;
			var strLen = isOn ? 18 : 17;
			for (i in 0...Math.floor((strLen - displayText.length) * 1.3) - 3)
				str += " ";
			if (isOn)
				str += "ON";
			else
				str += "OFF";
			_titleCache[index] = str;
		}
		return _titleCache[index];
	}

	public function alphabetItemDisabled(index:Int):Bool {
		return false;
	}

	function getDisplayName(prefName:String):String {
		switch (prefName) {
			case "downScroll":
				return "Down Scroll";
			case "hideHUD":
				return "Hide HUD";
			case "smoothHealthbar":
				return "Smooth Health";
			case "ratingPopup":
				return "Rating Popup";
			case "scoreTxtBopping":
				return "Score Bop";
			case "cameraZooming":
				return "Camera Zoom";
			case "iconBopping":
				return "Icon Bop";
			default:
				return prefName;
		}
	}
}
