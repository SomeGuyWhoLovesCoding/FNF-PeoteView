package structures.notes;

using StringTools;
import haxe.Int64;

// ------------------------------------------------------------------
// Bytecode Opcodes (Strictly 8-bit for SWAR packing)
// ------------------------------------------------------------------
enum abstract OnValue(Int64) from Int64 to Int64 {
  var PLUS = 0x00;
  var MINUS = 0x01;
  var TIMES = 0x02;
  var DIVIDE = 0x03;
  var MOD = 0x04;
  var SIN = 0x05;
  var COS = 0x06;
  var MIN = 0x07;
  var MAX = 0x08;
  var ABS = 0x09;
  var NOT = 0x0A;
  var AND = 0x0B;
  var OR = 0x0C;
  
  var PUSH_CONST = 0x10;
  var PUSH_VAR = 0x11;
  var SET_VAR = 0x20;
  
  var ABORT = 0x30;
  var ABORT_IF_NOT_EQ = 0x31;
  var ABORT_IF_EQ = 0x32;
  var NOP = 0x33;
}

@:final
class NoteMovementInterp {
  var codeBlocks:Array<Int64> = [];
  var args:Array<Int> = [];
  var constants:Array<Float> = [];
  
  var varMap:FakeStringMap<Int>;
  var varCount:Int;

  var locals:Vector<Float>;
  var stack:Vector<Float>;
  var stackPtr:Int;
  var argPtr:Int;

  var opcodeBuffer:Array<Int> = [];
  var argsBuffer:Array<Int> = [];

  public function new(codeStr:String) {
    varMap = new FakeStringMap<Int>();
    varCount = 0;
    compile(preprocess(codeStr));
    locals = new Vector<Float>(varCount + 100);
    stack = new Vector<Float>(512);
  }

  // ------------------------------------------------------------------
  // Preprocessing & Lua Translation
  // ------------------------------------------------------------------
  function preprocess(luaCode:String):String {
    if (luaCode == null || StringTools.trim(luaCode) == "") return "";
    var code = luaCode;
    
    // 0. Strip Lua comments
    code = ~/--\[\[[\s\S]*?\]\]/g.replace(code, "");
    code = ~/--[^\n]*/g.replace(code, "");

    // 1. Extract custom functions and inline them
    var customFuncs = new Map<String, {args: Array<String>, body: String}>();
    var funcRegex = ~/function\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*\(([^)]*)\)\s*(.*?)\s*end/gi;
    while (funcRegex.match(code)) {
      var name = funcRegex.matched(1);
      var argsStr = funcRegex.matched(2);
      var body = funcRegex.matched(3);
      var args = argsStr.split(",").map(function(s) return StringTools.trim(s)).filter(function(s) return s != "");
      
      var retMatch = ~/return\s+(.*?);/i;
      if (retMatch.match(body)) {
        var expr = retMatch.matched(1);
        customFuncs.set(name.toLowerCase(), {args: args, body: expr});
      }
      code = funcRegex.replace(code, "");
    }

    // Inline custom function calls
    var inlinedCode = "";
    var i = 0;
    while (i < code.length) {
      var matchedFunc = null;
      var matchedName = "";
      for (name in customFuncs.keys()) {
        if (code.substr(i, name.length).toLowerCase() == name) {
          var prevChar = i > 0 ? code.charAt(i - 1) : " ";
          var nextChar = code.charAt(i + name.length);
          if (!~/[a-zA-Z0-9_]/.match(prevChar) && nextChar == "(") {
            matchedFunc = customFuncs.get(name);
            matchedName = name;
            break;
          }
        }
      }
      
      if (matchedFunc != null) {
        i += matchedName.length + 1;
        var callArgs = [];
        var depth = 1;
        var currentArg = "";
        while (i < code.length && depth > 0) {
          var c = code.charAt(i);
          if (c == "(") depth++;
          else if (c == ")") {
            depth--;
            if (depth == 0) {
              callArgs.push(StringTools.trim(currentArg));
              break;
            }
          } else if (c == "," && depth == 1) {
            callArgs.push(StringTools.trim(currentArg));
            currentArg = "";
            i++;
            continue;
          }
          currentArg += c;
          i++;
        }
        i++; // skip ')'
        
        if (callArgs.length != matchedFunc.args.length) {
          trace("Warning: Function " + matchedName + " expects " + matchedFunc.args.length + " arguments, but got " + callArgs.length);
        }
        
        var inlined = matchedFunc.body;
        for (j in 0...matchedFunc.args.length) {
          var argName = matchedFunc.args[j];
          var argVal = j < callArgs.length ? callArgs[j] : "0";
          var reg = new EReg("\\b" + argName + "\\b", "g");
          inlined = reg.replace(inlined, "(" + argVal + ")");
        }
        inlinedCode += "(" + inlined + ")";
      } else {
        inlinedCode += code.charAt(i);
        i++;
      }
    }
    code = inlinedCode;

    // 2. Fold min/max with >2 arguments into nested 2-argument calls
    var minMaxFold = ~/\b(min|max)\s*\(([^()]+),\s*([^()]+),\s*([^()]+)\)/gi;
    while (minMaxFold.match(code)) {
      code = minMaxFold.replace(code, "$1($1($2, $3), $4)");
    }

    // 3. Extract main function arguments and map them strictly by position
    var funcMatch = ~/function\s+noteFormula\s*\(([^)]*)\)/i;
    if (funcMatch.match(code)) {
      var paramsStr = funcMatch.matched(1);
      var params = paramsStr.split(",");
      var internalNames = ["diff", "scrollSpeed", "receptorX", "receptorY", "index", "type"];
      
      for (i in 0...params.length) {
        var paramName = StringTools.trim(params[i]);
        if (i < internalNames.length && paramName != "") {
          var reg = new EReg("\\b" + paramName + "\\b", "g");
          code = reg.replace(code, internalNames[i]);
        }
      }
    }
    
    // 4. Replace math constants and functions
    code = ~/math\.pi/gi.replace(code, "3.141592653589793");
    code = ~/math\.sin/gi.replace(code, "sin");
    code = ~/math\.cos/gi.replace(code, "cos");
    code = ~/math\.min/gi.replace(code, "min");
    code = ~/math\.max/gi.replace(code, "max");
    code = ~/math\.abs/gi.replace(code, "abs");
    
    // 5. Translate Lua control flow into ABORT opcodes
    code = ~/if\s+\(*\s*([a-zA-Z0-9_]+)\s*\)*\s*~=\s*([0-9.]+)\s+then\s+return\s+nil\s+end/gi.replace(code, "__abort_if_not_eq($1, $2);");
    code = ~/if\s+\(*\s*([a-zA-Z0-9_]+)\s*\)*\s*==\s*([0-9.]+)\s+then\s+return\s+nil\s+end/gi.replace(code, "__abort_if_eq($1, $2);");
    code = ~/\breturn\s+nil\b/gi.replace(code, "__abort();");
    
    // 6. Remove Lua-specific keywords
    code = ~/local\s+/gi.replace(code, "");
    code = ~/function\s+noteFormula\s*\([^)]*\)/i.replace(code, "");
    code = ~/\bend\b/gi.replace(code, "");
    
    // 7. Parse return statements into explicit assignments
    var lines = code.split("\n");
    var newLines = [];
    for (line in lines) {
      line = StringTools.trim(line);
      if (line.startsWith("return ")) {
        var retVals = line.substr(7).split(",");
        var targets = ["x", "y", "scale", "sustainRot", "scrollMultiplier"];
        for (i in 0...retVals.length) {
          if (i < targets.length) {
            newLines.push(targets[i] + " = " + StringTools.trim(retVals[i]) + ";");
          }
        }
      } else if (line != "") {
        if (!line.endsWith(";")) line += ";";
        newLines.push(line);
      }
    }
    
    var finalCode = newLines.join(" ");
    return finalCode;
  }

  // ------------------------------------------------------------------
  // Compilation (Tokenize -> Parse -> Pack into Int64 SWAR blocks)
  // ------------------------------------------------------------------
  function compile(codeStr:String) {
    var tokens = tokenize(codeStr);
    var pos = 0;
    
    while (pos < tokens.length) {
      var token = tokens[pos];
      if (token == ";") { pos++; continue; }
      
      var eqPos = -1;
      var commaBeforeEq = false;
      for (j in pos...tokens.length) {
        if (tokens[j] == "=") { eqPos = j; break; }
        if (tokens[j] == ";") break;
        if (tokens[j] == ",") commaBeforeEq = true;
      }
      
      if (eqPos != -1 && (eqPos == pos + 1 || commaBeforeEq)) {
        var targets = [];
        for (j in pos...eqPos) { if (tokens[j] != ",") targets.push(tokens[j]); }
        
        pos = eqPos + 1;
        var exprs = [];
        var currentExprStart = pos;
        var depth = 0;
        while (pos < tokens.length) {
          var t = tokens[pos];
          if (t == "(") depth++;
          else if (t == ")") depth--;
          else if (t == "," && depth == 0) {
            exprs.push(tokens.slice(currentExprStart, pos));
            currentExprStart = pos + 1;
          } else if (t == ";" && depth == 0) break;
          pos++;
        }
        exprs.push(tokens.slice(currentExprStart, pos));
        if (pos < tokens.length && tokens[pos] == ";") pos++;
        
        for (expr in exprs) parseExpressionTokens(expr);
        
        for (i in 0...targets.length) {
          var target = targets[targets.length - 1 - i];
          var vIdx = getVarIndex(target);
          opcodeBuffer.push(0x20); // SET_VAR
          argsBuffer.push(vIdx);
        }
      } else {
        var exprStart = pos;
        while (pos < tokens.length && tokens[pos] != ";") pos++;
        parseExpressionTokens(tokens.slice(exprStart, pos));
        if (pos < tokens.length && tokens[pos] == ";") pos++;
      }
    }
    
    // Pack the 8-bit opcodes into Int64 blocks (8 slots per block)
    var len = opcodeBuffer.length;
    var numBlocks = Math.ceil(len / 8);
    for (i in 0...numBlocks) {
      var b0 = i * 8 < len ? opcodeBuffer[i * 8] : 0x33;
      var b1 = i * 8 + 1 < len ? opcodeBuffer[i * 8 + 1] : 0x33;
      var b2 = i * 8 + 2 < len ? opcodeBuffer[i * 8 + 2] : 0x33;
      var b3 = i * 8 + 3 < len ? opcodeBuffer[i * 8 + 3] : 0x33;
      var low = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
      
      var b4 = i * 8 + 4 < len ? opcodeBuffer[i * 8 + 4] : 0x33;
      var b5 = i * 8 + 5 < len ? opcodeBuffer[i * 8 + 5] : 0x33;
      var b6 = i * 8 + 6 < len ? opcodeBuffer[i * 8 + 6] : 0x33;
      var b7 = i * 8 + 7 < len ? opcodeBuffer[i * 8 + 7] : 0x33;
      var high = b4 | (b5 << 8) | (b6 << 16) | (b7 << 24);
      
      codeBlocks.push(Int64.make(high, low));
    }
    args = argsBuffer;
  }

  var currentPos:Int = 0;

  function tokenize(codeStr:String):Array<String> {
    var tokens:Array<String> = [];
    var current = "";
    for (i in 0...codeStr.length) {
      var c = codeStr.charAt(i);
      if (c == " " || c == "\t" || c == "\n" || c == "\r") {
        if (current != "") { tokens.push(current); current = ""; }
      } else if (c == "+" || c == "-" || c == "*" || c == "/" || c == "%" || c == "(" || c == ")" || c == "=" || c == "," || c == ";") {
        if (current != "") { tokens.push(current); current = ""; }
        tokens.push(c);
      } else {
        current += c;
      }
    }
    if (current != "") tokens.push(current);
    return tokens;
  }

  function parseExpressionTokens(tokens:Array<String>):Void {
    currentPos = 0;
    var output:Array<Int> = [];
    var operators:Array<String> = [];
    
    while (currentPos < tokens.length) {
      var token = tokens[currentPos];
      if (token == ";") break;
      
      if (isNumber(token)) {
        var val = Std.parseFloat(token);
        var cIdx = constants.length;
        constants.push(val);
        output.push(0x10); // PUSH_CONST
        argsBuffer.push(cIdx);
        currentPos++;
      }
      else if (token.toLowerCase() == "not") {
        operators.push(token);
        currentPos++;
      }
      else if (isFunction(token)) {
        operators.push(token);
        currentPos++;
      }
      else if (isVariable(token)) {
        var vIdx = getVarIndex(token);
        output.push(0x11); // PUSH_VAR
        argsBuffer.push(vIdx);
        currentPos++;
      } 
      else if (token == "(") {
        operators.push(token);
        currentPos++;
      } 
      else if (token == ")") {
        while (operators.length > 0 && operators[operators.length - 1] != "(") {
          output.push(Int64.toInt(getOpOpcode(operators.pop())));
        }
        if (operators.length > 0) operators.pop();
        
        if (operators.length > 0 && isFunction(operators[operators.length - 1])) {
          output.push(Int64.toInt(getOpOpcode(operators.pop())));
        }
        currentPos++;
      } 
      else if (token == ",") {
        while (operators.length > 0 && operators[operators.length - 1] != "(") {
          output.push(Int64.toInt(getOpOpcode(operators.pop())));
        }
        currentPos++;
      } 
      else if (isOperator(token) || token.toLowerCase() == "and" || token.toLowerCase() == "or") {
        if ((token == "-" || token == "+") && (currentPos == 0 || isPrevTokenOperator(tokens, currentPos))) {
          if (token == "-") {
            output.push(0x10); // PUSH_CONST
            argsBuffer.push(constants.length);
            constants.push(0.0);
            token = "-"; 
          } else {
            currentPos++;
            continue; 
          }
        }
        
        while (operators.length > 0 && precedence(operators[operators.length - 1]) >= precedence(token)) {
          output.push(Int64.toInt(getOpOpcode(operators.pop())));
        }
        operators.push(token);
        currentPos++;
      } 
      else {
        currentPos++; 
      }
    }
    
    while (operators.length > 0) {
      output.push(Int64.toInt(getOpOpcode(operators.pop())));
    }
    
    for (j in 0...output.length) opcodeBuffer.push(output[j]);
  }

  function isNumber(s:String):Bool return ~/^-?[0-9]+(\.[0-9]+)?$/.match(s);

  function isVariable(s:String):Bool {
    if (isFunction(s)) return false;
    var lower = s.toLowerCase();
    if (lower == "and" || lower == "or" || lower == "not") return false;
    return ~/^[a-zA-Z_][a-zA-Z0-9_]*$/.match(s);
  }

  function getVarIndex(name:String):Int {
    var lower = name.toLowerCase();
    var idx = -1;
    
    switch(lower) {
      case "x": idx = 0;
      case "y": idx = 1;
      case "scale": idx = 2;
      case "sustainrot", "sustain_rotation": idx = 3;
      case "scrollmultiplier", "scroll_multiplier": idx = 4;
      case "diff": idx = 5;
      case "scrollspeed", "scroll_speed": idx = 6;
      case "receptorx", "receptor_x": idx = 7;
      case "receptory", "receptor_y": idx = 8;
      case "index": idx = 9;
      case "type": idx = 10;
    }
    
    if (idx == -1) {
      if (!varMap.exists(lower)) {
        varMap.set(lower, varCount + 100);
        varCount++;
      }
      idx = varMap.get(lower);
    }
    return idx;
  }

  function isOperator(s:String):Bool return s == "+" || s == "-" || s == "*" || s == "/" || s == "%";

  function isFunction(s:String):Bool {
    s = s.toLowerCase();
    return s == "sin" || s == "cos" || s == "min" || s == "max" || s == "abs" ||
           s == "math.sin" || s == "math.cos" || s == "math.min" || s == "math.max" || s == "math.abs" ||
           s == "__abort" || s == "__abort_if_not_eq" || s == "__abort_if_eq";
  }

  function isPrevTokenOperator(tokens:Array<String>, pos:Int):Bool {
    if (pos == 0) return true;
    var prev = tokens[pos - 1];
    var lowerPrev = prev.toLowerCase();
    return prev == "(" || prev == "=" || prev == "," || prev == ";" || 
           isOperator(prev) || isFunction(prev) || 
           lowerPrev == "not" || lowerPrev == "and" || lowerPrev == "or";
  }

  function precedence(op:String):Int {
    return switch(op.toLowerCase()) {
      case "or": 1;
      case "and": 2;
      case "+", "-": 3;
      case "*", "/", "%": 4;
      case "not", "sin", "cos", "min", "max", "abs", "math.sin", "math.cos", "math.min", "math.max", "math.abs", 
           "__abort", "__abort_if_not_eq", "__abort_if_eq": 5;
      default: 0;
    }
  }

  function getOpOpcode(op:String):Int64 {
    return switch(op.toLowerCase()) {
      case "+": OnValue.PLUS;
      case "-": OnValue.MINUS;
      case "*": OnValue.TIMES;
      case "/": OnValue.DIVIDE;
      case "%": OnValue.MOD;
      case "sin", "math.sin": OnValue.SIN;
      case "cos", "math.cos": OnValue.COS;
      case "min", "math.min": OnValue.MIN;
      case "max", "math.max": OnValue.MAX;
      case "abs", "math.abs": OnValue.ABS;
      case "not": OnValue.NOT;
      case "and": OnValue.AND;
      case "or": OnValue.OR;
      case "__abort": OnValue.ABORT;
      case "__abort_if_not_eq": OnValue.ABORT_IF_NOT_EQ;
      case "__abort_if_eq": OnValue.ABORT_IF_EQ;
      default: OnValue.PLUS;
    }
  }

  // ------------------------------------------------------------------
  // STRICTLY INLINED 8-SLOT SWAR EXECUTION LOOP
  // ------------------------------------------------------------------
  public function run(diff:Float, scrollSpeed:Float, receptorX:Float, receptorY:Float, index:Float, type:Float, baseResult:NoteFormulaResult):NoteFormulaResult {
    locals[0] = baseResult.x;
    locals[1] = baseResult.y;
    locals[2] = baseResult.scale;
    locals[3] = baseResult.sustainRot;
    locals[4] = baseResult.scrollMultiplier;
    locals[5] = diff;
    locals[6] = scrollSpeed;
    locals[7] = receptorX;
    locals[8] = receptorY;
    locals[9] = index;
    locals[10] = type;

    stackPtr = 0;
    argPtr = 0;
    var blockPtr = 0;
    var blocksLen = codeBlocks.length;
    
    while (blockPtr < blocksLen) {
      var block = codeBlocks[blockPtr++];
      
      // Extract the 32-bit halves ONCE. No overflow checks!
      var low = Int64.getLow(block);
      var high = Int64.getHigh(block);
      
      // ----------------------------------------------------
      // UNROLLED SLOT 0 (Native 32-bit shift & mask)
      // ----------------------------------------------------
      var op = low & 0xFF;
      switch (op) {
        case 0x10: stack[stackPtr++] = constants[args[argPtr++]];
        case 0x11: stack[stackPtr++] = locals[args[argPtr++]];
        case 0x20: locals[args[argPtr++]] = stack[--stackPtr];
        case 0x30: return null;
        case 0x31: var b = stack[--stackPtr]; var a = stack[--stackPtr]; if (a != b) return null;
        case 0x32: var b = stack[--stackPtr]; var a = stack[--stackPtr]; if (a == b) return null;
        case 0x00: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a + b;
        case 0x01: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a - b;
        case 0x02: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a * b;
        case 0x03: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = b != 0 ? a / b : 0;
        case 0x04: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = b != 0 ? a % b : 0;
        case 0x05: stack[stackPtr - 1] = Math.sin(stack[stackPtr - 1]);
        case 0x06: stack[stackPtr - 1] = Math.cos(stack[stackPtr - 1]);
        case 0x07: var b = stack[--stackPtr]; if (b < stack[stackPtr - 1]) stack[stackPtr - 1] = b;
        case 0x08: var b = stack[--stackPtr]; if (b > stack[stackPtr - 1]) stack[stackPtr - 1] = b;
        case 0x09: stack[stackPtr - 1] = Math.abs(stack[stackPtr - 1]);
        case 0x0A: stack[stackPtr - 1] = stack[stackPtr - 1] == 0 ? 1.0 : 0.0;
        case 0x0B: var b = stack[--stackPtr]; var a = stack[stackPtr - 1]; stack[stackPtr - 1] = a != 0 ? b : 0.0;
        case 0x0C: var b = stack[--stackPtr]; var a = stack[stackPtr - 1]; stack[stackPtr - 1] = a != 0 ? a : b;
        case 0x33: {} // NOP
      }
      
      // ----------------------------------------------------
      // UNROLLED SLOT 1
      // ----------------------------------------------------
      op = (low >> 8) & 0xFF;
      switch (op) {
        case 0x10: stack[stackPtr++] = constants[args[argPtr++]];
        case 0x11: stack[stackPtr++] = locals[args[argPtr++]];
        case 0x20: locals[args[argPtr++]] = stack[--stackPtr];
        case 0x30: return null;
        case 0x31: var b = stack[--stackPtr]; var a = stack[--stackPtr]; if (a != b) return null;
        case 0x32: var b = stack[--stackPtr]; var a = stack[--stackPtr]; if (a == b) return null;
        case 0x00: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a + b;
        case 0x01: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a - b;
        case 0x02: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a * b;
        case 0x03: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = b != 0 ? a / b : 0;
        case 0x04: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = b != 0 ? a % b : 0;
        case 0x05: stack[stackPtr - 1] = Math.sin(stack[stackPtr - 1]);
        case 0x06: stack[stackPtr - 1] = Math.cos(stack[stackPtr - 1]);
        case 0x07: var b = stack[--stackPtr]; if (b < stack[stackPtr - 1]) stack[stackPtr - 1] = b;
        case 0x08: var b = stack[--stackPtr]; if (b > stack[stackPtr - 1]) stack[stackPtr - 1] = b;
        case 0x09: stack[stackPtr - 1] = Math.abs(stack[stackPtr - 1]);
        case 0x0A: stack[stackPtr - 1] = stack[stackPtr - 1] == 0 ? 1.0 : 0.0;
        case 0x0B: var b = stack[--stackPtr]; var a = stack[stackPtr - 1]; stack[stackPtr - 1] = a != 0 ? b : 0.0;
        case 0x0C: var b = stack[--stackPtr]; var a = stack[stackPtr - 1]; stack[stackPtr - 1] = a != 0 ? a : b;
        case 0x33: {}
      }

      // ----------------------------------------------------
      // UNROLLED SLOT 2
      // ----------------------------------------------------
      op = (low >> 16) & 0xFF;
      switch (op) {
        case 0x10: stack[stackPtr++] = constants[args[argPtr++]];
        case 0x11: stack[stackPtr++] = locals[args[argPtr++]];
        case 0x20: locals[args[argPtr++]] = stack[--stackPtr];
        case 0x30: return null;
        case 0x31: var b = stack[--stackPtr]; var a = stack[--stackPtr]; if (a != b) return null;
        case 0x32: var b = stack[--stackPtr]; var a = stack[--stackPtr]; if (a == b) return null;
        case 0x00: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a + b;
        case 0x01: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a - b;
        case 0x02: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a * b;
        case 0x03: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = b != 0 ? a / b : 0;
        case 0x04: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = b != 0 ? a % b : 0;
        case 0x05: stack[stackPtr - 1] = Math.sin(stack[stackPtr - 1]);
        case 0x06: stack[stackPtr - 1] = Math.cos(stack[stackPtr - 1]);
        case 0x07: var b = stack[--stackPtr]; if (b < stack[stackPtr - 1]) stack[stackPtr - 1] = b;
        case 0x08: var b = stack[--stackPtr]; if (b > stack[stackPtr - 1]) stack[stackPtr - 1] = b;
        case 0x09: stack[stackPtr - 1] = Math.abs(stack[stackPtr - 1]);
        case 0x0A: stack[stackPtr - 1] = stack[stackPtr - 1] == 0 ? 1.0 : 0.0;
        case 0x0B: var b = stack[--stackPtr]; var a = stack[stackPtr - 1]; stack[stackPtr - 1] = a != 0 ? b : 0.0;
        case 0x0C: var b = stack[--stackPtr]; var a = stack[stackPtr - 1]; stack[stackPtr - 1] = a != 0 ? a : b;
        case 0x33: {}
      }

      // ----------------------------------------------------
      // UNROLLED SLOT 3 (Unsigned shift >>> for top byte)
      // ----------------------------------------------------
      op = (low >>> 24) & 0xFF;
      switch (op) {
        case 0x10: stack[stackPtr++] = constants[args[argPtr++]];
        case 0x11: stack[stackPtr++] = locals[args[argPtr++]];
        case 0x20: locals[args[argPtr++]] = stack[--stackPtr];
        case 0x30: return null;
        case 0x31: var b = stack[--stackPtr]; var a = stack[--stackPtr]; if (a != b) return null;
        case 0x32: var b = stack[--stackPtr]; var a = stack[--stackPtr]; if (a == b) return null;
        case 0x00: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a + b;
        case 0x01: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a - b;
        case 0x02: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a * b;
        case 0x03: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = b != 0 ? a / b : 0;
        case 0x04: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = b != 0 ? a % b : 0;
        case 0x05: stack[stackPtr - 1] = Math.sin(stack[stackPtr - 1]);
        case 0x06: stack[stackPtr - 1] = Math.cos(stack[stackPtr - 1]);
        case 0x07: var b = stack[--stackPtr]; if (b < stack[stackPtr - 1]) stack[stackPtr - 1] = b;
        case 0x08: var b = stack[--stackPtr]; if (b > stack[stackPtr - 1]) stack[stackPtr - 1] = b;
        case 0x09: stack[stackPtr - 1] = Math.abs(stack[stackPtr - 1]);
        case 0x0A: stack[stackPtr - 1] = stack[stackPtr - 1] == 0 ? 1.0 : 0.0;
        case 0x0B: var b = stack[--stackPtr]; var a = stack[stackPtr - 1]; stack[stackPtr - 1] = a != 0 ? b : 0.0;
        case 0x0C: var b = stack[--stackPtr]; var a = stack[stackPtr - 1]; stack[stackPtr - 1] = a != 0 ? a : b;
        case 0x33: {}
      }

      // ----------------------------------------------------
      // UNROLLED SLOT 4
      // ----------------------------------------------------
      op = high & 0xFF;
      switch (op) {
        case 0x10: stack[stackPtr++] = constants[args[argPtr++]];
        case 0x11: stack[stackPtr++] = locals[args[argPtr++]];
        case 0x20: locals[args[argPtr++]] = stack[--stackPtr];
        case 0x30: return null;
        case 0x31: var b = stack[--stackPtr]; var a = stack[--stackPtr]; if (a != b) return null;
        case 0x32: var b = stack[--stackPtr]; var a = stack[--stackPtr]; if (a == b) return null;
        case 0x00: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a + b;
        case 0x01: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a - b;
        case 0x02: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a * b;
        case 0x03: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = b != 0 ? a / b : 0;
        case 0x04: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = b != 0 ? a % b : 0;
        case 0x05: stack[stackPtr - 1] = Math.sin(stack[stackPtr - 1]);
        case 0x06: stack[stackPtr - 1] = Math.cos(stack[stackPtr - 1]);
        case 0x07: var b = stack[--stackPtr]; if (b < stack[stackPtr - 1]) stack[stackPtr - 1] = b;
        case 0x08: var b = stack[--stackPtr]; if (b > stack[stackPtr - 1]) stack[stackPtr - 1] = b;
        case 0x09: stack[stackPtr - 1] = Math.abs(stack[stackPtr - 1]);
        case 0x0A: stack[stackPtr - 1] = stack[stackPtr - 1] == 0 ? 1.0 : 0.0;
        case 0x0B: var b = stack[--stackPtr]; var a = stack[stackPtr - 1]; stack[stackPtr - 1] = a != 0 ? b : 0.0;
        case 0x0C: var b = stack[--stackPtr]; var a = stack[stackPtr - 1]; stack[stackPtr - 1] = a != 0 ? a : b;
        case 0x33: {}
      }

      // ----------------------------------------------------
      // UNROLLED SLOT 5
      // ----------------------------------------------------
      op = (high >> 8) & 0xFF;
      switch (op) {
        case 0x10: stack[stackPtr++] = constants[args[argPtr++]];
        case 0x11: stack[stackPtr++] = locals[args[argPtr++]];
        case 0x20: locals[args[argPtr++]] = stack[--stackPtr];
        case 0x30: return null;
        case 0x31: var b = stack[--stackPtr]; var a = stack[--stackPtr]; if (a != b) return null;
        case 0x32: var b = stack[--stackPtr]; var a = stack[--stackPtr]; if (a == b) return null;
        case 0x00: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a + b;
        case 0x01: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a - b;
        case 0x02: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a * b;
        case 0x03: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = b != 0 ? a / b : 0;
        case 0x04: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = b != 0 ? a % b : 0;
        case 0x05: stack[stackPtr - 1] = Math.sin(stack[stackPtr - 1]);
        case 0x06: stack[stackPtr - 1] = Math.cos(stack[stackPtr - 1]);
        case 0x07: var b = stack[--stackPtr]; if (b < stack[stackPtr - 1]) stack[stackPtr - 1] = b;
        case 0x08: var b = stack[--stackPtr]; if (b > stack[stackPtr - 1]) stack[stackPtr - 1] = b;
        case 0x09: stack[stackPtr - 1] = Math.abs(stack[stackPtr - 1]);
        case 0x0A: stack[stackPtr - 1] = stack[stackPtr - 1] == 0 ? 1.0 : 0.0;
        case 0x0B: var b = stack[--stackPtr]; var a = stack[stackPtr - 1]; stack[stackPtr - 1] = a != 0 ? b : 0.0;
        case 0x0C: var b = stack[--stackPtr]; var a = stack[stackPtr - 1]; stack[stackPtr - 1] = a != 0 ? a : b;
        case 0x33: {}
      }

      // ----------------------------------------------------
      // UNROLLED SLOT 6
      // ----------------------------------------------------
      op = (high >> 16) & 0xFF;
      switch (op) {
        case 0x10: stack[stackPtr++] = constants[args[argPtr++]];
        case 0x11: stack[stackPtr++] = locals[args[argPtr++]];
        case 0x20: locals[args[argPtr++]] = stack[--stackPtr];
        case 0x30: return null;
        case 0x31: var b = stack[--stackPtr]; var a = stack[--stackPtr]; if (a != b) return null;
        case 0x32: var b = stack[--stackPtr]; var a = stack[--stackPtr]; if (a == b) return null;
        case 0x00: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a + b;
        case 0x01: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a - b;
        case 0x02: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a * b;
        case 0x03: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = b != 0 ? a / b : 0;
        case 0x04: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = b != 0 ? a % b : 0;
        case 0x05: stack[stackPtr - 1] = Math.sin(stack[stackPtr - 1]);
        case 0x06: stack[stackPtr - 1] = Math.cos(stack[stackPtr - 1]);
        case 0x07: var b = stack[--stackPtr]; if (b < stack[stackPtr - 1]) stack[stackPtr - 1] = b;
        case 0x08: var b = stack[--stackPtr]; if (b > stack[stackPtr - 1]) stack[stackPtr - 1] = b;
        case 0x09: stack[stackPtr - 1] = Math.abs(stack[stackPtr - 1]);
        case 0x0A: stack[stackPtr - 1] = stack[stackPtr - 1] == 0 ? 1.0 : 0.0;
        case 0x0B: var b = stack[--stackPtr]; var a = stack[stackPtr - 1]; stack[stackPtr - 1] = a != 0 ? b : 0.0;
        case 0x0C: var b = stack[--stackPtr]; var a = stack[stackPtr - 1]; stack[stackPtr - 1] = a != 0 ? a : b;
        case 0x33: {}
      }

      // ----------------------------------------------------
      // UNROLLED SLOT 7 (Unsigned shift >>> for top byte)
      // ----------------------------------------------------
      op = (high >>> 24) & 0xFF;
      switch (op) {
        case 0x10: stack[stackPtr++] = constants[args[argPtr++]];
        case 0x11: stack[stackPtr++] = locals[args[argPtr++]];
        case 0x20: locals[args[argPtr++]] = stack[--stackPtr];
        case 0x30: return null;
        case 0x31: var b = stack[--stackPtr]; var a = stack[--stackPtr]; if (a != b) return null;
        case 0x32: var b = stack[--stackPtr]; var a = stack[--stackPtr]; if (a == b) return null;
        case 0x00: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a + b;
        case 0x01: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a - b;
        case 0x02: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a * b;
        case 0x03: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = b != 0 ? a / b : 0;
        case 0x04: var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = b != 0 ? a % b : 0;
        case 0x05: stack[stackPtr - 1] = Math.sin(stack[stackPtr - 1]);
        case 0x06: stack[stackPtr - 1] = Math.cos(stack[stackPtr - 1]);
        case 0x07: var b = stack[--stackPtr]; if (b < stack[stackPtr - 1]) stack[stackPtr - 1] = b;
        case 0x08: var b = stack[--stackPtr]; if (b > stack[stackPtr - 1]) stack[stackPtr - 1] = b;
        case 0x09: stack[stackPtr - 1] = Math.abs(stack[stackPtr - 1]);
        case 0x0A: stack[stackPtr - 1] = stack[stackPtr - 1] == 0 ? 1.0 : 0.0;
        case 0x0B: var b = stack[--stackPtr]; var a = stack[stackPtr - 1]; stack[stackPtr - 1] = a != 0 ? b : 0.0;
        case 0x0C: var b = stack[--stackPtr]; var a = stack[stackPtr - 1]; stack[stackPtr - 1] = a != 0 ? a : b;
        case 0x33: {}
      }
    }
    
    baseResult.x = locals[0];
    baseResult.y = locals[1];
    baseResult.scale = locals[2];
    baseResult.sustainRot = locals[3];
    baseResult.scrollMultiplier = locals[4];
    
    return baseResult;
  }
}