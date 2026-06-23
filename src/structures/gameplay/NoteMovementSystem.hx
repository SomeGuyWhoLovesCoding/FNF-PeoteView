package structures.gameplay;

@:publicFields
class NoteMovementSystem {
	function new(parent:NoteSystem) {
	}

	function run(parent:NoteSystem, noteSpr:VirtualNote, sustainSpr:VirtualSustain, receptor:Note, index:Int, type:Float, isHit:Bool) {
		/**
			1 = noteSprX
			2 = noteSprX
			3 = noteSprScale
			4 = sustainSprRotation
		**/
		#if linc_luajit_funkinview
		var playField = parent.parent;
		if (playField != null) {
			var lua = playField.funkinviewlua;
			var returnValue = lua.callNoteFormula(noteSpr.diff, parent.parent.scrollSpeed, receptor.x, receptor.y, index, type);
			if (returnValue == null) return;

			//if (index == 0) Sys.println('NOTE INDEX: $index - returnValue: $returnValue');
			if (noteSpr != null) {
				noteSpr.Sx = Std.int(returnValue.x);
				//if (index == 0) Sys.println(noteSpr.Sx);
				noteSpr.Sy = Std.int(returnValue.y);
				noteSpr.scale = returnValue.scale;
			}
			if (sustainSpr != null) {
				sustainSpr.r = returnValue.sustainRot;
				sustainSpr.followNote(isHit ? receptor.x : noteSpr.Sx, isHit ? receptor.y : noteSpr.Sy, index);
			}
		}
		#end
	}

	function dispose() {

	}
}