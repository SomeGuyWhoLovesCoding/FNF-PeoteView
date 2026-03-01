package elements;

/**
	RotatableDisplay is a custom class that extends Display with added rotation support at the vertex level.
**/
@:publicFields
@:access(people.view.Program)
class RotatableDisplay extends Display
{
	private var rotation(default, set):Float = 0.0;

	var uAngle:UniformFloat;
	var uCos:UniformFloat;
	var uSin:UniformFloat;
	var uCenter:UniformVec2;

	public function new(x:Int, y:Int, width:Int, height:Int, color = 0x00000000) {
		super(x, y, width, height, color);
		uAngle   = new UniformFloat("uDisplayAngle", 0.0);
		uSin     = new UniformFloat("uSin", 0.0);
		uCos     = new UniformFloat("uCos", 1.0); // this has to be 1.0. cosine is just sine but inverted.
		uCenter = new UniformVec2("uDisplayC", [x + width * 0.5, y + height * 0.5]);
	}

	/// finally. line of code that isn't an inline function I can override.
	override private function renderFramebufferProgram(peoteView:PeoteView):Void
	{
		programListItem = programList.first;
		@:privateAccess while (programListItem != null)
		{
			var _this:CustomProgram = Std.downcast(programListItem.value, CustomProgram);
			var display:RotatableDisplay = this;

			_this.gl.useProgram(_this.glProgram);
			_this.render_activeTextureUnits(peoteView, _this.textureList);
			
			if (PeoteGL.Version.isUBO)
			{	
				// ------------- uniform block -------------
				_this.gl.bindBufferBase(_this.gl.UNIFORM_BUFFER, UniformBufferView.block, display.uniformBufferViewFB.uniformBuffer);
				_this.gl.bindBufferBase(_this.gl.UNIFORM_BUFFER, UniformBufferDisplay.block, display.uniformBufferFB.uniformBuffer);
			}
			else
			{
				// ------------- simple uniform -------------
				_this.gl.uniform2f (_this.uRESOLUTION, display.width, -display.height);
				_this.gl.uniform2f (_this.uZOOM, display.xz, display.yz);
				
				// TODO: check if peoteViews offset have to be here!
				_this.gl.uniform2f (_this.uOFFSET, (display.xOffset + peoteView.xOffset) / display.xz, 
									(display.yOffset + peoteView.yOffset - display.height) / display.yz );
			}
			
			_this.gl.uniform1f (_this.uTIME, peoteView.time);
			for (i in 0..._this.uniformFloats.length) _this.gl.uniform1f (_this.uniformFloatLocations[i], _this.uniformFloats[i].value);
			if (_this.uniformVec2s != null) {
				for (i in 0..._this.uniformVec2s.length) {
					var vec2 = _this.uniformVec2s[i];
					var value1 = vec2.value[0];
					var value2 = vec2.value[1];
					//trace(value1,value2);
					_this.gl.uniform2f (_this.uniformVec2Locations[i], value1, value2);
				}
			}
			
			peoteView.setColor(_this.colorEnabled);
			peoteView.setGLDepth(_this.zIndexEnabled);		
			peoteView.setGLBlend(_this.blendEnabled, _this.blendSeparate, _this.glBlendSrc, _this.glBlendDst, _this.glBlendSrcAlpha, _this.glBlendDstAlpha, _this.blendFuncSeparate, _this.glBlendFunc, _this.glBlendFuncAlpha, _this.blendColor, _this.useBlendColor, _this.useBlendColorSeparate, _this.glBlendR, _this.glBlendG, _this.glBlendB, _this.glBlendA);		
			peoteView.setMask(_this.mask, _this.clearMask);
			
			_this.buffer.render(peoteView, display, _this);
			_this.gl.useProgram (null);

			programListItem = programListItem.next;
		}
	}

	override private function renderProgram(peoteView:PeoteView):Void
	{
		programListItem = programList.first;
		@:privateAccess while (programListItem != null)
		{
			var _this:CustomProgram = Std.downcast(programListItem.value, CustomProgram);
			var display:RotatableDisplay = this;

			if (_this.isVisible)
			{
				#if peoteview_debug_program
				//trace("    ---program.render---");		
				if (!_this.ready) trace("=======PROBLEM=====> not READY !!!!!!!!"); // TODO !!!
				#end
				_this.gl.useProgram(_this.glProgram);
				
				_this.render_activeTextureUnits(peoteView, _this.textureList);
				
				// TODO: custom uniforms per Program
				
				if (PeoteGL.Version.isUBO)
				{	
					// ------------- uniform block -------------
					// for multiple ranges
					//gl.bindBufferRange(gl.UNIFORM_BUFFER, peoteView.uniformBuffer.block, peoteView.uniformBuffer.uniformBuffer, 256, 3 * 4*4);
					//gl.bindBufferRange(gl.UNIFORM_BUFFER, display.uniformBuffer.block  , display.uniformBuffer.uniformBuffer  , 256, 2 * 4*4);
					_this.gl.bindBufferBase(_this.gl.UNIFORM_BUFFER, UniformBufferView.block, peoteView.uniformBuffer.uniformBuffer);
					_this.gl.bindBufferBase(_this.gl.UNIFORM_BUFFER, UniformBufferDisplay.block, display.uniformBuffer.uniformBuffer);
				}
				else
				{
					// ------------- simple uniform -------------
					_this.gl.uniform2f (_this.uRESOLUTION, peoteView.width, peoteView.height);
					_this.gl.uniform2f (_this.uZOOM, peoteView.xz * display.xz, peoteView.yz * display.yz);
					_this.gl.uniform2f (_this.uOFFSET, (display.x + display.xOffset + peoteView.xOffset) / display.xz, 
										(display.y + display.yOffset + peoteView.yOffset) / display.yz);
				}
				
				_this.gl.uniform1f (_this.uTIME, peoteView.time);
				for (i in 0..._this.uniformFloats.length) _this.gl.uniform1f (_this.uniformFloatLocations[i], _this.uniformFloats[i].value);
				if (_this.uniformVec2s != null) {
					for (i in 0..._this.uniformVec2s.length) {
						var vec2 = _this.uniformVec2s[i];
						var value1 = vec2.value[0];
						var value2 = vec2.value[1];
						//trace(value1,value2);
						_this.gl.uniform2f (_this.uniformVec2Locations[i], value1, value2);
					}
				}
				
				peoteView.setColor(_this.colorEnabled);
				peoteView.setGLDepth(_this.zIndexEnabled);		
				peoteView.setGLBlend(_this.blendEnabled, _this.blendSeparate, _this.glBlendSrc, _this.glBlendDst, _this.glBlendSrcAlpha, _this.glBlendDstAlpha, _this.blendFuncSeparate, _this.glBlendFunc, _this.glBlendFuncAlpha, _this.blendColor, _this.useBlendColor, _this.useBlendColorSeparate, _this.glBlendR, _this.glBlendG, _this.glBlendB, _this.glBlendA);		
				peoteView.setMask(_this.mask, _this.clearMask);
				
				_this.buffer.render(peoteView, display, _this);
				_this.gl.useProgram (null);
			}

			programListItem = programListItem.next;
		}
	}

	private function set_rotation(deg:Float):Float {
		uAngle.value = deg * (Math.PI / 180.0);
		uCos.value = Math.cos(uAngle.value);
		uSin.value = Math.sin(uAngle.value);
		return rotation = deg;
	}
}