package underlying.data;

/**
        The song mixer's output mode, shown in the options menu under
        Audio > Output.

        STEREO     keeps the classic 2 channel mix where every song track
                   (inst and voices) is folded into the front left/right pair.
        SURROUND71 widens the song into a full 7.1 layout: voices play
                   through the CENTER speaker, the instrumental stays wide
                   on the FRONT pair and is also spread across the side and
                   rear quad (so a stereo-only song still fills the room),
                   and the SUB channel carries the low end. Menu music and
                   sound effects follow the same layout when it is enabled.
        @since Development
**/
enum abstract AudioOutput(Int) from Int to Int {
        var STEREO;
        /** Was SURROUND31 (3.1) — same persisted value, now the full 7.1 map. */
        var SURROUND71;

        /** Display name used by the options menu. */
        public function toString():String {
                return this == SURROUND71 ? "Surround Sound 7.1" : "Stereo";
        }
}
