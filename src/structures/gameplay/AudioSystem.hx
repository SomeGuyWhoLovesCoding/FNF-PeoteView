package structures.gameplay;

import Miniaudio.MaSoundGroup;
import Miniaudio.MaResult;

/**
	The auditory system for the playfield.
	This is an internal structure and should only be used inside of the playfield NOT to be touched with.
	Please hope to god the fucking miniaudio mixing shit can actually be written in the future.
	E.g. the developer's been having this issue that all the sounds' timing don't match up at the exact same moment when you change the time of an audio VERY frequently or when it happens due to minor lag from background processes.
	I swear, please make this end.
	@since Development
**/
@:publicFields
@:access(structures.PlayField)
class AudioSystem {
	var inst:Sound;
	var voices:Array<Sound> = [];

	var soundgrp:MaSoundGroup;

	function new(chart:Chart) {
		inst = new Sound();
		inst.fromFile(chart.header.instDir);

		for (voicesDir in chart.header.voicesDirs) {
			var voicesInstance = new Sound();
			voicesInstance.fromFile(voicesDir);
			voices.push(voicesInstance);
		}

		var result = Miniaudio.ma_sound_group_init(Sound.engine, 0, null, soundgrp);

		if (result != MaResult.MA_SUCCESS) {
			Sys.println("[Sound system] Failed to initialize engine");
			return;
		} else {
			Sys.println("HHAAAAHHHH");
		}
	}

	function play() {
		Miniaudio.ma_sound_group_set_pitch(soundgrp, 1);
		Miniaudio.ma_sound_group_set_volume(soundgrp, 1);

		inst.play();

		for (voicesTrack in voices) {
			voicesTrack.play();
		}

		Miniaudio.ma_sound_group_stop(soundgrp);
		Miniaudio.ma_sound_group_start(soundgrp);
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
		var timeInSec:cpp.Float64 = time * 0.001;
		var sampleRate:cpp.UInt32 = 48000;

		var dataSource = Miniaudio.ma_sound_get_data_source(untyped cast soundgrp);
		Miniaudio.ma_data_source_get_data_format(dataSource, null, null, cpp.Pointer.addressOf(sampleRate).ptr, null, 0);

		Miniaudio.ma_sound_seek_to_pcm_frame(untyped cast soundgrp, untyped (sampleRate * timeInSec));

		@:privateAccess {
			var programPos = -Timestamp.get() + timeInSec;
			inst._programPos = programPos;

			for (voicesTrack in voices) {
				voicesTrack._programPos = programPos;
			}
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

		Miniaudio.ma_sound_group_uninit(soundgrp);
	}
}