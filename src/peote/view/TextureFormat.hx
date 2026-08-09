package peote.view;

/**
	Specifies the colorchannels and precision for storing imagedata and provides the `format` for `TextureData` and `Texture`s by `TextureConfig`.  
	The value of a color/alpha channel of a pixel can have 8 bit integer or alternatively 32 bit floatpoint precision.
**/
@:allow(peote.view.intern.TexUtils, peote.view.Texture, peote.view.TextureData, peote.view.TextureDataImpl) #if (haxe_ver >= 4.0) enum #else @:enum #end
abstract TextureFormat(Int) from Int to Int {
	// ES 3.0: https://docs.gl/es3/glTexImage2D
	public static inline var R:Int = 1;
	public static inline var RG:Int = 2;

	// ES 2.0: https://docs.gl/es2/glTexImage2D
	public static inline var RGB:Int = 3;
	public static inline var RGBA:Int = 4;

	public static inline var LUMINANCE:Int = 5;
	public static inline var ALPHA:Int = 6;
	public static inline var LUMINANCE_ALPHA:Int = 7;

	// float precision
	public static inline var FLOAT_R:Int = 8;
	public static inline var FLOAT_RG:Int = 9;
	public static inline var FLOAT_RGB:Int = 10;
	public static inline var FLOAT_RGBA:Int = 11;

	// compressed formats
	public static inline var ASTC_44:Int = 12;
	public static inline var BPTC_44:Int = 13;

	/**
		Returns the enum-identifier as a `String`.
	**/
	@:to public function toString():String {
		return switch (this) {
			case R: "R";
			case RG: "RG";
			case RGB: "RGB";
			case RGBA: "RGBA";
			case LUMINANCE: "LUMINANCE";
			case ALPHA: "ALPHA";
			case LUMINANCE_ALPHA: "LUMINANCE_ALPHA";
			case FLOAT_R: "FLOAT_R";
			case FLOAT_RG: "FLOAT_RG";
			case FLOAT_RGB: "FLOAT_RGB";
			case FLOAT_RGBA: "FLOAT_RGBA";
			case ASTC_44: "ASTC_44";
			case BPTC_44: "BPTC_44";
			default: "unknown";
		}
	}

	/**
		Is `true` if using floatpoint precision.
	**/
	public var isFloat(get, never):Bool;

	inline function get_isFloat():Bool
		return (this > LUMINANCE_ALPHA && this < ASTC_44);

	/**
		Is `true` if using a block-compressed format.
	**/
	public var isCompressed(get, never):Bool;

	inline function get_isCompressed():Bool
		return this >= ASTC_44;

	inline function isGreaterR():Bool
		return this > R && !isCompressed;

	inline function isGreaterRG():Bool
		return this > RG && !isCompressed;

	inline function isInRGBA():Bool
		return this < LUMINANCE;

	inline function isGreaterFloatR():Bool
		return this > FLOAT_R && this < ASTC_44;

	inline function isGreaterFloatRG():Bool
		return this > FLOAT_RG && this < ASTC_44;

	inline function isGreaterFloatRGB():Bool
		return this > FLOAT_RGB && this < ASTC_44;

	/**
		The number of Bytes what is used per pixel.
		For compressed formats, this returns the average bytes per pixel (1 for ASTC 4x4).
	**/
	public var bytesPerPixel(get, never):Int;

	inline function get_bytesPerPixel():Int {
		if (isCompressed)
			return 1; // 16 bytes per 4x4 block = 1 byte per pixel average
		if (isFloat)
			return get_bytesPerPixelFloat();
		else
			return get_bytesPerPixelInt();
	}

	var bytesPerPixelInt(get, never):Int;

	inline function get_bytesPerPixelInt():Int {
		if (this < LUMINANCE)
			return this;
		else if (this < LUMINANCE_ALPHA)
			return 1;
		else
			return 2;
	}

	var bytesPerPixelFloat(get, never):Int;

	inline function get_bytesPerPixelFloat():Int
		return (this - LUMINANCE_ALPHA) * 4;

	/**
		The amount of used colorchannels (including alpha).
	**/
	public var channels(get, never):Int;

	inline function get_channels():Int {
		if (isCompressed)
			return 4; // ASTC_44 contains RGBA
		if (isFloat)
			return this - LUMINANCE_ALPHA;
		else
			return get_bytesPerPixelInt();
	}

	// Integer internal- and format

	inline function integer(gl:PeoteGL):Int {
		return switch (this) {
			case LUMINANCE: gl.LUMINANCE;
			case ALPHA: gl.ALPHA;
			case LUMINANCE_ALPHA: gl.LUMINANCE_ALPHA;

			case RGBA: gl.RGBA;
			case RGB: gl.RGB;

			case RG: gl.RG8;
			case R: gl.R8;

			default: gl.RGBA;
		}
	}

	inline function formatInteger(gl:PeoteGL):Int {
		return switch (this) {
			case LUMINANCE: gl.LUMINANCE;
			case ALPHA: gl.ALPHA;
			case LUMINANCE_ALPHA: gl.LUMINANCE_ALPHA;

			case RGBA: gl.RGBA;
			case RGB: gl.RGB;

			case RG: gl.RG;
			case R: gl.RED;

			default: gl.RGBA;
		}
	}

	// Float internal- and format

	inline function float32(gl:PeoteGL):Int {
		return switch (this) {
			case FLOAT_RGBA: gl.RGBA32F;
			case FLOAT_RGB: gl.RGB32F;
			case FLOAT_RG: gl.RG32F;
			case FLOAT_R: gl.R32F;

			default: gl.RGBA32F;
		}
	}

	inline function float16(gl:PeoteGL):Int {
		return switch (this) {
			case FLOAT_RGBA: gl.RGBA16F;
			case FLOAT_RGB: gl.RGB16F;
			case FLOAT_RG: gl.RG16F;
			case FLOAT_R: gl.R16F;

			default: gl.RGBA16F;
		}
	}

	inline function formatFloat(gl:PeoteGL):Int {
		return switch (this) {
			case FLOAT_RGBA: gl.RGBA;
			case FLOAT_RGB: gl.RGB;
			case FLOAT_RG: gl.RG;
			case FLOAT_R: gl.RED;

			default: gl.RGBA;
		}
	}

	// Compressed internal format
	// ASTC 4x4 internal format constant (0x93B0)
	public static inline var COMPRESSED_RGBA_ASTC_4x4_KHR:Int = 0x93B0;
	public static inline var COMPRESSED_RGBA_BPTC_UNORM:Int = 0x8E8C;

	inline function compressedInternalFormat(gl:PeoteGL):Int {
		return switch (this) {
			case ASTC_44: COMPRESSED_RGBA_ASTC_4x4_KHR;
			case BPTC_44: COMPRESSED_RGBA_BPTC_UNORM;
			default: 0;
		}
	}
}
