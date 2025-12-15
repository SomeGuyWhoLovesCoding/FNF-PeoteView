package elements;

import elements.text.*;

/**
	The text buffer class.
**/
@:publicFields
class Text {
	var buffer:Buffer<TextCharSprite>;
	var program:Program;

	var _key:String;

	var display:Display;

	var text(default, set):String = "";

	function set_text(str:String) {
		//if (text.length == 0) text = "_";
		if (str == text) {
			return text;
		}

		var advanceX:Float = 0;

		if (text != null) {
			for (i in str.length...text.length) {
				var elem = buffer.getElement(i);
				if (elem != null) {
					elem.x = elem.y = -999999999;
					elem.w = elem.h = 0;  // Also set width/height to 0
					elem.alpha = 0;        // And make them invisible
				}

				buffer.updateElement(elem); // don't remove this or a bug will appear
			}
		}

		text = str;

		var quarterScale = scale / 4; // Yes, I did this intentionally.

		for (i in 0...str.length) {
			var code = str.charCodeAt(i);

			var data = parsedTextAtlasData[code];

			var canUseFromBuffer = i < buffer.length;

			var spr:TextCharSprite = canUseFromBuffer
				? buffer.getElement(i)
				: buffer.addElement(new TextCharSprite());

			spr.clipX = data[0];
			spr.clipY = data[1];
			spr.clipWidth = spr.clipSizeX = data[2];
			spr.w = (spr.clipWidth * quarterScale);
			spr.clipHeight = spr.clipSizeY = data[3];
			spr.h = (spr.clipHeight * quarterScale);
			spr.x = x + (data[4] * quarterScale) + advanceX;
			spr.y = y + (data[5] * quarterScale);
			spr.c = color;
			spr.oc = outlineColor;
			spr.os = outlineSize;
			spr.alpha = alpha;  // Restore alpha to current value
			advanceX += (data[6] * quarterScale);

			if (height < spr.h) {
				height = spr.h;
			}

			buffer.updateElement(spr);
		}

		width = advanceX;

		return str;
	}

	var x(default, set):Float;

	function set_x(value:Float) {
		if (value == x) {
			return x;
		}

		for (i in 0...text.length) {
			var elem = buffer.getElement(i);
			elem.x += value - x;

			buffer.updateElement(elem);
		}

		return x = value;
	}

	var y(default, set):Float;

	function set_y(value:Float) {
		if (value == y) {
			return y;
		}

		for (i in 0...text.length) {
			var elem = buffer.getElement(i);
			elem.y += value - y;

			buffer.updateElement(elem);
		}

		return y = value;
	}

	var scale(default, set):Float = 1.0;

	function set_scale(value:Float) {
		if (value == scale) {
			return scale;
		}

		scale = value;
		var quarterScale = scale / 4; // Yes, I did this intentionally.

		var advanceX:Float = 0;

		for (i in 0...text.length) {
			var code = text.charCodeAt(i);

			var data = parsedTextAtlasData[code];

			var spr = buffer.getElement(i);

			spr.clipX = data[0];
			spr.clipY = data[1];
			spr.clipWidth = spr.clipSizeX = data[2];
			spr.w = (spr.clipWidth * quarterScale);
			spr.clipHeight = spr.clipSizeY = data[3];
			spr.h = (spr.clipHeight * quarterScale);
			spr.x = x + (data[4] * quarterScale) + advanceX;
			spr.y = y + (data[5] * quarterScale);
			advanceX += (data[6] * quarterScale);

			if (height < spr.h) {
				height = spr.h;
			}

			buffer.updateElement(spr);
		}

		width = advanceX;
		_scale = scale;

		return value;
	}

	var _scale(default, null):Float = 1.0;

	var width(default, null):Float;

	var height(default, null):Float;

	var alpha(default, set):Float = 1.0;

	function set_alpha(value:Float):Float {
		for (i in 0...text.length) {
			var spr = buffer.getElement(i);
			if (spr != null) {
				spr.alpha = value;
			}

			buffer.updateElement(spr);
		}

		return alpha = value;
	}

	var color(default, set):Color = 0xFFFFFFFF;

	function set_color(value:Color):Color {
		for (i in 0...text.length) {
			var spr = buffer.getElement(i);
			if (spr != null) {
				spr.c = value;
			}

			buffer.updateElement(spr);
		}

		return color = value;
	}

	var outlineColor(default, set):Color = 0x000000FF;

	function set_outlineColor(value:Color):Color {
		for (i in 0...text.length) {
			var spr = buffer.getElement(i);
			if (spr != null) {
				spr.oc = value;
			}

			buffer.updateElement(spr);
		}

		return outlineColor = value;
	}

	var outlineSize(default, set):Float = 0;

	function set_outlineSize(value:Float):Float {
		if (outlineSize <= 0) outlineSize = -1;
		for (i in 0...text.length) {
			var spr = buffer.getElement(i);
			if (spr != null) {
				spr.os = value;
			}

			buffer.updateElement(spr);
		}

		return outlineSize = value;
	}

	var font(default, set):String;

	function set_font(value:String) {
		if (font == value) return value;
		parsedTextAtlasData = Tools.parseFont(value);
		var displayTextureID = value + "Font";
		TextureSystem.setTexture(program, displayTextureID, "font");
		return font = value;
	}

	function setMarkerPair(part:String, color:Color, outlineColor:Color = 0x000000FF, outlineSize:Float = 0) {
		var index = text.indexOf(part);

		for (i in index...index + part.length) {
			var spr = buffer.getElement(i);
			if (spr != null) {
				spr.c = color;
				spr.oc = outlineColor;
				spr.os = outlineSize;
			}

			buffer.updateElement(spr);
		}
	}

	var parsedTextAtlasData:Array<TextCharData>;

	function new(key:String, x:Float, y:Float, display:Display, text:String = "Sample text", font:String = "vcr") {
		_key = key;

		//trace("Okay, so new buffer is finally made now");
		buffer = new Buffer<TextCharSprite>(8, 8, false);

		var noProgram = program == null;

		if (noProgram) {
			program = new Program(buffer);
			program.blendEnabled = true;
			program.blendSrc = program.blendSrcAlpha = BlendFactor.ONE;
			program.blendDst = program.blendDstAlpha = BlendFactor.ONE_MINUS_SRC_ALPHA;
			program.setFragmentFloatPrecision('medium', true);

			program.injectIntoFragmentShader('
				vec4 outline(int textureID, float os, vec4 oc) {
					// original code from https://stackoverflow.com/q/69481402/21013172, translated using claude.ai

					// Since sprite is enlarged by formula w + (w * os * 2.0), 
					// the original texture should map to the center portion
					// Invert the enlargement: if new_size = old_size * (1 + os * 2), 
					// then old_size / new_size = 1 / (1 + os * 2)
					float invScale = 1.0 + os * 2.0;
					vec2 coord = (vTexCoord - 0.5) * invScale + 0.5;

					float x = coord.x;
					float y = coord.y;
					
					vec4 current = getTextureColor(textureID, coord);

					if (current.a <= 0.7) {
						float w = os;
						float h = os;
						
						if (getTextureColor(textureID, vec2(coord.x + w, coord.y)).a != 0.0
						|| getTextureColor(textureID, vec2(coord.x - w, coord.y)).a != 0.0
						|| getTextureColor(textureID, vec2(coord.x, coord.y + h)).a != 0.0
						|| getTextureColor(textureID, vec2(coord.x, coord.y - h)).a != 0.0)
							current = oc;
					}
					
					return current;
				}
			');

			program.setColorFormula('(os == 0.0 ? getTextureColor(font_ID, vTexCoord) : outline(font_ID, os, oc)) * (c * alphaColor)');
		}

		this.font = font;

		if (!program.isIn(display)) {
			display.addProgram(program);
		}

		//trace("Fuck all of this");
		//Sys.println(buffer != null);
		if (text.length == 0 || text == null) text = "Sample text";
		else this.text = text;
		this.x = x;
		this.y = y;

		this.display = display;
	}

	function dispose() {
		if (program.isIn(display)) {
			display.removeProgram(program);
		}
		buffer.clear();
		display = null;
	}
}