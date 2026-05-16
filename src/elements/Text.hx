package elements;

import elements.text.*;

private class ColorSpan {
	public var start:Int;
	public var end:Int;
	public var color:Color;
	public var outlineColor:Color;
	public var outlineSize:Float;

	public function new(start:Int, end:Int, color:Color, outlineColor:Color, outlineSize:Float) {
		this.start        = start;
		this.end          = end;
		this.color        = color;
		this.outlineColor = outlineColor;
		this.outlineSize  = outlineSize;
	}
}

/**
	The visual representation of text, whether you want to have it show in a certain font, or move it around.
	@since Development
**/
@:publicFields
class Text {

	private static inline var TEXT_FRAGMENT_SHADER = '
		vec4 pixelAlpha(int textureID, vec4 c, vec4 oc, float os, float rw, float rh) {
			const float TAU   = 6.28318530;
			const float steps = 32.0;

			float expandedW = rw + os * 2.0;
			float expandedH = rh + os * 2.0;

			float paddingX = os / expandedW;
			float paddingY = os / expandedH;

			vec2 glyphCoord = (vTexCoord - vec2(paddingX, paddingY))
							/ vec2(1.0 - paddingX * 2.0, 1.0 - paddingY * 2.0);

			vec2 texelSize = vec2(1.0 / expandedW, 1.0 / expandedH);
			vec2 lo = texelSize * 1.5;
			vec2 hi = vec2(1.0) - texelSize * 1.5;

			vec4 current = ravuSample(textureID, glyphCoord, texelSize, lo, hi);

			float outlineAlpha = 0.0;
			for (float i = 0.0; i < TAU; i += TAU / steps) {
				vec2 offset = vec2(sin(i), cos(i)) * texelSize * os;
				outlineAlpha = max(
					outlineAlpha,
					ravuSample(textureID, glyphCoord + offset, texelSize, lo, hi).a
				);
			}

			outlineAlpha = smoothstep(0.5, 0.7, outlineAlpha);

			float fillA   = current.a;
			float haloA   = outlineAlpha * (1.0 - fillA);
			vec3  fillRGB = c.rgb * fillA;
			vec3  haloRGB = oc.rgb * haloA;
			return vec4(fillRGB + haloRGB, fillA + haloA);
		}
	';

	private static inline var TEXT_FRAGMENT_SHADER_NO_UPSCALE = '
		vec4 pixelAlpha(int textureID, vec4 c, vec4 oc, float os, float rw, float rh) {
			const float TAU   = 6.28318530;
			const float steps = 32.0;

			float expandedW = rw + os * 2.0;
			float expandedH = rh + os * 2.0;

			float paddingX = os / expandedW;
			float paddingY = os / expandedH;

			vec2 glyphCoord = (vTexCoord - vec2(paddingX, paddingY))
							/ vec2(1.0 - paddingX * 2.0, 1.0 - paddingY * 2.0);
			vec4 current = getTextureColor(textureID, glyphCoord);

			vec2 aspect = vec2(1.0 / expandedW, 1.0 / expandedH);

			float outlineAlpha = 0.0;
			for (float i = 0.0; i < TAU; i += TAU / steps) {
				vec2 offset = vec2(sin(i), cos(i)) * aspect * os;
				outlineAlpha = max(outlineAlpha, getTextureColor(textureID, glyphCoord + offset).a);
			}

			outlineAlpha = smoothstep(0.5, 0.7, outlineAlpha);

			float fillA   = current.a;
			float haloA   = outlineAlpha * (1.0 - fillA);
			vec3  fillRGB = c.rgb * fillA;
			vec3  haloRGB = oc.rgb * haloA;
			return vec4(fillRGB + haloRGB, fillA + haloA);
		}
	';

	var buffer:Buffer<TextCharSprite>;
	var program:CustomProgram;

	var _key:String;
	var display:Display;

	// ── Markup ────────────────────────────────────────────────────────────────

	var markerPairs(default, null):Array<TextFormatMarkerPair> = [];

	function setMarkerPairs(pairs:Array<TextFormatMarkerPair>) {
		for (pair in markerPairs) pair._onChange = null;
		markerPairs = pairs;
		for (pair in markerPairs) pair._onChange = markDirty;
		markDirty();
		this.text = text; // so it updates automatically regardless if you've set your text to the new onee or not.
	}

	private var colorSpans:Array<ColorSpan> = [];

	// ── Dirty flag ────────────────────────────────────────────────────────────

	private var _dirty:Bool = false;

	function markDirty() {
		_dirty = true;
	}

	function flushIfDirty() {
		if (!_dirty) return;
		set_text(_rawText);
	}

	// ── Text ──────────────────────────────────────────────────────────────────

	var rawText(get, never):String;
	function get_rawText() return _rawText;

	private var _rawText:String = "";

	var text(default, set):String = "";

	var x(default, set):Float = 0;

	var y(default, set):Float = 0;

	var scale(default, set):Float = 1.0;

	var _scale(default, null):Float = 1.0;

	var width(default, null):Float;
	var height(default, null):Float;

	var alpha(default, set):Float = 1.0;

	var color(default, set):Color = 0xFFFFFFFF;

	var outlineColor(default, set):Color = 0x000000FF;

	var outlineSize(default, set):Float = 0;

	// set_text — single slot per character:
	private var _activeCount:Int = 0;  // how many sprites are actually live

	// ── set_text ──────────────────────────────────────────────────────────────

	function set_text(raw:String) {
		if (raw == _rawText && !_dirty) return text;
		_dirty   = false;
		_rawText = raw;

		var parsed = parseMarkup(raw);
		var str    = parsed.clean;
		colorSpans = parsed.spans;
		text       = str;

		// Hide previously-active sprites that are now beyond the new length.
		var oldCount = _activeCount;
		if (str.length < oldCount) {
			for (ci in str.length...oldCount) {
				var spr = buffer.getElement(ci);
				if (spr == null) continue;
				spr.x = spr.y = -999999999;
				spr.w = spr.h = 0;
				spr.alpha     = 0;
				buffer.updateElement(spr);
			}
		}
		_activeCount = str.length;

		var quarterScale = scale / 2;
		var advanceX:Float = 0;
		var newHeight:Float = 0;           // reset height properly
		var spanIdx:Int = 0;               // walk spans in order (see resolveStyleFast)

		for (ci in 0...str.length) {
			var code = str.charCodeAt(ci);
			var data = parsedTextAtlasData[code];

			var spr:TextCharSprite = ci < buffer.length
				? buffer.getElement(ci)
				: buffer.addElement(new TextCharSprite());

			// Resolve style with O(1)-amortised span walk instead of O(spans) per char.
			while (spanIdx < colorSpans.length && colorSpans[spanIdx].end <= ci)
				spanIdx++;
			var span = (spanIdx < colorSpans.length && ci >= colorSpans[spanIdx].start)
				? colorSpans[spanIdx] : null;
			var sc  = span != null ? span.color        : color;
			var soc = span != null ? span.outlineColor : outlineColor;
			var sos = (span != null && span.outlineSize != 0.0) ? span.outlineSize : outlineSize;

			// Fill sprite.
			var padding = parsedTextAtlasData[256];
			spr.clipX      = data[0];
			spr.clipY      = data[1];
			spr.clipWidth  = spr.clipSizeX = data[2];
			spr.clipHeight = spr.clipSizeY = data[3];
			spr.w          = data[2] * quarterScale;
			spr.h          = data[3] * quarterScale;
			spr.rw         = data[2] * quarterScale;
			spr.rh         = data[3] * quarterScale;
			spr.x          = x + data[4] * quarterScale + advanceX;
			spr.y          = y + data[5] * quarterScale;
			spr.c          = sc;
			spr.oc         = soc;
			spr.os         = sos;
			spr.alpha      = alpha;

			advanceX += data[6] * quarterScale;

			var sprH = spr.h + spr.y - y;   // height contribution relative to baseline
			if (sprH > newHeight) newHeight = sprH;

			buffer.updateElement(spr);   // single update per sprite
		}

		width  = advanceX;
		height = newHeight;
		return str;
	}

	// set_x:
	function set_x(value:Float) {
		if (value == x) return x;
		for (ci in 0...text.length) {
			var spr = buffer.getElement(ci);
			if (spr == null) continue;
			spr.x += value - x;
		}
		buffer.update();
		return x = value;
	}

	// set_y:
	function set_y(value:Float) {
		if (value == y) return y;
		for (ci in 0...text.length) {
			var spr = buffer.getElement(ci);
			if (spr == null) continue;
			spr.y += value - y;
		}
		buffer.update();
		return y = value;
	}

	// set_scale:
	function set_scale(value:Float) {
		if (value == scale) return scale;
		scale = value;
		var quarterScale = scale / 2; // Default text size is 20. Atlas text size is 40, so we have to shrink to compensate.
		var advanceX:Float = 0;
		for (ci in 0...text.length) {
			var code = text.charCodeAt(ci);
			var data = parsedTextAtlasData[code];
			var spr  = buffer.getElement(ci);
			advanceX = setupCharSpriteScaled(spr, data, quarterScale, x, y, advanceX, parsedTextAtlasData);
			if (height < spr.h + spr.y - data[1])
				height = spr.h + spr.y - data[1];
		}
		width  = advanceX;
		height = parsedTextAtlasData[256][2] * quarterScale;
		_scale = scale;
		buffer.update();
		return value;
	}

	// set_alpha:
	function set_alpha(value:Float):Float {
		for (ci in 0...text.length) {
			var spr = buffer.getElement(ci);
			if (spr != null) spr.alpha = value;
		}
		buffer.update();
		return alpha = value;
	}

	// set_color:
	function set_color(value:Color):Color {
		for (ci in 0...text.length) {
			var spr = buffer.getElement(ci);
			if (spr != null) spr.c = value;
		}
		buffer.update();
		return color = value;
	}

	// set_outlineColor:
	function set_outlineColor(value:Color):Color {
		for (ci in 0...text.length) {
			var spr = buffer.getElement(ci);
			if (spr != null) spr.oc = value;
		}
		buffer.update();
		return outlineColor = value;
	}

	// set_outlineSize:
	function set_outlineSize(value:Float):Float {
		for (ci in 0...text.length) {
			var spr = buffer.getElement(ci);
			if (spr != null) spr.os = value;
		}
		buffer.update();
		return outlineSize = value;
	}

	// ── Font ──────────────────────────────────────────────────────────────────

	var font(default, set):String;

	function set_font(value:String) {
		if (font == value) return value;
		parsedTextAtlasData = Tools.parseFont(value);
		var displayTextureID = value + "Font";
		TextureSystem.setTexture(program, displayTextureID, "font");
		return font = value;
	}

	var parsedTextAtlasData:Array<TextCharData>;

	// ── Markup parsing ────────────────────────────────────────────────────────

	private function parseMarkup(raw:String):{clean:String, spans:Array<ColorSpan>} {
		var spans:Array<ColorSpan> = [];
		var clean = new StringBuf();
		var charPos = 0;
		var i = 0;

		var openMarkerIdx:Int = -1;
		var openCharPos:Int   = -1;

		while (i < raw.length) {
			var matched = matchMarkerAt(raw, i);

			if (matched != -1) {
				var mp = markerPairs[matched];

				if (openMarkerIdx == -1) {
					openMarkerIdx = matched;
					openCharPos   = charPos;
					i += mp.marker.length;
				} else if (matched == openMarkerIdx) {
					spans.push(new ColorSpan(
						openCharPos, charPos,
						mp.color, mp.outlineColor, mp.outlineSize
					));
					openMarkerIdx = -1;
					openCharPos   = -1;
					i += mp.marker.length;
				} else {
					// Different marker while one is open — treat as literal.
					clean.addChar(raw.charCodeAt(i));
					i++;
					charPos++;
				}
			} else {
				clean.addChar(raw.charCodeAt(i));
				i++;
				charPos++;
			}
		}

		// Unmatched opener: silently drop.

		return {clean: clean.toString(), spans: spans};
	}

	private function matchMarkerAt(raw:String, i:Int):Int {
		var best    = -1;
		var bestLen = 0;

		for (mi in 0...markerPairs.length) {
			var m = markerPairs[mi].marker;
			if (m.length <= bestLen)       continue;
			if (i + m.length > raw.length) continue;
			if (raw.substr(i, m.length) == m) {
				best    = mi;
				bestLen = m.length;
			}
		}

		return best;
	}

	private inline function resolveStyle(ci:Int):{c:Color, oc:Color, os:Float} {
		var c  = color;
		var oc = outlineColor;
		var os = outlineSize;
		for (span in colorSpans) {
			if (ci >= span.start && ci < span.end) {
				c  = span.color;
				oc = span.outlineColor;
				if (span.outlineSize != 0.0) os = span.outlineSize;
				else os = outlineSize; // default to it like how flixel prob does it
			}
		}
		return {c: c, oc: oc, os: os};
	}

	// ── Sprite setup helpers ──────────────────────────────────────────────────

	function setupCharSprite(spr:TextCharSprite, data:TextCharData, quarterScale:Float, x:Float, y:Float, advanceX:Float, color:Color, outlineColor:Color, outlineSize:Float, alpha:Float, atlasData:Array<TextCharData>):Float {
		var padding    = atlasData[256];
		// data[0,1] = atlas position of padded rect (no adjustment needed)
		// data[2,3] = padded width/height (already includes padding on both sides)
		// data[4,5] = xoffset/yoffset (already has padding subtracted by fontbm)
		spr.clipX      = data[0];
		spr.clipY      = data[1];
		spr.clipWidth  = spr.clipSizeX = data[2];
		spr.w          = data[2] * quarterScale;
		spr.clipHeight = spr.clipSizeY = data[3];
		spr.h          = data[3] * quarterScale;
		// rw/rh = raw glyph size without padding, in screen pixels
		spr.rw         = data[2] * quarterScale;
		spr.rh         = data[3] * quarterScale;
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
		var padding    = atlasData[256];
		spr.clipX      = data[0];
		spr.clipY      = data[1];
		spr.clipWidth  = spr.clipSizeX = data[2];
		spr.w          = data[2] * quarterScale;
		spr.clipHeight = spr.clipSizeY = data[3];
		spr.h          = data[3] * quarterScale;
		spr.rw         = (data[2] - padding[0] - padding[2]) * quarterScale;
		spr.rh         = (data[3] - padding[1] - padding[3]) * quarterScale;
		spr.x          = x + (data[4] * quarterScale) + advanceX;
		spr.y          = y + (data[5] * quarterScale);
		advanceX      += data[6] * quarterScale;
		return advanceX;
	}

	// ── Constructor ───────────────────────────────────────────────────────────

	function new(key:String, x:Float, y:Float, display:Display, text:String = "Sample text", font:String = "vcr") {
		_key   = key;
		buffer = new Buffer<TextCharSprite>(32, 32);

		program = new CustomProgram(buffer);
		if (Main.current.upscale) {
			program.injectIntoFragmentShader(Shaders.UPSCALE_FRAGMENT_SHADER + "\n\n" + TEXT_FRAGMENT_SHADER);
		} else {
			program.injectIntoFragmentShader(TEXT_FRAGMENT_SHADER_NO_UPSCALE);
		}
		program.setColorFormula('pixelAlpha(font_ID, c, oc, os, rw, rh) * alphaColor');

		this.font    = font;
		this.display = display;

		display.addProgram(program);

		// x and y must be set before text so sprite positions are correct.
		this.x = x;
		this.y = y;

		if (text == null || text.length == 0) text = "Sample text";
		this.text = text;
	}

	// ── Utilities ─────────────────────────────────────────────────────────────

	function screenCenter(axis:Axis = XY) {
		switch (axis) {
			case X:  x = (display.width  - width)  * 0.5;
			case Y:  y = (display.height - height) * 0.5;
			default: x = (display.width  - width)  * 0.5;
					 y = (display.height - height) * 0.5;
		}
	}

	function dispose() {
		for (pair in markerPairs) pair._onChange = null;
		markerPairs = [];
		if (program.isIn(display)) display.removeProgram(program);
		buffer.clear();
		display = null;
	}

	function removeProgram() {
		display.removeProgram(program);
	}

	function addProgram() {
		display.addProgram(program);
	}
}