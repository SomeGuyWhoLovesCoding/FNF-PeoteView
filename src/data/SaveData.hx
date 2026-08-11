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
		window.onClose.add(save, 1);

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
			open();
			return;
		}
		trace('Savedata file loaded...');
		state = result;
	}

	static function save() {
		trace('Saving data...');
		try {
			//BOTTLENECK: low full haxe.Serializer graph serialization + blocking File.write on main thread (init/window-close only) | FIX: skip save when state unchanged; defer to background thread if call frequency grows
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
