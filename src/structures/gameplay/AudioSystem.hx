package structures.gameplay;

/**
	The auditory system for the playfield.
	This is an internal structure and should only be used inside of the playfield NOT to be touched with.
**/
@:publicFields
@:access(structures.PlayField)
class AudioSystem {
	var inst:Sound;
	var voices:Array<Sound> = [];

	function new(chart:Chart) {
		inst = new Sound();
		inst.fromFile(chart.header.instDir);

		for (voicesDir in chart.header.voicesDirs) {
			var voicesInstance = new Sound();
			voicesInstance.fromFile(voicesDir);
			voices.push(voicesInstance);
		}
	}

	function play() {
		inst.play();

		for (voicesTrack in voices) {
			voicesTrack.play();
		}
	}

	function stop() {
		inst.stop();

		for (voicesTrack in voices) {
			voicesTrack.stop();
		}
	}

	function update(playField:PlayField, deltaTime:Float) {
		if ((inst.finished || (RenderingMode.enabled && playField.songPosition > inst.length)) && !playField.songEnded) {
			playField.onStopSong.dispatch(playField.chart);
		}

		if (!playField.songStarted || playField.songEnded || RenderingMode.enabled) {
			playField.songPosition += deltaTime;
		} else {
			inst.update();
			playField.songPosition = inst.time;
		}
	}

	function setTime(time:Float) {
		inst.time = time;

		for (voicesTrack in voices) {
			voicesTrack.time = time;
		}
	}

	function dispose() {
		inst.dispose();
		inst = null;
		while (voices.length != 0) {
			voices.pop().dispose();
		}
		voices.resize(0);
		voices = null;
	}
}