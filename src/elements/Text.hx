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
        var len = str.length;
        if (len == 0) {
            lines.push("");
            return lines;
        }

        if (!multiline) {
            // Fast newline-to-space replacement without split allocation
            var buf = new StringBuf();
            for (i in 0...len) {
                var c = str.charCodeAt(i);
                buf.addChar(c == 10 ? 32 : c);
            }
            lines.push(buf.toString());
            return lines;
        }

        if (maxWidth <= 0) {
            // Fast newline split using index tracking (no split array allocation)
            var lastIdx = 0;
            for (i in 0...len) {
                if (str.charCodeAt(i) == 10) {
                    lines.push(str.substr(lastIdx, i - lastIdx));
                    lastIdx = i + 1;
                }
            }
            lines.push(str.substr(lastIdx));
            return lines;
        }

        // Word wrap with maxWidth (single pass, minimal allocation)
        var quarterScale = scale / 2;
        var lineStart = 0;
        var currentLineWidth:Float = 0;
        var lastSpaceIndex:Int = -1;
        var lastSpaceWidth:Float = 0;

        for (i in 0...len) {
            var c = str.charCodeAt(i);
            
            if (c == 10) {
                lines.push(str.substr(lineStart, i - lineStart));
                lineStart = i + 1;
                currentLineWidth = 0;
                lastSpaceIndex = -1;
                lastSpaceWidth = 0;
                continue;
            }

            var data = parsedTextAtlasData[c];
            var charWidth = (data != null ? data[6] : 0.0) * quarterScale;
            var totalCharWidth = charWidth + (charWidth * spacerPercent);

            if (c == 32) {
                lastSpaceIndex = i;
                lastSpaceWidth = currentLineWidth;
            }

            if (currentLineWidth + totalCharWidth > maxWidth && lastSpaceIndex != -1) {
                // Wrap at last space
                lines.push(str.substr(lineStart, lastSpaceIndex - lineStart));
                lineStart = lastSpaceIndex + 1;
                currentLineWidth = lastSpaceWidth + totalCharWidth;
                lastSpaceIndex = -1;
                lastSpaceWidth = 0;
            } else {
                currentLineWidth += totalCharWidth;
            }
        }
        
        // Push remaining text
        if (lineStart < len || (len > 0 && str.charCodeAt(len - 1) == 10)) {
            lines.push(str.substr(lineStart));
        } else if (lines.length == 0) {
            lines.push(str);
        }

        return lines;
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

    // ── set_text (updated with pre-allocation and combined dimension pass) ────

    function set_text(raw:String) {
        if (!_dirty) if (raw == _rawText) return text;
        _dirty = false;
        _rawText = raw;
        
        // Preserve newlines for markup parsing
        var parsed = parseMarkup(raw);
        var str = parsed.clean;
        colorSpans = parsed.spans;
        
        // Handle multiline
        _lines = multiline ? wrapText(str) : [str.replace("\n", " ")];
        
        var quarterScale = scale / 2;
        lineHeight = parsedTextAtlasData[256][4] * quarterScale;
        _lineWidths = [];
        var maxLineWidth:Float = 0;
        
        // Single pass for width frequency analysis (avoids iterating text multiple times)

        for (lineIdx in 0..._lines.length) {
            var line = _lines[lineIdx];
            var lineWidth:Float = 0;
            
            for (i in 0...line.length) {
                var data = parsedTextAtlasData[line.charCodeAt(i)];
                if (data != null) {
                    var charWidth = data[6] * quarterScale;
                    lineWidth += charWidth + (charWidth * spacerPercent);
                }
            }
            
            _lineWidths.push(lineWidth);
            if (lineWidth > maxLineWidth) maxLineWidth = lineWidth;
        }
        
        // Store actual dimensions
        width = maxLineWidth;
        height = _lines.length * lineHeight;
        
        // Count total characters to render
        var totalChars = 0;
        for (line in _lines) totalChars += line.length;
        
        // PRE-ALLOCATE: Ensure buffer has capacity to prevent runtime 'new' allocations mid-loop
        while (buffer.length < totalChars) {
            buffer.addElement(new TextCharSprite()); 
        }
        
        // Hide previously-active excess sprites
        if (totalChars < _activeCount) {
            for (ci in totalChars..._activeCount) {
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
        var rawCharIdx = 0;
        var originalTextLen = str.length;
        
        for (lineIdx in 0..._lines.length) {
            var line = _lines[lineIdx];
            var lineWidth = _lineWidths[lineIdx];
            
            // Calculate X offset based on alignment
            var xOffset = switch (alignment) {
                case LEFT: 0.0;
                case CENTER: (maxLineWidth - lineWidth) * 0.5;
                case RIGHT: maxLineWidth - lineWidth;
            }
            
            var advanceX = xOffset;
            var lineY = y + (lineIdx * lineHeight);
            
            for (i in 0...line.length) {
                var code = line.charCodeAt(i);
                var data = parsedTextAtlasData[code];
                if (data == null) {
                    rawCharIdx++;
                    continue; // Skip unmapped chars safely
                }
                
                // Safe fetch: we guaranteed capacity above
                var spr:TextCharSprite = buffer.getElement(globalCharIdx);
                
                // Resolve style based on position in original text
                while (spanIdx < colorSpans.length && colorSpans[spanIdx].end <= rawCharIdx) {
                    spanIdx++;
                }
                var span = (spanIdx < colorSpans.length && rawCharIdx >= colorSpans[spanIdx].start)
                    ? colorSpans[spanIdx] : null;
                var sc = span != null ? span.color : color;
                var soc = span != null ? span.outlineColor : outlineColor;
                var sos = (span != null && span.outlineSize != 0.0) ? span.outlineSize : outlineSize;
                
                // Apply spacer percentage to advance width
                var baseAdvance = data[6] * quarterScale;
                var totalAdvance = baseAdvance + (baseAdvance * spacerPercent);
                
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
            while (rawCharIdx < originalTextLen && str.charCodeAt(rawCharIdx) == 10) {
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
    var lineHeight(default, null):Float;

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

    // ── Optimized Markup Matching (Allocation-Free) ───────────────────────────

    @:privateAccess
    private inline function matchMarkerAt(raw:String, i:Int):Int {
        var best = -1;
        var bestLen = 0;
        var rawLen = raw.length;
        
        for (mi in 0...markerPairs.length) {
            var m = markerPairs[mi].marker;
            var len = m.length;
            if (len <= bestLen || i + len > rawLen) continue;
            
            var match = true;
            // Inline character comparison avoids substr allocation
            for (j in 0...len) {
                if (raw.charCodeAt(i + j) != m.charCodeAt(j)) {
                    match = false;
                    break;
                }
            }
            if (match) {
                best = mi;
                bestLen = len;
            }
        }
        return best;
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    function new(key:String, x:Float, y:Float, display:Display, txt:String = "Sample text", font:String = "vcr") {
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

        if (txt == null || txt.length == 0) txt = "Sample text";
        text = txt;
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
        if (program.isIn(display)) display.removeProgram(program);
    }

    function addProgram() {
        if (!program.isIn(display)) display.addProgram(program);
    }
}
