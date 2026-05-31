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
			game: defaultControlsGame(),
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
		migrate(state);
	}

	static function migrate(data:SaveData) {
		var game = data.controls.game;
		if (game.mania < 1 || game.mania > 16) game.mania = 4;
		var defaults = defaultKeybindArray();
		while (game.keybindArray.length < defaults.length) {
			game.keybindArray.push(defaults[game.keybindArray.length]);
		}

		var ui = data.controls.ui;
		if (ui.left == 0) ui.left = KeyCode.LEFT;
		if (ui.down == 0) ui.down = KeyCode.DOWN;
		if (ui.up == 0) ui.up = KeyCode.UP;
		if (ui.right == 0) ui.right = KeyCode.RIGHT;
		if (ui.accept == 0) ui.accept = KeyCode.RETURN;
		if (ui.back == 0) ui.back = KeyCode.BACKSPACE;
	}

	static function defaultControlsGame():Controls_Game {
		return {
			mania: 4,
			keybindArray: defaultKeybindArray(),
			reset: KeyCode.R,
			pause: KeyCode.RETURN,
			debug: KeyCode.NUMBER_7
		};
	}

	static function defaultKeybindArray():Array<Array<Array<KeyCode>>> {
		return [
			[[KeyCode.SPACE]],
			[[KeyCode.A], [KeyCode.RIGHT]],
			[[KeyCode.A], [KeyCode.SPACE], [KeyCode.RIGHT]],
			[[KeyCode.A, KeyCode.LEFT], [KeyCode.S, KeyCode.DOWN], [KeyCode.W, KeyCode.UP], [KeyCode.D, KeyCode.RIGHT]],
			[[KeyCode.A, KeyCode.LEFT], [KeyCode.S, KeyCode.DOWN], [KeyCode.SPACE], [KeyCode.W, KeyCode.UP], [KeyCode.D, KeyCode.RIGHT]],
			[[KeyCode.S], [KeyCode.D], [KeyCode.F], [KeyCode.J], [KeyCode.K], [KeyCode.L]],
			[[KeyCode.S], [KeyCode.D], [KeyCode.F], [KeyCode.SPACE], [KeyCode.J], [KeyCode.K], [KeyCode.L]],
			[[KeyCode.A], [KeyCode.S], [KeyCode.D], [KeyCode.F], [KeyCode.H], [KeyCode.J], [KeyCode.K], [KeyCode.L]],
			[[KeyCode.A], [KeyCode.S], [KeyCode.D], [KeyCode.F], [KeyCode.SPACE], [KeyCode.H], [KeyCode.J], [KeyCode.K], [KeyCode.L]],
			generatedKeybinds(10),
			generatedKeybinds(11),
			generatedKeybinds(12),
			generatedKeybinds(13),
			generatedKeybinds(14),
			generatedKeybinds(15),
			generatedKeybinds(16),
		];
	}

	static function generatedKeybinds(laneCount:Int):Array<Array<KeyCode>> {
		var row = [
			KeyCode.A, KeyCode.S, KeyCode.D, KeyCode.F, KeyCode.G,
			KeyCode.H, KeyCode.J, KeyCode.K, KeyCode.L, KeyCode.SEMICOLON,
			KeyCode.QUOTE, KeyCode.BACKSLASH, KeyCode.Z, KeyCode.X, KeyCode.C, KeyCode.V
		];
		return [for (i in 0...laneCount) [row[i % row.length]]];
	}

	static function save() {
		trace('Saving data...');
		try {
			var result = SaveData_Securer.lock(state);
			var fo:FileOutput = File.write("save.dat");
			fo.writeString(result);
			fo.close();
		} catch(e) {} // for rare cases like actually editing the save file itself
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
@:publicFields
class Controls_Game {
	/** Selected keybind layout (1–16 keys). **/
	var mania:Int;
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
	@since Development
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
