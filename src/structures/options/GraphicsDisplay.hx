package structures.options;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;
#if LIME_840
import lime.app.VSyncMode;
#end

/**
	Handles the display and interaction for graphics options in the options menu.
	The list is rendered through the shared FreeplayAlphabet, so the graphics
	options behave exactly like the preferences/performance lists.
	@since Development
**/
@:publicFields
class GraphicsDisplay implements IAlphabetScrollHost implements OptionsInputHost {
	public static var graphicsStr(default, null):Array<String> = ["resolution", "fullscreen", "vsync", "frameRate", "compressTextures"];

	// Descriptions for each graphics option, in the same order.
	static var graphicsDescriptions:Array<String> = [
		"Set the game window resolution. ENTER cycles through presets.",
		"Toggle fullscreen mode.",
		#if LIME_840
		"Enable vertical sync (limit frame rate to monitor refresh).\nIf supported, adaptive vsync is used for better input latency.",
		#else
		"Not supported on lime versions under 8.4.0.",
		#end
		"Set the maximum frame rate. SHIFT+LEFT/RIGHT changes the value.",
		"Enable/disable compressed texture support.\n\nFunkin' View has two main methods: ASTC and BC7\nBC7 is mainstream for PC and ASTC is mainstream on mobile devices, like android.\n\nThis requires a session restart for changes to be made."
	];

	static var FRAMERATES:Array<Float> = [30, 50, 60, 75, 120, 144, 165, 240];
	static var RESOLUTIONS:Array<Array<Int>> = [
		[1280, 720],
		[1600, 900],
		[1920, 1080],
		[2560, 1440]
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

	// Cached last pushed info string (avoid per-frame Text relayout).
	var _lastInfoText:String = null;

	// Cached rendered list-row titles; rebuilt only when a value changes.
	var _titleCache:Array<String> = [];
	var _lastWinW:Int = -1;
	var _lastWinH:Int = -1;

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

		var win = lime.app.Application.current.window;
		if (win.width != _lastWinW || win.height != _lastWinH) {
			_lastWinW = win.width;
			_lastWinH = win.height;
			_titleCache = [];
		}

		if (!isDragging && Math.abs(dragVelocity) > 0.01) {
			curSelectedTarget += (dragVelocity * deltaTime) / (156.0 / (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT));
			curSelectedTarget = Math.max(0, Math.min(graphicsStr.length - 1, curSelectedTarget));
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
		if (index >= 0 && index < graphicsStr.length) {
			var name = getDisplayName(index);
			var desc = graphicsDescriptions[index];
			var value = getValueString(index);
			var help = graphicsStr[index] == "frameRate" ? "\nSHIFT+LEFT/RIGHT changes framerate." : "\nPress ENTER to change.";
			var combined = '$name: $desc\nCurrent: $value$help';
			if (combined != _lastInfoText) {
				_lastInfoText = combined;
				infoText.text = combined;
				// Position at top-right
				infoText.x = Main.INITIAL_WIDTH - infoText.width - 4;
				infoText.y = 4;
			}
		} else {
			if (_lastInfoText != "") {
				_lastInfoText = "";
				infoText.text = "";
			}
		}

		// Fade text based on menu alpha
		var show = parent.opened && index >= 0 && index < graphicsStr.length;
		infoText.alpha = Tools.lerp(infoText.alpha, show ? 1.0 : 0.0, ratio);

		alphabet.setDeltaTime(deltaTime);
		var incrementBest = graphicsStr.length > 7 ? Math.floor(Math.min(Math.max(curSelectedLerp - 3, 0), graphicsStr.length - 7)) : 0;

		for (i in 0...7) {
			alphabet.updateRowText(i, incrementBest);
		}
		alphabet.buffer.update();
	}

	// -------------------- MOUSE HANDLERS --------------------

	function mousePress(x:Float, y:Float, button:MouseButton) {
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

	function mouseRelease(x:Float, y:Float, button:MouseButton) {
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
		curSelectedTarget = Math.max(0, Math.min(graphicsStr.length - 1, curSelectedTarget));
		parent.optionsNav.setTo(Math.round(curSelectedTarget));
	}

	// -------------------- END MOUSE HANDLERS --------------------

	// SHIFT+LEFT/RIGHT changes the framerate while the graphics list is open.
	function onKeyDown(keyCode:KeyCode, keyModifier:KeyModifier) {
		if (closed || !parent.opened)
			return;

		var index = Math.floor(curSelectedTarget);
		if (index < 0 || index >= graphicsStr.length)
			return;

		if (!keyModifier.shiftKey && graphicsStr[index] != "frameRate")
			return;
		switch (keyCode) {
			case KeyCode.LEFT:
				changeFrameRate(-1);
			case KeyCode.RIGHT:
				changeFrameRate(1);
			default:
		}
	}

	function enter() {
		if (closed || alphabet == null)
			return;

		var index = Math.floor(curSelectedTarget);
		if (index < 0 || index >= graphicsStr.length)
			return;

		switch (graphicsStr[index]) {
			case "resolution":
				cycleResolution();
			case "fullscreen":
				toggleFullscreen();
			case "vsync":
				#if LIME_840
				toggleVsync();
				#end
			case "compressTextures":
				SaveData.state.graphics.compressTextures = !SaveData.state.graphics.compressTextures;
				SaveData.save();
			case "frameRate":
				changeFrameRate(1);
		}

		_lastInfoText = null;
		_titleCache = [];
		if (alphabet != null && !closed) {
			alphabet.buffer.update();
		}

		if (graphicsStr[index] != "frameRate")
			Main.current.playCancelSound();
	}

	// -------------------- GRAPHICS SETTINGS --------------------

	function changeFrameRate(dir:Int) {
		var current = SaveData.state.graphics.frameRate;
		var idx = -1;
		for (i in 0...FRAMERATES.length) {
			if (FRAMERATES[i] == current) {
				idx = i;
				break;
			}
		}
		if (idx == -1) {
			// Snap to the nearest preset so SHIFT+LEFT/RIGHT always lands on one.
			var best = 0;
			var bestDist:Float = 1e10;
			for (i in 0...FRAMERATES.length) {
				var dist = Math.abs(FRAMERATES[i] - current);
				if (dist < bestDist) {
					bestDist = dist;
					best = i;
				}
			}
			idx = best;
		}

		var next = (idx + dir + FRAMERATES.length) % FRAMERATES.length;
		var rate = FRAMERATES[next];

		SaveData.state.graphics.frameRate = rate;
		Application.current.window.frameRate = rate;
		SaveData.save();

		_lastInfoText = null;
		_titleCache = [];
		Main.current.playScrollSound();
	}

	function toggleFullscreen() {
		var window = Application.current.window;
		window.fullscreen = !window.fullscreen;
	}

	#if LIME_840
	function toggleVsync() {
		FunkinMainLoop.run(FunkinMainLoop.FRAMERATE, false, !SaveData.state.graphics.vsync);
		SaveData.state.graphics.vsync = !SaveData.state.graphics.vsync;
		SaveData.save();
	}
	#end

	function cycleResolution() {
		var window = Application.current.window;
		var best = 0;
		var bestDist:Float = 1e10;
		for (i in 0...RESOLUTIONS.length) {
			var dist = Math.abs(RESOLUTIONS[i][0] - window.width) + Math.abs(RESOLUTIONS[i][1] - window.height);
			if (dist < bestDist) {
				bestDist = dist;
				best = i;
			}
		}
		var next = (best + 1) % RESOLUTIONS.length;
		window.width = RESOLUTIONS[next][0];
		window.height = RESOLUTIONS[next][1];
	}

	function getValueString(index:Int):String {
		var window = Application.current.window;
		switch (graphicsStr[index]) {
			case "resolution":
				return '${window.width}x${window.height}';
			case "fullscreen":
				return window.fullscreen ? "ON" : "OFF";
			case "compressTextures":
				return SaveData.state.graphics.compressTextures ? "ON" : "OFF";
			case "vsync":
				#if LIME_840
				return window.vsyncMode == VSyncMode.Adaptive ? "ON" : "OFF";
				#else
				return "OFF";
				#end
			case "frameRate":
				return '${Std.int(SaveData.state.graphics.frameRate)}';
		}
		return "";
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
		return graphicsStr.length;
	}

	public function alphabetItemTitle(index:Int):String {
		if (index < 0 || index >= graphicsStr.length)
			return "";
		if (index >= _titleCache.length || _titleCache[index] == null) {
			var displayText = getDisplayName(index);
			var str = displayText;
			for (i in 0...Math.floor((14 - displayText.length) * 1.13))
				str += " ";
			str += " ";
			str += getValueString(index);
			_titleCache[index] = str;
		}
		return _titleCache[index];
	}

	/**
		VSync is only supported on lime 8.4.0+, so gray it out on older limes.
	**/
	public function alphabetItemDisabled(index:Int):Bool {
		#if LIME_840
		return false;
		#else
		if (index < 0 || index >= graphicsStr.length)
			return true;
		return graphicsStr[index] == "vsync";
		#end
	}

	function getDisplayName(index:Int):String {
		switch (graphicsStr[index]) {
			case "resolution":
				return "Resolution";
			case "fullscreen":
				return "Fullscreen";
			case "vsync":
				return "VSync";
			case "frameRate":
				return "Frame Rate";
			case "compressTextures":
				return "Texture Compression";
		}
		return graphicsStr[index];
	}
}
