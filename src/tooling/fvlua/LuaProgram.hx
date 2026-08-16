package tooling.fvlua;

/**
	An extension to CustomProgram that adds control to remove from displays.
	@since Development
**/
@:publicFields
class LuaProgram extends CustomProgram {
	var visibleToDisplays:Array<CustomDisplay> = [];
}
