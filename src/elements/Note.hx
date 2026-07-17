package elements;

import structures.gameplay.NoteskinRuntimeHelper;
import structures.gameplay.NoteskinHandle.BasicNoteskinClip;

/**
    The note sprite of the note system. This is also used for the receptor.
**/
@:publicFields
class Note implements Element
{
    static public var defaultAlpha:Float = 1;
    static public var defaultMissAlpha:Float = 0.5;

    @varying @custom @formula("ox * scale") public var ox:Int;
    @varying @custom @formula("oy * scale") public var oy:Int;
    @posX @formula("uDisplayRotateX(aPos + vec2(px, py) + vec2(ox, oy))") @set("properties") public var x:Int;
    @posY @formula("uDisplayRotateY(aPos + vec2(px, py) + vec2(ox, oy))") @set("properties") public var y:Int;

    @varying @sizeX @formula("w * scale") @set("properties") public var w:Int = 100;
    @varying @sizeY @formula("h * scale") @set("properties") public var h:Int = 100;
    @varying @custom @set("properties") public var scale:Float = 1.0;

    @rotation @formula("uDisplayRotation(r)") public var r:Float;

    @pivotX @const @formula("w * 0.5") public var px:Int;
    @pivotY @const @formula("h * 0.5") public var py:Int;

    @color public var c:Color = 0xFFFFFFFF;

    @varying @custom @set("properties") public var initialAlpha(default, set):Float = 1.0;
    inline public function set_initialAlpha(value:Float) {
        initialAlpha = value;
        if (initialAlpha < 0) initialAlpha = 0;
        if (initialAlpha > 1) initialAlpha = 1;
        return value;
    }

    @varying @custom @set("properties") public var addedAlpha:Float = 0.0;

    /**
        Multi-texture slot selectors. These tell peote-view's shader
        which entry in the program's bound `setMultiTexture` array to
        sample from for THIS element.

        - `texUnit`: index into `NoteskinManager.textureCache` (the
          array passed to `program.setMultiTexture(cache, "noteTexV2")`).
        - `texSlot`: sub-slot within that unit. Always 0 for noteskins
          (one Texture per unit, no sub-packing).

        Updated by `setHandle(handle)` whenever the strumline switches
        to a different noteskin — that's the ONLY call needed to make
        a note start sampling from a different skin's sheet. No
        `setTexture` re-binding, no shader re-injection.
    **/
    @texUnit public var texUnit:Int = 0;
    @texSlot public var texSlot:Int = 0;

    public var diff:Int = 0;
    public var scrollDirection:Int = 90;

    @texX var clipX:Int = 0;
    @texY var clipY:Int = 0;
    @texW var clipWidth:Int = 100;
    @texH var clipHeight:Int = 100;
    @texPosX  var clipPosX:Int = 0;
    @texPosY  var clipPosY:Int = 0;
    @texSizeX var clipSizeX:Int = 100;
    @texSizeY var clipSizeY:Int = 100;

    public var rW:Int;
    public var rH:Int;

    public var id:Int = 0;

    // Internal state for checking methods
    private var state:NoteState = IDLE;

    var handle:NoteskinHandle;

    inline public function new(x:Int, y:Int, w:Int, h:Int, handle:NoteskinHandle, scale:Float = 1.0, initialAlpha:Float = 1.0, addedAlpha:Float = 0.0) {
        this.handle = handle;
        setProperties(x, y, w, h, scale, initialAlpha, addedAlpha);
        setHandle(handle);
        reset();
    }

    static public function init(program:CustomProgram)
    {
    }

    inline public function changeID(id:Int) {
        this.id = id;
    }

    /**
        Propagate `texUnit` / `texSlot` from a noteskin handle to this
        note. Called from the constructor and from
        `Strumline.set_noteskinHandle` whenever the active skin changes.

        After this call, the note's `@texUnit` / `@texSlot` attributes
        point at the new skin's slot in `NoteskinManager.textureCache`,
        so the shader will sample from that skin's sheet on the next
        draw. No `setTexture` re-binding or shader re-injection is
        needed — peote-view picks up the new attributes on the next
        `buffer.updateElement(note)` call (which the strumline / editor
        is responsible for triggering).

        If `handle` is null, this is a no-op (the note keeps its
        previous texUnit/texSlot — useful for the editor's "no skin
        loaded yet" state).
    **/
    inline public function setHandle(handle:NoteskinHandle) {
        if (handle == null) return;
        this.handle = handle;
        texUnit = handle.texUnit;
        texSlot = handle.texSlot;
    }

    // --- State methods ---

    public function reset() {
        state = IDLE;
        if (handle == null) return;
        var clip = NoteskinRuntimeHelper.getIdleClip(handle, id);
                //trace('Idle and ${clip.clipX}x${clip.clipY},${clip.clipW}x${clip.clipH},index:$id');
        applyClip(clip);
        rW = w;
        rH = h;
    }

    public function toNote() {
        state = COLOR;
                if (handle == null) return;
        var clip = NoteskinRuntimeHelper.getColorClip(handle, id);
        applyClip(clip);
    }

    public function press() {
        state = PRESS;
        if (handle == null) return;
        var clip = NoteskinRuntimeHelper.getPressClip(handle, id);
        applyClip(clip);
    }

    public function confirm() {
        state = CONFIRM;
        if (handle == null) return;
        var clip = NoteskinRuntimeHelper.getConfirmClip(handle, id);
        applyClip(clip);
    }

    // --- Checking methods ---

    inline public function idle() {
        return state == IDLE;
    }

    inline public function isNote() {
        return state == COLOR;
    }

    inline public function pressed() {
        return state == PRESS;
    }

    inline public function confirmed() {
        return state == CONFIRM;
    }

    // --- Helper to apply a clip to the note ---

    private inline function applyClip(clip:BasicNoteskinClip) {
        clipX = clip.clipX;
        clipY = clip.clipY;
        w = clip.clipW;
        h = clip.clipH;
        clipWidth = clip.clipW;
        clipHeight = clip.clipH;
        clipSizeX = clip.clipW;
        clipSizeY = clip.clipH;
        ox = clip.offsX;
        oy = clip.offsY;
        // Rotation is not used for Note sprites (handled separately if needed)
    }
}