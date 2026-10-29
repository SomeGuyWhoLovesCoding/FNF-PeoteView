package tooling.fvlua.components;

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
	The few bits the engine itself has to adopt (an optional note type routing
	lookup plus a spawner guard for reduced-mania sections) are documented as
	ready-to-paste snippets in INTEGRATION.md, centred around
	`CustomStrumlineComponent.laneForType()` below.

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
	// toggles) reposition strumlines by the vanilla slot formula, which flings
	// anything past strumline 1 off-screen - updateVariablesList puts Lua-added
	// strumlines back where the script asked for them.
	var customStrumlineX:Map<Int, Int> = new Map<Int, Int>();
	var customStrumlineY:Map<Int, Int> = new Map<Int, Int>();

	public function new(_parent:FunkinViewLua) {
		super(_parent);

		// Statics survive between songs - start each song with a clean table.
		for (i in 0...1 << 8)
			typeToStrumline[i] = -1;
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
					note.x = arrowLayoutX(strumline, i);
					note.y = arrowLayoutY(strumline);
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
		// Position
		// =============================================================
		vm.addCallback('setStrumlinePos', function(id:Int, x:Int, y:Int) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return FunkinViewLua.Function_Stop;

			strumline.x = x;
			strumline.y = y;

			// Lua-added strumlines: remember the position so engine resets
			// (seeks / downscroll toggles) can't fling it off-screen.
			if (customStrumlineX.exists(id)) {
				customStrumlineX.set(id, x);
				customStrumlineY.set(id, y);
			}

			playField.noteSystem.rebuildMovementLUTs();
			return FunkinViewLua.Function_Continue;
		});

		vm.addCallback('getStrumlinePosX', function(id:Int) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return 0;
			return strumline.x;
		});

		vm.addCallback('getStrumlinePosY', function(id:Int) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return 0;
			return strumline.y;
		});

		// =============================================================
		// Gap + Scale
		// =============================================================
		vm.addCallback('getStrumlineGap', function(id:Int) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return 0;
			return strumline.gap;
		});

		vm.addCallback('setStrumlineGap', function(id:Int, value:Int) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return FunkinViewLua.Function_Stop;

			strumline.gap = value;
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
		//     x: strumline.x + floor(gap * index) + offsetX
		//     y: strumline.y + offsetY
		// Offsets are transient deltas on top of that: anything that
		// re-layouts the strumline (moving/rescaling it, gap changes, noteskin
		// swaps, engine resets) clears them - scripts that animate arrows just
		// re-apply them every frame, which is exactly what the setters are for.
		// =============================================================
		vm.addCallback('getStrumlineArrowOffsetX', function(id:Int, index:Int) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return 0;
			var note = resolveArrowNote(strumline, index);
			if (note == null)
				return 0;
			return note.x - arrowLayoutX(strumline, index);
		});

		vm.addCallback('getStrumlineArrowOffsetY', function(id:Int, index:Int) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return 0;
			var note = resolveArrowNote(strumline, index);
			if (note == null)
				return 0;
			return note.y - arrowLayoutY(strumline);
		});

		vm.addCallback('setStrumlineArrowOffset', function(id:Int, index:Int, x:Int, y:Int) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return FunkinViewLua.Function_Stop;
			var note = resolveArrowNote(strumline, index);
			if (note == null)
				return FunkinViewLua.Function_Stop;

			note.x = arrowLayoutX(strumline, index) + x;
			note.y = arrowLayoutY(strumline) + y;
			return FunkinViewLua.Function_Continue;
		});

		vm.addCallback('setStrumlineArrowOffsetX', function(id:Int, index:Int, x:Int) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return FunkinViewLua.Function_Stop;
			var note = resolveArrowNote(strumline, index);
			if (note == null)
				return FunkinViewLua.Function_Stop;

			note.x = arrowLayoutX(strumline, index) + x;
			return FunkinViewLua.Function_Continue;
		});

		vm.addCallback('setStrumlineArrowOffsetY', function(id:Int, index:Int, y:Int) {
			var strumline = resolveStrumline(id);
			if (strumline == null)
				return FunkinViewLua.Function_Stop;
			var note = resolveArrowNote(strumline, index);
			if (note == null)
				return FunkinViewLua.Function_Stop;

			note.y = arrowLayoutY(strumline) + y;
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
				note.x = arrowLayoutX(strumline, i);
				note.y = arrowLayoutY(strumline);
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

		// =============================================================
		// Extra strumlines + note type routing
		// =============================================================
		vm.addCallback('addStrumline', function(id:Int, x:Int, y:Int, noteskinName:String = null) {
			var ns = playField.noteSystem;
			if (ns == null) {
				FunkinViewLua.error("Can't do that - the note system isn't ready yet. Call this from createPost, not create.");
				return FunkinViewLua.Function_Stop;
			}
			if (id != ns.strumlines.length) {
				FunkinViewLua.error('Can\'t do that - strumlines are append-only, the next free id is ${ns.strumlines.length}, got $id.');
				return FunkinViewLua.Function_Stop;
			}
			if (id >= 256) {
				FunkinViewLua.error("Can't do that - 256 strumlines is where the ride ends.");
				return FunkinViewLua.Function_Stop;
			}

			var handle:NoteskinHandle = null;
			if (noteskinName != null) {
				handle = NoteskinManager.get(noteskinName);
				if (handle == null) {
					FunkinViewLua.error('Can\'t do that - Noteskin Handle "$noteskinName" either not found or has invalid data.');
					return FunkinViewLua.Function_Stop;
				}
				// Keep note sprites of this type in the same skin as the arrows.
				NoteSystem.typeToHandle[id] = handle;
			}
			if (handle == null)
				handle = NoteSystem.typeToHandle[id];
			if (handle == null)
				handle = NoteskinManager.get("default");

			var absoluteMania = Chart.header.mania;

			// Same recipe the engine itself uses in NoteSystem.new(), except
			// playable stays false - extra strumlines auto-hit their notes
			// exactly like the opponent's lane does.
			var strumline = new Strumline(x, y, handle, 0, 0, absoluteMania, ns);
			strumline.playable = false;
			strumline.applyNoteskinProperties(handle, absoluteMania - 1);

			ns.strumlines.push(strumline);

			for (receptor in strumline.receptors)
				NoteSystem.notesBuf.addElement(receptor.note);

			// The virtual note buffer is sized by strumline count - regrow it
			// so notes routed to the new lane have a place to live.
			@:privateAccess
			ns.virtualNoteBuffer = new NoteVB(ns.strumlines.length, 1 << 8);

			ns.rebuildMovementLUTs();

			// Field camera defaults are indexed by lane - grow them so hits on
			// this lane don't read out of bounds (scripts can retune the values
			// later via setDefaultCameraPosition).
			var field = playField.field;
			if (field != null) {
				while (field.defaultCameraXpos.length <= id)
					field.defaultCameraXpos.push(0);
				while (field.defaultCameraYpos.length <= id)
					field.defaultCameraYpos.push(0);
			}

			// Remember the position so engine resets can't fling it off-screen.
			customStrumlineX.set(id, x);
			customStrumlineY.set(id, y);

			try
				NoteSystem.notesBuf.update()
			catch (e:Dynamic) {}

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

	// Where the strumline layout would put arrow `index` (mirrors Strumline.set_x).
	inline function arrowLayoutX(strumline:Strumline, index:Int):Int {
		return strumline.x + Math.floor(strumline.gap * index) + strumline.offsetX;
	}

	// Mirrors Strumline.set_y.
	inline function arrowLayoutY(strumline:Strumline):Int {
		return strumline.y + strumline.offsetY;
	}

	// ------------------------------------------------------------------
	// Per-frame upkeep
	// ------------------------------------------------------------------
	override public function updateVariablesList(vm:FunkinViewLuaScript):Void {
		// Engine resets (seeks, downscroll toggles) reposition every strumline
		// by the vanilla slot formula, which shoves anything past strumline 1
		// off-screen. Re-assert the positions scripts asked for.
		if (customStrumlineX == null || customStrumlineY == null)
			return;
		var ns = playField.noteSystem;
		if (ns == null || ns.strumlines == null)
			return;
		for (id in customStrumlineX.keys()) {
			if (id < 0 || id >= ns.strumlines.length)
				continue;
			var strumline = ns.strumlines[id];
			if (strumline == null)
				continue;
			var wantX = customStrumlineX.get(id);
			var wantY = customStrumlineY.get(id);
			if (wantX != null && strumline.x != wantX)
				strumline.x = wantX;
			if (wantY != null && strumline.y != wantY)
				strumline.y = wantY;
		}
	}

	override public function dispose():Void {
		if (customStrumlineX != null) {
			customStrumlineX.clear();
			customStrumlineX = null;
		}
		if (customStrumlineY != null) {
			customStrumlineY.clear();
			customStrumlineY = null;
		}
		for (i in 0...1 << 8)
			typeToStrumline[i] = -1;
		super.dispose();
	}
	#end
}
