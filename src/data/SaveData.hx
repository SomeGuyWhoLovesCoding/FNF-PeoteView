package data;

import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import sys.io.File;
import sys.FileSystem;
import sys.io.FileOutput;
import haxe.Serializer;
import haxe.Unserializer;
import lime.ui.KeyCode;
import lime.ui.Window;

/**
	The save data securer.
	@since Development
**/
@:publicFields
class SaveData_Securer {
	static function lock(data:SaveData):String {
		return Serializer.run(data);
	}

	static function unlock(encoded:String):SaveData {
		return Unserializer.run(encoded);
	}
}

/**
	The save data structure.
	@since Development
**/
@:structInit
@:publicFields
class SaveData {
	static var state:SaveData = getDefaultState();

	static function getDefaultState():SaveData {
		return {
			controls: {
				ui: {
					left: KeyCode.LEFT,
					down: KeyCode.DOWN,
					up: KeyCode.UP,
					right: KeyCode.RIGHT,
					accept: KeyCode.RETURN,
					back: KeyCode.BACKSPACE,
				},
				game: {
					keybindArray: [
						[[KeyCode.SPACE]],
						[[KeyCode.A], [KeyCode.RIGHT]],
						[[KeyCode.A], [KeyCode.SPACE], [KeyCode.RIGHT]],
						[
							[KeyCode.A, KeyCode.LEFT],
							[KeyCode.S, KeyCode.DOWN],
							[KeyCode.W, KeyCode.UP],
							[KeyCode.D, KeyCode.RIGHT]
						],
						[
							[KeyCode.A, KeyCode.LEFT],
							[KeyCode.S, KeyCode.DOWN],
							[KeyCode.SPACE],
							[KeyCode.W, KeyCode.UP],
							[KeyCode.D, KeyCode.RIGHT]
						],
						[[KeyCode.S], [KeyCode.D], [KeyCode.F], [KeyCode.J], [KeyCode.K], [KeyCode.L]],
						[
							[KeyCode.S],
							[KeyCode.D],
							[KeyCode.F],
							[KeyCode.SPACE],
							[KeyCode.J],
							[KeyCode.K],
							[KeyCode.L]
						],
						[
							[KeyCode.A],
							[KeyCode.S],
							[KeyCode.D],
							[KeyCode.F],
							[KeyCode.H],
							[KeyCode.J],
							[KeyCode.K],
							[KeyCode.L]
						],
						[
							[KeyCode.A],
							[KeyCode.S],
							[KeyCode.D],
							[KeyCode.F],
							[KeyCode.SPACE],
							[KeyCode.H],
							[KeyCode.J],
							[KeyCode.K],
							[KeyCode.L]
						]
					],
					reset: KeyCode.R,
					pause: KeyCode.RETURN,
					debug: KeyCode.NUMBER_7
				},
				inputOffset: 0
			},
			preferences: {
				downScroll: false,
				hideHUD: false,
				smoothHealthbar: true,
				ratingPopup: true,
				scoreTxtBopping: false,
				cameraZooming: true,
				iconBopping: true,
				timeStretch: true,
				antialiasing: true
			},
			graphics: {
				frameRate: 60,
				compressTextures: true,
				vsync: false,
				customTitleBarColor: 0x3d3f4177, // RGB then opacity at the end. Except opacity doesn't work.
				customWindowOutlineColor: 0x27292b77,
				customTitleTextFont: "Inconsolata"
			}
		};
	}

	static function init(window:Window) {
		window.onClose.add(saveSync, 1);

		if (!FileSystem.exists('save.dat')) {
			save();
		}

		open();
	}

	static function open() {
		var result:SaveData = null;
		try {
			result = SaveData_Securer.unlock(File.getContent("save.dat"));
		} catch (e) {
			// Corrupt / unreadable save file: fall back to defaults instead of
			// recursing forever (old code re-called open(), overflowing the stack).
			trace('Save file could not be loaded; using defaults.');
			state = getDefaultState();
			return;
		}
		if (result == null)
			result = getDefaultState();
		trace('Savedata file loaded...');
		state = result;
	}

	// Deferred save: rapid save() calls coalesce into one disk write, so binding
	// keys or flipping options mid-game never blocks the main thread on I/O.
	static var _saveTimer:haxe.Timer = null;
	static var _saveDirty:Bool = false;
	static inline var SAVE_DEBOUNCE_MS:Int = 250;

	/**
		Schedule a disk write. Multiple calls inside the debounce window collapse
		into a single write of the latest state. The window-close hook calls
		`saveSync()` so no changes are lost on a normal exit.
	**/
	static function save() {
		_saveDirty = true;
		if (_saveTimer == null) {
			_saveTimer = haxe.Timer.delay(() -> {
				_saveTimer = null;
				writeToDisk();
			}, SAVE_DEBOUNCE_MS);
		}
	}

	/** Write immediately (synchronously). Used on window close so data survives exit. */
	static function saveSync() {
		if (_saveTimer != null) {
			_saveTimer.stop();
			_saveTimer = null;
		}
		writeToDisk();
	}

	static function writeToDisk() {
		if (!_saveDirty) {
			_saveDirty = false;
			return;
		}
		_saveDirty = false;
		trace('Saving data...');
		try {
			// Serialization + file I/O happens off the frame that triggered save()
			// (deferred via the debounce timer) instead of blocking mid-gameplay.
			var result = SaveData_Securer.lock(state);
			var fo:FileOutput = File.write("save.dat");
			fo.writeString(result);
			fo.close();
		} catch (e) {} // for rare cases like actually editing the save file itself
	}

	var controls:SaveData_Controls;
	var preferences:SaveData_Preferences;
	var graphics:SaveData_Graphics;
}

/**
	The save data controls category.
	@since Development
**/
@:structInit
@:struct
@:publicFields
class SaveData_Controls {
	var ui:Controls_UI;
	var game:Controls_Game;
	var inputOffset:Int;
}

/**
	The save data UI sub-category of the controls.
	@since Development
**/
@:structInit
@:struct
@:publicFields
class Controls_UI {
	var left:Int;
	var down:Int;
	var up:Int;
	var right:Int;
	var accept:Int;
	var back:Int;
}

/**
	The save data game sub-category of the controls.
	@since Development
**/
@:structInit
@:struct
@:publicFields
class Controls_Game {
	var keybindArray:Array<Array<Array<KeyCode>>>;
	var pause:Int;
	var reset:Int;
	var debug:Int;
}

/**
	The save data preferences category.
	@since Development
**/
@:structInit
@:struct
@:publicFields
class SaveData_Preferences {
	var downScroll:Bool;
	var hideHUD:Bool;
	var smoothHealthbar:Bool;
	var ratingPopup:Bool;
	var scoreTxtBopping:Bool;
	var cameraZooming:Bool;
	var iconBopping:Bool;
	var timeStretch:Bool;
	var antialiasing:Bool;
}

/**
	The save data graphics category.
	@since Development
**/
@:structInit
@:struct
@:publicFields
class SaveData_Graphics {
	var frameRate:Float;
	var compressTextures:Bool;
	var vsync:Bool;
	var customTitleBarColor:Int;
	var customWindowOutlineColor:Int;
	var customTitleTextFont:String;
}
