package gameplay;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.app.Application;
import miniaudio.MiniAudio;

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
		Gameplay maps `type % strumlineCount` to the owning strumline
		(0 = opponent side, 1 = player side).
	*/
	var notetype:Int = 1;

	/** The dedicated stepped-strumline mouse input system. */
	var strumlineInput:StrumlineNoteInteraction;

	/** True when the chart has unsaved edits. */
	var dirtyChart:Bool = false;

	/** True while the song transport is running (audible). */
	var playing:Bool = false;

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
		strumlineInput.attach();
		attachKeys();
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

		// ESC/back toggles the editor's pause: the BARE pause(false) /
		// resume() freeze — no pause menu exists in the editor. Main
		// skips playfield update+render while paused (both modes), so the
		// last rendered frame simply stays on screen with nothing — not
		// the note system, not the mixer clock — moving.
		if (code == SaveData.state.controls.ui.back || code == KeyCode.ESCAPE) {
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

		// ALT+LEFT / ALT+RIGHT cycle the notetype number the editor
		// places (wrapped through 0..255, the chart's 8-bit type field).
		if ((mod & KeyModifier.ALT) != 0) {
			switch (code) {
				case KeyCode.LEFT:
					notetype = notetype <= 0 ? 255 : notetype - 1;
				case KeyCode.RIGHT:
					notetype = notetype >= 255 ? 0 : notetype + 1;
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
		Replaces the score text with the editor readout, called once per
		frame from PlayField.update's editor branch AFTER hud.update (so
		the HUD's own score/misses/accuracy write is always overwritten —
		the editor never touches score state, so that text is meaningless
		there anyway).

		Shows the RAW values, no rounding or unit conversion:
		  pos    — the editor-owned songPosition, exactly as the note
		           system consumes it (ms)
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
		// prints the full 64-bit decimal value.
		if (field.noteSystem != null && field.noteSystem.noteSpawner != null) {
			var spawner = field.noteSystem.noteSpawner;
			scoreTxt.text = 'pos: ${field.songPosition} | bottom: ${spawner.bottom} | top: ${spawner.top}';
		} else {
			scoreTxt.text = 'pos: ${field.songPosition} | bottom: - | top: -';
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
		if (strumlineInput != null) {
			strumlineInput.dispose();
			strumlineInput = null;
		}
	}
}
