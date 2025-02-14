package structures.gameplay;

/**
	The body of the note system.
**/
@:publicFields
class NoteSystem {
	static var sustainProg(default, null):Program;
	static var sustainsBuf(default, null):Buffer<Sustain>;

	static var notesProg(default, null):Program;
	static var notesBuf(default, null):Buffer<Note>;

	static function init() {
		if (notesBuf == null) {
			notesBuf = new Buffer<Note>(128, 128, false);
		}

		if (notesProg == null) {
			notesProg = new Program(notesBuf);
			notesProg.blendEnabled = true;
	
			TextureSystem.setTexture(notesProg, "noteTex", "noteTex");
		}

		if (sustainsBuf == null) {
			sustainsBuf = new Buffer<Sustain>(128, 128, false);
		}

		if (sustainProg == null) {
			var tex2 = TextureSystem.getTexture("sustainTex");

			sustainProg = new Program(sustainsBuf);
			sustainProg.blendEnabled = true;

			Sustain.init(sustainProg, "sustainTex", tex2);
		}
	}

	var noteSpawner(default, null):NoteSpawner;
	var notePool(default, null):NotePool;
	var strumlines(default, null):Array<Strumline>;

	var notesHit(default, null):Map<MetaNote, Bool>;
	var notesMissed(default, null):Map<MetaNote, Bool>;
	var notesHeld(default, null):Map<MetaNote, Bool>;

	var parent(default, null):PlayField;

	/**
	 * Creates the note system.
	 * @param parent The parent of this class.
	**/
	function new(parent:PlayField) {
		notesHit = [];
		notesMissed = [];
		notesHeld = [];

		this.parent = parent;

		var display = parent.display;

		display.addProgram(sustainProg);
		display.addProgram(notesProg);

		var inputSystem = parent.inputSystem;
		var chart = parent.chart;

		notePool = new NotePool(this);
		noteSpawner = new NoteSpawner(chart.file, this);

		var mania = chart.header.mania;

		strumlines = [];

		for (i in 0...2) {
			var strumline = new Strumline(50 + Math.floor(Main.INITIAL_WIDTH * (i * 0.5)),
				parent.downScroll ? Main.INITIAL_HEIGHT - 50 : 50, 
				Math.floor(inputSystem.strumline[0]), inputSystem.strumline[1], mania, this);
			strumline.playable = parent.inputSystem.strumlinePlayable[i];
			strumlines.push(strumline);
		}

		setScrollSpeed(chart.header.speed);

		update(0);
	}

	function update(pos:Int64) {
		notePool.resetPositions();

		notesBuf.clear();
		sustainsBuf.clear();

		for (i in 0...strumlines.length) {
			var strumline = strumlines[i];
			strumline.draw(notesBuf);
		}

		if (noteSpawner != null) {
			noteSpawner.update(pos);
		}
	}

	/**
	 * Again, do not fuck with this.
	 * I put lots of effort into this abomination of a function.
	 * This function was ported from the old note system.
	 * Note hitreg and sustain inputs are handled here.
	 * @param pos The song's position in note position format.
	 * @param note The meta note you want to draw the note to.
	**/
	function drawNote(pos:Int64, note:MetaNote) {
		var index = note.index;
		var lane = note.lane;
		var position = note.position;

		var strumline = strumlines[lane];
		var rec = strumline.buffer[index];

		var id = parent.inputSystem.receptorIds[index];

		var noteSpr = notePool.newNote(id, note);

		var sustainSpr = note.duration > 100 ? notePool.newSustain(id) : null;
		var sustainExists = sustainSpr != null;

		var diff = (Int64.toInt(position - pos) * 0.01) * parent.scrollSpeed;
		var leftover = Math.floor(Int64.toInt(pos - position) * 0.01);
		var isHit = notesHit[note];
		var isMissed = notesMissed[note];
		var isHeld = notesHeld[note];

		if (parent.downScroll) diff = -diff;

		var noteSprX = rec.x;
		var noteSprY = rec.y + Math.floor(diff);

		if (parent.downScroll) diff = -diff;

		noteSpr.x = noteSprX;
		noteSpr.y = noteSprY;
		noteSpr.scale = rec.scale;

		var playable = strumline.playable && !(parent.botplay || RenderingMode.enabled);

		if (playable) {
			if (!isHit) {
				var noteToHit = strumline.notesToHit[index];
				var noteToHitExists = noteToHit != null;
				var hitPos = noteToHitExists ? noteToHit.position : 0;

				if ((!isMissed && diff < parent.hitbox && !noteToHitExists) ||
					(noteToHitExists && pos - hitPos > (position - hitPos) >> 1)) {
					strumline.notesToHit[index] = note;
				}

				if (diff < -parent.hitbox && !isMissed) {
					noteSpr.c.aF = 0.5;
					isMissed = notesMissed[note] = true;

					parent.onNoteMiss.dispatch(note);

					if (sustainExists && !isHeld) {
						sustainSpr.c.aF = Sustain.defaultMissAlpha;
						isHeld = notesHeld[note] = true;
						parent.onSustainRelease.dispatch(note);
					}

					strumline.notesToHit[index] = null;

					var hud = parent.hud;
					if (SaveData.state.preferences.ratingPopup && hud != null) {
						hud.hideRatingPopup();
					}
				}
			}
		} else {
			if (strumline.botHitsToCheck[index]) {
				if (!rec.idle()) {
					rec.reset();
					strumline.botHitsToCheck[index] = false;
				}
			}

			if (!isHit && diff < 0) {
				isHit = notesHit[note] = true;
				strumline.sustainsToHold[index] = note;

				if (!rec.confirmed()) {
					rec.confirm();
				}

				if (sustainExists) {
					sustainSpr.followNote(rec);
					sustainSpr.w = sustainSpr.length - leftover;
					if (sustainSpr.w < 0) sustainSpr.w = 0;
				}

				parent.onNoteHit.dispatch(note, 0);
				strumline.botHitsToCheck[index] = !sustainExists;
			}
		}

		if (sustainExists) {
			sustainSpr.changeID(id);
			sustainSpr.parent = noteSpr;
			sustainSpr.r = parent.downScroll ? -90 : 90;
			sustainSpr.speed = parent.scrollSpeed;
			sustainSpr.scale = rec.scale;

			if (!isHit) {
				sustainSpr.followNote(noteSpr);
			} else if (sustainSpr.c.aF != 0) {
				if (sustainSpr.w > 0) {
					sustainSpr.followNote(rec);
					sustainSpr.w = sustainSpr.length - leftover;
					if (sustainSpr.w < 0) sustainSpr.w = 0;
				}

				if (pos > position + (sustainSpr.length * 100) - 75 && (!isHeld && !isMissed)) {
					isHeld = notesHeld[note] = true;
					if (rec.confirmed()) {
						if (playable) rec.press();
						else rec.reset();
					}
					parent.onSustainComplete.dispatch(note);
				}
			}

			sustainsBuf.addElement(sustainSpr);
		}

		if (!isHit) notesBuf.addElement(noteSpr);
	}

	/**
	 * Change the scroll speed of this note system.
	**/
	function setScrollSpeed(value:Float) {
		noteSpawner.spawnDist = Math.floor(160000 / value);
		noteSpawner.despawnDist = Math.floor(40000 / Math.min(value, 1.0));
		parent.hitbox = 200 * value;
		return value;
	}

	/**
	 * Resets the strumlines of this note system.
	**/
	function resetStrumlines(resetAnims:Bool = true) {
		for (i in 0...strumlines.length) {
			var strumline = strumlines[i];
			strumline.x = 50 + Math.floor(Main.INITIAL_WIDTH * (i * 0.5));
			strumline.y = parent.downScroll ? Main.INITIAL_HEIGHT - 150 : 50;
			strumline.resetAnimations();
		}
	}

	function resetNotes() {
		noteSpawner.resetNotes();
	}

	/**
	 * Disposes the note system.
	**/
	function dispose() {
		if (strumlines != null) {
			while (strumlines.length != 0) {
				var strumline = strumlines.pop();
				strumline.dispose();
			}
	
			strumlines = null;
		}

		if (noteSpawner != null) {
			noteSpawner = null;
		}

		if (notePool != null) {
			notePool.dispose();
			notePool = null;
		}

		notesBuf.clear();
		sustainsBuf.clear();

		var display = parent.display;

		display.removeProgram(sustainProg);
		display.removeProgram(notesProg);
	}
}