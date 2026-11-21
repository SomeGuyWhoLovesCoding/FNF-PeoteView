package gameplay;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.app.Application;
import underlying.miniaudio.MiniAudio;

/**
	The playfield editor — the MINIMAL one.

	Owns only: the editor keybinds, the stepped-strumline mouse input
	(StrumlineNoteInteraction), seek/snap math, chart saving, and the
	playback toggle. Everything else the editor uses (HUD, note system,
	song system, pause menu) is built by PlayField.create()'s editor
	branch and lives on the PlayField itself, exactly like gameplay.

	=== The editor's song position: owned, frozen, silent ===

	`PlayField.songPosition` in editor mode starts FROZEN at 0 — no clock
	advances it (Mixer.update's editorFrozen branch skips the fake-clock
	delta; see Mixer.hx). It moves ONLY on explicit editor seeks (wheel,
	LEFT/RIGHT). ENTER toggles audible playback through the same
	onStartSong event the gameplay countdown path dispatches; while
	playing, the real audio clock drives the position, and stopping
	re-freezes it at where the transport actually is.

	=== Snap grid ===

	(60000 / Main.conductor.bpm / 4) * snapMultiplier ms — one 16th note
	at the current BPM times x, in the ms unit every chart time uses
	(matches the conductor's stepCrochet = 15000 / bpm).

	@since Development
**/
@:publicFields
class PlayFieldEditorMode {
	/** Owning playfield (never null after construction). */
	var field:PlayField;

	/**
		Snap resolution multiplier x — 1 is a 16th-note grid, 2 an 8th,
		4 a quarter, 0.5 a 32nd... The base recomputes from the
		conductor's current BPM, so BPM changes keep the grid locked to
		the beat.
	*/
	var snapMultiplier:Float = 1.0;

	/** The live snap step in MILLISECONDS (see class doc). */
	var snapMs(get, never):Float;

	inline function get_snapMs():Float {
		var bpm = Main.conductor != null ? Main.conductor.bpm : 100.0;
		if (bpm <= 0)
			bpm = 100.0;
		// 60000ms per minute / bpm beats / 4 sixteenths per beat — the
		// same unit the conductor's stepCrochet uses (15000 / bpm).
		return (60000 / bpm / 4) * snapMultiplier;
	}

	/**
		The notetype number the editor places (ALT+LEFT/RIGHT cycles it).
		Gameplay routes notetypes to strumlines through
		NoteSystem.noteTypeToStrumline (default table: 0 → opponent
		strumline, everything else → player strumline).
	*/
	var notetype:Int = 1;

	/** The dedicated stepped-strumline mouse input system. */
	var strumlineInput:StrumlineNoteInteraction;

	/** The exit-confirmation popup (ESC/back): editor/menu/titlescreen. */
	var exitPopup:EditorExitPopup;

	/**
		The input-instructions popup (F1 / triple-click). The old watermark
		("FV v...") did nothing useful in editor mode — it now points here
		instead: "Press F1 or triple click/tap for editor's input
		instructions".
	**/
	var instructionsPopup:EditorInstructionsPopup;

	/** True when ANY modal popup (exit / instructions) is open. */
	function anyPopupOpen():Bool {
		return (exitPopup != null && exitPopup.opened) || (instructionsPopup != null && instructionsPopup.opened);
	}

	/** True when the chart has unsaved edits. */
	var dirtyChart:Bool = false;

	/** True while the song transport is running (audible). */
	var playing:Bool = false;

	// -------------------------------------------------------------------
	// Smooth scroll (wheel/arrow seeks while SILENT) — render-side lerp
	// -------------------------------------------------------------------

	/**
		The position the note system actually renders at while silent:
		a FAST lerp toward `field.songPosition` (the exact seek target).
		`songPosition` itself stays exact — everything that consumes it
		(the readout, seek math, note adds) keeps snapping to the grid —
		while the VISIBLE chart glides to it. One wheel notch is a tiny
		nudge (feels smooth); a Ctrl+wheel jump or an arrow-key seek
		glides for a few frames instead of teleporting. On the first
		frame after a seek the distance is snap-committed when it is
		below SNAP_MS so micro-seeks don't wobble.
	**/
	var smoothPosition:Float = 0;

	/** Fast-lerp ratio per frame (at 60fps ≈ 0.55 → ~95% in 4 frames). */
	static inline var SMOOTH_RATIO:Float = 0.55;

	/**
		Remaining render distance below which the lerp snaps to the
		target — stops sub-pixel wobble on micro-seeks.
	**/
	static inline var SMOOTH_SNAP_MS:Float = 4.0;

	// -------------------------------------------------------------------
	// Playback rate (ALT+[ / ALT+])
	// -------------------------------------------------------------------

	/** Current editor playback rate (ALT+[ / ALT+] cycles it). */
	var playbackRate:Float = 1.0;

	/** The rate ladder the editor cycles through, FNF-style. */
	static var RATES:Array<Float> = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

	// -------------------------------------------------------------------
	// Keybind placement mode (F2)
	// -------------------------------------------------------------------

	/**
		When true, the PLAYER keybinds place notes at the playhead
		(ALT+LEFT/RIGHT still cycle the notetype while paused — and retype
		the held note, see StrumlineNoteInteraction.retypeHeldNote). Lets
		you chart with the keyboard alone, Arrow-Vortex style.
	**/
	var keybindPlaceMode:Bool = false;

	var keysActive:Bool = false;

	function new(field:PlayField) {
		this.field = field;
	}

	// -------------------------------------------------------------------
	// Construction
	// -------------------------------------------------------------------

	/**
		Called from PlayField.create()'s editor branch AFTER the shared
		subsystems (HUD, note system, Mixer, pause screen) were built.
		On success songStarted is still false and songPosition stays
		frozen at 0 — completely silent and still.
	**/
	function build() {
		field.songPosition = 0;
		smoothPosition = 0;
		playbackRate = 1.0;
		Mixer.speed = 1.0;

		// The HUD must be visible the instant the editor appears — the
		// gameplay fade-in (alphaLerp toward 1 on songStarted) would
		// otherwise keep it invisible until ENTER starts playback.
		if (field.hud != null) {
			field.hud.alphaLerp = 1;
			field.hud.setHUDAlpha(1);
			field.hud.render();
			field.hud.update(Math.POSITIVE_INFINITY);
			field.hud.updateBuffers();
		}

		// Both strumlines non-playable: no keybind input path exists, and
		// with the pure-render editor note path nothing ever hits a note —
		// receptors stay static and sustains never resolve.
		for (strumline in field.noteSystem.strumlines)
			strumline.playable = false;

		strumlineInput = new StrumlineNoteInteraction(field);
		strumlineInput.chartPath = field.chartPathForEditor();
		strumlineInput.attach();
		attachKeys();
		exitPopup = new EditorExitPopup(this);
		instructionsPopup = new EditorInstructionsPopup(this);
	}

	// -------------------------------------------------------------------
	// Key handling
	// -------------------------------------------------------------------

	function attachKeys() {
		if (field.disposed || keysActive)
			return;
		keysActive = true;
		#if !android
		Application.current.window.onKeyDown.add(keyDown);
		#end
	}

	function detachKeys() {
		if (!keysActive)
			return;
		keysActive = false;
		#if !android
		Application.current.window.onKeyDown.remove(keyDown);
		#end
	}

	function keyDown(code:KeyCode, mod:KeyModifier) {
		if (field.disposed)
			return;

		// While a modal popup is open it owns every key (the exit popup
		// navigates/accepts, the instructions card swallows everything
		// and closes on F1 / ESC / accept). Checked first — no editor
		// action may fire underneath a popup.
		if (exitPopup != null && exitPopup.opened) {
			exitPopup.handleKey(code, mod);
			return;
		}
		if (instructionsPopup != null && instructionsPopup.opened) {
			instructionsPopup.handleKey(code, mod);
			return;
		}

		// F1 (checked before everything else): open the instructions
		// card. The watermark at the bottom of the editor points here.
		if (code == KeyCode.F1) {
			if (instructionsPopup != null)
				instructionsPopup.open();
			return;
		}

		// ESC/back opens the exit popup (exit editor mode / back to
		// menu / back to titlescreen).
		if (code == SaveData.state.controls.ui.back || code == KeyCode.ESCAPE) {
			if (exitPopup != null) {
				exitPopup.open();
				return;
			}
			// No popup available (shouldn't happen): fall back to the
			// bare pause toggle.
			if (field.paused)
				field.resume();
			else
				field.pause(false);
			return;
		}

		// The game's pause keybind (default ENTER) toggles playback:
		// first press starts the song through the same onStartSong event
		// the countdown path dispatches; second press stops the transport
		// back to the silent frozen clock.
		if (code == SaveData.state.controls.game.pause) {
			togglePlayback();
			return;
		}

		if (field.paused)
			return;

		// F2 toggles keybind placement: the player keybinds place notes
		// at the playhead on whichever lane they map to. (Was F1 — F1 is
		// the instructions card now. Checked BEFORE the ALT branch so
		// ALT+F2 can never be eaten by it, and before the keybind-place
		// dispatch so the toggle key itself never places a note.)
		if (code == KeyCode.F2) {
			keybindPlaceMode = !keybindPlaceMode;
			Main.current.playScrollSound();
			return;
		}

		// Keybind placement mode: every player keybind press places (or
		// removes, when ALT is held) a note at the playhead on that
		// keybind's lane. Runs even while the ALT modifier is held —
		// ALT+keybind is the remove gesture.
		if (keybindPlaceMode) {
			var lane = laneForBind(code);
			if (lane >= 0) {
				placeAtPlayhead(lane, (mod & KeyModifier.ALT) != 0);
				return;
			}
			// Non-player keys still fall through to the binds below
			// (seek, snap, notetype) — only the PLAYER keys are captured.
		}

		// ALT+LEFT / ALT+RIGHT cycle the notetype number the editor
		// places (wrapped through 0..255, the chart's 8-bit type field).
		// Works paused or not — in keybind-place mode this is how you
		// re-color the pen without the mouse. While a note is HELD
		// (mouse hold-edit or the duration state), the same keys also
		// RETYPE that held note — the type is coerced to the note's own
		// strumline (the routing table decides the side, a mismatched
		// type would jump strumlines) — and the pen follows, so the next
		// placement uses the type you just dialed in.
		if ((mod & KeyModifier.ALT) != 0) {
			switch (code) {
				case KeyCode.LEFT:
					notetype = notetype <= 0 ? 255 : notetype - 1;
					if (strumlineInput != null)
						notetype = strumlineInput.retypeHeldNote(notetype);
					updateReadout();
				case KeyCode.RIGHT:
					notetype = notetype >= 255 ? 0 : notetype + 1;
					if (strumlineInput != null)
						notetype = strumlineInput.retypeHeldNote(notetype);
					updateReadout();
				case KeyCode.LEFT_BRACKET:
					cyclePlaybackRate(-1);
				case KeyCode.RIGHT_BRACKET:
					cyclePlaybackRate(1);
				default:
					// With ALT held the user asked for the notetype
					// action; eat the key.
					return;
			}
			return;
		}

		switch (code) {
			case KeyCode.LEFT:
				seekTo(field.songPosition - ((mod & KeyModifier.CTRL) != 0 ? 4000 : 1000));
			case KeyCode.RIGHT:
				seekTo(field.songPosition + ((mod & KeyModifier.CTRL) != 0 ? 4000 : 1000));
			case KeyCode.UP:
				// UI up/down lengthen/shorten the hold note being edited
				// (the duration-change state) by one snap step.
				if (strumlineInput != null)
					strumlineInput.nudgeHoldDuration(1);
			case KeyCode.DOWN:
				if (strumlineInput != null)
					strumlineInput.nudgeHoldDuration(-1);
			case KeyCode.MINUS:
				// Halve the snap multiplier (finer grid), floored at 1/32nds.
				snapMultiplier = Math.max(snapMultiplier / 2, 0.03125);
			case KeyCode.EQUALS:
				// Double the snap multiplier (coarser grid), capped at 16 beats.
				snapMultiplier = Math.min(snapMultiplier * 2, 64);
			case KeyCode.S:
				if ((mod & KeyModifier.CTRL) != 0)
					saveChartToDisk();
			default:
		}
	}

	// -------------------------------------------------------------------
	// Keybind placement (F2 mode)
	// -------------------------------------------------------------------

	/**
		The player-strumline lane a KeyCode maps to under the CURRENT
		mania's keybind set (keybindArray[mania-1]), or -1. The editor
		reads the same keybinds gameplay's InputSystem does — both
		keybinds and keybindsTwo alternates match.
	**/
	function laneForBind(code:KeyCode):Int {
		var keybindArray = SaveData.state.controls.game.keybindArray;
		var mania = Chart.header.mania;
		if (keybindArray == null || mania < 1 || mania > keybindArray.length)
			return -1;
		var bind = keybindArray[mania - 1];
		if (bind == null)
			return -1;
		for (i in 0...bind.length) {
			var keybind = bind[i];
			if (keybind == null || keybind.length == 0)
				continue;
			if (code == keybind[0] || (keybind.length > 1 && code == keybind[1]))
				return i;
		}
		return -1;
	}

	/**
		Place (or with `remove`, delete) a note at the CURRENT playhead
		time on the PLAYER strumline (the editor's default notetype 1
		routes to the player strumline through the routing table).
		Snapped to the grid, and the type used is the editor's selected
		notetype — ALT+LEFT/RIGHT re-colors this pen live.
	**/
	function placeAtPlayhead(lane:Int, remove:Bool) {
		if (strumlineInput == null)
			return;

		var timeMs = strumlineInput.snapTime(field.songPosition);
		var noteSystem = field.noteSystem;
		if (noteSystem == null || lane >= noteSystem.strumlines[1].length)
			return;

		if (remove) {
			var id = strumlineInput.findNoteAt(lane, 1, timeMs);
			if (id >= 0) {
				File.removeNote(id);
				Main.current.playScrollSound();
				onChartEdited();
			}
			return;
		}

		if (strumlineInput.findNoteAt(lane, 1, timeMs) < 0) {
			var id = File.addNote(MetaNote.floatToMetaNotePosition(timeMs), 0, lane, notetype);
			if (id >= 0) {
				Main.current.playScrollSound();
				onChartEdited();
			}
		}
	}

	/**
		Steps the playback rate one rung down (-1) or up (+1) the RATES
		ladder and applies it through Mixer.speed — the same setter the
		gameplay speed options use, so the pitch-preservation preference
		is respected. Also updates the readout immediately.
	**/
	function cyclePlaybackRate(dir:Int) {
		var idx = 0;
		for (i in 0...RATES.length) {
			if (Math.abs(RATES[i] - playbackRate) < 0.001) {
				idx = i;
				break;
			}
		}
		idx += dir;
		if (idx < 0)
			idx = 0;
		if (idx >= RATES.length)
			idx = RATES.length - 1;
		playbackRate = RATES[idx];
		Mixer.speed = playbackRate;
		updateReadout();
	}

	// -------------------------------------------------------------------
	// Playback toggle (pause keybind)
	// -------------------------------------------------------------------

	/**
		Starts/stops audible playback. Starting goes through
		field.onStartSong.dispatch — the exact countdown-path event — so
		the transport starts the same way gameplay does (startSong is its
		only listener: it spins the mixer, hooks conductor events, sets
		songStarted). While playing, the REAL audio clock drives the
		editor-owned position (Mixer.updateWithAudioTime). Stopping
		mirrors stopSong/gameOver: detach the conductor listeners (lime's
		Event.add does NOT dedupe, so a start cycle must not stack
		duplicates), stop the transport (PCM position preserved) and drop
		songStarted, which re-freezes the position where it stopped.

		The audio clock is read DIRECTLY through MiniAudio.getPlaybackPosition()
		(never through a Mixer wrapper — a same-named static there resolved
		to itself on cpp and produced C4717 infinite recursion).
	**/
	function togglePlayback() {
		if (field.disposed || field.paused || field.songEnded)
			return;

		if (playing) {
			var conductor = Main.conductor;
			conductor.onMeasure.remove(field.measureHit);
			conductor.onStep.remove(field.stepHit);
			conductor.onBeat.remove(field.beatHit);

			// Freeze at where the transport ACTUALLY is, not where the
			// audio clock last read: a stopped device still reports its
			// buffered-ahead position, which would resume the next ENTER
			// ahead of what was heard.
			field.songPosition = MiniAudio.getPlaybackPosition();
			Mixer.stopMusic();
			field.songStarted = false;
			playing = false;
			// The smooth-scroll render position restarts from exactly
			// where playback stopped — no glide after a stop.
			smoothPosition = field.songPosition;

			// The spawner window was built against the moving position; a
			// stop is a position change for rendering purposes — rebuild
			// it so the frozen frame shows the correct note set.
			if (field.noteSystem != null) {
				var pos = MetaNote.floatToMetaNotePosition(field.songPosition);
				field.noteSystem.onSongPositionJump(pos);
			}
		} else {
			// Align the mixer's PCM position with the editor's (frozen)
			// position BEFORE the transport spins up. The countdown path
			// gets this for free (audio starts at 0 exactly when the fake
			// clock crosses 0); here the position has been frozen wherever
			// the last seek left it, so without this seek the audio would
			// resume behind the notes.
			var target = field.songPosition;
			if (target < 0)
				target = 0;
			if (target > Mixer.length - 1000)
				target = Mixer.length - 1000;
			Mixer.setTime(Math.max(target, 0.0), field);
			field.songPosition = Math.max(target, 0.0);

			// Resuming hands the position to the audible transport — any
			// pan fling still gliding would keep seeking UNDER the audio
			// clock (the chart fights the song for ~a second). Kill it.
			if (strumlineInput != null)
				strumlineInput.cancelPanFling();

			field.onStartSong.dispatch(Chart.header);
			playing = true;

			// Re-align the editor position with the REAL audio clock right
			// after the transport spins up — the editor clock begins
			// exactly where the transport actually is, instead of holding
			// the pre-start seek target and jumping ahead the moment
			// playback becomes audible.
			field.songPosition = MiniAudio.getPlaybackPosition();
		}
	}

	// -------------------------------------------------------------------
	// Seek / chart editing
	// -------------------------------------------------------------------

	/**
		Editor seek — the ONE position mover in the editor.

		Works identically on both clocks (frozen silent or ENTER playback)
		and NEVER restarts the song: the base PlayField.setTime treats a
		backwards seek as a full song restart (pause + switchState +
		recreate) because judged/missed gameplay state cannot be un-judged;
		the editor has no such state (its render path is pure, nothing is
		ever judged or hit), so backwards seeking is just a window
		rebuild.

		Instead: Mixer.setTime seeks the PCM transport directly (safe
		while stopped AND while playing — the audio follows the seek), the
		editor-owned songPosition snaps to the target, and
		noteSystem.onSongPositionJump does the resetNoteRender-style
		teardown/redraw — every element of the note system is removed and
		redrawn at the new position (pool reset, spawn window rebuilt by
		binary search, strumline caches cleared). One frame, no restart.
	**/
	function seekTo(value:Float) {
		if (field.disposed || field.paused)
			return;
		if (value < 0)
			value = 0;
		if (value > Mixer.length - 1000)
			value = Mixer.length - 1000;

		if (playing) {
			// Audible playback: the transport must follow the new position.
			// One seek + one window reset per wheel burst is fine here —
			// the playhead is moving anyway, and the reset also re-aligns
			// the predict clock after the decoder re-prime.
			Mixer.setTime(Math.max(value, 0.0), field);
			field.songPosition = value;
			if (field.noteSystem != null) {
				var pos = MetaNote.floatToMetaNotePosition(value);
				field.noteSystem.onSongPositionJump(pos);
			}
			return;
		}

		// Frozen (silent) editor: the position is editor-owned and NOTHING
		// is listening to the transport. Seeking the PCM decoder here was
		// a full stop/re-prime of the audio pipeline per wheel notch —
		// the scroll stall — for a seek whose result would be thrown away
		// on the next resume anyway. Instead: move ONLY the editor
		// position; the note window follows through the same per-frame
		// cullTop/cullBottom that move it during playback (no rebuild,
		// no strumline reset, no pool flush — notes simply slide in and
		// out of the window). The transport is re-synced exactly once,
		// at the next ENTER resume, from wherever the position froze.
		field.songPosition = value;
	}

	/**
		Called by StrumlineNoteInteraction after every successful
		add/remove/duration write. Rebuilds the note system's window at
		the current (frozen) position so the edit is visible the same
		frame: a structural edit shifts global indices AFTER the edit
		point (the sharded store re-sorts), which invalidates every
		cached window/index until the next rebuild.
	**/
	function onChartEdited() {
		dirtyChart = true;

		if (field.noteSystem != null) {
			var pos = MetaNote.floatToMetaNotePosition(field.songPosition);
			field.noteSystem.onSongPositionJump(pos);
		}
	}

	/**
		Persists the chart. NOTE: must not be named `saveChart` — the
		local method would shadow File.saveChart in the call below.
	**/
	function saveChartToDisk() {
		if (File.saveChart()) {
			dirtyChart = false;
			Main.current.playHitsound();
		}
	}

	// -------------------------------------------------------------------
	// Debug readout (score text)
	// -------------------------------------------------------------------

	/**
		Per-frame smooth-scroll advance (called from PlayField.update's
		editor branch BEFORE the note system consumes the position).
		While SILENT the render position fast-lerps toward the exact
		`songPosition`; while PLAYING it tracks exactly (the audio clock
		is already continuous) and re-syncs on stop. Returns the position
		the note system should render at this frame.
	**/
	function advanceSmoothScroll(deltaTime:Float):Float {
		if (playing) {
			smoothPosition = field.songPosition;
			return smoothPosition;
		}

		var target = field.songPosition;
		if (Math.abs(target - smoothPosition) <= SMOOTH_SNAP_MS) {
			smoothPosition = target;
			return smoothPosition;
		}

		// Frame-rate-normalized ratio: at 60fps this is SMOOTH_RATIO,
		// at 120fps half of it per frame — same glide per real second.
		var ratio = 1 - Math.pow(1 - SMOOTH_RATIO, Math.max(deltaTime, 0) / (1000 / 60));
		smoothPosition = Tools.lerp(smoothPosition, target, ratio);
		return smoothPosition;
	}

	/**
		Replaces the score text with the editor readout, called once per
		frame from PlayField.update's editor branch AFTER hud.update (so
		the HUD's own score/misses/accuracy write is always overwritten —
		the editor never touches score state, so that text is meaningless
		there anyway).

		Shows the RAW values, no rounding or unit conversion:
		  pos    — the editor-owned songPosition, exactly as the note
		           system consumes it (ms)
		  rate   — the current playback rate (x0.5 .. x2)
		  kbd    — ON when F2 keybind-placement is active
		  bot/top— the note spawner's live cull window as RAW global chart
		           indices (bottom = first note not yet despawned,
		           top = first note outside spawn range), read straight
		           off NoteSpawner.bottom/top after this frame's
		           noteSystem.update ran the cull loops.
	**/
	function updateReadout() {
		if (field.hud == null)
			return;

		var scoreTxt = HUD.scoreTxt;
		if (scoreTxt == null)
			return;

		// Raw values, straight off the live objects — no rounding, no
		// unit conversion. Int64 interpolates through Std.string, which
		// prints the full 64-bit decimal value. The notetype segment
		// shows BOTH the pen's type and, when hovering a strumline that
		// would coerce it (see StrumlineNoteInteraction.coercedType),
		// the coerced type it would actually place there — e.g.
		// "type: 2→0" for pen 2 over the opponent strumline.
		var rateStr = playbackRate == Math.floor(playbackRate) ? Std.string(Math.floor(playbackRate)) : Std.string(playbackRate);
		var typeStr = 'type: $notetype';
		if (strumlineInput != null && strumlineInput.hoverStrumline >= 0) {
			var c = strumlineInput.coercedType(strumlineInput.hoverStrumline);
			if (c != notetype)
				typeStr = 'type: $notetype->$c';
		}
		if (field.noteSystem != null && field.noteSystem.noteSpawner != null) {
			var spawner = field.noteSystem.noteSpawner;
			scoreTxt.text = 'pos: ${field.songPosition} | rate: x$rateStr | $typeStr | kbd: ${keybindPlaceMode ? "ON" : "OFF"}'
				+ ' | bottom: ${spawner.bottom} | top: ${spawner.top}';
		} else {
			scoreTxt.text = 'pos: ${field.songPosition} | rate: x$rateStr | $typeStr | kbd: ${keybindPlaceMode ? "ON" : "OFF"} | bottom: - | top: -';
		}

		// Re-center for the readout's own width (hud.update positioned the
		// text for the score string it wrote; ours is a different length).
		var healthBar = field.hud.healthBar;
		scoreTxt.x = healthBar.bg.x + ((healthBar.bg.w - scoreTxt.width) * 0.5);
	}

	// -------------------------------------------------------------------
	// Disposal
	// -------------------------------------------------------------------

	function dispose() {
		detachKeys();
		if (exitPopup != null) {
			exitPopup.dispose();
			exitPopup = null;
		}
		if (instructionsPopup != null) {
			instructionsPopup.dispose();
			instructionsPopup = null;
		}
		// Never leak a non-1x rate into gameplay or the menus — the
		// editor's rate is editor-only state.
		Mixer.speed = 1.0;
		if (strumlineInput != null) {
			strumlineInput.dispose();
			strumlineInput = null;
		}
	}
}
