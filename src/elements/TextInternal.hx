package elements;

import elements.text.*;

/**
	One rendered layer of text (either the outline pass or the fill pass).
	This is the original `Text` GPU/sprite logic, extracted verbatim so
	`Text` can own two of these — one behind (outline), one in front (fill).
**/
@:publicFields
class TextInternal {

	private static inline var TEXT_FRAGMENT_SHADER = '
		vec4 pixelAlpha(int textureID) {
			vec4 current = getTextureColor(textureID, vTexCoord);
			// Apply threshold for hard edges
			float alpha = step(0.5, current.a);
			return vec4(current.rgb, alpha);
		}
	';

	var buffer:Buffer<TextCharSprite>;
	var program:CustomProgram;
	var display:Display;

	var text(default, set):String = "";
	var isOutlineLayer:Bool; // Flag to identify if this is an outline layer

	function set_text(str:String) {
		if (str == text) return text;

		var advanceX:Float = 0;

		if (text != null) {
			for (i in str.length...text.length) {
				var elem = buffer.getElement(i);
				if (elem != null) {
					elem.x = elem.y = -999999999;
					elem.w = elem.h = 0;
					elem.alpha = 0;
				}
				buffer.updateElement(elem);
			}
		}

		text = str;

		var quarterScale = scale / 4;

		for (i in 0...str.length) {
			var code = str.charCodeAt(i);
			var data = parsedTextAtlasData[code];
			var canUseFromBuffer = i < buffer.length;

			var spr:TextCharSprite = canUseFromBuffer
				? buffer.getElement(i)
				: buffer.addElement(new TextCharSprite());

			advanceX = setupCharSprite(spr, data, quarterScale, x, y, advanceX, color, outlineColor, outlineSize, alpha, parsedTextAtlasData);

			if (height < spr.h + spr.y - data[1]) {
				height = spr.h + spr.y - data[1];
			}

			buffer.updateElement(spr);
		}

		width = advanceX;

		return str;
	}

	var x(default, set):Float = 0;

	function set_x(value:Float) {
		if (value == x) return x;

		for (i in 0...text.length) {
			var elem = buffer.getElement(i);
			elem.x += value - x;
			buffer.updateElement(elem);
		}

		return x = value;
	}

	var y(default, set):Float = 0;

	function set_y(value:Float) {
		if (value == y) return y;

		for (i in 0...text.length) {
			var elem = buffer.getElement(i);
			elem.y += value - y;
			buffer.updateElement(elem);
		}

		return y = value;
	}

	var scale(default, set):Float = 1.0;

	function set_scale(value:Float) {
		if (value == scale) return scale;

		scale = value;
		var quarterScale = scale / 4;
		var advanceX:Float = 0;

		for (i in 0...text.length) {
			var code = text.charCodeAt(i);
			var data = parsedTextAtlasData[code];
			var spr = buffer.getElement(i);

			advanceX = setupCharSpriteScaled(spr, data, quarterScale, x, y, advanceX, parsedTextAtlasData);

			if (height < spr.h + spr.y - data[1]) {
				height = spr.h + spr.y - data[1];
			}

			buffer.updateElement(spr);
		}

		width = advanceX;
		height = parsedTextAtlasData[256][2] * quarterScale;
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
			if (spr != null) spr.alpha = value;
			buffer.updateElement(spr);
		}
		return alpha = value;
	}

	var color(default, set):Color = 0xFFFFFFFF;

	function set_color(value:Color):Color {
		for (i in 0...text.length) {
			var spr = buffer.getElement(i);
			if (spr != null) spr.c = value;
			buffer.updateElement(spr);
		}
		return color = value;
	}

	var outlineColor(default, set):Color = 0x000000FF;

	function set_outlineColor(value:Color):Color {
		for (i in 0...text.length) {
			var spr = buffer.getElement(i);
			if (spr != null) spr.oc = value;
			buffer.updateElement(spr);
		}
		return outlineColor = value;
	}

	var outlineSize(default, set):Float = 0;

	function set_outlineSize(value:Float):Float {
		for (i in 0...text.length) {
			var spr = buffer.getElement(i);
			if (spr != null) spr.os = value;
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
				spr.c  = color;
				spr.oc = outlineColor;
				spr.os = outlineSize;
			}
			buffer.updateElement(spr);
		}
	}

	var parsedTextAtlasData:Array<TextCharData>;

	function setupCharSprite(spr:TextCharSprite, data:TextCharData, quarterScale:Float, x:Float, y:Float, advanceX:Float, color:Color, outlineColor:Color, outlineSize:Float, alpha:Float, atlasData:Array<TextCharData>):Float {
		var padding = atlasData[256];
		spr.clipX      = data[0] - (padding[0] >> 1);
		spr.clipY      = data[1] - (padding[1] >> 1);
		spr.clipWidth  = spr.clipSizeX = data[2] + padding[0];
		spr.w          = spr.clipWidth  * quarterScale;
		spr.clipHeight = spr.clipSizeY  = data[3] + padding[0];
		spr.h          = spr.clipHeight * quarterScale;
		spr.x          = x + (data[4] * quarterScale) + advanceX;
		spr.y          = y + (data[5] * quarterScale);
		spr.c          = color;
		spr.oc         = outlineColor;
		spr.os         = outlineSize;
		spr.alpha      = alpha;
		advanceX      += data[6] * quarterScale;
		return advanceX;
	}

	function setupCharSpriteScaled(spr:TextCharSprite, data:TextCharData, quarterScale:Float, x:Float, y:Float, advanceX:Float, atlasData:Array<TextCharData>):Float {
		var padding = atlasData[256];
		spr.clipX      = data[0] - (padding[0] >> 1);
		spr.clipY      = data[1] - (padding[1] >> 1);
		spr.clipWidth  = spr.clipSizeX = data[2] + padding[0];
		spr.w          = spr.clipWidth  * quarterScale;
		spr.clipHeight = spr.clipSizeY  = data[3] + padding[0];
		spr.h          = spr.clipHeight * quarterScale;
		spr.x          = x + (data[4] * quarterScale) + advanceX;
		spr.y          = y + (data[5] * quarterScale);
		advanceX      += data[6] * quarterScale;
		return advanceX;
	}

	function new(x:Float, y:Float, display:Display, font:String = "vcr", outline:Bool = false) {
		this.isOutlineLayer = outline;
		
		// For outline layer, we need a larger buffer to hold multiple offset copies
		var bufferSize = outline ? 16 * 9 : 16; // 8 directions + original = 9x the sprites
		buffer = new Buffer<TextCharSprite>(bufferSize, bufferSize);

		program = new CustomProgram(buffer);
		program.injectIntoFragmentShader(TEXT_FRAGMENT_SHADER);
		program.setColorFormula('pixelAlpha(font_ID) * (c * alphaColor)');

		this.font    = font;
		this.x       = x;
		this.y       = y;
		this.display = display;

		if (!program.isIn(display)) {
			display.addProgram(program);
		}
	}

	/**
		Render outline by creating multiple offset copies of each character.
		Call this after setting text, color, and outline properties.
	**/
	function renderOutline() {
		if (!isOutlineLayer || outlineSize <= 0) return;
		
		var quarterScale = scale / 4;
		var advanceX:Float = 0;
		var outlineOffset = outlineSize * scale;
		
		// Define the 8 directions for outline
		var offsets = [
			[-outlineOffset, -outlineOffset], // top-left
			[0, -outlineOffset],               // top
			[outlineOffset, -outlineOffset],  // top-right
			[-outlineOffset, 0],               // left
			[outlineOffset, 0],                // right
			[-outlineOffset, outlineOffset],   // bottom-left
			[0, outlineOffset],                 // bottom
			[outlineOffset, outlineOffset]      // bottom-right
		];
		
		// Clear the buffer first
		buffer.clear();
		
		// For each character, create 8 offset copies for the outline
		for (i in 0...text.length) {
			var code = text.charCodeAt(i);
			var data = parsedTextAtlasData[code];
			
			// Calculate base position
			var baseX = x + (data[4] * quarterScale) + advanceX;
			var baseY = y + (data[5] * quarterScale);
			
			// Create outline copies at each offset
			for (j in 0...offsets.length) {
				var spr = buffer.addElement(new TextCharSprite());
				setupOutlineSprite(spr, data, quarterScale, baseX + offsets[j][0], baseY + offsets[j][1], outlineColor);
				spr.alpha = alpha;
				buffer.updateElement(spr);
			}
			
			advanceX += data[6] * quarterScale;
		}
		
		width = advanceX;
	}

	/**
		Setup a sprite for outline rendering
	**/
	function setupOutlineSprite(spr:TextCharSprite, data:TextCharData, quarterScale:Float, x:Float, y:Float, outlineColor:Color) {
		var padding = parsedTextAtlasData[256];
		spr.clipX      = data[0] - (padding[0] >> 1);
		spr.clipY      = data[1] - (padding[1] >> 1);
		spr.clipWidth  = spr.clipSizeX = data[2] + padding[0];
		spr.w          = spr.clipWidth  * quarterScale;
		spr.clipHeight = spr.clipSizeY  = data[3] + padding[0];
		spr.h          = spr.clipHeight * quarterScale;
		spr.x          = x;
		spr.y          = y;
		spr.c          = outlineColor;
		spr.oc         = outlineColor;
		spr.os         = 0; // No additional outline for outline layer
		spr.alpha      = 1.0;
	}

	/**
		Screen center the sprite at a specific axis, in a display.
		@param axis The axis you want to center the sprite to.
	**/
	function screenCenter(axis:Axis = XY) {
		switch (axis) {
			case X:
				x = (display.width - width) * 0.5;
			case Y:
				y = (display.height - height) * 0.5;
			default:
				x = (display.width - width) * 0.5;
				y = (display.height - height) * 0.5;
		}
	}

	function dispose() {
		if (program.isIn(display)) {
			display.removeProgram(program);
		}
		buffer.clear();
		display = null;
	}
}