package elements.text;

@:publicFields
class TextInternal {
	var buffer:Buffer<TextCharSprite>;
	var program:CustomProgram;

    var display:CustomDisplay;

	var text(default, set):String = "";

	function set_text(str:String) {
		for (i in str.length...text.length) {
			var elem = buffer.getElement(i);
			if (elem != null) {
				elem.x = elem.y = -999999999;
				elem.w = elem.h = 0;
				elem.alpha = 0;
			}
			buffer.updateElement(elem);
		}

		text = str;

		var quarterScale = _scale / 4;
		var advanceX:Float = 0;

		for (i in 0...str.length) {
			var code = str.charCodeAt(i);
			var data = _atlasData[code];

			var spr:TextCharSprite = i < buffer.length
				? buffer.getElement(i)
				: buffer.addElement(new TextCharSprite());

			advanceX = setupChar(spr, data, quarterScale, advanceX);
			buffer.updateElement(spr);
		}

		_width = advanceX;

		return text = str;
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
		_scale = value;

		var quarterScale = _scale / 4;
		var advanceX:Float = 0;

		for (i in 0...text.length) {
			var code = text.charCodeAt(i);
			var data = _atlasData[code];
			var spr = buffer.getElement(i);
			advanceX = setupCharScaled(spr, data, quarterScale, advanceX);
			buffer.updateElement(spr);
		}

		_width = advanceX;
		return scale = value;
	}

	var alpha(default, set):Float = 1.0;

	function set_alpha(value:Float) {
		for (i in 0...text.length) {
			var spr = buffer.getElement(i);
			if (spr != null) spr.alpha = value;
			buffer.updateElement(spr);
		}
		return alpha = value;
	}

	var color(default, set):Color = 0xFFFFFFFF;

	function set_color(value:Color) {
		for (i in 0...text.length) {
			var spr = buffer.getElement(i);
			if (spr != null) spr.c = value;
			buffer.updateElement(spr);
		}
		return color = value;
	}

	var outlineColor(default, set):Color = 0x000000FF;

	function set_outlineColor(value:Color) {
		for (i in 0...text.length) {
			var spr = buffer.getElement(i);
			if (spr != null) spr.oc = value;
			buffer.updateElement(spr);
		}
		return outlineColor = value;
	}

	var outlineSize(default, set):Float = 0;

	function set_outlineSize(value:Float) {
		for (i in 0...text.length) {
			var spr = buffer.getElement(i);
			if (spr != null) spr.os = value;
			buffer.updateElement(spr);
		}
		return outlineSize = value;
	}

	var _width(default, null):Float = 0;
	var _height(default, null):Float = 0;
	var _scale:Float = 1.0;
	var _atlasData:Array<TextCharData>;

	function new(display:Display, fragmentShader:String, colorFormula:String) {
		buffer = new Buffer<TextCharSprite>(32, 32);
		program = new CustomProgram(buffer);
		if (fragmentShader.length >= 1)
			program.injectIntoFragmentShader(fragmentShader);
		if (colorFormula.length >= 1)
			program.setColorFormula(colorFormula);
        //trace("DISSSSSPLAYYYYYYY: " + display);
		if (!program.isIn(display))
			display.addProgram(program);
	}

	function setFont(atlasData:Array<TextCharData>) {
		_atlasData = atlasData;
        this.text = text;
	}

	private function setupChar(spr:TextCharSprite, data:TextCharData, quarterScale:Float, advanceX:Float):Float {
		var padding = _atlasData[256];
		spr.clipX = data[0] - (padding[0] >> 1);
		spr.clipY = data[1] - (padding[1] >> 1);
		spr.clipWidth = spr.clipSizeX = data[2] + padding[0];
		spr.w = spr.clipWidth * quarterScale;
		spr.clipHeight = spr.clipSizeY = data[3] + padding[0];
		spr.h = spr.clipHeight * quarterScale;
		spr.x = x + (data[4] * quarterScale) + advanceX;
		spr.y = y + (data[5] * quarterScale);
		spr.c = color;
		spr.oc = outlineColor;
		spr.os = outlineSize;
		spr.alpha = alpha;
		advanceX += data[6] * quarterScale;

		if (_height < spr.h + spr.y - data[1])
			_height = spr.h + spr.y - data[1];

		return advanceX;
	}

	private function setupCharScaled(spr:TextCharSprite, data:TextCharData, quarterScale:Float, advanceX:Float):Float {
		var padding = _atlasData[256];
		spr.clipX = data[0] - (padding[0] >> 1);
		spr.clipY = data[1] - (padding[1] >> 1);
		spr.clipWidth = spr.clipSizeX = data[2] + padding[0];
		spr.w = spr.clipWidth * quarterScale;
		spr.clipHeight = spr.clipSizeY = data[3] + padding[0];
		spr.h = spr.clipHeight * quarterScale;
		spr.x = x + (data[4] * quarterScale) + advanceX;
		spr.y = y + (data[5] * quarterScale);
		advanceX += data[6] * quarterScale;
		return advanceX;
	}

    function removeProgram() {
        if (display == null) return;
        if (program.isIn(display)) display.removeProgram(program);
    }

    function addProgram() {
        if (display == null) return;
        if (!program.isIn(display)) display.addProgram(program);
    }
}