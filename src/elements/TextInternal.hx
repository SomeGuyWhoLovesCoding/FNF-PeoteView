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

@:publicFields
class TextInternal {

	private static inline var TEXT_FRAGMENT_SHADER = '
		vec4 pixelAlpha(int textureID) {
			vec4 current = getTextureColor(textureID, vTexCoord);
			float alpha = step(0.5, current.a);
			return vec4(current.rgb, alpha);
		}
	';

	var buffer:Buffer<TextCharSprite>;
	var program:CustomProgram;
	var display:Display;

	var isOutlineLayer:Bool;

	// ── Markup ────────────────────────────────────────────────────────────────

	var markerPairs(default, null):Array<TextFormatMarkerPair> = [];

	function addMarkerPair(pair:TextFormatMarkerPair) {
		pair._onChange = () -> set_text(_rawText);
		markerPairs.push(pair);
	}

	function removeMarkerPair(pair:TextFormatMarkerPair) {
		pair._onChange = null;
		markerPairs.remove(pair);
	}

	private var colorSpans:Array<ColorSpan> = [];

	// ── Text ──────────────────────────────────────────────────────────────────

	private var _rawText:String = "";

	var text(default, set):String = "";

	function set_text(raw:String) {
		_rawText = raw;

		var parsed = parseMarkup(raw);
		var str    = parsed.clean;
		colorSpans = parsed.spans;

		// Hide sprites for characters that no longer exist.
		if (text != null && str.length < text.length) {
			if (isOutlineLayer) {
				for (ci in str.length...text.length) {
					if (ci >= outlineSlots.length) continue;
					for (spr in outlineSlots[ci]) {
						spr.x = spr.y = -999999999;
						spr.w = spr.h = 0;
						spr.alpha = 0;
						buffer.updateElement(spr);
					}
				}
			} else {
				for (i in str.length...text.length) {
					var elem = buffer.getElement(i);
					if (elem != null) {
						elem.x = elem.y = -999999999;
						elem.w = elem.h = 0;
						elem.alpha = 0;
						buffer.updateElement(elem);
					}
				}
			}
		}

		text = str;

		var quarterScale  = scale / 4;
		var outlineOffset = outlineSize * scale;
		var advanceX:Float = 0;

		for (ci in 0...str.length) {
			var code  = str.charCodeAt(ci);
			var data  = parsedTextAtlasData[code];
			var style = resolveStyle(ci);

			if (!isOutlineLayer) {
				// ── Fill: one sprite per character ────────────────────────
				var spr:TextCharSprite = ci < buffer.length
					? buffer.getElement(ci)
					: buffer.addElement(new TextCharSprite());

				advanceX = setupCharSprite(
					spr, data, quarterScale,
					x, y, advanceX,
					style.c, style.oc, style.os,
					alpha, parsedTextAtlasData
				);

				if (height < spr.h + spr.y - data[1])
					height = spr.h + spr.y - data[1];

				buffer.updateElement(spr);

			} else {
				// ── Outline: 8 offset sprites per character ───────────────
				if (ci >= outlineSlots.length) {
					var slots:Array<TextCharSprite> = [];
					for (_ in 0...OUTLINE_DIR_COUNT) {
						var spr = buffer.addElement(new TextCharSprite());
						slots.push(spr);
					}
					outlineSlots.push(slots);
				}

				var baseX = x + (data[4] * quarterScale) + advanceX;
				var baseY = y + (data[5] * quarterScale);
				var dirs  = OUTLINE_DIRS;

				for (di in 0...OUTLINE_DIR_COUNT) {
					var spr = outlineSlots[ci][di];
					setupOutlineSprite(
						spr, data, quarterScale,
						baseX + dirs[di][0] * outlineOffset,
						baseY + dirs[di][1] * outlineOffset,
						style.oc
					);
					spr.alpha = alpha;
					buffer.updateElement(spr);
				}

				advanceX += data[6] * quarterScale;
			}
		}

		width = advanceX;
		return str;
	}

	// ── Outline sprite slots ──────────────────────────────────────────────────

	private var outlineSlots:Array<Array<TextCharSprite>> = [];

	private static inline var OUTLINE_DIR_COUNT = 8;

	private static var OUTLINE_DIRS(get, never):Array<Array<Float>>;
	private static inline function get_OUTLINE_DIRS() return [
		[-1,-1],[0,-1],[1,-1],
		[-1, 0],       [1, 0],
		[-1, 1],[0, 1],[1, 1]
	];

	// ── Position ──────────────────────────────────────────────────────────────

	var x(default, set):Float = 0;

	function set_x(value:Float) {
		if (value == x) return x;

		if (isOutlineLayer) {
			for (slots in outlineSlots) {
				for (spr in slots) {
					spr.x += value - x;
					buffer.updateElement(spr);
				}
			}
		} else {
			for (i in 0...text.length) {
				var elem = buffer.getElement(i);
				elem.x += value - x;
				buffer.updateElement(elem);
			}
		}

		return x = value;
	}

	var y(default, set):Float = 0;

	function set_y(value:Float) {
		if (value == y) return y;

		if (isOutlineLayer) {
			for (slots in outlineSlots) {
				for (spr in slots) {
					spr.y += value - y;
					buffer.updateElement(spr);
				}
			}
		} else {
			for (i in 0...text.length) {
				var elem = buffer.getElement(i);
				elem.y += value - y;
				buffer.updateElement(elem);
			}
		}

		return y = value;
	}

	// ── Scale ─────────────────────────────────────────────────────────────────

	var scale(default, set):Float = 1.0;

	function set_scale(value:Float) {
		if (value == scale) return scale;

		scale = value;
		var quarterScale  = scale / 4;
		var outlineOffset = outlineSize * scale;
		var advanceX:Float = 0;

		for (ci in 0...text.length) {
			var code = text.charCodeAt(ci);
			var data = parsedTextAtlasData[code];

			if (isOutlineLayer) {
				if (ci >= outlineSlots.length) { advanceX += data[6] * quarterScale; continue; }

				var baseX = x + (data[4] * quarterScale) + advanceX;
				var baseY = y + (data[5] * quarterScale);
				var dirs  = OUTLINE_DIRS;

				for (di in 0...OUTLINE_DIR_COUNT) {
					var spr = outlineSlots[ci][di];
					setupOutlineSprite(
						spr, data, quarterScale,
						baseX + dirs[di][0] * outlineOffset,
						baseY + dirs[di][1] * outlineOffset,
						spr.c
					);
					buffer.updateElement(spr);
				}

				advanceX += data[6] * quarterScale;
			} else {
				var spr = buffer.getElement(ci);
				advanceX = setupCharSpriteScaled(spr, data, quarterScale, x, y, advanceX, parsedTextAtlasData);

				if (height < spr.h + spr.y - data[1])
					height = spr.h + spr.y - data[1];

				buffer.updateElement(spr);
			}
		}

		width  = advanceX;
		height = parsedTextAtlasData[256][2] * quarterScale;
		_scale = scale;

		return value;
	}

	var _scale(default, null):Float = 1.0;

	var width(default, null):Float;
	var height(default, null):Float;

	// ── Alpha ─────────────────────────────────────────────────────────────────

	var alpha(default, set):Float = 1.0;

	function set_alpha(value:Float):Float {
		if (isOutlineLayer) {
			for (slots in outlineSlots) {
				for (spr in slots) {
					spr.alpha = value;
					buffer.updateElement(spr);
				}
			}
		} else {
			for (i in 0...text.length) {
				var spr = buffer.getElement(i);
				if (spr != null) spr.alpha = value;
				buffer.updateElement(spr);
			}
		}
		return alpha = value;
	}

	// ── Color ─────────────────────────────────────────────────────────────────

	var color(default, set):Color = 0xFFFFFFFF;

	function set_color(value:Color):Color {
		if (!isOutlineLayer) {
			for (i in 0...text.length) {
				var spr = buffer.getElement(i);
				if (spr != null) spr.c = value;
				buffer.updateElement(spr);
			}
		}
		return color = value;
	}

	var outlineColor(default, set):Color = 0x000000FF;

	function set_outlineColor(value:Color):Color {
		if (isOutlineLayer) {
			for (slots in outlineSlots) {
				for (spr in slots) {
					spr.c  = value;
					spr.oc = value;
					buffer.updateElement(spr);
				}
			}
		} else {
			for (i in 0...text.length) {
				var spr = buffer.getElement(i);
				if (spr != null) spr.oc = value;
				buffer.updateElement(spr);
			}
		}
		return outlineColor = value;
	}

	var outlineSize(default, set):Float = 0;

	function set_outlineSize(value:Float):Float {
		outlineSize = value;
		if (isOutlineLayer) {
			set_text(_rawText);
		} else {
			for (i in 0...text.length) {
				var spr = buffer.getElement(i);
				if (spr != null) spr.os = value;
				buffer.updateElement(spr);
			}
		}
		return outlineSize;
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
				os = span.outlineSize;
			}
		}
		return {c: c, oc: oc, os: os};
	}

	// ── Sprite setup helpers ──────────────────────────────────────────────────

	function setupCharSprite(spr:TextCharSprite, data:TextCharData, quarterScale:Float, x:Float, y:Float, advanceX:Float, color:Color, outlineColor:Color, outlineSize:Float, alpha:Float, atlasData:Array<TextCharData>):Float {
		var padding    = atlasData[256];
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
		var padding    = atlasData[256];
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

	function setupOutlineSprite(spr:TextCharSprite, data:TextCharData, quarterScale:Float, x:Float, y:Float, color:Color) {
		var padding    = parsedTextAtlasData[256];
		spr.clipX      = data[0] - (padding[0] >> 1);
		spr.clipY      = data[1] - (padding[1] >> 1);
		spr.clipWidth  = spr.clipSizeX = data[2] + padding[0];
		spr.w          = spr.clipWidth  * quarterScale;
		spr.clipHeight = spr.clipSizeY  = data[3] + padding[0];
		spr.h          = spr.clipHeight * quarterScale;
		spr.x          = x;
		spr.y          = y;
		spr.c          = color;
		spr.oc         = color;
		spr.os         = 0;
		spr.alpha      = 1.0;
	}

	// ── Constructor ───────────────────────────────────────────────────────────

	function new(x:Float, y:Float, display:Display, font:String = "vcr", outline:Bool = false) {
		this.isOutlineLayer = outline;

		var bufferSize = outline ? 128 * OUTLINE_DIR_COUNT : 128;
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
		outlineSlots = [];
		display = null;
	}
}
