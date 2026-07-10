package structures.gameplay;

/**
    For certain events, this class is utilized.
    @since 0.94
**/
@:publicFields
@:struct
class EventTimer {
    var startTime:Float;
    var endTime:Float;
    var eventObject:EventSystem.EventObject;
    var finishCallback:EventSystem.EventObject->Void;

    function new(v1:Float, v2:Float, v3:EventSystem.EventObject, v4:EventSystem.EventObject->Void) {
        startTime = v1;
        endTime = v2;
        eventObject = v3;
        finishCallback = v4;
    }
}