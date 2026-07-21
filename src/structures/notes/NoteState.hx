package structures.notes;

enum abstract NoteState(Int) from Int to Int {
	var IDLE;
	var COLOR;
	var PRESS;
	var CONFIRM;
}