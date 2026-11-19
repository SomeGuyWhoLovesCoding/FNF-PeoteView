package gameplay;

/**
	The playfield's frontend: everything the player sees AROUND the notes
	that is not the note system itself — the stage/actors (Field), the
	countdown display, and the lua script VM (FunkinViewLua).

	In editor mode this class is NEVER constructed: `PlayField.frontend`
	stays null and every lua dispatch / field access goes through the
	null-guards already present at each call site, so the editor runs
	with zero stage, zero countdown, zero lua — by construction, not by
	branches sprinkled through PlayField.

	All lua callbacks are routed through the `lua*` helpers here so a
	missing frontend degrades to a no-op instead of a null deref:
	  luaCall('update', dt)            — fire-and-forget dispatch
	  luaCallStop(...)                 — Function_Stop check (true = stop)
	@since Development
**/
@:publicFields
class PlayFieldFrontEnd {
	/** Owning playfield. */
	var parent(default, null):PlayField;

	/** The stage: characters, camera, spectator rows. Null never (when this exists). */
	var field(default, null):Field;

	/** The countdown display (gameplay only). */
	var countdownDisp(default, null):CountdownDisplay;

	#if linc_luajit_funkinview
	/** The lua script VM bound to this playfield. */
	var funkinviewlua(default, null):FunkinViewLua;
	#end

	function new(parent:PlayField) {
		this.parent = parent;
	}

	/**
		Builds the full gameplay frontend: stage, countdown, and (in
		lua-enabled builds) the FunkinViewLua VM. Called from
		PlayField.create()'s gameplay branch only.

		The chart path is passed in (PlayField.chartPath is private, and
		Haxe has no package-private visibility).
	**/
	function build(chartPath:String) {
		field = new Field(parent);

		CountdownDisplay.init(parent.roof);
		countdownDisp = new CountdownDisplay();
		countdownDisp.setupSounds();

		#if linc_luajit_funkinview
		funkinviewlua = new FunkinViewLua(parent, chartPath, Chart.header);
		#end
	}

	// -------------------------------------------------------------------
	// Lua dispatch (all null-safe; no-ops without a frontend)
	// -------------------------------------------------------------------

	/** Fire-and-forget lua dispatch. */
	inline function luaCall(fname:String, args:haxe.Rest<Dynamic>) {
		#if linc_luajit_funkinview
		if (funkinviewlua != null)
			funkinviewlua.callFunction(fname, args);
		#end
	}

	/**
		Dispatch whose Function_Stop result matters. Returns true when a
		script returned Function_Stop (caller should stop), false otherwise
		(including when there is no frontend at all).
	**/
	inline function luaCallStop(fname:String, args:haxe.Rest<Dynamic>):Bool {
		#if linc_luajit_funkinview
		if (funkinviewlua != null)
			return funkinviewlua.callFunction(fname, args)[0] == FunkinViewLua.Function_Stop;
		#end
		return false;
	}

	// -------------------------------------------------------------------
	// Update / render / dispose
	// -------------------------------------------------------------------

	function update(deltaTime:Float) {
		if (field != null)
			field.update(deltaTime);
		if (countdownDisp != null)
			countdownDisp.update(deltaTime);
	}

	function updateCamera(deltaTime:Float) {
		if (field != null)
			field.updateCamera(deltaTime);
	}

	function render() {
		if (field != null)
			field.render();
	}

	function dispose() {
		if (field != null) {
			field.dispose();
			field = null;
		}
		if (countdownDisp != null) {
			countdownDisp.dispose();
			countdownDisp = null;
		}
		#if linc_luajit_funkinview
		if (funkinviewlua != null) {
			funkinviewlua.callFunction('dispose', null);
			funkinviewlua.callFunction('disposePost', null);
			funkinviewlua.callFunction('postDispose', null); // alternative syntax
			funkinviewlua.dispose();
			funkinviewlua = null;
		}
		#end
	}
}
