package elements.text;

@:publicFields
class Text {
	private static inline var OUTLINE_SHADER = '';
	private static inline var OUTLINE_FORMULA = '';
	private static inline var GLYPH_FORMULA = '';

	var glyphs:TextInternal;
	var outline:TextInternal;

	var _key:String;
	var parsedTextAtlasData:Array<TextCharData>;

    var display(default, set):CustomDisplay;

    function set_display(value:CustomDisplay) {
        glyphs.display = value;
        outline.display = value;
        return display = value;
    }

	var text(default, set):String = "";

	function set_text(str:String) {
		if (str == text) return text;
		glyphs.text = str;
		outline.text = str;
		return text = str;
	}

	var x(default, set):Float = 0;

	function set_x(value:Float) {
		glyphs.x = value;
		outline.x = value;
		return x = value;
	}

	var y(default, set):Float = 0;

	function set_y(value:Float) {
		glyphs.y = value;
		outline.y = value;
		return y = value;
	}

	var scale(default, set):Float = 1.0;

	function set_scale(value:Float) {
		glyphs.scale = value;
		outline.scale = value;
		return scale = value;
	}

	var alpha(default, set):Float = 1.0;

	function set_alpha(value:Float) {
		glyphs.alpha = value;
		outline.alpha = value;
		return alpha = value;
	}

	var color(default, set):Color = 0xFFFFFFFF;

	function set_color(value:Color) {
		glyphs.color = value;
		return color = value;
	}

	var outlineColor(default, set):Color = 0x000000FF;

	function set_outlineColor(value:Color) {
		outline.outlineColor = value;
		return outlineColor = value;
	}

	var outlineSize(default, set):Float = 0;

	function set_outlineSize(value:Float) {
		outline.outlineSize = value;
		return outlineSize = value;
	}

	var width(get, null):Float;
	function get_width() return glyphs._width;

	var height(get, null):Float;
	function get_height() return glyphs._height;

	var font(default, set):String;

	function set_font(value:String) {
		if (font == value) return value;
		parsedTextAtlasData = Tools.parseFont(value);
		var displayTextureID = value + "Font";
		TextureSystem.setTexture(glyphs.program, displayTextureID, "font");
		TextureSystem.setTexture(outline.program, displayTextureID, "font");
		glyphs.setFont(parsedTextAtlasData);
		outline.setFont(parsedTextAtlasData);
		return font = value;
	}

	function new(key:String, x:Float, y:Float, display:CustomDisplay, text:String = "Sample text", font:String = "vcr") {
		_key = key;

		outline = new TextInternal(display, OUTLINE_SHADER, OUTLINE_FORMULA);
		glyphs = new TextInternal(display, GLYPH_FORMULA, GLYPH_FORMULA);
		this.display = display;

		this.font = font;
		this.x = x;
		this.y = y;

		this.text = text;
	}

	function screenCenter(axis:Axis = XY) {
		var display = glyphs.program.displays[0];
		switch (axis) {
			case X: x = (display.width - width) * 0.5;
			case Y: y = (display.height - height) * 0.5;
			default:
				x = (display.width - width) * 0.5;
				y = (display.height - height) * 0.5;
		}
	}

	function setMarkerPair(part:String, color:Color, outlineColor:Color = 0x000000FF, outlineSize:Float = 0) {
		var index = text.indexOf(part);
		for (i in index...index + part.length) {
			var spr = glyphs.buffer.getElement(i);
			if (spr != null) spr.c = color;
			glyphs.buffer.updateElement(spr);

			var ospr = outline.buffer.getElement(i);
			if (ospr != null) {
				ospr.oc = outlineColor;
				ospr.os = outlineSize;
			}
			outline.buffer.updateElement(ospr);
		}
	}

	function dispose() {
		removeProgram();
		glyphs.buffer.clear();
		outline.buffer.clear();
		display = null;
	}

	function addProgram() {
		glyphs.addProgram();
		outline.addProgram();
		var displayTextureID = font + "Font";
		TextureSystem.setTexture(glyphs.program, displayTextureID, "font");
		TextureSystem.setTexture(outline.program, displayTextureID, "font");
	}

	function removeProgram() {
		glyphs.removeProgram();
		outline.removeProgram();
		var displayTextureID = font + "Font";
		TextureSystem.setTexture(glyphs.program, displayTextureID, "font");
		TextureSystem.setTexture(outline.program, displayTextureID, "font");
	}
}