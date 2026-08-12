package structures.options;

import lime.ui.MouseButton;
import miniaudio.MiniAudio;

/**
	Handles the display and interaction for performance options in the options menu.
	Mirrors `PreferencesDisplay` but for performance-related toggles that gate optional
	engine mechanics. Currently exposes a single toggle: `timeStretch` (pitch-preserving
	time-stretch when playback rate != 1.0; disabling it swaps in a cheap linear resampler).
	@since 0.94
**/
@:publicFields
class PerformanceDisplay implements IAlphabetScrollHost {
	public static var perfStr(default, null):Array<String> = [
		"timeStretch",
		"antialiasing"
	];

	static var perfDescriptions:Array<String> = [
		"Keep pitch when song speed != 1x (uses FFT time-stretch).\nOFF uses a cheaper linear resample (pitch shifts).\nTurn OFF if you get audio dropouts on slower/faster sections.",
		"Toggle anti-aliasing for smoother edges\napplies to new textures or session restart.",
	];

	var parent(default, null):OptionsMenu;
	var options(default, null):Array<OptionsSprite> = [];
	var alphabet(default, null):FreeplayAlphabet;
	var infoText(default, null):Text;

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

	// Cached last pushed info string (avoid per-frame Text relayout).
	var _lastInfoText:String = null;

	// Cached rendered list-row titles; rebuilt only when a value changes.
	var _titleCache:Array<String> = [];

	var inputCtx:InputContext;

	function new(parent:OptionsMenu, alphabet:FreeplayAlphabet, infoText:Text) {
		this.parent = parent;
		this.alphabet = alphabet;
		this.infoText = infoText;
	}

	function reload() {
		destroyOptions();
		alphabet.setHost(this);
		alphabet.reload();
		closed = false;

		resetHostState();
		resetDragState();
		registerInputHandlers();
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

	function registerInputHandlers() {
		if (inputCtx == null) {
			inputCtx = new InputContext();
			inputCtx.mouseDown = mousePress;
			inputCtx.mouseUp = mouseRelease;
			inputCtx.mouseMove = mouseDrag;
		}
		Main.current.input.push(inputCtx);
	}

	function unregisterInputHandlers() {
		Main.current.input.pop(inputCtx);
		inputCtx = null;
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
			curSelectedTarget = Math.max(0, Math.min(perfStr.length - 1, curSelectedTarget));
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

		var index = Math.round(curSelectedTarget);
		if (index >= 0 && index < perfStr.length) {
			var prefName = perfStr[index];
			var desc = perfDescriptions[index];
			var isOn = Reflect.getProperty(SaveData.state.preferences, prefName);
			var status = isOn ? "ON" : "OFF";
			var combined = '${getDisplayName(prefName)}: $desc\nStatus: $status\nPress ENTER to toggle.';
			if (combined != _lastInfoText) {
				_lastInfoText = combined;
				infoText.text = combined;
				infoText.x = Main.INITIAL_WIDTH - infoText.width - 4;
				infoText.y = 4;
			}
		} else {
			if (_lastInfoText != "") {
				_lastInfoText = "";
				infoText.text = "";
			}
		}

		var show = parent.opened && index >= 0 && index < perfStr.length;
		infoText.alpha = Tools.lerp(infoText.alpha, show ? 1.0 : 0.0, ratio);

		alphabet.setDeltaTime(deltaTime);
		var incrementBest = perfStr.length > 7 ? Math.floor(Math.min(Math.max(curSelectedLerp - 3, 0), perfStr.length - 7)) : 0;

		for (i in 0...7) {
			alphabet.updateRowText(i, incrementBest);
		}
		alphabet.buffer.update();
	}

	// -------------------- MOUSE HANDLERS --------------------

	function mousePress(x:Float = 0.0, y:Float = 0.0, button:MouseButton) {
		if (closed || alphabet == null)
			return;
		switch (button) {
			case LEFT:
				isDragging = true;
				dragStartY = y;
				lastDragY = y;
				dragAccum = 0.0;
				dragVelocity = 0.0;
				lastDragTime = haxe.Timer.stamp();
				curSelectedTarget = curSelectedLerp;
			default:
		}
	}

	function mouseRelease(x:Float = 0.0, y:Float = 0.0, button:MouseButton) {
		if (button != LEFT)
			return;
		if (closed || alphabet == null)
			return;

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
	}

	function mouseDrag(x:Float, y:Float) {
		if (!isDragging || closed || alphabet == null)
			return;

		var delta = lastDragY - y;
		lastDragY = y;

		var now = haxe.Timer.stamp();
		var dt = now - lastDragTime;
		lastDragTime = now;

		var _delta = (delta / (156.0 / (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT)));
		if (dt > 0)
			dragVelocity = _delta / 3;

		curSelectedTarget += _delta;
		curSelectedTarget = Math.max(0, Math.min(perfStr.length - 1, curSelectedTarget));
		parent.optionsNav.setTo(Math.round(curSelectedTarget));
	}

	// -------------------- END MOUSE HANDLERS --------------------

	function enter() {
		if (closed || alphabet == null)
			return;

		var field = perfStr[Math.floor(curSelectedTarget)];
		var optionChecked = Reflect.getProperty(SaveData.state.preferences, field);
		Reflect.setProperty(SaveData.state.preferences, field, !optionChecked);
		_titleCache = [];

		// Apply side effects per-toggle.
		switch (field) {
			case "timeStretch":
				#if (cpp || hl)
				MiniAudio.setStretchEnabled(!optionChecked);
				#end
			default:
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

		unregisterInputHandlers();
		resetHostState();
		resetDragState();

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
		return perfStr.length;
	}

	public function alphabetItemTitle(index:Int):String {
		if (index < 0 || index >= perfStr.length)
			return "";
		if (index >= _titleCache.length || _titleCache[index] == null) {
			var prefName = perfStr[index];
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
			case "timeStretch":
				return "Time Stretch";
			case "antialiasing":
				return "Anti-aliasing";
			default:
				return prefName;
		}
	}
}
