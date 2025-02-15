package debug;

import lime.ui.Window;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;

/**
	This class is intended for developers of the engine to test new stuff.
**/
@:publicFields
class DeveloperStuff {
	static function init(window:Window, m:Main) {
		window.onKeyDown.add(testPlayfieldInputStuff);
	}

	static function testPlayfieldInputStuff(code:KeyCode, mod:KeyModifier) {
		var playField = Main.current.playField;
		if (playField == null) return;
		switch (code) {
			case KeyCode.EQUALS:
				playField.setTime(playField.songPosition + 2000);
			case KeyCode.MINUS:
				playField.setTime(playField.songPosition - 2000);
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