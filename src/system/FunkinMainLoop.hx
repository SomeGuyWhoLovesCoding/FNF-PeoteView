package system;

import lime.app.FrameProfile;
import lime.app.FrameOptions;
import lime.app.TimePrecision;
import lime.app.BusyWaitMode;
import lime.app.UncapMode;
import lime.app.VSyncMode;

/**
    This main loop is set up with specific configurations needed for it to work.
**/
@:publicFields
class FunkinMainLoop {
    static var FRAMERATE:Float = 60;
    static var FRAMEOPTS:FrameOptions = {
        timePrecision: TimePrecision.HighResolution,
        busyWait: BusyWaitMode.On,
        uncapMode: UncapMode.Off
    };

    static function run(frameRate:Float) {
        Application.current.configureFrameTiming(FrameProfile.Precision, FRAMEOPTS, VSyncMode.Adaptive);
    }
}