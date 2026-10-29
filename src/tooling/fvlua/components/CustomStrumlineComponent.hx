package tooling.fvlua.components;

#if linc_luajit_funkinview
import llua.Lua;
#end

using StringTools;

/**
	A strumline manipulation component instance for Funkin' View.

	Adds a strumline-focused Lua API on top of the note system:
	- mid-song mania changes (changeStrumlineMania, ceiling = the chart's absolute mania)
	- strumline position / gap / scale get + set
	- per-arrow offsets (x, y and local rotation)
	- extra strumlines at runtime (addStrumline), auto-hit like the opponent's
	- note type routing (assignNoteTypeToStrumline)

	Everything lives in this one file - no engine classes are modified.
	The few bits the engine itself has to adopt are documented as
	ready-to-paste snippets in INTEGRATION.md, centred around
	`CustomStrumlineComponent.laneForType()` below.

	Position / gap / offset numbers are FLOATS at the Lua boundary. The
	stock engine stores strumline x/y/gap and Note x/y as Int, so on an
	unpatched engine fractional values simply truncate to whole pixels.
	INTEGRATION.md Patch 7 widens those engine fields to Float, which
	makes every position sub-pixel precise — the component compiles and
	runs correctly against BOTH (see the dual-mode helpers getF/setF).

	Pause survival: PlayField.pause() runs NoteSystem.resetStrumlines(),
	which re-slots every strumline by the vanilla formula — anything past
	strumline 1 gets flung off-screen, and PlayField.update() (whose
	updateVariablesList would put it back) early-returns while paused.
	This component installs a 'pausePost' hook into any script that
	doesn't define one of its own, re-asserting Lua-added strumline
	positions right after the engine reset. INTEGRATION.md Patch 6 does
	the same job engine-side if you prefer that.

	Why the mania/strumline callbacks poke at `NoteSystem.notesBuf` at all:
	receptor arrow sprites are persistent GPU elements - the engine adds each
	one to the buffer exactly once at playfield creation and never touches the
	membership again. Shrinking a strumline's receptor array would leave the
	dropped arrows rendering as ghosts, and growing it would mint invisible new
	ones. So every receptor gained or lost is paired with an addElement /
	removeElement (that is the "GPU buffer management") plus a buffer update
	flush so the change shows up immediately.

	@since 0.94
**/
@:publicFields
class CustomStrumlineComponent extends LuaComponentObject {
	// ==================================================================
	// Static note-type routing table.
	// Kept OUTSIDE the linc_luajit_funkinview flag so engine code
	// (NoteSystem / NoteSpawner / PlayField) can consult it without
	// caring whether the Lua VMs are compiled in.
	//
	// typeToStrumline[type] = target strumline id,
	// or -1 to fall back to the engine default (type % strumline count).
	//
	// Engine integration (all optional, see INTEGRATION.md): anywhere a note
	// picks its strumline, swap
	//     var lane = n.type % strumlineCount;
	// for
	//     var lane = CustomStrumlineComponent.laneForType(n.type, strumlineCount);
	// ==================================================================
	public static var typeToStrumline:Array<Int> = [for (_ in 0...1 << 8) -1];

	public static function laneForType(type:Int, strumlineCount:Int):Int {
		if (strumlineCount <= 0)
			return 0;
		if (type < 0)
			type = 0;
		if (type >= 256)
			type = 255;
		var lane = typeToStrumline[type];
		if (lane < 0 || lane >= strumlineCount)
			return type % strumlineCount;
		return lane;
	}

	#if linc_luajit_funkinview

	// Intended x/y of Lua-added strumlines. Engine resets (seeks, downscroll
	// toggles, pauses) reposition strumlines by the vanilla slot formula,
	// which flings anything past strumline 1 off-screen -
	// reassertCustomPositions puts Lua-added strumlines back where the
	// script asked for them.
	var customStrumlineX:Array<Float> = new Array<Float>();
	var customStrumlineY:Array<Float> = new Array<Float>();

	public function new(_parent:FunkinViewLua) {
		super(_parent);

		// Statics survive between songs - start each song with a clean table.
		for (i in 0...1 << 8)
			typeToStrumline[i] = -1;

		for (i in 0...1 << 8) {
			customStrumlineX[i] = -9999;
			customStrumlineY[i] = -9999;
		}
	}

	// ------------------------------------------------------------------
	// Dual-mode engine access (INTEGRATION.md Patch 7).
	// Stock engine: Strumline.x/y/gap and Note.x/y are Int; with Patch 7
	// they are Float and every position becomes sub-pixel precise. This
	// component must compile against BOTH, so position writes/reads go
	// through Reflect: on a stock engine the property setter truncates to
	// whole pixels (identical to passing Ints), on a patched engine the
	// full float lands on the GPU. Reflect honours the custom setters
	// (Strumline.set_x relayouts its receptors; Note's @set("properties")
	// flags the element for the next buffer update), so nothing bypasses
	// the engine's own machinery.
	// ------------------------------------------------------------------
	static inline function getF(obj:Dynamic, field:String):Float {
		return Reflect.getProperty(obj, field);
	}

	static inline function setF(obj:Dynamic, field:String, value:Float):Void {
		Reflect.setProperty(obj, field, value);
	}

	override public function addCallbacksList(vm:FunkinViewLuaScript):Void {
		// =============================================================
		// Mania
		// =============================================================
		vm.addCallback('changeStrumlineMania', function(id:Int, mania:Int) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return FunkinViewLua.Function_Stop;

			var absoluteMania = Chart.header.mania;
			if (mania < 1 || mania > absoluteMania) {
				FunkinViewLua.error('Can\'t do that - mania $mania is outside the chart\'s absolute mania range (1 - $absoluteMania).');
				return FunkinViewLua.Function_Stop;
			}

			var oldMania = strumline.length;
			if (mania == oldMania)
				return FunkinViewLua.Function_Continue;

			if (mania < oldMania) {
				// The receptor sprites that are about to be dropped would
				// otherwise keep rendering from inside notesBuf as ghosts.
				for (i in mania...oldMania)
					NoteSystem.notesBuf.removeElement(strumline.receptors[i].note);
				strumline.length = mania;
			} else {
				strumline.length = mania;
				// Fresh receptors are minted bare (scale 1, clip-lookup mania 4,
				// parked at the base position) - dress them up so they match the
				// rest of the strumline, then put them into the buffer.
				for (i in oldMania...mania) {
					var note = strumline.receptors[i].note;
					note.scale = strumline.scale;
					note.mania_for_clipruntimehelper = mania;
					setF(note, "x", arrowLayoutX(strumline, i));
					setF(note, "y", arrowLayoutY(strumline));
					note.reset();
					NoteSystem.notesBuf.addElement(note);
				}
			}

			playField.noteSystem.rebuildMovementLUTs();
			try
				NoteSystem.notesBuf.update()
			catch (e:Dynamic) {}

			return FunkinViewLua.Function_Continue;
		});

		vm.addCallback('getStrumlineMania', function(id:Int) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return 0;
			return strumline.length;
		});

		vm.addCallback('getAbsoluteMania', function() {
			return Chart.header.mania;
		});

		vm.addCallback('getStrumlineCount', function() {
			var ns = playField.noteSystem;
			if (ns == null || ns.strumlines == null)
				return 0;
			return ns.strumlines.length;
		});

		// =============================================================
		// Position (floats: sub-pixel precise with INTEGRATION.md Patch 7,
		// truncated to whole pixels on a stock engine)
		// =============================================================
		vm.addCallback('setStrumlinePos', function(id:Int, x:Float, y:Float) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return FunkinViewLua.Function_Stop;

			setF(strumline, "x", x);
			setF(strumline, "y", y);

			// Lua-added strumlines: remember the position so engine resets
			// (seeks / pauses / downscroll toggles) can't fling it off-screen.
			if (customStrumlineX[id] == -9999 || customStrumlineY[id] == -999) {
				customStrumlineX[id] = x;
				customStrumlineY[id] = y;
			}

			playField.noteSystem.rebuildMovementLUTs();
			return FunkinViewLua.Function_Continue;
		});

		vm.addCallback('getStrumlinePosX', function(id:Int) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return 0.0;
			return getF(strumline, "x");
		});

		vm.addCallback('getStrumlinePosY', function(id:Int) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return 0.0;
			return getF(strumline, "y");
		});

		// =============================================================
		// Gap + Scale
		// =============================================================
		vm.addCallback('getStrumlineGap', function(id:Int) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return 0.0;
			return getF(strumline, "gap");
		});

		vm.addCallback('setStrumlineGap', function(id:Int, value:Float) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return FunkinViewLua.Function_Stop;

			setF(strumline, "gap", value);
			playField.noteSystem.rebuildMovementLUTs();
			return FunkinViewLua.Function_Continue;
		});

		vm.addCallback('getStrumlineScale', function(id:Int) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return 0.0;
			return strumline.scale;
		});

		vm.addCallback('setStrumlineScale', function(id:Int, value:Float) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return FunkinViewLua.Function_Stop;

			strumline.scale = value;
			return FunkinViewLua.Function_Continue;
		});

		// =============================================================
		// Per-arrow offsets (relative to the arrow's layout slot)
		//
		// The layout position of arrow `index` is
		//     x: strumline.x + gap * index + offsetX
		//     y: strumline.y + offsetY
		// Offsets are transient deltas on top of that: anything that
		// re-layouts the strumline (moving/rescaling it, gap changes, noteskin
		// swaps, engine resets) clears them - scripts that animate arrows just
		// re-apply them every frame, which is exactly what the setters are for.
		// =============================================================
		vm.addCallback('getStrumlineArrowOffsetX', function(id:Int, index:Int) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return 0.0;
			var note = resolveArrowNote(strumline, index);
			if (note == null)
				return 0.0;
			return getF(note, "x") - arrowLayoutX(strumline, index);
		});

		vm.addCallback('getStrumlineArrowOffsetY', function(id:Int, index:Int) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return 0.0;
			var note = resolveArrowNote(strumline, index);
			if (note == null)
				return 0.0;
			return getF(note, "y") - arrowLayoutY(strumline);
		});

		vm.addCallback('setStrumlineArrowOffset', function(id:Int, index:Int, x:Float, y:Float) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return FunkinViewLua.Function_Stop;
			var note = resolveArrowNote(strumline, index);
			if (note == null)
				return FunkinViewLua.Function_Stop;

			setF(note, "x", arrowLayoutX(strumline, index) + x);
			setF(note, "y", arrowLayoutY(strumline) + y);
			return FunkinViewLua.Function_Continue;
		});

		vm.addCallback('setStrumlineArrowOffsetX', function(id:Int, index:Int, x:Float) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return FunkinViewLua.Function_Stop;
			var note = resolveArrowNote(strumline, index);
			if (note == null)
				return FunkinViewLua.Function_Stop;

			setF(note, "x", arrowLayoutX(strumline, index) + x);
			return FunkinViewLua.Function_Continue;
		});

		vm.addCallback('setStrumlineArrowOffsetY', function(id:Int, index:Int, y:Float) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return FunkinViewLua.Function_Stop;
			var note = resolveArrowNote(strumline, index);
			if (note == null)
				return FunkinViewLua.Function_Stop;

			setF(note, "y", arrowLayoutY(strumline) + y);
			return FunkinViewLua.Function_Continue;
		});

		vm.addCallback('resetStrumlineArrowOffsets', function(id:Int) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return FunkinViewLua.Function_Stop;

			for (i in 0...strumline.length) {
				var note = resolveArrowNote(strumline, i);
				if (note == null)
					continue;
				setF(note, "x", arrowLayoutX(strumline, i));
				setF(note, "y", arrowLayoutY(strumline));
			}
			return FunkinViewLua.Function_Continue;
		});

		// Local rotation of an individual arrow, in degrees. This rotates the
		// receptor sprite itself (on top of whatever the noteskin baked in).
		vm.addCallback('getStrumlineArrowOffsetRot', function(id:Int, index:Int) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return 0.0;
			var note = resolveArrowNote(strumline, index);
			if (note == null)
				return 0.0;
			return note.r;
		});

		vm.addCallback('setStrumlineArrowOffsetRot', function(id:Int, index:Int, value:Float) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return FunkinViewLua.Function_Stop;
			var note = resolveArrowNote(strumline, index);
			if (note == null)
				return FunkinViewLua.Function_Stop;

			note.r = value;
			return FunkinViewLua.Function_Continue;
		});

		// Routing: every note of `type` is drawn/judged on strumline `id`.
		// Pass id = -1 to reset a type back to engine default routing
		// (type % strumline count).
		//
		// Identity mappings (type 2 -> strumline 2) work out of the box
		// because the engine's default routing is `type % strumlineCount`:
		// once addStrumline(2) bumps the count to 3, type 2 % 3 = 2 lands on
		// the new lane all by itself.
		//
		// ARBITRARY mappings (e.g. type 5 -> strumline 2) additionally need
		// the one-line routing swaps from INTEGRATION.md, which all funnel
		// into laneForType() above. The assignment is stored either way, so
		// scripts can be written against the final API today.
		vm.addCallback('assignNoteTypeToStrumline', function(type:Int, id:Int) {
			if (type < 0 || type >= 256) {
				FunkinViewLua.error('Notetype ID out of range! $type >= 256 or $type < 0');
				return FunkinViewLua.Function_Stop;
			}
			var ns = playField.noteSystem;
			if (ns == null) {
				FunkinViewLua.error("Can't do that - the note system isn't ready yet. Call this from createPost, not create.");
				return FunkinViewLua.Function_Stop;
			}
			if (id != -1 && (id < 0 || id >= ns.strumlines.length)) {
				FunkinViewLua.error('Can\'t do that - Strumline $id is null (there are ${ns.strumlines.length} strumlines). Use -1 to reset a type to default routing.');
				return FunkinViewLua.Function_Stop;
			}

			typeToStrumline[type] = id;
			return FunkinViewLua.Function_Continue;
		});

		// =============================================================
		// Pause survival, zero-engine-patch edition.
		//
		// PlayField.pause() calls NoteSystem.resetStrumlines(), which
		// re-slots every strumline by the vanilla formula
		// (x = 50 + INITIAL_WIDTH * id * 0.5) - strumline 2 lands ~1330px
		// out, off-screen. PlayField.update() would put it back via
		// updateVariablesList, but it early-returns while paused, so the
		// strumline stays gone for the whole pause (render() still runs,
		// which is why it's "invisible" rather than "frozen").
		//
		// The engine dispatches 'pausePost' to the script VMs right after
		// resetStrumlines - so if THIS script doesn't define its own
		// pausePost, register one that re-asserts the scripted positions.
		// Scripts that DO define pausePost keep full control (they can
		// re-assert themselves - see third_strumline_demo.lua).
		// INTEGRATION.md Patch 6 is the engine-side equivalent for every
		// script, patched or not.
		// =============================================================
		Lua.getglobal(vm.vm, 'pausePost');
		var scriptOwnsPausePost = (Lua.type(vm.vm, -1) == Lua.LUA_TFUNCTION);
		Lua.pop(vm.vm, 1);
		if (!scriptOwnsPausePost) {
			vm.addCallback('pausePost', function() {
				reassertCustomPositions(true);
				return FunkinViewLua.Function_Continue;
			});
		}
	}

	// ------------------------------------------------------------------
	// Helpers
	// ------------------------------------------------------------------
	function resolveStrumline(id:Int):Strumline {
		var ns = playField.noteSystem;
		if (ns == null || ns.strumlines == null) {
			FunkinViewLua.error("Can't do that - the note system isn't ready yet. Call this from createPost, not create.");
			return null;
		}
		if (id < 0 || id >= ns.strumlines.length) {
			FunkinViewLua.error('Can\'t do that - Strumline $id is null (there are ${ns.strumlines.length} strumlines).');
			return null;
		}
		var strumline = ns.strumlines[id];
		if (strumline == null) {
			FunkinViewLua.error('Can\'t do that - Strumline $id is null.');
			return null;
		}
		return strumline;
	}

	function resolveArrowNote(strumline:Strumline, index:Int):Note {
		if (index < 0 || index >= strumline.length) {
			FunkinViewLua.error('Can\'t do that - arrow index $index is out of range for a strumline with ${strumline.length} arrows.');
			return null;
		}
		var receptor = strumline.receptors[index];
		if (receptor == null || receptor.note == null) {
			FunkinViewLua.error('Can\'t do that - arrow $index is null on this strumline.');
			return null;
		}
		return receptor.note;
	}

	// Where the strumline layout would put arrow `index` (mirrors Strumline.set_x
	// for both engine flavours: exact once Patch 7 drops its Math.floor,
	// identical for integer values on a stock engine).
	inline function arrowLayoutX(strumline:Strumline, index:Int):Float {
		return getF(strumline, "x") + getF(strumline, "gap") * index + strumline.offsetX;
	}

	// Mirrors Strumline.set_y.
	inline function arrowLayoutY(strumline:Strumline):Float {
		return getF(strumline, "y") + strumline.offsetY;
	}

	// ------------------------------------------------------------------
	// Position re-assertion (engine resets: seeks, pauses, downscroll)
	// ------------------------------------------------------------------
	function reassertCustomPositions(rebuildLUTs:Bool):Void {
		if (customStrumlineX == null || customStrumlineY == null)
			return;
		var ns = playField.noteSystem;
		if (ns == null || ns.strumlines == null)
			return;

		var moved = false;
		for (id in 0...customStrumlineX.length) {
			if (id < 0 || id >= ns.strumlines.length)
				continue;
			var strumline = ns.strumlines[id];
			if (strumline == null)
				continue;
			var wantX = customStrumlineX[id];
			var wantY = customStrumlineY[id];
			if (wantX != -9999 && getF(strumline, "x") != wantX) {
				setF(strumline, "x", wantX);
				moved = true;
			}
			if (wantY != -9999 && getF(strumline, "y") != wantY) {
				setF(strumline, "y", wantY);
				moved = true;
			}
		}

		// Receptor positions get baked into movement LUTs when a custom
		// note formula is active - refresh them so mid-air notes aim at
		// the re-asserted position instead of where the reset flung it.
		if (moved && rebuildLUTs)
			ns.rebuildMovementLUTs();
	}

	// ------------------------------------------------------------------
	// Per-frame upkeep
	// ------------------------------------------------------------------
	override public function updateVariablesList(vm:FunkinViewLuaScript):Void {
		// Engine resets (seeks, downscroll toggles) reposition every strumline
		// by the vanilla slot formula, which shoves anything past strumline 1
		// off-screen. Re-assert the positions scripts asked for. (During a
		// pause this never runs - PlayField.update() early-returns - which is
		// exactly why the pausePost guard above / Patch 6 exist.)
		reassertCustomPositions(true);
	}

	override public function dispose():Void {
		if (customStrumlineX != null) {
			while (customStrumlineX.length != 0) customStrumlineX.pop();
			customStrumlineX = null;
		}
		if (customStrumlineY != null) {
			while (customStrumlineY.length != 0) customStrumlineY.pop();
			customStrumlineY = null;
		}
		for (i in 0...1 << 8)
			typeToStrumline[i] = -1;
		for (i in 0...1 << 8) {
			customStrumlineX[i] = -9999;
			customStrumlineY[i] = -9999;
		}
		super.dispose();
	}
	#end
}
