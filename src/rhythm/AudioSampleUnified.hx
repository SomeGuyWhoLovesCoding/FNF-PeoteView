package rhythm;

import data.AudioOutput;
import data.SaveData;
import miniaudio.MiniAudio;

/**
        AudioSampleUnified — the unified song-audio channel system.

        The ma_thing mixing system feeds every decoded song track (the inst
        and every voices stem) into the song mixer.  This system is the
        single place that decides WHERE each of those sample streams is
        heard: it owns the surround sound buses and the stereo/surround
        output toggle.

        The channel identifiers:
                CENTER     — the center speaker.  Voices live here in
                             surround mode as a mono feed, pulling them out
                             of the stereo image.
                BACKGROUND — the front left/right pair.  The instrumental
                             stays here, full-range and wide.
                SUB        — the subwoofer (LFE).  Streams routed here play
                             only their low-passed content; every other bus
                             is additionally bass-managed into the sub so
                             the ".1" always carries the low end.

        Output modes (the Audio > Output option):
                "Stereo"             — classic 2 channel output.  Music and
                                       sound remain exactly like they have
                                       always been: every track folds into
                                       the front pair.
                "Surround Sound 3.1" — 4 channel output (FL/FR/C/LFE) for a
                                       wider sounding song.  The decoders
                                       and the music/sound effect mixer
                                       (background music, menu and gameplay
                                       SFX) stay stereo in both modes; only
                                       the song device widens to 3.1.

        Mixer.load calls onSongLoaded() so freshly opened decoders are routed
        automatically (inst -> BACKGROUND, voices -> CENTER) and the saved
        output mode is re-asserted.  Mods can re-route any track afterwards
        through setTrackChannel().
        @since Development
**/
@:publicFields
class AudioSampleUnified {
        /**
                Whether the song mixer currently outputs Surround Sound 3.1.
                False means classic stereo output.
        **/
        static var surroundEnabled(get, never):Bool;

        inline static function get_surroundEnabled():Bool {
                return MiniAudio.isSurroundEnabled();
        }

        /** The output mode saved in the save data ("Stereo" / "Surround Sound 3.1"). */
        static var output(get, set):AudioOutput;

        inline static function get_output():AudioOutput {
                return SaveData.state.audio.output;
        }

        inline static function set_output(value:AudioOutput):AudioOutput {
                applyOutput(value);
                return value;
        }

        /**
                Called by Mixer.load once the song decoders exist.  Applies the
                unified default routing — track 0 (inst) -> BACKGROUND, every
                voices stem -> CENTER — and re-asserts the saved output mode
                (a no-op when the fresh device already matches).
        **/
        static function onSongLoaded(trackCount:Int):Void {
                for (i in 0...trackCount)
                        MiniAudio.setStreamChannel(i, (i == 0) ? AudioChannelIdentifier.BACKGROUND : AudioChannelIdentifier.CENTER);

                MiniAudio.setSurroundEnabled(SaveData.state.audio.output == AudioOutput.SURROUND31);
        }

        /**
                Routes one decoded song track into a surround channel bus.
                Track 0 is the inst, tracks 1+ are the voices stems.
        **/
        static function setTrackChannel(track:Int, channel:AudioChannelIdentifier):Void {
                MiniAudio.setStreamChannel(track, channel);
        }

        /** Reads back which surround bus a song track is currently routed to. */
        static function getTrackChannel(track:Int):AudioChannelIdentifier {
                return MiniAudio.getStreamChannel(track);
        }

        /**
                Switches the song mixer's output mode and persists it.  Called
                by the Audio > Output option; safe to call during gameplay
                (the device is re-opened without losing the playback position).
        **/
        static function applyOutput(value:AudioOutput):Void {
                SaveData.state.audio.output = value;
                SaveData.save();
                MiniAudio.setSurroundEnabled(value == AudioOutput.SURROUND31);
        }
}

/**
        The song mixer's surround channel identifiers.  Values must stay in
        sync with the MaThingAudioChannel enum in ma_thing_core.h.
        @since Development
**/
enum abstract AudioChannelIdentifier(Int) from Int to Int {
        /** Center speaker — the vocals bus in surround mode. */
        var CENTER = 0;
        /** Front left/right pair — the instrumental bus in surround mode. */
        var BACKGROUND = 1;
        /** Subwoofer (LFE) — the low-passed bass bus. */
        var SUB = 2;
}
