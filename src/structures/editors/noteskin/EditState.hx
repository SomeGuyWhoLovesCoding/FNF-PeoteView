package structures.editors.noteskin;

enum abstract EditState(Int) from Int to Int {
    var IDLE;
    var COLOR;
    var PRESS;
    var CONFIRM;
}
