function beatHit(beat)
    if (beat + 1) % 8 == 0 then
        trace("Hey!")
        local bf = getBF()
        playCustomActorAnimation(bf, "singLEFT")
    end
end