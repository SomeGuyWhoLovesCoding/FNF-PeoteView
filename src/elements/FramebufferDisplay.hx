package elements;

@:publicFields
class FramebufferDisplay extends Display {
	var buffer:Buffer<PixelElement>;
	var program:Program;
	var frame:PixelElement;
    var display:Display;
    var texture:Texture;
    
    var useFramebuffer:Bool;

	public function new(x:Int, y:Int, width:Int, height:Int, color:Color = 0x00000000, ?useFramebuffer:Bool = true) {
		super(x, y, width, height, color);
        this.useFramebuffer = useFramebuffer;
        
        display = new Display(0, 0, width, height, 0x00000000);
		
		if (useFramebuffer) {
            // tell peote view to use this display as a framebuffer
            Main.current.peoteView.addFramebufferDisplay(this);

            texture = new Texture(width, height);
            texture.smoothExpand = texture.smoothShrink = true;
            texture.mipmap = texture.smoothMipmap = true;

            // set a texture that the framebuffer will be rendered to
            setFramebuffer(texture);
        }
		
		// buffer/program/element for rendering the texture
		buffer = new Buffer<PixelElement>(1);

		program = new Program(buffer);
		program.blendEnabled = true;
		program.blendSrc = program.blendSrcAlpha = BlendFactor.ONE;
		program.blendDst = program.blendDstAlpha = BlendFactor.ONE_MINUS_SRC_ALPHA;
		
		if (useFramebuffer) {
            program.addTexture(fbTexture);
        }

		frame = buffer.addElement(new PixelElement(0, 0, width, height));

		// set up pivot and offset position so the rotate is around the center
		frame.pivot_x = 0.5;
		frame.pivot_y = 0.5;
		frame.x += (frame.width * 0.5);
		frame.y += (frame.height * 0.5);
		
		program.addToDisplay(display);
	}

    /** Enable or disable framebuffer usage at runtime **/
    public function setFramebufferEnabled(enabled:Bool):Void {
        if (enabled == useFramebuffer) return;
        
        if (enabled) {
            // Enable framebuffer
            Main.current.peoteView.addFramebufferDisplay(this);
            texture = new Texture(width, height);
            texture.smoothExpand = texture.smoothShrink = true;
            texture.mipmap = texture.smoothMipmap = true;
            setFramebuffer(texture);
            program.addTexture(fbTexture);
        } else {
            // Disable framebuffer
            Main.current.peoteView.removeFramebufferDisplay(this);
            setFramebuffer(null);
            program.removeTexture(fbTexture);
            texture.dispose();
            texture = null;
        }

        peoteView.removeDisplay(!useFramebuffer ? display : this);
        peoteView.addDisplay(useFramebuffer ? display : this);
        
        useFramebuffer = enabled;
    }

    public function addIt(peoteView:PeoteView) {
        peoteView.addDisplay(useFramebuffer ? display : this);
    }

    public function resize(w:Int, h:Int) {
        width = w;
        height = h;

        if (useFramebuffer) {
            display.width = w;
            display.height = h;
            program.removeTexture(fbTexture);
            texture.dispose();
            texture = null;
            texture = new Texture(w, h);
            texture.smoothExpand = texture.smoothShrink = true;
            texture.mipmap = texture.smoothMipmap = true;
            setFramebuffer(texture);
            program.addTexture(fbTexture);
        }
    }

	/** rotate the element to rotate the display **/
	public function rotate(angle:Float) {
		frame.r = angle;
		buffer.updateElement(frame);
        return angle; // for the set_r property in `CustomDisplay`.
	}

	/** helper function for setting shader **/
	public function inject_glsl_program(glsl:String, color_formula:String) {
		program.injectIntoFragmentShader(glsl);
		program.setColorFormula(color_formula);
	}
}