package tooling;

import lime.ui.Window;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;

/**
	This class is intended for developers of the engine to test new stuff.
	It is not intended for end users.
	It contains various methods that can be used to test the engine's features.
	@since Development
**/
@:publicFields
class DeveloperStuff {
	static function init(window:Window, m:Main) {
		window.onKeyDown.add(testPlayfieldInputStuff);
	}

	static function testPlayfieldInputStuff(code:KeyCode, mod:KeyModifier) {
		var playField = Main.current?.playField;
		//trace(code, playField);
		if (playField == null || playField.disposed) return;
		// Debug key: toggle playfieldEditorMode. Flipping the flag and
		// switching to GAMEPLAY disposes + recreates the playfield — the
		// state machine's built-in song restart — building it in the other
		// mode. In editor mode only the note system, HUD, song system and
		// pause menu are ever created/updated; lua never runs.
		if (code == SaveData.state.controls.game.debug) {
			// Delegates to the playfield's shared toggle (same path the
			// in-playfield debug keybind takes, so the lua
			// toggleEditorMode callback fires from here too). The
			// playfield's own window listener for the same key bails
			// when it sees editorModeNext already flipped by this call.
			playField.debugToggleEditorMode();
			return;
		}
		switch (code) {
			case KeyCode.PERIOD:
				playField.setTime(playField.songPosition + 1500, 350);
			case KeyCode.COMMA:
				playField.setTime(playField.songPosition - 1500, 350);
			/*case KeyCode.S:
				playField.setTime(2200);*/
			case KeyCode.NUMBER_9:
				if (playField.songStarted)
					Mixer.speed -= 0.25;
			case KeyCode.NUMBER_0:
				if (playField.songStarted)
					Mixer.speed += 0.25;
			case KeyCode.F8:
				playField.flipHealthBar = !playField.flipHealthBar;
			case KeyCode.LEFT_BRACKET:
				if (playField.songStarted)
					playField.latencyCompensation -= 10;
			case KeyCode.RIGHT_BRACKET:
				if (playField.songStarted)
					playField.latencyCompensation += 10;
			case KeyCode.B:
				if (playField.songStarted)
					playField.botplay = !playField.botplay;
			case KeyCode.M:
				if (playField.songStarted)
					playField.downScroll = !playField.downScroll;
			default:
		}
	}
}