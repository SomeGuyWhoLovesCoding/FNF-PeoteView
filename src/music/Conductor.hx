package music;

import lime.app.Event;
import haxe.Int64;

/**
	The conductor. Steps, beats, and measures use floats because this class was carried over from fnf zenith's.
	Also, time signature changing math was implemented here.
	Revamped math by sword_352: https://github.com/Sword352
**/
@:publicFields
class Conductor
{
	/**
		The conductor's step event.
	**/
	var onStep:Event<Float->Void> = new Event<Float->Void>();

	/**
		The conductor's beat event.
	**/
	var onBeat:Event<Float->Void> = new Event<Float->Void>();

	/**
		The conductor's measure event.
	**/
	var onMeasure:Event<Float->Void> = new Event<Float->Void>();

	/**
		The conductor's step crochet.
	**/
	var stepCrochet(default, null):Float;

	/**
		The conductor's crochet.
	**/
	var crochet(default, null):Float;

	/**
		The conductor's measure crochet.
	**/
	var measureCrochet(default, null):Float;

	/**
		The conductor's last beats per minute.
	**/
	var lastBpm(default, null):Float = 100;

	/**
		The conductor's beats per minute.
	**/
	var bpm(default, null):Float = 100;

	/**
		Whenever the conductor's active.
	**/
	var active:Bool;

	/**
		The conductor's time.
	**/
	var time(default, set):Float = 0;

	/**
		Set the conductor's time.
	**/
	function set_time(value:Float):Float
	{
		time = value;

		_stepTracker = Math.ffloor(stepOffset + (time - offsetTime) / stepCrochet);
		_beatTracker = Math.ffloor(beatOffset + (time - offsetTime) / crochet);
		_measureTracker = Math.ffloor(measureOffset + (time - offsetTime) / measureCrochet);

		if (active) {
			if (curStep != _stepTracker)
			{
				var leftover:Float = _stepTracker - curStep;

				/**
					This is here just in case you miss a couple steps.
				**/
				if (leftover > 1) {
					var leftoverCounter:Float = 0;
					while (++leftoverCounter < leftover) {
						onStep.dispatch(curStep + leftoverCounter);
					}
				}

				curStep = _stepTracker;

				onStep.dispatch(curStep);
			}

			if (curBeat != _beatTracker)
			{
				var leftover:Float = _beatTracker - curBeat;

				/**
					This is here just in case you miss a couple beats.
				**/
				if (leftover > 1) {
					var leftoverCounter:Float = 0;
					while (++leftoverCounter < leftover) {
						onBeat.dispatch(curBeat + leftoverCounter);
					}
				}

				curBeat = _beatTracker;

				onBeat.dispatch(curBeat);
			}

			if (curMeasure != _measureTracker)
			{
				var leftover:Float = _measureTracker - curMeasure;

				/**
					This is here just in case you miss a couple measures.
				**/
				if (leftover > 1) {
					var leftoverCounter:Float = 0;
					while (++leftoverCounter < leftover) {
						onMeasure.dispatch(curMeasure + leftoverCounter);
					}
				}

				curMeasure = _measureTracker;

				onMeasure.dispatch(curMeasure);
			}
		} else {
			curStep = _stepTracker;
			curBeat = _beatTracker;
			curMeasure = _measureTracker;
		}

		return value;
	}

	/**
		The step counter.
	**/
	var curStep(default, null):Float = 0;

	/**
		The beat counter.
	**/
	var curBeat(default, null):Float = 0;

	/**
		The measure counter.
	**/
	var curMeasure(default, null):Float = 0;

	/**
		The step tracker.
	**/
	private var _stepTracker(default, null):Float = 0;

	/**
		The beat tracker.
	**/
	private var _beatTracker(default, null):Float = 0;

	/**
		The measure tracker.
	**/
	private var _measureTracker(default, null):Float = 0;

	/**
		The time offset.
	**/
	private var offsetTime(default, null):Float = 0;

	/**
		The step offset.
	**/
	private var stepOffset(default, null):Float = 0;

	/**
		The beat offset.
	**/
	private var beatOffset(default, null):Float = 0;

	/**
		The measure offset.
	**/
	private var measureOffset(default, null):Float = 0;

	/**
		The time signature steps.
	**/
	var numerator:Float = 4;

	/**
		The time signature beats.
	**/
	var denominator:Float = 4;

	/**
		Change the conductor's beats per minute.
		This also includes time signatures.
		@param position The position you want to execute the event on.
		@param newBpm The new beats per minute.
		@param newNumerator The new numerator of the time signature.
		@param newDenominator The new denominator of the time signature.
	**/
	inline function changeBpmAt(position:Float, newBpm:Float = 0, newNumerator:Float = 4, newDenominator:Float = 4):Void
	{
		var calc = (position - offsetTime);
		stepOffset += calc / stepCrochet;
		beatOffset += calc / crochet;
		measureOffset += calc / measureCrochet;
		offsetTime = position;

		if (newBpm > 0) {
			stepCrochet = (15000 / bpm);
			bpm = newBpm;
		}

		crochet = stepCrochet * newNumerator;
		measureCrochet = crochet * newDenominator;

		numerator = newNumerator;
		denominator = newDenominator;
	}

	/**
		Reset the conductor.
	**/
	inline function reset():Void
	{
		stepOffset = beatOffset = measureOffset = offsetTime = time = 0.0;
		changeBpmAt(0, 0);
	}

	/**
		Constructs a conductor.
		@param initialBpm The initial beats per minute.
	**/
	inline function new(initialBpm:Float = 100, initialNumerator:Float = 4, initialDenominator:Float = 4):Void
	{
		changeBpmAt(0, initialBpm, initialNumerator, initialDenominator);
		active = true;
	}
}