package elements;

import elements.text.*;
using StringTools;

/**
	The visual representation of text, whether you want to have it show in a certain font, or move it around.
	Supports multiline, alignment, and spacer percentage!
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
		refresh();
	}

	private var colorSpans:Array<ColorSpan> = [];

	// ── Dirty flag ────────────────────────────────────────────────────────────

	private var _dirty:Bool = false;

	function markDirty() {
		_dirty = true;
	}

	function flushIfDirty() {
		if (!_dirty) return;
		refresh();
	}

	// ── Text ──────────────────────────────────────────────────────────────────

	var rawText(get, never):String;
	function get_rawText() return _rawText;

	private var _rawText:String = "";
	var text(default, set):String = "";
	
	// New: Line array for multiline
	private var _lines:Array<String> = [];
	private var _lineWidths:Array<Float> = [];
	private var _lineHeights:Array<Float> = [];
	
	// New: Multiline properties
	var multiline(default, set):Bool = false;
	var lineSpacing(default, set):Float = 0; // Additional spacing between lines in pixels
	var maxWidth(default, set):Float = 0; // Maximum width before wrapping (0 = no wrap)
	
	// New: Alignment
	var alignment(default, set):TextAlign = LEFT;
	
	// New: Spacer percentage (0-1) for character spacing
	var spacerPercent(default, set):Float = 0.0; // 0 = normal, 1 = double spacing

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

	private var _activeCount:Int = 0;

	// New: Getters for line information
	var lineCount(get, never):Int;
	function get_lineCount() return _lines.length;
	
	function getLineText(line:Int):String {
		return (line >= 0 && line < _lines.length) ? _lines[line] : "";
	}
	
	function getLineWidth(line:Int):Float {
		return (line >= 0 && line < _lineWidths.length) ? _lineWidths[line] : 0;
	}

	// ── Setters for new properties ────────────────────────────────────────────
	
	function set_multiline(value:Bool):Bool {
		if (multiline == value) return value;
		multiline = value;
		markDirty();
		refresh();
		return value;
	}
	
	function set_lineSpacing(value:Float):Float {
		if (lineSpacing == value) return value;
		lineSpacing = value;
		if (multiline) {
			markDirty();
			refresh();
		}
		return value;
	}
	
	function set_maxWidth(value:Float):Float {
		if (maxWidth == value) return value;
		maxWidth = value;
		if (multiline && maxWidth > 0) {
			markDirty();
			refresh();
		}
		return value;
	}
	
	function set_alignment(value:TextAlign):TextAlign {
		if (alignment == value) return value;
		alignment = value;
		if (multiline) {
			markDirty();
			refresh();
		}
		return value;
	}
	
	function set_spacerPercent(value:Float):Float {
		var clamped = Math.min(Math.max(value, 0.0), 1.0);
		if (spacerPercent == clamped) return value;
		spacerPercent = clamped;
		markDirty();
		refresh();
		return value;
	}

	// ── Text wrapping and line breaking ───────────────────────────────────────

	private function wrapText(str:String):Array<String> {
		var lines:Array<String> = [];
		
		if (!multiline) {
			// Even when not multiline, we should strip newlines
			return [str.replace("\n", " ")];
		}
		
		// First, split by explicit newlines
		var newlineSegments = str.split("\n");
		
		for (segment in newlineSegments) {
			if (maxWidth <= 0) {
				// No width limit, just add the segment as-is
				if (segment.length > 0 || lines.length > 0 || segment == newlineSegments[0]) {
					lines.push(segment);
				}
			} else {
				// Word wrap within maxWidth
				var words = segment.split(" ");
				var currentLine = "";
				var quarterScale = scale / 2;
				
				for (i in 0...words.length) {
					var word = words[i];
					var testLine = currentLine.length == 0 ? word : currentLine + " " + word;
					var testWidth = calculateTextWidth(testLine, quarterScale);
					
					if (testWidth > maxWidth && currentLine.length > 0) {
						lines.push(currentLine);
						currentLine = word;
					} else {
						currentLine = testLine;
					}
				}
				
				if (currentLine.length > 0 || segment.length == 0) {
					lines.push(currentLine);
				}
			}
		}
		
		return lines.length == 0 ? (multiline ? [""] : [str]) : lines;
	}

	private function calculateTextWidth(line:String, quarterScale:Float):Float {
		var totalWidth:Float = 0;
		for (ci in 0...line.length) {
			var code = line.charCodeAt(ci);
			var data = parsedTextAtlasData[code];
			if (data != null) {
				var charWidth = data[6] * quarterScale;
				var spacing = charWidth * spacerPercent;
				totalWidth += charWidth + spacing;
			}
		}
		return totalWidth;
	}
	
	private function calculateLineHeight():Float {
		if (_lines.length == 0) return 0;
		
		var maxHeight:Float = 0;
		var quarterScale = scale / 2;
		
		for (line in _lines) {
			for (ci in 0...line.length) {
				var code = line.charCodeAt(ci);
				var data = parsedTextAtlasData[code];
				if (data != null) {
					var charHeight = data[3] * quarterScale;
					if (charHeight > maxHeight) maxHeight = charHeight;
				}
			}
		}
		
		return maxHeight + lineSpacing;
	}

	// ── set_text (updated with multiline support) ─────────────────────────────

	function set_text(raw:String) {
		if (!_dirty) if (raw == _rawText) return text;
		_dirty = false;
		_rawText = raw;
		
		// Preserve newlines for markup parsing
		var parsed = parseMarkup(raw);
		var str = parsed.clean;
		colorSpans = parsed.spans;
		text = str;
		
		// Handle multiline - this now respects \n from parseMarkup
		if (multiline) {
			_lines = wrapText(str);
		} else {
			// When not multiline, replace newlines with spaces
			_lines = [str.replace("\n", " ")];
		}
		
		// Calculate line widths and total dimensions
		var quarterScale = scale / 2;
		_lineWidths = [];
		var maxLineWidth:Float = 0;
		var totalHeight:Float = 0;
		var lineHeight = calculateLineHeight();
		
		for (lineIdx in 0..._lines.length) {
			var line = _lines[lineIdx];
			var lineWidth = calculateTextWidth(line, quarterScale);
			_lineWidths.push(lineWidth);
			if (lineWidth > maxLineWidth) maxLineWidth = lineWidth;
		}
		
		// Total height = sum of all line heights
		totalHeight = _lines.length * lineHeight;
		
		// Store actual dimensions
		width = maxLineWidth;  // Width is the maximum line width
		height = totalHeight;   // Height is total height of all lines
		
		// Hide previously-active sprites
		var oldCount = _activeCount;
		var totalChars = 0;
		for (line in _lines) totalChars += line.length;
		
		if (totalChars < oldCount) {
			for (ci in totalChars...oldCount) {
				var spr = buffer.getElement(ci);
				if (spr == null) continue;
				spr.x = spr.y = -999999999;
				spr.w = spr.h = 0;
				spr.alpha = 0;
				buffer.updateElement(spr);
			}
		}
		_activeCount = totalChars;
		
		// Render each character with line positioning
		var globalCharIdx = 0;
		var spanIdx = 0;
		
		// Track character position within the original raw text for color spans
		var rawCharIdx = 0;
		
		for (lineIdx in 0..._lines.length) {
			var line = _lines[lineIdx];
			var lineWidth = _lineWidths[lineIdx];
			
			// Calculate X offset based on alignment - using actual line width, not max width
			var xOffset = switch (alignment) {
				case LEFT: 0.0;
				case CENTER: (maxLineWidth - lineWidth) / 2;
				case RIGHT: maxLineWidth - lineWidth;
			}
			
			var advanceX = xOffset;
			var lineY = y + (lineIdx * lineHeight);
			
			for (ci in 0...line.length) {
				var code = line.charCodeAt(ci);
				var data = parsedTextAtlasData[code];
				
				var spr:TextCharSprite = globalCharIdx < buffer.length
					? buffer.getElement(globalCharIdx)
					: buffer.addElement(new TextCharSprite());
				
				// Resolve style based on position in original text
				while (spanIdx < colorSpans.length && colorSpans[spanIdx].end <= rawCharIdx)
					spanIdx++;
				var span = (spanIdx < colorSpans.length && rawCharIdx >= colorSpans[spanIdx].start)
					? colorSpans[spanIdx] : null;
				var sc = span != null ? span.color : color;
				var soc = span != null ? span.outlineColor : outlineColor;
				var sos = (span != null && span.outlineSize != 0.0) ? span.outlineSize : outlineSize;
				
				// Apply spacer percentage to advance width
				var baseAdvance = data[6] * quarterScale;
				var spacerAmount = baseAdvance * spacerPercent;
				var totalAdvance = baseAdvance + spacerAmount;
				
				// Fill sprite
				spr.clipX = data[0];
				spr.clipY = data[1];
				spr.clipWidth = spr.clipSizeX = data[2];
				spr.clipHeight = spr.clipSizeY = data[3];
				spr.w = data[2] * quarterScale;
				spr.h = data[3] * quarterScale;
				spr.rw = data[2] * quarterScale;
				spr.rh = data[3] * quarterScale;
				spr.x = x + (data[4] * quarterScale) + advanceX;
				spr.y = lineY + (data[5] * quarterScale);
				spr.c = sc;
				spr.oc = soc;
				spr.os = sos;
				spr.alpha = alpha;
				
				advanceX += totalAdvance;
				buffer.updateElement(spr);
				globalCharIdx++;
				rawCharIdx++;
			}
			
			// Skip over newline characters in rawCharIdx for proper span tracking
			var originalText = text;
			while (rawCharIdx < originalText.length && originalText.charCodeAt(rawCharIdx) == 10) {
				rawCharIdx++;
			}
		}
		
		return str;
	}

	// ── Position/transform setters (updated to handle multiline repositioning) ──

	function set_x(value:Float) {
		if (value == x) return x;
		var delta = value - x;
		for (ci in 0..._activeCount) {
			var spr = buffer.getElement(ci);
			if (spr == null) continue;
			spr.x += delta;
			buffer.updateElement(spr);
		}
		return x = value;
	}

	function set_y(value:Float) {
		if (value == y) return y;
		var delta = value - y;
		for (ci in 0..._activeCount) {
			var spr = buffer.getElement(ci);
			if (spr == null) continue;
			spr.y += delta;
			buffer.updateElement(spr);
		}
		return y = value;
	}

	function set_scale(value:Float) {
		if (value == scale) return scale;
		scale = value;
		markDirty();
		refresh();
		return value;
	}

	function set_alpha(value:Float):Float {
		for (ci in 0..._activeCount) {
			var spr = buffer.getElement(ci);
			if (spr != null) spr.alpha = value;
			buffer.updateElement(spr);
		}
		return alpha = value;
	}

	function set_color(value:Color):Color {
		for (ci in 0..._activeCount) {
			var spr = buffer.getElement(ci);
			if (spr != null) spr.c = value;
			buffer.updateElement(spr);
		}
		buffer.update();
		return color = value;
	}

	function set_outlineColor(value:Color):Color {
		for (ci in 0..._activeCount) {
			var spr = buffer.getElement(ci);
			if (spr != null) spr.oc = value;
			buffer.updateElement(spr);
		}
		return outlineColor = value;
	}

	function set_outlineSize(value:Float):Float {
		for (ci in 0..._activeCount) {
			var spr = buffer.getElement(ci);
			if (spr != null) spr.os = value;
			buffer.updateElement(spr);
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
		font = value;
		markDirty();
		refresh();
		return value;
	}

	var parsedTextAtlasData:Array<TextCharData>;

	// ── Markup parsing (unchanged) ────────────────────────────────────────────

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
		return {clean: clean.toString(), spans: spans};
	}

	private function matchMarkerAt(raw:String, i:Int):Int {
		var best = -1;
		var bestLen = 0;
		for (mi in 0...markerPairs.length) {
			var m = markerPairs[mi].marker;
			if (m.length <= bestLen) continue;
			if (i + m.length > raw.length) continue;
			if (raw.substr(i, m.length) == m) {
				best = mi;
				bestLen = m.length;
			}
		}
		return best;
	}

	// ── Constructor ───────────────────────────────────────────────────────────

	function new(key:String, x:Float, y:Float, display:Display, text:String = "Sample text", font:String = "vcr") {
		_key = key;
		buffer = new Buffer<TextCharSprite>(32, 32);

		program = new CustomProgram(buffer);
		if (Main.current.upscale) {
			program.injectIntoFragmentShader(Shaders.UPSCALE_FRAGMENT_SHADER + "\n\n" + TEXT_FRAGMENT_SHADER);
		} else {
			program.injectIntoFragmentShader(TEXT_FRAGMENT_SHADER_NO_UPSCALE);
		}
		program.setColorFormula('pixelAlpha(font_ID, c, oc, os, rw, rh) * alphaColor');

		this.font = font;
		this.display = display;
		display.addProgram(program);

		this.x = x;
		this.y = y;
		
		// Initialize with default values
		multiline = false;
		alignment = LEFT;
		spacerPercent = 0.0;
		lineSpacing = 0;
		maxWidth = 0;

		if (text == null || text.length == 0) text = "Sample text";
		this.text = text;
	}

	// ── Utilities (updated) ───────────────────────────────────────────────────

	function screenCenter(axis:Axis = XY) {
		switch (axis) {
			case X: x = (display.width - width) * 0.5;
			case Y: y = (display.height - height) * 0.5;
			default: 
				x = (display.width - width) * 0.5;
				y = (display.height - height) * 0.5;
		}
	}
	
	// New: Force text recalculation (useful after changing properties)
	function refresh() {
		set_text(_rawText);
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