package fvlua;

/**
    An extension to CustomProgram that adds control to remove from displays.
**/
@:publicFields
class LuaProgram extends CustomProgram
{
    var visibleToDisplays:Array<CustomDisplay> = [];
}