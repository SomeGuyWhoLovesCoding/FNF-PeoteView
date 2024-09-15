package audio;

import audio.MiniAudio.MAResMan;
import audio.MiniAudio.MAGroup;
import audio.MiniAudio.MAEngine;
import audio.MiniAudio.MASound;
import lime.media.vorbis.VorbisFile;
import cpp.RawPointer;

class Audio
{
	var sound:RawPointer<MASound>;

	public var volume(get, set):Float;
	public var time(get, set):Float;
	public var speed(get, set):Float;
	public var looping(get, set):Bool;
	public var playing(get, never):Bool;
	public var finished(get, never):Bool;
	public var length(get, never):Float;
	// public var gamePaused:Bool = false;

	var _length:Float = -1;
	var _volume:Float = 1;

	static var engine:RawPointer<MAEngine>;
	static var group:RawPointer<MAGroup>;
	static var resourceManager:RawPointer<MAResMan>;

	static var addedSounds:Array<Audio> = [];

	public  function new(filePath:String, grouped:Bool = false)
	{
		if (resourceManager == null)
			resourceManager = MiniAudio.init_resource();

		if (engine == null)
			engine = MiniAudio.init(resourceManager);

		if (grouped && group == null)
			createGroup();

		sound = MiniAudio.loadSound(engine, filePath, (grouped ? group : null));
		if (sound == null)
		{
			trace("CAN'T LOAD SOUND " + filePath);
			return;
		}

		if (StringTools.endsWith(filePath, ".ogg"))
		{
			var vorb = VorbisFile.fromFile(filePath);
			_length = vorb.timeTotal() * 1000;
			vorb.clear();
			vorb = null;
			trace("THIS IS OGG");
		}
		else
		{
			_length = MiniAudio.getLength(sound) * 1000;
			trace("THIS IS OTHER");
		}
		MiniAudio.setTime(sound, 0);

		addedSounds.push(this);
	}

	public function dispose()
	{
		if (sound != null)
		{
			MiniAudio.stopSound(sound);
			MiniAudio.destroySound(sound);
		}
		sound = null;
		addedSounds.remove(this);
	}

	static public function disposeEngine()
	{
		if (resourceManager != null)
			MiniAudio.uninit_resource(resourceManager);
		resourceManager = null;
		if (engine != null)
			MiniAudio.uninit(engine);
		engine = null;
		if (group != null)
			disposeGroup();
		group = null;
	}

	static public function disposeEverything()
	{
		if (addedSounds != null)
		{
			while (addedSounds.length > 0)
			{
				addedSounds[0].stop();
				addedSounds[0].dispose();
			}
		}
		addedSounds = null;
		disposeEngine();
	}

	public function play()
	{
		if (MiniAudio.startSound(sound) != 0)
			trace("CAN'T PLAY SOUND");
	}

	public function pause()
	{
		MiniAudio.pauseSound(sound);
	}

	public function stop()
	{
		MiniAudio.stopSound(sound);
	}

	public static function createGroup()
	{
		if (group != null)
			disposeGroup();
		group = MiniAudio.makeGroup(engine);
	}

	public static function disposeGroup()
	{
		if (group != null)
			MiniAudio.killGroup(group);
		else
			trace("NO GROUP TO DISPOSE");
		group = null;
	}

	public static function playGroup()
	{
		if (group != null)
			MiniAudio.startGroup(group);
		else
			trace("NO GROUP TO PLAY");
	}

	public static function pauseGroup()
	{
		if (group != null)
			MiniAudio.haltGroup(group);
		else
			trace("NO GROUP TO PAUSE");
	}

	function get_playing():Bool
	{
		return MiniAudio.isPlaying(sound);
	}

	function get_finished():Bool
	{
		return MiniAudio.isDone(sound);
	}

	inline function get_length():Float
	{
		return _length;
	}

	inline function get_volume():Float
	{
		return _volume;
	}

	function set_volume(newVol:Float):Float
	{
		_volume = newVol;
		MiniAudio.setVolume(sound, _volume);
		return newVol;
	}

	function get_time():Float
	{
		return MiniAudio.getTime(sound) * 1000;
	}

	function set_time(newTime:Float):Float
	{
		if (newTime < 0 || newTime > length) // Prevent weird bugs with audio playback
		{
			newTime = 0;
		}

		MiniAudio.setTime(sound, newTime / 1000);
		return newTime;
	}

	function get_speed():Float
	{
		return MiniAudio.getPitch(sound);
	}

	function set_speed(newSpeed:Float):Float
	{
		MiniAudio.setPitch(sound, newSpeed);
		return newSpeed;
	}

	function get_looping():Bool
	{
		return MiniAudio.getLooping(sound);
	}

	function set_looping(shouldLoop:Bool):Bool
	{
		MiniAudio.setLooping(sound, shouldLoop);
		return shouldLoop;
	}
}
