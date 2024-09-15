package system.internal;

import sys.io.File;

/**
 * The texture system.
 */
#if !debug
@:noDebug
#end
@:publicFields
class TextureSystem {
    /**
     * The texture pool.
     */
    static var pool:Map<String, Texture> = [];

    /**
     * Get a pre-existing texture from pool.
     * @param name 
     */
    inline static function getTexture(name:String) {
        return pool[name];
    }

    /**
     * Set the program's texture to the texture and key.
     * @param prgm 
     * @param name 
     * @param tex 
     */

    inline static function setTexture(prgm:Program, name:String, tex:String) {
        prgm.setTexture(getTexture(name), tex, true);
    }

    /**
     * Create a texture and put it in the texture pool.
     * @param name 
     * @param path 
     * @param slot 
     */
    static function createTexture(name:String, path:String, slot:Int = 0) {
        if (pool.exists(name)) {
            return;
        }

        var textureBytes = File.getBytes(path);
        var textureData = TextureData.fromFormatPNG(textureBytes);

        var texture = new Texture(textureData.width, textureData.height, 1, {format: textureData.format});
        texture.setData(textureData, slot);

        pool[name] = texture;
    }

    /**
     * Create a multitexture and put it in the texture pool.
     * @param name 
     * @param paths 
     */
    static function createMultiTexture(name:String, paths:Array<String>) {
        if (pool.exists(name)) {
            return;
        }

        var texturesToPush:Array<TextureData> = [];

        var totalTextureWidth:Int = 0;
        var totalTextureHeight:Int = 0;

        for (i in 0...paths.length) {
            var textureBytes = File.getBytes(paths[i]);
            var textureData = TextureData.RGBAfrom(TextureData.fromFormatPNG(textureBytes));

            texturesToPush.push(textureData);

            totalTextureWidth += textureData.width;

            if (totalTextureHeight < textureData.height) {
                totalTextureHeight = textureData.height;
            }
        }

        var texture = new Texture(totalTextureWidth, totalTextureHeight, texturesToPush.length);

        for (i in 0...texturesToPush.length) {
            texture.setData(texturesToPush[i], i);
        }

        pool[name] = texture;
    }
}