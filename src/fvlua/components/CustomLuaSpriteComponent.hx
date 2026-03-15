package fvlua.components;

import sys.FileSystem;
import haxe.ds.StringMap;

using StringTools;

/**
	A single Lua script instance for Funkin' View.
**/
@:publicFields
class CustomLuaSpriteComponent {
	#if linc_luajit_funkinview
	public var parent(default, null):FunkinViewLua;
	public var playField(default, null):PlayField;

	public var customBuffers(default, null):StringMap<Buffer<LuaSprite>>;
	public var customPrograms(default, null):StringMap<LuaProgram>;
	public var customTextures(default, null):StringMap<Texture>;
	public var customSprites(default, null):StringMap<LuaSprite>;
	public var customTexts(default, null):StringMap<LuaText>;

	public function new(parent:FunkinViewLua) {
		this.parent = parent;
		playField = parent.parent;

		customBuffers = new StringMap<Buffer<LuaSprite>>();
		customPrograms = new StringMap<LuaProgram>();
		customTextures = new StringMap<Texture>();
		customSprites = new StringMap<LuaSprite>();
		customTexts = new StringMap<LuaText>();
	}

	// functions are a placeholder.
	public function addCallbacksList(vm:FunkinViewLuaScript) {
		// NEW
		vm.addCallback("customBufferNew", (bufferName:String, minSize:Int, growSize:Int = 0, autoShrink:Bool = false) -> {
			//trace('args:$bufferName,$minSize,$growSize,$autoShrink');
			if (bufferName == "" || bufferName == null) {
				FunkinViewLua.error("Custom Buffer's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			customBuffers.set(bufferName, new Buffer<LuaSprite>(minSize, growSize, autoShrink));
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("customProgramNew", (programName:String, customBuffer:String) -> {
			//trace('args:$programName,$customBuffer');
			if (programName == "" || programName == null) {
				FunkinViewLua.error("Custom Program's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			if (!customBuffers.exists(customBuffer)) {
				FunkinViewLua.error("Custom Buffer not found: " + customBuffer);
				return FunkinViewLua.Function_Stop;
			}
			var buffer = customBuffers.get(customBuffer);
			customPrograms.set(programName, new LuaProgram(buffer));
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("customElementNew", (elem:String, x:Int, y:Int, w:Float, h:Float, color:String = "white") -> {
			if (elem == "" || elem == null) {
				FunkinViewLua.error("Custom Element's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			var sprite = new LuaSprite(x, y, Std.int(w), Std.int(h));

			sprite.c = FunkinViewLua.colorFromStringUtil(color);
			customSprites.set(elem, sprite);

			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("customTextNew", (textElem:String, x:Int, y:Int, toDisplay:String, text:String, font:String = "vcr",
			color:String = "white", outlineSize:Int = 0, outlineColor:String = "black") -> {
			if (textElem == "" || textElem == null) {
				FunkinViewLua.error("Custom Text's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			var displayValue = toDisplay.toLowerCase();
			var display = Reflect.field(playField, toDisplay.toLowerCase());
			if (display == null) {
				FunkinViewLua.error("Display not found: " + toDisplay.toLowerCase());
				return FunkinViewLua.Function_Stop;
			}
			var sprite = new LuaText(textElem, x, y, display, text, font);

			sprite.color = FunkinViewLua.colorFromStringUtil(color);
			sprite.outlineSize = outlineSize;
			sprite.outlineColor = FunkinViewLua.colorFromStringUtil(outlineColor);
			customTexts.set(textElem, sprite);

			return FunkinViewLua.Function_Continue;
		}); // note: text is automatically added in by init as shown in the `Text` class.

		// ADD
		vm.addCallback("addElementToBuffer", (elemName:String, bufferName:String) -> {
			if (elemName == "" || elemName == null) {
				return FunkinViewLua.Function_Stop;
			}
			if (!customSprites.exists(elemName)) {
				FunkinViewLua.error("Custom Element not found: " + elemName);
				return FunkinViewLua.Function_Stop;
			}
			if (!customBuffers.exists(bufferName)) {
				FunkinViewLua.error("Custom Buffer not found: " + bufferName);
				return FunkinViewLua.Function_Stop;
			}
			var sprite = customSprites.get(elemName);
			var buffer = customBuffers.get(bufferName);
			buffer.addElement(sprite);
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("addTextureToProgram", (programName:String, texturePNG:String, disableAntialiasing:Bool = false) -> {
			//trace('args:$programName,$texturePNG,$disableAntialiasing');
			if (programName == "" || programName == null) {
				FunkinViewLua.error("Custom Program's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			if (!customPrograms.exists(programName)) {
				FunkinViewLua.error("Custom Program not found: " + programName);
				return FunkinViewLua.Function_Stop;
			}
			//var texKey = '##${texturePNG.replace('.png', '')}_CUSTOMLUATEXTURE';
			var program = customPrograms.get(programName);
			//trace('Custom Program: $program');
			var texPath = Paths.asset(texturePNG);
			if (!FileSystem.exists(texPath)) {
				FunkinViewLua.error("Image not found: " + texPath);
				return FunkinViewLua.Function_Stop;
			}
			// this was going to be customLuaTexture_key btw.
			TextureSystem.createTexture(programName, texturePNG, disableAntialiasing, true);
			//trace('Custom Texture: ${TextureSystem.getTexture(programName)}');
			TextureSystem.setTexture(program, programName, programName);
			//trace('Added Custom Texture: ${TextureSystem.getTexture(programName)}');
			customTextures.set(programName, TextureSystem.getTexture(programName));
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("addProgramToDisplay", (programName:String, toDisplay:String, isBehind:Bool = false, ?atCustomProgram:String) -> {
			//trace('args:$programName,$toDisplay,$isBehind');
			if (programName == "" || programName == null) {
				FunkinViewLua.error("Custom Program's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			if (!customPrograms.exists(programName)) {
				FunkinViewLua.error("Custom Program not found: " + programName);
				return FunkinViewLua.Function_Stop;
			}
			var program = customPrograms.get(programName);
			var displayValue = toDisplay.toLowerCase();
			var display = Reflect.field(playField, toDisplay.toLowerCase());
			if (display == null) {
				FunkinViewLua.error("Display not found: " + toDisplay.toLowerCase());
				return FunkinViewLua.Function_Stop;
			}
			if (!customPrograms.exists(atCustomProgram) && atCustomProgram != null) {
				FunkinViewLua.error("Custom Program not found: " + programName);
				return FunkinViewLua.Function_Stop;
			}
			var atProgram = atCustomProgram != null ? customPrograms.get(atCustomProgram) : null;
			if (atProgram == null)
				display.addProgram(program, null, isBehind);
			else
				display.addProgram(program, atProgram, isBehind);
			program.visibleToDisplays.push(display);
			return FunkinViewLua.Function_Continue;
		});

		// REMOOVE
		vm.addCallback("removeElementFromBuffer", (elemName:String, bufferName:String) -> {
			if (elemName == "" || elemName == null) {
				return FunkinViewLua.Function_Stop;
			}
			if (!customSprites.exists(elemName)) {
				FunkinViewLua.error("Custom Element not found: " + elemName);
				return FunkinViewLua.Function_Stop;
			}
			if (!customBuffers.exists(bufferName)) {
				FunkinViewLua.error("Custom Buffer not found: " + bufferName);
				return FunkinViewLua.Function_Stop;
			}
			var sprite = customSprites.get(elemName);
			var buffer = customBuffers.get(bufferName);
			buffer.removeElement(sprite);
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("wipeTextureFromProgram", (programName:String) -> {
			if (programName == "" || programName == null) {
				FunkinViewLua.error("Custom Program's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			if (!customPrograms.exists(programName)) {
				FunkinViewLua.error("Custom Program not found: " + programName);
				return FunkinViewLua.Function_Stop;
			}
			var program = customPrograms.get(programName);
			var texture = customTextures.get(programName);
			program.removeTexture(texture);
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("removeProgramFromDisplay", (programName:String, fromDisplay:String) -> {
			if (programName == "" || programName == null) {
				FunkinViewLua.error("Custom Program's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			if (!customPrograms.exists(programName)) {
				FunkinViewLua.error("Custom Program not found: " + programName);
				return FunkinViewLua.Function_Stop;
			}
			var program = customPrograms.get(programName);
			var display = Reflect.field(playField, fromDisplay.toLowerCase());
			if (display == null) {
				FunkinViewLua.error("Display not found: " + fromDisplay.toLowerCase());
				return FunkinViewLua.Function_Stop;
			}
			display.removeProgram(program);
			program.visibleToDisplays.remove(display);
			return FunkinViewLua.Function_Continue;
		});

		// UPDATE
		vm.addCallback("updateElementToBuffer", (elemName:String, bufferName:String) -> {
			if (elemName == "" || elemName == null) {
				return FunkinViewLua.Function_Stop;
			}
			if (!customSprites.exists(elemName)) {
				FunkinViewLua.error("Custom Element not found: " + elemName);
				return FunkinViewLua.Function_Stop;
			}
			if (!customBuffers.exists(bufferName)) {
				FunkinViewLua.error("Custom Buffer not found: " + bufferName);
				return FunkinViewLua.Function_Stop;
			}
			var sprite = customSprites.get(elemName);
			var buffer = customBuffers.get(bufferName);
			buffer.updateElement(sprite);
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("setDisplayAngle", (fromDisplay:String, rotation:Float) -> {
			var display = Reflect.field(playField, fromDisplay.toLowerCase());
			if (display == null) {
				FunkinViewLua.error("Display not found: " + fromDisplay.toLowerCase());
			}
			display.r = rotation;
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("updateBuffer", (bufferName:String) -> {
			if (bufferName == "" || bufferName == null) {
				return FunkinViewLua.Function_Stop;
			}
			if (!customBuffers.exists(bufferName)) {
				FunkinViewLua.error("Custom Buffer not found: " + bufferName);
				return FunkinViewLua.Function_Stop;
			}
			var buffer = customBuffers.get(bufferName);
			buffer.update();
			return FunkinViewLua.Function_Continue;
		});

		// GET/SET ELEMENT PROPS
		vm.addCallback("setElementPos", (elemName:String, x:Float, y:Float) -> {
			if (elemName == "" || elemName == null) {
				return FunkinViewLua.Function_Stop;
			}
			if (!customSprites.exists(elemName)) {
				FunkinViewLua.error("Custom Element not found: " + elemName);
				return FunkinViewLua.Function_Stop;
			}
			var sprite = customSprites.get(elemName);
			sprite.x = x;
			sprite.y = y;
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("getElementPosX", (elemName:String) -> {
			if (elemName == "" || elemName == null) {
				return 0.0;
			}
			if (!customSprites.exists(elemName)) {
				FunkinViewLua.error("Custom Element not found: " + elemName);
				return 0.0;
			}
			var sprite = customSprites.get(elemName);
			return sprite.x;
		});
		vm.addCallback("getElementPosY", (elemName:String) -> {
			if (elemName == "" || elemName == null) {
				return 0.0;
			}
			if (!customSprites.exists(elemName)) {
				FunkinViewLua.error("Custom Element not found: " + elemName);
				return 0.0;
			}
			var sprite = customSprites.get(elemName);
			return sprite.y;
		});
		vm.addCallback("setTextPos", (textElem:String, x:Int, y:Int) -> {
			if (textElem == "" || textElem == null) {
				FunkinViewLua.error("Custom Text's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			var sprite = customTexts.get(textElem);
			sprite.x = x;
			sprite.y = y;
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("getTextPosX", (textElem:String) -> {
			if (textElem == "" || textElem == null) {
				FunkinViewLua.error("Custom Text's Key cannot be empty or nil!");
				return 0.0;
			}
			var sprite = customTexts.get(textElem);
			return sprite.x;
		});
		vm.addCallback("getTextPosY", (textElem:String) -> {
			if (textElem == "" || textElem == null) {
				FunkinViewLua.error("Custom Text's Key cannot be empty or nil!");
				return 0.0;
			}
			var sprite = customTexts.get(textElem);
			return sprite.y;
		});
		vm.addCallback("setElementCoordinate", (elemName:String, w:Float, h:Float) -> {
			if (elemName == "" || elemName == null) {
				return FunkinViewLua.Function_Stop;
			}
			if (!customSprites.exists(elemName)) {
				FunkinViewLua.error("Custom Element not found: " + elemName);
				return FunkinViewLua.Function_Stop;
			}
			var sprite = customSprites.get(elemName);
			sprite.w = w;
			sprite.h = h;
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("getElementCoordinateX", (elemName:String) -> {
			if (elemName == "" || elemName == null) {
				return 0.0;
			}
			if (!customSprites.exists(elemName)) {
				FunkinViewLua.error("Custom Element not found: " + elemName);
				return 0.0;
			}
			var sprite = customSprites.get(elemName);
			return sprite.w;
		});
		vm.addCallback("getElementCoordinateY", (elemName:String) -> {
			if (elemName == "" || elemName == null) {
				return 0.0;
			}
			if (!customSprites.exists(elemName)) {
				FunkinViewLua.error("Custom Element not found: " + elemName);
				return 0.0;
			}
			var sprite = customSprites.get(elemName);
			return sprite.h;
		});
		vm.addCallback("setTextString", (textElem:String, text:String) -> {
			if (textElem == "" || textElem == null) {
				FunkinViewLua.error("Custom Text's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			var sprite = customTexts.get(textElem);
			sprite.text = text;
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("getTextString", (textElem:String) -> {
			if (textElem == "" || textElem == null) {
				FunkinViewLua.error("Custom Text's Key cannot be empty or nil!");
				return "";
			}
			var sprite = customTexts.get(textElem);
			return sprite.text;
		});
		vm.addCallback("setElementTint", (elemName:String, color:String) -> {
			if (elemName == "" || elemName == null) {
				return FunkinViewLua.Function_Stop;
			}
			if (!customSprites.exists(elemName)) {
				FunkinViewLua.error("Custom Element not found: " + elemName);
				return FunkinViewLua.Function_Stop;
			}
			var sprite = customSprites.get(elemName);

			sprite.c = FunkinViewLua.colorFromStringUtil(color);
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("getElementTint", (elemName:String) -> {
			if (elemName == "" || elemName == null) {
				return "0x00000000";
			}
			if (!customSprites.exists(elemName)) {
				FunkinViewLua.error("Custom Element not found: " + elemName);
				return "0x00000000";
			}
			var sprite = customSprites.get(elemName);
			return "0x" + StringTools.hex(sprite.c, 8);
		});
		vm.addCallback("setTextColor", (textElem:String, color:String) -> {
			if (textElem == "" || textElem == null) {
				FunkinViewLua.error("Custom Text's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			var sprite = customTexts.get(textElem);
			sprite.color = FunkinViewLua.colorFromStringUtil(color);
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("getTextColor", (textElem:String) -> {
			if (textElem == "" || textElem == null) {
				FunkinViewLua.error("Custom Text's Key cannot be empty or nil!");
				return "0x00000000";
			}
			var sprite = customTexts.get(textElem);
			return "0x" + StringTools.hex(sprite.color, 8);
		});
		vm.addCallback("setTextOutlineColor", (textElem:String, color:String) -> {
			if (textElem == "" || textElem == null) {
				FunkinViewLua.error("Custom Text's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			var sprite = customTexts.get(textElem);
			sprite.outlineColor = FunkinViewLua.colorFromStringUtil(color);
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("getTextOutlineColor", (textElem:String) -> {
			if (textElem == "" || textElem == null) {
				FunkinViewLua.error("Custom Text's Key cannot be empty or nil!");
				return "0x00000000";
			}
			var sprite = customTexts.get(textElem);
			return "0x" + StringTools.hex(sprite.outlineColor, 8);
		});
		vm.addCallback("setTextOutlineSize", (textElem:String, size:Float) -> {
			if (textElem == "" || textElem == null) {
				FunkinViewLua.error("Custom Text's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			var sprite = customTexts.get(textElem);
			sprite.outlineSize = size;
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("getTextOutlineSize", (textElem:String) -> {
			if (textElem == "" || textElem == null) {
				FunkinViewLua.error("Custom Text's Key cannot be empty or nil!");
				return 0.0;
			}
			var sprite = customTexts.get(textElem);
			return sprite.outlineSize;
		});
		vm.addCallback("screenCenterElement", (elemName:String, fromDisplay:String, axis:String) -> {
			if (elemName == "" || elemName == null) {
				return FunkinViewLua.Function_Stop;
			}
			if (!customSprites.exists(elemName)) {
				FunkinViewLua.error("Custom Element not found: " + elemName);
				return FunkinViewLua.Function_Stop;
			}
			var display = Reflect.field(playField, fromDisplay.toLowerCase());
			if (display == null) {
				FunkinViewLua.error("Display not found: " + fromDisplay.toLowerCase());
			}
			var sprite = customSprites.get(elemName);
			sprite.screenCenter(display, switch (axis.toUpperCase()) {
				case "X":
					X;
				case "Y":
					Y;
				default:
					XY;
			});
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("screenCenterText", (elemName:String, axis:String) -> {
			if (elemName == "" || elemName == null) {
				return FunkinViewLua.Function_Stop;
			}
			if (!customTexts.exists(elemName)) {
				FunkinViewLua.error("Custom Text not found: " + elemName);
				return FunkinViewLua.Function_Stop;
			}
			var sprite = customTexts.get(elemName);
			sprite.screenCenter(switch (axis.toUpperCase()) {
				case "X":
					X;
				case "Y":
					Y;
				default:
					XY;
			});
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("setElementAngle", (elemName:String, rotation:Float) -> {
			if (elemName == "" || elemName == null) {
				return FunkinViewLua.Function_Stop;
			}
			if (!customSprites.exists(elemName)) {
				FunkinViewLua.error("Custom Element not found: " + elemName);
				return FunkinViewLua.Function_Stop;
			}
			var sprite = customSprites.get(elemName);
			sprite.r = rotation;
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("getElementAngle", (elemName:String) -> {
			if (elemName == "" || elemName == null) {
				return 0.0;
			}
			if (!customSprites.exists(elemName)) {
				FunkinViewLua.error("Custom Element not found: " + elemName);
				return 0.0;
			}
			var sprite = customSprites.get(elemName);
			return sprite.r;
		});
		vm.addCallback("setElementAlpha", (elemName:String, alpha:Float) -> {
			if (elemName == "" || elemName == null) {
				return FunkinViewLua.Function_Stop;
			}
			if (!customSprites.exists(elemName)) {
				FunkinViewLua.error("Custom Element not found: " + elemName);
				return FunkinViewLua.Function_Stop;
			}
			var sprite = customSprites.get(elemName);
			sprite.c.aF = alpha;
			sprite.c.luminanceF = alpha;
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("getElementAlpha", (elemName:String) -> {
			if (elemName == "" || elemName == null) {
				return 1.0;
			}
			if (!customSprites.exists(elemName)) {
				FunkinViewLua.error("Custom Element not found: " + elemName);
				return 1.0;
			}
			var sprite = customSprites.get(elemName);
			return sprite.c.aF;
		});
		vm.addCallback("setTextAlpha", (elemName:String, alpha:Float) -> {
			if (elemName == "" || elemName == null) {
				return FunkinViewLua.Function_Stop;
			}
			if (!customTexts.exists(elemName)) {
				FunkinViewLua.error("Custom Text not found: " + elemName);
				return FunkinViewLua.Function_Stop;
			}
			var sprite = customTexts.get(elemName);
			sprite.alpha = alpha;
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("getTextAlpha", (elemName:String) -> {
			if (elemName == "" || elemName == null) {
				return 1.0;
			}
			if (!customTexts.exists(elemName)) {
				FunkinViewLua.error("Custom Text not found: " + elemName);
				return 1.0;
			}
			var sprite = customTexts.get(elemName);
			return sprite.alpha;
		});
		vm.addCallback("setTextFormatMarkerPairs", (textElem:String, colors:Array<Dynamic>) -> {
			if (textElem == "" || textElem == null) {
				FunkinViewLua.error("Custom Text's Key cannot be empty or nil!");
				return FunkinViewLua.Function_Stop;
			}
			if (!customTexts.exists(textElem)) {
				FunkinViewLua.error("Custom Text not found: " + textElem);
				return FunkinViewLua.Function_Stop;
			}
			var sprite = customTexts.get(textElem);
			var pairs:Array<TextFormatMarkerPair> = [];
			for (entry in colors) {
				var marker:String = entry.marker;
				var color:Color = FunkinViewLua.colorFromStringUtil(entry.color);
				trace("Color: " + color, entry.color);
				var outlineColor:Color = FunkinViewLua.colorFromStringUtil(entry.outlineColor ?? "0x00000000");
				var outlineSize:Float = entry.outlineSize ?? 0.0;
				pairs.push(new TextFormatMarkerPair(marker, color, outlineColor, outlineSize));
			}
			sprite.setMarkerPairs(pairs);
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("hideText", (elemName:String) -> {
			if (elemName == "" || elemName == null) {
				return FunkinViewLua.Function_Stop;
			}
			if (!customTexts.exists(elemName)) {
				FunkinViewLua.error("Custom Text not found: " + elemName);
				return FunkinViewLua.Function_Stop;
			}
			var sprite = customTexts.get(elemName);
			try { sprite.removeProgram(); } catch(E) {}
			return FunkinViewLua.Function_Continue;
		});
		vm.addCallback("showText", (elemName:String) -> {
			if (elemName == "" || elemName == null) {
				return FunkinViewLua.Function_Stop;
			}
			if (!customTexts.exists(elemName)) {
				FunkinViewLua.error("Custom Text not found: " + elemName);
				return FunkinViewLua.Function_Stop;
			}
			var sprite = customTexts.get(elemName);
			try { sprite.addProgram(); } catch(E) {}
			return FunkinViewLua.Function_Continue;
		});

		// OTHER STUFF
		vm.addCallback("getTextureCoordinateX", (programName:String) -> {
			if (programName == "" || programName == null) {
				FunkinViewLua.error("Custom Program's Key cannot be empty or nil!");
				return 100;
			}
			var tex = customTextures.get(programName);
			return tex.width;
		});

		vm.addCallback("getTextureCoordinateY", (programName:String) -> {
			if (programName == "" || programName == null) {
				FunkinViewLua.error("Custom Program's Key cannot be empty or nil!");
				return 100;
			}
			var tex = customTextures.get(programName);
			return tex.height;
		});
	}

	public function dispose() {
		parent = null;
		playField = null;

		for (customBuffer in customBuffers) {
			if (customBuffer != null) {
				customBuffer.clear();
				customBuffer = null;
			}
		}
		customBuffers.clear();
		customBuffers = null;

		for (customProgram in customPrograms) {
			if (customProgram != null) {
				for (displayVisible in customProgram.visibleToDisplays)
					customProgram.removeFromDisplay(displayVisible);
				customProgram = null;
			}
		}
		customPrograms.clear();
		customPrograms = null;

		for (customTexture in customTextures) {
			if (customTexture != null) {
				customTexture = null;
			}
		}
		customTextures.clear();
		customTextures = null;

		for (customSprite in customSprites) {
			if (customSprite != null) {
				customSprite = null;
			}
		}
		customSprites.clear();
		customSprites = null;

		for (customText in customTexts) {
			if (customText != null) {
				customText.dispose();
				customText = null;
			}
		}
		customTexts.clear();
		customTexts = null;
	}
	#end
}