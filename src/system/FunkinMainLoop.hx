package system;

#if LIME_840
import lime.app.FrameProfile;
import lime.app.FrameOptions;
import lime.app.TimePrecision;
import lime.app.BusyWaitMode;
import lime.app.UncapMode;
import lime.app.VSyncMode;
#end

/**
    This main loop is set up with specific configurations needed for it to work.
**/
@:publicFields
class FunkinMainLoop {
    static var FRAMERATE:Float  =  60;
    #if LIME_840
    static var FRAMEOPTS:FrameOptions;
    #end

    static function run(frameRate:Float, uncapped:Bool) {
        #if LIME_840
        FRAMEOPTS = {
            timePrecision: TimePrecision.HighResolution,
            busyWait: BusyWaitMode.On,
            uncapMode: uncapped ? UncapMode.Soft : UncapMode.Off
        };
        #end
        var uncappedModeStr:String = uncapped ? "Soft" : "Off";
		Sys.println('[ System ] Framerate set to $frameRate with uncapped mode set to ${uncappedModeStr}');
        Application.current.window.frameRate = FRAMERATE = frameRate;
        #if LIME_840
        Application.current.configureFrameTiming(FrameProfile.Precision, FRAMEOPTS, VSyncMode.Off);
        #end
    }
}