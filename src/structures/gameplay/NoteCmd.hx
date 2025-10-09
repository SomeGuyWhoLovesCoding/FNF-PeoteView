package structures.gameplay;

/**
 * The note command.
 * Used for the greedy merge queue when necessary.
**/
@:structInit
@:publicFields
class NoteCmd {
	var pos:Int64;
	var n:MetaNote;
	var diff:Float;
	var id_:Int64;
	@:optional var notesInOne:Int64;
	@:optional var addedAlpha:Float;
}