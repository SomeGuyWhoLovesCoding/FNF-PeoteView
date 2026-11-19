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

	=== Audio by default: SILENT, without touching volume ===

	The normal gameplay start path is the countdown path: create() parks
	songPosition in the negative (countdown) range and lets Mixer.update
	advance it on a FAKE clock (songPosition += deltaTime) while
	!songStarted; only when the countdown conductor crosses beat 0 does
	countdownBeatHit dispatch onStartSong, whose listener startSong() is
	the single place that ever calls Mixer.startMusic().

	The editor reuses exactly that mechanism, minus the countdown lead-in:
	- create() leaves songStarted false and songPosition at 0 —
	  Mixer.update advances the position on the fake clock. The mixer
	  transport is NEVER started at entry, so there is nothing to mute;
	  the audio device never pulls song frames.
	- The pause keybind (controls.game.pause, default ENTER) dispatches
	  onStartSong — the same event the countdown path uses — which
	  starts real audio playback from the current fake-clock position.
	  Pressing it again stops the transport back to the fake clock
	  (Mixer.stopMusic preserves the PCM position).
	No master-volume parking, no volume writes anywhere: what you hear
	outside the editor is untouched by entering it.

	@since Development
**/
@:publicFields
class PlayFieldEditorMode {
	/** Owning playfield (never null after construction). */
	var field:PlayField;

	/** Grid + wheel snap resolution in ms (1 step at 120 BPM 4/4 = 125 ms). */
	var snapMs:Float = 125.0;

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
		songStarted is still false — the song runs on the fake clock,
		completely silent (see class doc).
	**/
	function build() {
		// Editor subset only: no Field (stage/characters/camera), no
		// FunkinViewLua, no EventSystem, no InputSystem, no
		// CountdownDisplay. The song starts silently at position 0 on
		// the fake clock — audio never starts at entry.
		field.songPosition = 0;

		// Receptors enter the STATIC NoteSystem.notesBuf mid-constructor;
		// if anything below throws, PlayField.noteSystem never gets
		// assigned and dispose() would skip it — leaving those receptors
		// as permanent strumline ghosts on screen. PlayField's create
		// wraps this call in try/catch → cleanupFailedCreate().
		HUD.init();
		if (!SaveData.state.preferences.hideHUD)
			field.hud = new HUD(field.display, field);

		NoteSystem.init();
		field.noteSystem = new NoteSystem(field);

		Mixer.init(Chart.header); // the song system (transport NOT started)

		PauseScreen.init(field.roof);
		field.pauseScreen = new PauseScreen(Chart.header.difficulty);

		// Both strumlines non-playable: no keybind input path exists,
		// receptors auto-confirm through the spawner's bot path.
		for (strumline in field.noteSystem.strumlines)
			strumline.playable = false;
		field.botplay = true;

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
				snapMs = snapMs / 2 < 10 ? snapMs : snapMs / 2;
				updateInstructionsText();
			case KeyCode.EQUALS:
				snapMs *= 2;
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
		sets songStarted). Stopping mirrors what stopSong/gameOver do:
		detach the conductor listeners (lime's Event.add does NOT dedupe,
		so a start cycle must not stack duplicates), stop the transport
		(PCM position preserved) and drop songStarted, which puts
		Mixer.update back on the fake clock.
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
			// Align the mixer's PCM position with the fake clock BEFORE the
			// transport spins up. The countdown path gets this for free
			// (audio starts at 0 exactly when the fake clock crosses 0);
			// here the fake clock has been running since entry (and a
			// stop→restart cycle leaves the PCM position wherever the
			// transport was stopped), so without this seek the audio would
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
		instructionsText.text = "=== PLAYFIELD EDITOR ===\n"
			+ "MOUSE        move the square over a lane (snaps to " + Std.int(snapMs) + "ms steps)\n"
			+ "LMB          add note on release (empty slot only)\n"
			+ "RMB          remove note under the square\n"
			+ "WHEEL        seek song  (CTRL = 4x speed)\n"
			+ "LEFT/RIGHT   seek 1s    (CTRL = 4s)\n"
			+ "- / =        halve / double the snap step\n"
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
}
