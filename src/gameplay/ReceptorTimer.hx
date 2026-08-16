package gameplay;

/**
	This timer is used in response of the strumline animation system rework.
	@since 0.94
**/
@:publicFields
@:struct
class ReceptorTimer {
	var startTime:Float;
	var tailTime:Float;
	var endTime:Float;

	function new(v1:Float, v2:Float, v3:Float) {
		startTime = v1;
		tailTime = v2;
		endTime = v3;
	}
}
