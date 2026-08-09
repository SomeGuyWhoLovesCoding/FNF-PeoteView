package fvlua.components;

import sys.FileSystem;

using StringTools;

/**
	A note system utility component instance for Funkin' View.
	@since 0.94
**/
@:publicFields
class CustomNoteUtilsComponent extends LuaComponentObject {
	#if linc_luajit_funkinview
	public function new(_parent:FunkinViewLua) {
		super(_parent);
	}

	override public function addCallbacksList(vm:FunkinViewLuaScript):Void {
		vm.addCallback('setCustomNoteMoveFormula', function(script:String) {
			if (script == null) {
				FunkinViewLua.error("Script cannot be nil. Use `resetCustomNoteMoveFormula` instead.");
				return FunkinViewLua.Function_Stop;
			}
			parent.setNoteFormulaSource(script);
			return FunkinViewLua.Function_Continue;
		});

		vm.addCallback('resetCustomNoteMoveFormula', function() {
			parent.resetNoteFormulaSource();
			return FunkinViewLua.Function_Continue;
		});

		vm.addCallback('setNoteskinID', function(id:Int, value:String) {
			if (id < 0 || id >= 256) {
				FunkinViewLua.error('Notetype ID out of range! $id >= 256 or $id < 0');
				return FunkinViewLua.Function_Stop;
			}
			var noteskinHandle = NoteskinManager.get(value);
			if (noteskinHandle == null) {
				FunkinViewLua.error('Can\'t do that - Noteskin Handle "$value" either not found or has invalid data.');
				return FunkinViewLua.Function_Stop;
			}
			NoteSystem.typeToHandle[id] = noteskinHandle;
			return FunkinViewLua.Function_Continue;
		});

		vm.addCallback('setStrumlineNoteskinByID', function(id:Int, value:String) {
			if (id < 0 || id >= 256) {
				FunkinViewLua.error('Strumline index out of possibly range! $id >= 256 or $id < 0');
				return FunkinViewLua.Function_Stop;
			}

			var targetStrumline = playField.noteSystem.strumlines[id];
			if (targetStrumline == null) {
				FunkinViewLua.error('Can\'t do that - Strumline $id is null.');
				return FunkinViewLua.Function_Stop;
			}
			var noteskinHandle = NoteskinManager.get(value);
			if (noteskinHandle == null) {
				FunkinViewLua.error('Can\'t do that - Noteskin Handle "$value" either not found or has invalid data.');
				return FunkinViewLua.Function_Stop;
			}
			targetStrumline.noteskinHandle = noteskinHandle;
			return FunkinViewLua.Function_Continue;
		});
	}

	override public function dispose():Void {
		// any cleanup
		super.dispose();
	}
	#end
}
