package gameplay;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.app.Application;

/**
	The playfield editor, split out of PlayField.

	Owns every editor-only concern: construction of the editor subset
	(note system, HUD, song system, pause menu), the keyboard shortcuts,
	the instructions overlay, chart saving, and the stepped-strumline
	mouse input. PlayField delegates its editor-mode branches here.

	=== The editor's song position: owned, frozen, unmodified ===

	Editor mode has its OWN song position semantics: `PlayField.
	songPosition` while in the editor is editor-owned and starts out
	COMPLETELY UNMODIFIED — no clock of any kind adds deltaTime to it
	(Mixer.update's fake-clock branch, the one that drives the gameplay
	countdown, explicitly skips playfieldEditorMode fields). It moves
	ONLY through an explicit editor seek (wheel, LEFT/RIGHT, hold-drag
	edits never touch it either). Every editor consumer — note system
	update/render, HUD time bar, conductor time, strumline input math —
	reads this same editor-owned position, so there is one global owner
	of "where in the song the editor is" and nothing else moves it.

	=== Audio by default: SILENT, without touching volume ===

	- create() leaves songStarted false and songPosition at 0, frozen.
	  The mixer transport is NEVER started at entry, so there is nothing
	  to mute; the audio device never pulls song frames.
	- The pause keybind (controls.game.pause, default ENTER) dispatches
	  onStartSong — the same event the gameplay countdown path uses —
	  which starts real audio playback from the current (seek-aligned)
	  position. While playing, the real audio clock drives the position;
	  pressing it again stops the transport and re-freezes the position
	  (Mixer.stopMusic preserves the PCM position).

	No master-volume parking, no volume writes anywhere: what you hear
	outside the editor is untouched by entering it.

	=== Editor feature set ===

	- Notes NEVER hit in the editor: NoteSystem's editor render path
	  draws notes/sustains purely — no judgement, no receptor confirms,
	  no sustain resolve/complete. Sustains render whole.
	- ALT+LEFT / ALT+RIGHT cycle the notetype number placed by LMB
	  (type % strumlineCount picks the strumline; the visual column
	  follows).
	- Hold-edit: press LMB on an existing note and either roll the wheel
	  (± one snap step per notch) or drag along the lane to set the
	  sustain duration; the note keeps its position, the duration is
	  written live (remove + re-add with the new duration).
	- Snap grid: (60 / Main.conductor.bpm / 4) * x ms — BPM-reactive.

	@since Development
**/
@:publicFields
class PlayFieldEditorMode {
	/** Owning playfield (never null after construction). */
	var field:PlayField;

	/**
	 * Snap resolution multiplier x — the grid step is
	 * `(60 / Main.conductor.bpm / 4) * snapMultiplier` ms (one 16th at the
	 * current BPM times x). x = 1 is a 16th-note grid, 2 an 8th, 4 a
	 * quarter, 0.5 a 32nd... The base recomputes from the conductor's
	 * current BPM, so BPM changes (events, seek past a changeBpmAt) keep
	 * the grid locked to the beat.
	 */
	var snapMultiplier:Float = 1.0;

	/** The live snap step in ms: (60 / bpm / 4) * snapMultiplier. */
	var snapMs(get, never):Float;

	inline function get_snapMs():Float {
		var bpm = Main.conductor != null ? Main.conductor.bpm : 100.0;
		if (bpm <= 0)
			bpm = 100.0;
		return (60 / bpm / 4) * snapMultiplier;
	}

	/**
	 * The notetype number the editor places (ALT+LEFT/RIGHT cycles it).
	 * Gameplay maps `type % strumlineCount` to the owning strumline
	 * (0 = opponent side, 1 = player side), so odd types flip a note to
	 * the player's strumline — the visible column follows the value.
	 */
	var notetype:Int = 1;

	/** The dedicated stepped-strumline mouse input system. */
	var strumlineInput:StrumlineNoteInteraction;

	/** True when the chart has unsaved edits. */
	var dirtyChart:Bool = false;

	/** True while the song transport is running (audible). */
	var playing:Bool = false;

	// --- Instructions menu (NoteskinEditor-style popup) ---
	var instructionsText:render.text.Text;
	var instructionsBackground:RepeatSprite;
	var instructionsBuf:Buffer<RepeatSprite>;
	var instructionsProg:CustomProgram;
	var showInstructions:Bool = false;

	var keysActive:Bool = false;

	function new(field:PlayField) {
		this.field = field;
	}

	// -------------------------------------------------------------------
	// Construction
	// -------------------------------------------------------------------

	/**
		Builds the editor subset inside PlayField.create()'s editor branch:
		HUD, note system, song system, pause menu, then the stepped
		strumline input + this class's key handler. On success
		songStarted is still false and songPosition stays frozen at 0 —
		completely silent and completely still (see class doc).
	**/
	function build() {
		// Editor subset only: no Field (stage/characters/camera), no
		// FunkinViewLua, no EventSystem, no InputSystem, no
		// CountdownDisplay. The editor's position starts frozen at 0 —
		// audio never starts at entry and nothing advances the clock.
		field.songPosition = 0;

		// Receptors enter the STATIC NoteSystem.notesBuf mid-constructor;
		// if anything below throws, PlayField.noteSystem never gets
		// assigned and dispose() would skip it — leaving those receptors
		// as permanent strumline ghosts on screen. PlayField's create
		// wraps this call in try/catch → cleanupFailedCreate().
		HUD.init();
		if (!SaveData.state.preferences.hideHUD)
			field.hud = new HUD(field.display, field);
		// The HUD must be visible the instant the editor appears — the
		// gameplay fade-in (alphaLerp lerp toward 1 on songStarted) would
		// otherwise keep it invisible until ENTER starts playback. Jump
		// straight to full alpha, exactly what PlayField.resetHUD does.
		if (field.hud != null) {
			field.hud.alphaLerp = 1;
			field.hud.setHUDAlpha(1);
			field.hud.render();
			field.hud.update(Math.POSITIVE_INFINITY);
			field.hud.updateBuffers();
		}

		NoteSystem.init();
		field.noteSystem = new NoteSystem(field);

		Mixer.init(Chart.header); // the song system (transport NOT started)

		PauseScreen.init(field.roof);
		field.pauseScreen = new PauseScreen(Chart.header.difficulty);

		// Both strumlines non-playable: no keybind input path exists, and
		// with the pure-render editor note path nothing ever hits a note —
		// receptors stay static and sustains never resolve.
		for (strumline in field.noteSystem.strumlines)
			strumline.playable = false;

		field.scrollSpeed = Chart.header.speed;

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

		// ESC/back first — also closes the instructions popup.
		if (code == SaveData.state.controls.ui.back || code == KeyCode.ESCAPE) {
			if (showInstructions) {
				hideInstructions();
				return;
			}
			if (!field.paused)
				field.pause();
			return;
		}

		// The game's pause keybind (default ENTER) toggles playback:
		// first press starts the song through the same onStartSong event
		// the countdown path dispatches (startSong → Mixer.startMusic);
		// second press stops the transport back to the silent fake clock.
		if (code == SaveData.state.controls.game.pause) {
			togglePlayback();
			return;
		}

		if (field.paused)
			return;

		// ALT+LEFT / ALT+RIGHT cycle the notetype number the editor places
		// (wrapped through 0..255, the 8-bit type field of the chart note).
		if ((mod & KeyModifier.ALT) != 0) {
			switch (code) {
				case KeyCode.LEFT:
					notetype = notetype <= 0 ? 255 : notetype - 1;
					updateInstructionsText();
					return;
				case KeyCode.RIGHT:
					notetype = notetype >= 255 ? 0 : notetype + 1;
					updateInstructionsText();
					return;
				default:
					// fall through to plain LEFT/RIGHT? No — with ALT held the
					// user asked for the notetype action; eat the key.
					return;
			}
		}

		switch (code) {
			case KeyCode.F1 | KeyCode.H:
				if (showInstructions)
					hideInstructions();
				else
					showInstructionsMenu();
			case KeyCode.LEFT:
				seekTo(field.songPosition - ((mod & KeyModifier.CTRL) != 0 ? 4000 : 1000));
			case KeyCode.RIGHT:
				seekTo(field.songPosition + ((mod & KeyModifier.CTRL) != 0 ? 4000 : 1000));
			case KeyCode.MINUS:
				// Halve the snap multiplier (finer grid), floored at 1/32nd notes.
				snapMultiplier = Math.max(snapMultiplier / 2, 0.03125);
				updateInstructionsText();
			case KeyCode.EQUALS:
				// Double the snap multiplier (coarser grid), capped at 16 beats.
				snapMultiplier = Math.min(snapMultiplier * 2, 64);
				updateInstructionsText();
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
		field.onStartSong.dispatch — the exact countdown-path event —
		so the transport starts the same way gameplay does (startSong is
		its only listener: it spins the mixer, hooks conductor events,
		sets songStarted). While playing, the REAL audio clock drives the
		editor-owned position (Mixer.updateWithAudioTime). Stopping mirrors
		what stopSong/gameOver do: detach the conductor listeners (lime's
		Event.add does NOT dedupe, so a start cycle must not stack
		duplicates), stop the transport (PCM position preserved) and drop
		songStarted, which re-freezes the position where it stopped.
	**/
	function togglePlayback() {
		if (field.disposed || field.paused || field.songEnded)
			return;

		if (playing) {
			var conductor = Main.conductor;
			conductor.onMeasure.remove(field.measureHit);
			conductor.onStep.remove(field.stepHit);
			conductor.onBeat.remove(field.beatHit);

			Mixer.stopMusic();
			field.songStarted = false;
			playing = false;
		} else {
			// Align the mixer's PCM position with the editor's (frozen)
			// position BEFORE the transport spins up. The countdown path
			// gets this for free (audio starts at 0 exactly when the fake
			// clock crosses 0); here the position has been frozen wherever
			// the last seek left it (and a stop→restart cycle leaves the PCM
			// position wherever the transport was stopped), so without this
			// seek the audio would resume behind the notes.
			var target = field.songPosition;
			if (target < 0)
				target = 0;
			if (target > Mixer.length - 1000)
				target = Mixer.length - 1000;
			Mixer.setTime(Math.max(target, 0.0), field);
			field.songPosition = Math.max(target, 0.0);

			field.onStartSong.dispatch(Chart.header);
			playing = true;
		}
		updateInstructionsText();
	}

	// -------------------------------------------------------------------
	// Seek / chart editing
	// -------------------------------------------------------------------

	/**
		Editor seek — works on both clocks, bypassing the base setTime's
		countdown/latency gates (no restart dance; Mixer stop/start
		preserve position, seekToPCMFrame lands exactly).
	**/
	function seekTo(value:Float) {
		if (field.disposed || field.paused)
			return;
		if (value < 0)
			value = 0;
		if (value > Mixer.length - 1000)
			value = Mixer.length - 1000;

		Mixer.setTime(Math.max(value, 0.0), field);
		field.songPosition = value;

		var pos = MetaNote.floatToMetaNotePosition(value);
		if (field.noteSystem != null)
			field.noteSystem.onSongPositionJump(pos);
	}

	/** Called by StrumlineNoteInteraction after every successful add/remove. */
	function onChartEdited() {
		dirtyChart = true;
		updateInstructionsText();
	}

	/** Persists the chart. NOTE: must not be named `saveChart` — the
	 *  local method would shadow File.saveChart in the call below. */
	function saveChartToDisk() {
		if (File.saveChart()) {
			dirtyChart = false;
			updateInstructionsText();
			Main.current.playHitsound();
		}
	}

	// -------------------------------------------------------------------
	// Pause menu interplay (called from PlayField.pause/resume)
	// -------------------------------------------------------------------

	/** Called by PlayField.pause: unhook editor input while the menu is up. */
	function onPause() {
		if (strumlineInput != null)
			strumlineInput.removeEvents();
		detachKeys();
	}

	/** Called by PlayField.resume: rehook editor input. */
	function onResume() {
		if (strumlineInput != null)
			Tools.forSync(strumlineInput.addEvents);
		Tools.forSync(attachKeys);
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
		hideInstructions();
		if (instructionsText != null) {
			instructionsText.dispose();
			instructionsText = null;
		}
		if (instructionsBuf != null) {
			try
				instructionsBuf.clear()
			catch (e) {}
			instructionsBuf = null;
			instructionsProg = null;
			instructionsBackground = null;
		}
	}

	// -------------------------------------------------------------------
	// Instructions menu (NoteskinEditor-style popup)
	// -------------------------------------------------------------------

	function showInstructionsMenu() {
		showInstructions = true;
		ensureInstructionsAssets();
		if (instructionsProg != null && !instructionsProg.isIn(field.display))
			field.display.addProgram(instructionsProg);
		if (instructionsBuf != null && instructionsBackground != null) {
			instructionsBackground.c = 0x000000FF;
			instructionsBackground.c.aF = 0.6;
			instructionsBuf.addElement(instructionsBackground);
		}
		if (instructionsText != null) {
			instructionsText.addProgram();
			instructionsText.alpha = 1;
		}
		updateInstructionsText();
	}

	function hideInstructions() {
		if (!showInstructions)
			return;
		showInstructions = false;
		if (instructionsBuf != null && instructionsBackground != null) {
			try
				instructionsBuf.removeElement(instructionsBackground)
			catch (e) {}
		}
		if (instructionsText != null) {
			instructionsText.alpha = 0;
			instructionsText.removeProgram();
		}
	}

	function ensureInstructionsAssets() {
		if (instructionsText == null) {
			instructionsText = new Text("PLAYFIELD_EDITOR_INSTRUCTIONS", 0, 0, field.display, "", "vcr");
			instructionsText.scale = 0.7;
			instructionsText.alpha = 0;
			instructionsText.multiline = true;
			instructionsText.alignment = LEFT;
			instructionsText.spacerPercent = -0.1;
			instructionsText.outlineColor = Color.BLACK;
			instructionsText.outlineSize = 1;
		}
		if (instructionsBuf == null) {
			instructionsBuf = new Buffer<RepeatSprite>(2, 2, true);
			instructionsProg = new CustomProgram(instructionsBuf);
			instructionsBackground = new RepeatSprite(0, 0, 0, 0);
		}
	}

	function updateInstructionsText() {
		if (instructionsText == null)
			return;

		var saved = dirtyChart ? "UNSAVED" : "saved";
		var bpm = Main.conductor != null ? Main.conductor.bpm : 100.0;
		instructionsText.text = "=== PLAYFIELD EDITOR ===\n"
			+ "Position is FROZEN until you seek — nothing advances it.\n"
			+ "MOUSE        move the square over a lane (snaps to the beat grid)\n"
			+ "LMB          add note on release (empty slot only; hold on a note to edit its sustain)\n"
			+ "  hold+WHEEL or hold+DRAG   lengthen/shorten the held note's sustain\n"
			+ "RMB          remove note under the square\n"
			+ "WHEEL        seek song  (CTRL = 4x speed)\n"
			+ "LEFT/RIGHT   seek 1s    (CTRL = 4s)\n"
			+ "ALT+LEFT/RIGHT   notetype: " + notetype + " (type % 2 = " + (notetype % 2) + " = " + ((notetype % 2) == 0 ? "opponent" : "player") + " strumline)\n"
			+ "- / =        halve / double the snap grid (currently " + snapName() + ")\n"
			+ "             (" + Math.round(snapMs * 100) / 100 + "ms at " + Math.round(bpm * 100) / 100 + " BPM)\n"
			+ "CTRL+S       save chart (.fvc)\n"
			+ "ENTER        " + (playing ? "STOP audio (currently PLAYING)" : "play audio (currently SILENT)") + "\n"
			+ "F1 or H      toggle this help\n"
			+ "ESC          pause menu\n"
			+ "DEBUG KEY    exit editor mode (song restarts)\n"
			+ "Chart: " + saved;

		if (showInstructions && instructionsBackground != null && instructionsBuf != null) {
			var padding = 24;
			var bgW = Std.int(instructionsText.width + padding * 2);
			var bgH = Std.int(instructionsText.height + padding * 2);
			var bgX = Std.int((Main.INITIAL_WIDTH - bgW) * 0.5);
			var bgY = Std.int((Main.INITIAL_HEIGHT - bgH) * 0.5);
			instructionsBackground.x = bgX;
			instructionsBackground.y = bgY;
			instructionsBackground.w = bgW;
			instructionsBackground.h = bgH;
			instructionsText.x = bgX + padding;
			instructionsText.y = bgY + padding;
			try {
				instructionsBuf.updateElement(instructionsBackground);
				instructionsBuf.update();
			} catch (e) {}
		}
	}

	/** Human name for the current snap multiplier relative to a 16th note. */
	function snapName():String {
		if (snapMultiplier == 1)
			return "1/16";
		if (snapMultiplier == 2)
			return "1/8";
		if (snapMultiplier == 4)
			return "1/4 (beat)";
		if (snapMultiplier == 8)
			return "1/2";
		if (snapMultiplier == 16)
			return "1/1 (measure)";
		if (snapMultiplier == 0.5)
			return "1/32";
		if (snapMultiplier == 0.25)
			return "1/64";
		return Std.string(snapMultiplier) + "x 1/16";
	}
}
