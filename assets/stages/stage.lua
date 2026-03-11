local stageback_img = "assets/stages/stage/stageback.png"
local stagefront_img = "assets/stages/stage/stagefront.png"
local stage_light_img = "assets/stages/stage/stage_light.png"
local stagecurtains_img = "assets/stages/stage/stagecurtains.png"

function createPost()
    -- STAGE FLOOR CREATION (ONLY MEANT TO BE STATIC, NOT TO BE UPDATED)
    setupStageObject("stageback", stageback_img, -450, -300, 0.9, 0.9, "view", true)
    setupStageObject("stagefront", stagefront_img, -550, 450, 0.9 * 1.1, 0.9, "view", false, "stageback")

    -- STAGE LIGHT CREATION (ONLY MEANT TO BE STATIC, NOT TO BE UPDATED)
    setupStageObject("stage_light", stage_light_img, -125, -400, 0.9 * 1.1, 0.9, "view", false, "stageback")
    setupStageObject("stage_light2", stage_light_img, -1225, -400, -0.9 * 1.1, -0.9, "view", false, "stageback")
    setupStageObject("stagecurtains", stagecurtains_img, -1300, -1000, 1.3 * 0.9, 1.3, "view", false)
end

function setupStageObject(key, img, x, y, scaleX, scaleY, cam, behind, atProgram)
    customBufferNew(key, 1)
    customProgramNew(key, key)
    addTextureToProgram(key, img)
    addProgramToDisplay(key, cam, behind, atProgram)
    customElementNew(key, x, y, getTextureCoordinateX(key) * scaleX, getTextureCoordinateY(key) * scaleY)
    addElementToBuffer(key, key)
end