package handler;

/**
	String-labeled input modes. Every active UI context declares a mode; `Controls`
	keeps exactly one mode's `KeyboardAction` active in the single shared
	`Input2Action` at any time. Switching modes never rebuilds window listeners —
	it only swaps which prebuilt layout is listening.
	@since Development
**/
@:publicFields
enum abstract ControlsMode(String) to String {
	var NONE = "none";
	var MAIN_MENU = "mainMenu";
	var FREEPLAY = "freeplay";
	var STORY = "story";
	var OPTIONS = "options";
	var GAMEPLAY = "gameplay";
	var PAUSE = "pause";
	var GAME_OVER = "gameOver";
	var EDITOR_MENU = "editorMenu";
	var NOTESKIN_EDITOR = "noteskinEditor";
	var AWARDS = "awards";
	var CREDITS = "credits";
}
