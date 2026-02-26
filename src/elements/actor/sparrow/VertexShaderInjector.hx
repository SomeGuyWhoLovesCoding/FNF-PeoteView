package elements.actor.sparrow;

import peote.view.Program;
import peote.view.UniformFloat;

class VertexShaderInjector {
    /**
     * Injects skew transformation code into the vertex shader.
     * This should be called when setting up the program for Actor elements.
     */
    public static function injectSkewIntoVertexShader(program:Program, skewUniforms:Array<UniformFloat> = null):Void {
        // Define skew transformation GLSL code with proper syntax
        var skewCode = "
        void main(void) {
            // Apply skew if needed
            // Get the vertex position relative to the pivot point
            float localX = position.x - (px + adjust_x + off_x);
            float localY = position.y - (py + adjust_y + off_y);
            
            // Apply skew matrix (with bounds checking)
            float tanSkewX = 0.0;
            float tanSkewY = 0.0;
            
            // Avoid tan of 90 degrees (infinite)
            if (abs(_skewX) < 1.57) { // Less than ~90 degrees
                tanSkewX = tan(_skewX);
            }
            if (abs(_skewY) < 1.57) {
                tanSkewY = tan(_skewY);
            }
            
            float skewedX = localX + localY * tanSkewY;
            float skewedY = localY + localX * tanSkewX;
            
            // Add back the pivot offset
            position.x = skewedX + (px + adjust_x + off_x);
            position.y = skewedY + (py + adjust_y + off_y);
        }
        ";
        
        // Inject the code
        program.injectIntoVertexShader(skewCode);
    }
}