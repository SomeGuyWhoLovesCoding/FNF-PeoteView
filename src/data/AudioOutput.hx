package data;

/**
        The song mixer's output mode, shown in the options menu under
        Audio > Output.

        STEREO     keeps the classic 2 channel mix where every song track
                   (inst and voices) is folded into the front left/right pair.
        SURROUND31 widens the song into a 3.1 layout: voices play through the
                   CENTER speaker, the instrumental stays wide on the
                   BACKGROUND front pair and the SUB channel carries the low
                   end. Music and sound effects remain stereo in both modes.
        @since Development
**/
enum abstract AudioOutput(Int) from Int to Int {
        var STEREO;
        var SURROUND31;

        /** Display name used by the options menu. */
        public function toString():String {
                return this == SURROUND31 ? "Surround Sound 3.1" : "Stereo";
        }
}
