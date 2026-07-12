package structures.options;

import data.SaveData;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import structures.FreeplayAlphabet;
import structures.IAlphabetScrollHost;
import structures.OptionsMenu;
import structures.gameplay.InputSystem;
import structures.gameplay.NoteSystem;

/**
	Noteskin editor for the options gameplay category.
	Shows a live strumline preview via `NoteSystem.notesBuf` and exposes per-index clip/offset editing.
	@since 0.94
**/
@:publicFields
class NoteskinDisplay implements IAlphabetScrollHost {
	public static var propertyLabels(default, null):Array<String> = [
		"clip X",
		"clip Y",
		"width",
		"height",
		"offset X",
		"offset Y"
	];

	inline static var INSTRUCTIONS_TEXT = "NOTESKIN Instructions:\nPress TAB to begin editing\nPress ESC to cancel editing\n\n" +
		"Press CTRL+Left or CTRL+Right to change MANIA\nPress CTRL+Up or CTRL+Down to change lane\nPress CTRL+TAB to toggle glow preview";

	var parent(default, null):OptionsMenu;
	var options(default, null):Array<OptionsSprite> = [];
	static var alphabet(default, null):FreeplayAlphabet;

	static var titleTxt(default, null):Text;
	static var instructionsTxt(default, null):Text;
	static var editStatusTxt(default, null):Text;

	var previewNotes:Array<Note> = [];

	var editing:Bool = false;
	var closed:Bool;

	@:isVar var curManiaNum(get, set):Int = 4;
	inline function get_curManiaNum() {
		return curManiaNum;
	}
	inline function set_curManiaNum(value:Int) {
		if (value > 9) value = 0;
		if (value < 0) value = 9;
		return curManiaNum = value;
	}

	var selectedKeyIndex:Int = 0;
	var glowPreview:Bool = false;
	var notesOnDisplay:Bool = false;

	var xLerp:Float = 0.0;
	var curSelectedLerp:Float = 0.0;
	var curSelectedTarget:Float = 0.0;
	var alphaLerp:Float = 0.0;

	inline static var STRUMLINE_Y = 180;

	function new(parent:OptionsMenu) {
		this.parent = parent;
	}

	function reload() {
		destroyOptions();
		NoteSystem.init();

		if (alphabet == null) {
			alphabet = new FreeplayAlphabet(this, OptionsMenu.display);
			alphabet.ensurePrograms();
			alphabet.reload();
		}
		alphabet.addPrograms();
		closed = false;
		editing = false;

		if (titleTxt == null) {
			titleTxt = new Text("FUNKIN_VIEW_NOTESKIN_TITLE_TXT", 0, STRUMLINE_Y + 120, OptionsMenu.display, "", "vcr");
			titleTxt.outlineColor = Color.BLACK;
			titleTxt.outlineSize = 1.4;
			titleTxt.alpha = 0;
		}

		if (instructionsTxt == null) {
			instructionsTxt = new Text("FUNKIN_VIEW_NOTESKIN_INSTRUCTIONS_TXT", 4, 3, OptionsMenu.display, "", "vcr");
			instructionsTxt.scale = 0.75;
			instructionsTxt.alpha = 0;
			instructionsTxt.multiline = true;
			instructionsTxt.alignment = LEFT;
			instructionsTxt.spacerPercent = -0.1;
			instructionsTxt.outlineColor = Color.BLACK;
			instructionsTxt.outlineSize = 1;
			instructionsTxt.text = INSTRUCTIONS_TEXT;
			instructionsTxt.x = 4;
			instructionsTxt.y = Main.INITIAL_HEIGHT - (instructionsTxt.height + 4);
		}

		if (editStatusTxt == null) {
			editStatusTxt = new Text("FUNKIN_VIEW_NOTESKIN_EDIT_TXT", 0, 300, OptionsMenu.display, "", "vcr");
			editStatusTxt.multiline = true;
			editStatusTxt.alignment = RIGHT;
			editStatusTxt.alpha = 0;
			editStatusTxt.outlineColor = Color.BLACK;
			editStatusTxt.outlineSize = 1.4;
			editStatusTxt.x = Main.INITIAL_WIDTH - 4;
			editStatusTxt.setMarkerPairs([new TextFormatMarkerPair('#M1#', Color.CYAN)]);
		}

		showTexts();
		resetHostState();
		selectedKeyIndex = 0;
		rebuildPreviewNotes();
		refreshPreview();
		addNotesProgram();
	}

	function showTexts() {
		if (titleTxt != null) titleTxt.addProgram();
		if (instructionsTxt != null) instructionsTxt.addProgram();
		if (editStatusTxt != null) editStatusTxt.addProgram();
	}

	function removeTexts() {
		if (titleTxt != null) titleTxt.removeProgram();
		if (instructionsTxt != null) instructionsTxt.removeProgram();
		if (editStatusTxt != null) editStatusTxt.removeProgram();
	}

	function resetHostState() {
		xLerp = 0.0;
		curSelectedLerp = 0.0;
		curSelectedTarget = 0.0;
		alphaLerp = 0.0;
	}

	function addNotesProgram() {
		if (closed) return;
		var display = OptionsMenu.display;
		if (!NoteSystem.notesProg.isIn(display)) {
			display.addProgram(NoteSystem.notesProg);
		}
		notesOnDisplay = true;
	}

	function removeNotesProgram() {
		if (!notesOnDisplay) return;
		NoteSystem.notesBuf.clear();
		var display = OptionsMenu.display;
		if (NoteSystem.notesProg.isIn(display)) {
			display.removeProgram(NoteSystem.notesProg);
		}
		notesOnDisplay = false;
	}

	function rebuildPreviewNotes() {
		previewNotes = [];
		for (i in 0...16) {
			var note = new Note(0, STRUMLINE_Y, 0, 0);
			note.changeID(0);
			previewNotes.push(note);
		}
	}

	function refreshPreview() {
		NoteSystem.notesBuf.clear();

		if (curManiaNum == 0) {
			updateTitleText();
			alphabet.updateBuffer();
			return;
		}

		var config = getManiaConfig(curManiaNum);
		if (config == null) return;

		var ids = config.receptorIds;
		if (selectedKeyIndex >= ids.length) selectedKeyIndex = ids.length - 1;
		if (selectedKeyIndex < 0) selectedKeyIndex = 0;

		var gap = config.xOffset;
		var scale = config.scale;
		var laneCount = ids.length;

		var sampleNote = previewNotes[0];
		sampleNote.changeID(ids[0]);
		applyPreviewState(sampleNote);
		var noteWidth = sampleNote.w;

		var totalWidth = gap * (laneCount - 1) + Std.int(noteWidth * scale);
		var startX = Std.int((Main.INITIAL_WIDTH - totalWidth) * 0.5);

		for (i in 0...laneCount) {
			var note = previewNotes[i];
			var keyId = ids[i];
			note.changeID(keyId);
			applyPreviewState(note);
			note.scale = scale;
			note.x = startX + Std.int(gap * i);
			note.y = STRUMLINE_Y;
			note.c = i == selectedKeyIndex ? 0xFFFFFFFF : 0xAAAAAAFF;
			NoteSystem.notesBuf.addElement(note);
		}

		updateTitleText();
		try {
			NoteSystem.notesBuf.update();
		} catch (e) {}
	}

	inline function applyPreviewState(note:Note) {
		if (glowPreview) note.confirm();
		else note.reset();
	}

	inline function getManiaConfig(mania:Int) {
		if (mania < 1 || mania >= InputSystem.MANIA_CONFIGS.length) return InputSystem.MANIA_CONFIGS[4];
		var config = InputSystem.MANIA_CONFIGS[mania];
		return config != null ? config : InputSystem.MANIA_CONFIGS[4];
	}

	function updateTitleText() {
		var skinIndex = SaveData.state.noteskin != null ? SaveData.state.noteskin.skinIndex : 1;
		if (curManiaNum == 0) titleTxt.text = "READING INDEXES";
		else titleTxt.text = 'Noteskin #$skinIndex [${curManiaNum}K]';
		titleTxt.x = (Main.INITIAL_WIDTH - titleTxt.width) * 0.5;
		titleTxt.y = STRUMLINE_Y + 110;
	}

	function tab() {
		if (editing || closed) return;

		editing = true;
		parent.removeEvents();
		Application.current.window.onKeyDown.add(onKeyDown);
		Main.current.playScrollSound();
	}

	function cancelEditing() {
		if (!editing) return;
		editing = false;
		if (parent != null && parent.opened) {
			parent.addEvents();
			Application.current.window.onKeyDown.remove(onKeyDown);
			Main.current.playCancelSound();
		}
	}

	function confirmEditing() {
		if (!editing) return;
		editing = false;
		Tools.persistNoteskinFrames();
		refreshPreview();
		if (parent != null && parent.opened) {
			parent.addEvents();
			Application.current.window.onKeyDown.remove(onKeyDown);
			Main.current.playConfirmSound();
		}
		if (alphabet != null && !closed) alphabet.updateBuffer();
	}

	function onKeyDown(keyCode:KeyCode, keyModifier:KeyModifier) {
		if (closed) return;

		var BIND_KEY = KeyCode.TAB;
		var ctrl = keyModifier == KeyModifier.LEFT_CTRL || keyModifier == KeyModifier.RIGHT_CTRL;

		if (keyCode == KeyCode.ESCAPE) {
			cancelEditing();
			return;
		}

		if (ctrl && keyCode == BIND_KEY) {
			glowPreview = !glowPreview;
			refreshPreview();
			Main.current.playScrollSound();
			if (alphabet != null) alphabet.updateBuffer();
			return;
		}

		if (keyCode == BIND_KEY && !editing) {
			tab();
			return;
		}

		if (ctrl) {
			switch (keyCode) {
				case KeyCode.LEFT:
					curManiaNum--;
					onManiaChanged();
					Main.current.playScrollSound();
				case KeyCode.RIGHT:
					curManiaNum++;
					onManiaChanged();
					Main.current.playScrollSound();
				case KeyCode.UP:
					if (curManiaNum != 0) {
						selectedKeyIndex--;
						clampSelectedKey();
						refreshPreview();
						Main.current.playScrollSound();
					}
				case KeyCode.DOWN:
					if (curManiaNum != 0) {
						selectedKeyIndex++;
						clampSelectedKey();
						refreshPreview();
						Main.current.playScrollSound();
					}
				default:
			}
			return;
		}

		if (!editing) return;

		switch (keyCode) {
			case KeyCode.LEFT:
				adjustSelectedProperty(-1);
			case KeyCode.RIGHT:
				adjustSelectedProperty(1);
			case KeyCode.UP:
				adjustSelectedProperty(10);
			case KeyCode.DOWN:
				adjustSelectedProperty(-10);
			case KeyCode.RETURN:
				confirmEditing();
			default:
		}
	}

	function onManiaChanged() {
		parent.optionsNav.setTo(0);
		clampSelectedKey();
		refreshPreview();
		if (alphabet != null) alphabet.updateBuffer();
	}

	function clampSelectedKey() {
		if (curManiaNum == 0) return;
		var config = getManiaConfig(curManiaNum);
		if (config == null) return;
		if (selectedKeyIndex < 0) selectedKeyIndex = 0;
		if (selectedKeyIndex >= config.receptorIds.length) selectedKeyIndex = config.receptorIds.length - 1;
	}

	function currentFrameSlot():Int {
		if (curManiaNum == 0) return parent.optionsNav.value();
		var config = getManiaConfig(curManiaNum);
		var keyId = config.receptorIds[selectedKeyIndex];
		return Note.frameSlotForKey(keyId, glowPreview);
	}

	function adjustSelectedProperty(delta:Int) {
		var slot = currentFrameSlot();
		var field = parent.optionsNav.value();
		if (field < 0 || field >= propertyLabels.length) return;

		var value = Note.readFrameField(slot, field) + delta;
		Note.writeFrameField(slot, field, value);
		refreshPreview();
		if (alphabet != null) alphabet.updateBuffer();
		Main.current.playScrollSound();
	}

	function update(deltaTime:Float) {
		if (alphabet == null || closed) return;

		var ratio = Math.max(Math.min(deltaTime * 0.015, 1), 0.00001);
		if (ratio == 1) ratio = (1 / lime.app.Application.current.window.frameRate) * 0.015;

		alphaLerp = Tools.lerp(alphaLerp, parent.opened ? 1.0 : 0.0, ratio);
		curSelectedTarget = parent.optionsNav.value();
		curSelectedLerp = Tools.lerp(curSelectedLerp, curSelectedTarget, ratio);

		titleTxt.alpha = alphaLerp;
		instructionsTxt.alpha = alphaLerp;
		editStatusTxt.alpha = Tools.lerp(editStatusTxt.alpha, parent.opened && editing ? 1.0 : 0.0, ratio);

		if (editing) {
			var slot = currentFrameSlot();
			var field = parent.optionsNav.value();
			editStatusTxt.text = '#M1#Editing...#M1#\n${propertyLabels[field]}: ${Note.readFrameField(slot, field)}';
		} else {
			editStatusTxt.text = glowPreview ? "Preview: glow" : "Preview: normal";
		}
		editStatusTxt.x = Main.INITIAL_WIDTH - (editStatusTxt.width + 4);
		editStatusTxt.y = (Main.INITIAL_HEIGHT * 0.5) - (editStatusTxt.height * 0.5);

		instructionsTxt.y = Main.INITIAL_HEIGHT - (instructionsTxt.height + 4);

		alphabet.setDeltaTime(deltaTime);
		var listLen = alphabetListLength();
		var incrementBest = listLen > 7
			? Math.floor(Math.min(Math.max(curSelectedLerp - 3, 0), listLen - 7))
			: 0;

		for (i in 0...7) {
			alphabet.updateRowText(i, incrementBest);
		}
		alphabet.updateBuffer();
	}

	function destroyOptions() {
		if (closed) return;
		closed = true;

		if (editing) cancelEditing();

		removeTexts();
		removeNotesProgram();
		resetHostState();

		if (alphabet != null) alphabet.shutDown();

		while (options.length != 0) {
			var option = options.pop();
			try {
				OptionsMenu.optionsBuf.removeElement(option);
			} catch (e) {}
		}
	}

	function dispose() {
		destroyOptions();
		if (alphabet != null) alphabet.dispose();
	}

	function alphabetListLength():Int {
		if (curManiaNum == 0) return Note.frameSlotCount();
		return propertyLabels.length;
	}

	function alphabetItemTitle(index:Int):String {
		if (index < 0) return "";

		if (curManiaNum == 0) {
			if (index >= Note.frameSlotCount()) return "";
			var str = 'Index $index';
			for (i in 0...16 - str.length) str += " ";
			str += frameSummary(index);
			return str;
		}

		if (index >= propertyLabels.length) return "";
		var slot = currentFrameSlot();
		var str = propertyLabels[index];
		for (i in 0...16 - str.length) str += " ";
		str += '${Note.readFrameField(slot, index)}';
		return str;
	}

	function frameSummary(slot:Int):String {
		return '${Note.readFrameField(slot, 0)},${Note.readFrameField(slot, 1)} '
			+ '${Note.readFrameField(slot, 2)}x${Note.readFrameField(slot, 3)} '
			+ 'o${Note.readFrameField(slot, 4)},${Note.readFrameField(slot, 5)}';
	}
}
