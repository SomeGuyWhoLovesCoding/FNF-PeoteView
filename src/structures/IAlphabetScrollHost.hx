package structures;

/**
	Scroll state and list labels for {@link FreeplayAlphabet}.
	@since 0.94
**/
interface IAlphabetScrollHost {
	var xLerp:Float;
	var curSelectedLerp:Float;
	var curSelectedTarget:Float;
	var alphaLerp:Float;

	function alphabetListLength():Int;
	function alphabetItemTitle(index:Int):String;
}
