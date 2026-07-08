package structures.gameplay;

/**
    For certain events, this class is utilized.
    @since 0.94
**/
@:publicFields
@:structInit
class EventTimer {
    var startTime:Float;
    var endTime:Float;
    var finishCallback:EventSystem.EventObject->Void;
}