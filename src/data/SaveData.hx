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
**/
@:structInit
@:publicFields
class SaveData {
	static var state:SaveData = {
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
					[[KeyCode.A, KeyCode.LEFT], [KeyCode.S, KeyCode.DOWN], [KeyCode.W, KeyCode.UP], [KeyCode.D, KeyCode.RIGHT]],
					[[KeyCode.A, KeyCode.LEFT], [KeyCode.S, KeyCode.DOWN], [KeyCode.SPACE], [KeyCode.W, KeyCode.UP], [KeyCode.D, KeyCode.RIGHT]],
					[[KeyCode.S], [KeyCode.D], [KeyCode.F], [KeyCode.J], [KeyCode.K], [KeyCode.L]],
					[[KeyCode.S], [KeyCode.D], [KeyCode.F], [KeyCode.SPACE], [KeyCode.J], [KeyCode.K], [KeyCode.L]],
					[[KeyCode.A], [KeyCode.S], [KeyCode.D], [KeyCode.F], [KeyCode.H], [KeyCode.J], [KeyCode.K], [KeyCode.L]],
					[[KeyCode.A], [KeyCode.S], [KeyCode.D], [KeyCode.F], [KeyCode.SPACE], [KeyCode.H], [KeyCode.J], [KeyCode.K], [KeyCode.L]]
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
			iconBopping: true
		},
		graphics: {
			frameRate: 0,
			antialiasing: true,
			customTitleBarColor: 0x3d3f4177, // RGB then opacity at the end. Except opacity doesn't work.
			customWindowOutlineColor: 0x27292b77,
			customTitleTextFont: "Inconsolata"
		}
	};

	static function init(window:Window) {
		window.onClose.add(save, Math.floor(-Math.POSITIVE_INFINITY));
		//lime.app.Application.onExit.add(save); // Much better. window.onClose doesn't even work on my lime fork anymore due to the change I made to remove recursion so I basically just did this:

		if (!FileSystem.exists('save.dat')) {
			save();
		}

		open();
	}

	static function open() {
		var result:SaveData = null;
		try {
			result = SaveData_Securer.unlock(File.getContent("save.dat"));
			trace('AAAAAAAAAAAAAAAAAA2');
		} catch (e) {
			open();
			trace('AAAAAAAAAAAAAAAAAA');
			return;
		}
		state = result;
	}

	static function save() {
		//trace('Reah');
		try {
			var result = SaveData_Securer.lock(state);
			//FileSystem.deleteFile("save.dat");
			var fo:FileOutput = File.write("save.dat");
			fo.writeString(result);
			fo.close();
		} catch(e) {
			//trace('Reah');
		} // for rare cases like actually editing the save file itself
	}

	var controls:SaveData_Controls;
	var preferences:SaveData_Preferences;
	var graphics:SaveData_Graphics;
}

/**
	The save data controls category.
**/
@:structInit
@:publicFields
class SaveData_Controls {
	var ui:Controls_UI;
	var game:Controls_Game;
	var inputOffset:Int;
}

/**
	The save data UI sub-category of the controls.
**/
@:structInit
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
**/
@:structInit
@:publicFields
class Controls_Game {
	var keybindArray:Array<Array<Array<KeyCode>>>;
	var pause:Int;
	var reset:Int;
	var debug:Int;
}


/**
	The save data preferences category.
**/
@:structInit
@:publicFields
class SaveData_Preferences {
	var downScroll:Bool;
	var hideHUD:Bool;
	var smoothHealthbar:Bool;
	var ratingPopup:Bool;
	var scoreTxtBopping:Bool;
	var cameraZooming:Bool;
	var iconBopping:Bool;
}

/**
	The save data graphics category.
**/
@:structInit
@:publicFields
class SaveData_Graphics {
	var frameRate:Float;
	var antialiasing:Bool;
	var customTitleBarColor:Int;
	var customWindowOutlineColor:Int;
	var customTitleTextFont:String;
}
