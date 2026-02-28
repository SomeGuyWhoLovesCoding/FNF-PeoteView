package elements;

class PixelElement implements Element {
	/** Position of the element on x axis. Relative to top left of Display.**/
	@posX @formula("(width * 0.5) + x")  public var x:Float;

	/** Position of the element on y axis. Relative to top left of Display.**/
	@posY @formula("(height * 0.5) + y")  public var y:Float;

	/** Size of the element on x axis. **/
	@sizeX @varying public var width:Int;

	/** Size of the element on y axis. **/
	@sizeY @varying public var height:Int;

	/** The pivot point around with the element will rotate on the x axis - 0.5 is the center. **/
	@pivotX @formula("width * 0.5") public var pivot_x:Float;

	/** The pivot point around with the element will rotate on the y axis - 0.5 is the center. **/
	@pivotY @formula("height * 0.5") public var pivot_y:Float;

	/** Degrees of rotation. **/
	@rotation public var r:Float = 0.0;

	/** RGBA color. **/
	@color public var color:Color = 0xf0f0f0ff;

	/** Auto-enable blend in the Program the element is rendered by (for alpha and more) **/
	var OPTIONS = {blend: true};

	/** 
		@param x the starting x position in the Display.
		@param y the starting y position in the Display.
		@param width (optional) is 1 pixel by default.
		@param height (optional) is 1 pixel by default.
	**/
	public function new(x:Float, y:Float, width:Int = 1, height:Int = 1) {
		this.x = Std.int(x);
		this.y = Std.int(y);
		this.width = width;
		this.height = height;
	}
}
