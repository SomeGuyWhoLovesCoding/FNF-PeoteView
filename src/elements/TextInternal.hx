package elements;

import elements.text.*;

/**
	One rendered layer of text (either the outline pass or the fill pass).
	This is the original `Text` GPU/sprite logic, extracted verbatim so
	`Text` can own two of these — one behind (outline), one in front (fill).
**/
@:publicFields
class TextInternal {

	private static inline var TEXT_OUTLINE_FRAGMENT_SHADER = '
		vec4 outline(int textureID, float os, vec4 oc) {
            float invScale = 1.0 + os * 2.0;
            vec2 coord = (vTexCoord - 0.5) * invScale + 0.5;
            vec4 current = getTextureColor(textureID, coord);

            float s1 = 0.9239 * os;
            float s2 = 0.7071 * os;
            float s3 = 0.3827 * os;

            vec2 o0 = coord + vec2( os,  0.0); vec2 o1  = coord + vec2( s1,  s3);
            vec2 o2 = coord + vec2( s2,  s2);  vec2 o3  = coord + vec2( s3,  s1);
            vec2 o4 = coord + vec2(0.0,  os);  vec2 o5  = coord + vec2(-s3,  s1);
            vec2 o6 = coord + vec2(-s2,  s2);  vec2 o7  = coord + vec2(-s1,  s3);
            vec2 o8 = coord + vec2(-os, 0.0);  vec2 o9  = coord + vec2(-s1, -s3);
            vec2 oA = coord + vec2(-s2, -s2);  vec2 oB  = coord + vec2(-s3, -s1);
            vec2 oC = coord + vec2(0.0, -os);  vec2 oD  = coord + vec2( s3, -s1);
            vec2 oE = coord + vec2( s2, -s2);  vec2 oF  = coord + vec2( s1, -s3);

            #define IB(v) (step(0.0, v.x) * step(v.x, 1.0) * step(0.0, v.y) * step(v.y, 1.0))

            vec4 a0 = vec4(getTextureColor(textureID, o0).a * IB(o0), getTextureColor(textureID, o1).a * IB(o1), getTextureColor(textureID, o2).a * IB(o2), getTextureColor(textureID, o3).a * IB(o3));
            vec4 a1 = vec4(getTextureColor(textureID, o4).a * IB(o4), getTextureColor(textureID, o5).a * IB(o5), getTextureColor(textureID, o6).a * IB(o6), getTextureColor(textureID, o7).a * IB(o7));
            vec4 a2 = vec4(getTextureColor(textureID, o8).a * IB(o8), getTextureColor(textureID, o9).a * IB(o9), getTextureColor(textureID, oA).a * IB(oA), getTextureColor(textureID, oB).a * IB(oB));
            vec4 a3 = vec4(getTextureColor(textureID, oC).a * IB(oC), getTextureColor(textureID, oD).a * IB(oD), getTextureColor(textureID, oE).a * IB(oE), getTextureColor(textureID, oF).a * IB(oF));

            vec4 maxAB = max(a0, a1);
            vec4 maxCD = max(a2, a3);
            vec4 maxAll = max(maxAB, maxCD);
            float outlineAlpha = max(max(maxAll.x, maxAll.y), max(maxAll.z, maxAll.w));
            outlineAlpha = smoothstep(0.0, 0.25, outlineAlpha);

            vec4 outlineColor = vec4(oc.r, oc.g, oc.b, outlineAlpha);
            return mix(current, mix(outlineColor, current, current.a), clamp(os * 20.0, 0.0, 1.0));
        }
	';

	var buffer:Buffer<TextCharSprite>;
	var program:CustomProgram;

	var display:Display;

	var text(default, set):String = "";

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

	function new(x:Float, y:Float, display:Display, font:String = "vcr") {
		buffer = new Buffer<TextCharSprite>(16, 16);

		program = new CustomProgram(buffer);
		program.setFragmentFloatPrecision('medium', true);
		program.injectIntoFragmentShader(TEXT_OUTLINE_FRAGMENT_SHADER);
		program.setColorFormula('outline(font_ID, os, oc) * (c * alphaColor)');

		this.font    = font;
		this.x       = x;
		this.y       = y;
		this.display = display;

		if (!program.isIn(display)) {
			display.addProgram(program);
		}
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
