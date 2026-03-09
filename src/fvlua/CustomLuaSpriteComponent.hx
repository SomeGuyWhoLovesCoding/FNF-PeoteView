package fvlua;

/**
    A single Lua script instance for Funkin' View.
**/
@:publicFields
class CustomLuaSpriteComponent {
    #if linc_luajit_funkinview
    public var parent(default, null):FunkinViewLua;
    public var playField(default, null):PlayField;

    public var customBuffers(default, null):Array<Buffer<Sprite>>;
    public var customPrograms(default, null):Array<Program>;
    public var customSprites(default, null):Array<Sprite>;

    public function new(parent:FunkinViewLua) {
        this.parent = parent;
        playField = parent.parent;
    }

    // functions are a placeholder.
    public function addCallbacksList(vm:FunkinViewLuaScript) {
        vm.addCallback("customBufferNew", null); // customBufferNew(startCount, growCount, autoShrink)
        vm.addCallback("customProgramNew", null); // customProgramNew(customBuffer)
        vm.addCallback("customElemNew", null); // customElemNew(x, y, w, h, color)

        vm.addCallback("addElementToBuffer", null); // addElementToBuffer(customElem, customBuffer)
        vm.addCallback("addTextureToProgram", null); // addTextureToProgram(customProgram, texturePNG)
        vm.addCallback("addProgramToDisplay", null); // addProgramToDisplay(customProgram, toDisplay, isBehind)

        vm.addCallback("updateElementToBuffer", null); // updateElementToBuffer(customElem, customBuffer)
        vm.addCallback("setDisplayAngle", null); // setDisplayAngle(display, rotation)
        vm.addCallback("updateDisplay", null); // updateDisplay(display)
        vm.addCallback("updateBuffer", null); // updateBuffer(customBuffer)
    }

    public function dispose() {
        parent = null;
        playField = null;
    }
    #end
}