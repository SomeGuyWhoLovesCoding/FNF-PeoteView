package structures.noteSystem;

/**
	The body of the note system.
**/
@:publicFields
class NoteSystem {
	static var sustainProg(default, null):Program;
	static var sustainsBuf(default, null):Buffer<Sustain>;

	static var notesProg(default, null):Program;
	static var notesBuf(default, null):Buffer<Note>;

	var noteSpawner(default, null):NoteSpawner;

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

	//var noteSpawner(default, null):NoteSpawner;
	var strumlines(default, null):Array<Strumline>;

	var parent(default, null):PlayField;

	function new(parent:PlayField) {
		this.parent = parent;

		var display = parent.display;

		display.addProgram(sustainProg);
		display.addProgram(notesProg);

		strumlines = [];

		var inputSystem = parent.inputSystem;
		var chart = parent.chart;
		var scrollSpeed = chart.header.speed;

		noteSpawner = new NoteSpawner(chart.file);
		noteSpawner.setScrollSpeed(scrollSpeed);

		var mania = chart.header.mania;
		//var strumlineCount = chart.header.strumlines;

		for (i in 0...2) {
			var strumline = new Strumline(50 + Math.floor(Main.INITIAL_WIDTH * (i * 0.5)),
				parent.downScroll ? Main.INITIAL_HEIGHT - 50 : 50, 
				Math.floor(inputSystem.strumline[0]), inputSystem.strumline[1], mania, this);
			strumlines.push(strumline);
		}

		update(0);
	}

	function update(pos:Int64) {
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

	function resetStrumlines(resetAnims:Bool = true) {
		for (i in 0...strumlines.length) {
			var strumline = strumlines[i];
			strumline.x = 50 + Math.floor(Main.INITIAL_WIDTH * (i * 0.5));
			strumline.y = parent.downScroll ? Main.INITIAL_HEIGHT - 150 : 50;
			strumline.resetAnimations();
		}
	}

	function dispose() {
		if (strumlines != null) {
			while (strumlines.length != 0) {
				var strumline = strumlines.pop();
				strumline.dispose();
			}
	
			strumlines = null;
		}

		notesBuf.clear();
		sustainsBuf.clear();

		parent.display.removeProgram(notesProg);
		parent.display.removeProgram(sustainProg);
	}
}