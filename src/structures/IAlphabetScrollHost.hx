package structures;

/**
	Scroll state and list labels for menus like the freeplay menu, the credits menu, the options menu controls section, and of course, the mods menu.
	@since 0.94
**/
interface IAlphabetScrollHost {
	var xLerp:Float;
	var curSelectedLerp:Float;
	var curSelectedTarget:Float;
	var alphaLerp:Float;

	function alphabetListLength():Int;
	function alphabetItemTitle(index:Int):String;

	/**
		Returns true if the item at `index` should be displayed grayed out
		(meaning it's visible but not playable / selectable right now).
	**/
	function alphabetItemDisabled(index:Int):Bool;
}
