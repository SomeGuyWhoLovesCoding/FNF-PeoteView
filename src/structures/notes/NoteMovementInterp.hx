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
    code = ~/if\s+\(*\s*([a-zA-Z0-9_]+)\s*\)*\s*~=\s*([0-9.]+)\s+then\s+return\s+nil\s+end/gi.replace(code, "_ab_neq($1, $2);");
    code = ~/if\s+\(*\s*([a-zA-Z0-9_]+)\s*\)*\s*==\s*([0-9.]+)\s+then\s+return\s+nil\s+end/gi.replace(code, "_ab_eq($1, $2);");
    code = ~/\breturn\s+nil\b/gi.replace(code, "_ab();");
    
    // 6. Remove Lua-Specific keywords
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
    var len = tokens.length;
    
    while (pos < len) {
      var token = tokens[pos];
      if (token == ";") { pos++; continue; }
      
      // Single-pass statement boundary detection (O(N) instead of O(N²))
      var stmtEnd = pos;
      var eqPos = -1;
      var commaBeforeEq = false;
      while (stmtEnd < len && tokens[stmtEnd] != ";") {
        if (tokens[stmtEnd] == "=") {
          if (eqPos == -1) eqPos = stmtEnd;
        } else if (tokens[stmtEnd] == ",") {
          if (eqPos == -1) commaBeforeEq = true;
        }
        stmtEnd++;
      }
      
      if (eqPos != -1 && (eqPos == pos + 1 || commaBeforeEq)) {
        var targets = [];
        for (j in pos...eqPos) { 
          if (tokens[j] != ",") targets.push(tokens[j]); 
        }
        
        pos = eqPos + 1;
        var exprs = [];
        var currentExprStart = pos;
        var depth = 0;
        while (pos < stmtEnd) {
          var t = tokens[pos];
          if (t == "(") depth++;
          else if (t == ")") depth--;
          else if (t == "," && depth == 0) {
            exprs.push(tokens.slice(currentExprStart, pos));
            currentExprStart = pos + 1;
          }
          pos++;
        }
        exprs.push(tokens.slice(currentExprStart, pos));
        pos = stmtEnd + 1; // skip ';'
        
        for (expr in exprs) parseExpressionTokens(expr);
        
        var targetsLen = targets.length;
        for (i in 0...targetsLen) {
          var target = targets[targetsLen - 1 - i];
          var vIdx = getVarIndex(target);
          opcodeBuffer.push(0x20); // SET_VAR
          argsBuffer.push(vIdx);
        }
      } else {
        parseExpressionTokens(tokens.slice(pos, stmtEnd));
        pos = stmtEnd + 1; // skip ';'
      }
    }
    
    // Pack the 8-bit opcodes into Int64 blocks (8 slots per block) using bitwise ops
    var opLen = opcodeBuffer.length;
    var numBlocks = (opLen + 7) >> 3;
    for (i in 0...numBlocks) {
      var idx = i << 3;
      var b0 = idx < opLen ? opcodeBuffer[idx] : 0x33;
      var b1 = idx + 1 < opLen ? opcodeBuffer[idx + 1] : 0x33;
      var b2 = idx + 2 < opLen ? opcodeBuffer[idx + 2] : 0x33;
      var b3 = idx + 3 < opLen ? opcodeBuffer[idx + 3] : 0x33;
      var low = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
      
      var b4 = idx + 4 < opLen ? opcodeBuffer[idx + 4] : 0x33;
      var b5 = idx + 5 < opLen ? opcodeBuffer[idx + 5] : 0x33;
      var b6 = idx + 6 < opLen ? opcodeBuffer[idx + 6] : 0x33;
      var b7 = idx + 7 < opLen ? opcodeBuffer[idx + 7] : 0x33;
      var high = b4 | (b5 << 8) | (b6 << 16) | (b7 << 24);
      
      codeBlocks.push(Int64.make(high, low));
    }
    args = argsBuffer;
  }

  var currentPos:Int = 0;

  // Zero-allocation tokenization using charCodeAt and substring
  function tokenize(codeStr:String):Array<String> {
    var tokens:Array<String> = [];
    var len = codeStr.length;
    var start = 0;
    var i = 0;
    while (i < len) {
      var c = codeStr.charCodeAt(i);
      if (c == 32 || c == 9 || c == 10 || c == 13) { // space, tab, newline, cr
        if (i > start) tokens.push(codeStr.substring(start, i));
        start = i + 1;
      } else if (c == 43 || c == 45 || c == 42 || c == 47 || c == 37 || c == 40 || c == 41 || c == 61 || c == 44 || c == 59) { // + - * / % ( ) = , ;
        if (i > start) tokens.push(codeStr.substring(start, i));
        tokens.push(codeStr.charAt(i));
        start = i + 1;
      }
      i++;
    }
    if (i > start) tokens.push(codeStr.substring(start, i));
    return tokens;
  }

  function parseExpressionTokens(tokens:Array<String>):Void {
    currentPos = 0;
    var output:Array<Int> = [];
    var operators:Array<String> = [];
    var len = tokens.length;
    
    while (currentPos < len) {
      var token = tokens[currentPos];
      if (token == ";") break;
      
      var lowerToken = token.toLowerCase();
      
      if (isNumber(token)) {
        var val = Std.parseFloat(token);
        var cIdx = constants.length;
        constants.push(val);
        output.push(0x10); // PUSH_CONST
        argsBuffer.push(cIdx);
        currentPos++;
      }
      else if (lowerToken == "not") {
        operators.push(token);
        currentPos++;
      }
      else if (isFunction(lowerToken)) {
        operators.push(token);
        currentPos++;
      }
      else if (isVariable(token, lowerToken)) {
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
          output.push(getOpOpcode(operators.pop()));
        }
        if (operators.length > 0) operators.pop();
        
        if (operators.length > 0 && isFunction(operators[operators.length - 1].toLowerCase())) {
          output.push(getOpOpcode(operators.pop()));
        }
        currentPos++;
      } 
      else if (token == ",") {
        while (operators.length > 0 && operators[operators.length - 1] != "(") {
          output.push(getOpOpcode(operators.pop()));
        }
        currentPos++;
      } 
      else if (isOperator(token) || lowerToken == "and" || lowerToken == "or") {
        if ((token == "-" || token == "+") && (currentPos == 0 || isPrevTokenOperator(tokens, currentPos))) {
          if (token == "-") {
            output.push(0x10); // PUSH_CONST
            argsBuffer.push(constants.length);
            constants.push(0.0);
            // token remains "-" so it acts as a binary minus with 0.0 on the left
          } else {
            currentPos++;
            continue; 
          }
        }
        
        var prec = precedence(lowerToken);
        while (operators.length > 0) {
          var topOp = operators[operators.length - 1];
          if (precedence(topOp.toLowerCase()) >= prec) {
            output.push(getOpOpcode(operators.pop()));
          } else {
            break;
          }
        }
        operators.push(token);
        currentPos++;
      } 
      else {
        currentPos++; 
      }
    }
    
    while (operators.length > 0) {
      output.push(getOpOpcode(operators.pop()));
    }
    
    var outLen = output.length;
    for (j in 0...outLen) opcodeBuffer.push(output[j]);
  }

  // Ultra-fast number validation without regex
  function isNumber(s:String):Bool {
    var len = s.length;
    if (len == 0) return false;
    var i = 0;
    var c = s.charCodeAt(i);
    if (c == 45) { // '-'
      i++;
      if (i == len) return false;
      c = s.charCodeAt(i);
    }
    var hasDigit = false;
    var hasDot = false;
    while (i < len) {
      c = s.charCodeAt(i);
      if (c >= 48 && c <= 57) {
        hasDigit = true;
      } else if (c == 46) { // '.'
        if (hasDot) return false;
        hasDot = true;
      } else {
        return false;
      }
      i++;
    }
    return hasDigit;
  }

  // Ultra-fast variable validation without regex
  function isVariable(s:String, lower:String):Bool {
    var len = s.length;
    if (len == 0) return false;
    var c = s.charCodeAt(0);
    if (!((c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95)) return false;
    
    var i = 1;
    while (i < len) {
      c = s.charCodeAt(i);
      if (!((c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95)) return false;
      i++;
    }
    
    if (lower == "and" || lower == "or" || lower == "not") return false;
    if (isFunction(lower)) return false;
    return true;
  }

  function getVarIndex(name:String):Int {
    var lower = name.toLowerCase();
    var idx = -1;
    
    if (lower == "x") idx = 0;
    else if (lower == "y") idx = 1;
    else if (lower == "scale") idx = 2;
    else if (lower == "sustainrot" || lower == "sustain_rotation") idx = 3;
    else if (lower == "scrollmultiplier" || lower == "scroll_multiplier") idx = 4;
    else if (lower == "diff") idx = 5;
    else if (lower == "scrollspeed" || lower == "scroll_speed") idx = 6;
    else if (lower == "receptorx" || lower == "receptor_x") idx = 7;
    else if (lower == "receptory" || lower == "receptor_y") idx = 8;
    else if (lower == "index") idx = 9;
    else if (lower == "type") idx = 10;
    
    if (idx == -1) {
      if (!varMap.exists(lower)) {
        varMap.set(lower, varCount + 100);
        varCount++;
      }
      idx = varMap.get(lower);
    }
    return idx;
  }

  inline function isOperator(s:String):Bool {
    var c = s.charCodeAt(0);
    return s.length == 1 && (c == 43 || c == 45 || c == 42 || c == 47 || c == 37); // + - * / %
  }

  inline function isFunction(lower:String):Bool {
    return lower == "sin" || lower == "cos" || lower == "min" || lower == "max" || lower == "abs" ||
           lower == "math.sin" || lower == "math.cos" || lower == "math.min" || lower == "math.max" || lower == "math.abs" ||
           lower == "_ab" || lower == "_ab_neq" || lower == "_ab_eq";
  }

  // Ultra-fast previous token operator check without regex
  function isPrevTokenOperator(tokens:Array<String>, pos:Int):Bool {
    if (pos == 0) return true;
    var prev = tokens[pos - 1];
    var len = prev.length;
    if (len == 1) {
      var c = prev.charCodeAt(0);
      // ( = , ; + - * / %
      if (c == 40 || c == 61 || c == 44 || c == 59 || c == 43 || c == 45 || c == 42 || c == 47 || c == 37) return true;
    }
    var lowerPrev = prev.toLowerCase();
    return lowerPrev == "not" || lowerPrev == "and" || lowerPrev == "or" || isFunction(lowerPrev);
  }

  inline function precedence(op:String):Int {
    return switch(op) {
      case "or": 1;
      case "and": 2;
      case "+", "-": 3;
      case "*", "/", "%": 4;
      case "not", "sin", "cos", "min", "max", "abs", "math.sin", "math.cos", "math.min", "math.max", "math.abs", 
           "__abort", "_ab_neq", "_ab_eq": 5;
      default: 0;
    }
  }

  // Returns native Int to avoid Int64 overhead during compilation
  inline function getOpOpcode(op:String):Int {
    return switch(op) {
      case "+": 0x00;
      case "-": 0x01;
      case "*": 0x02;
      case "/": 0x03;
      case "%": 0x04;
      case "sin", "math.sin": 0x05;
      case "cos", "math.cos": 0x06;
      case "min", "math.min": 0x07;
      case "max", "math.max": 0x08;
      case "abs", "math.abs": 0x09;
      case "not": 0x0A;
      case "and": 0x0B;
      case "or": 0x0C;
      case "__abort": 0x30;
      case "__abort_if_not_eq": 0x31;
      case "__abort_if_eq": 0x32;
      default: 0x33;
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
