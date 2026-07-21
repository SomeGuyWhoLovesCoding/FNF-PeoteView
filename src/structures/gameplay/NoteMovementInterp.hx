package structures.gameplay;

using StringTools;

// ------------------------------------------------------------------
// Bytecode Opcodes
// ------------------------------------------------------------------
enum abstract OnValue(Int64) from Int64 to Int64 {
  var PLUS = 0x1000;
  var MINUS = 0x1001;
  var TIMES = 0x1002;
  var DIVIDE = 0x1003;
  var MOD = 0x1004;
  var SIN = 0x1005;
  var COS = 0x1006;
  var MIN = 0x1007;
  var MAX = 0x1008;
  var NOT = 0x1009;
  var AND = 0x100A;
  var OR = 0x100B;
  
  var PUSH_CONST = 0x2000;
  var PUSH_VAR = 0x4000;
  var SET_VAR = 0x5000;
  
  var ABORT = 0x6000;
  var ABORT_IF_NOT_EQ = 0x6001;
  var ABORT_IF_EQ = 0x6002;
}

// ------------------------------------------------------------------
// Lightweight Bytecode Compiler & Interpreter
// Written by Qwen 3.7-plus a limited manual lua interpreter that
// was done specifically for the function format of noteMoveFormula.
// ------------------------------------------------------------------
@:final
class NoteMovementInterp {
  var code:Array<Int64> = [];
  var constants:Array<Float> = [];
  var varMap:FakeStringMap<Int>;
  var varCount:Int;

  // Pre-allocated memory for zero-allocation execution
  var locals:Vector<Float>;
  var stack:Vector<Float>;
  var stackPtr:Int;

  public function new(codeStr:String) {
    varMap = new FakeStringMap<Int>();
    varCount = 0;
    compile(preprocess(codeStr));
    
    // Allocate execution buffers exactly once based on compiled requirements
    locals = new Vector<Float>(varCount + 100);
    stack = new Vector<Float>(512); // 512 depth is more than enough for any modchart
    
    // trace("=== [NoteMovementInterp] Bytecode Compilation ===");
    // trace("Constants Pool: " + constants);
    // trace("Variable Map: " + varMap);
    // trace("Total Instructions: " + code.length);
  }

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
    // trace("=== [NoteMovementInterp] Preprocessed Lua ===");
    // trace(finalCode);
    
    return finalCode;
  }

  function compile(codeStr:String) {
    var tokens = tokenize(codeStr);
    var pos = 0;
    
    while (pos < tokens.length) {
      var token = tokens[pos];
      if (token == ";") {
        pos++;
        continue;
      }
      
      var eqPos = -1;
      var commaBeforeEq = false;
      for (j in pos...tokens.length) {
        if (tokens[j] == "=") { eqPos = j; break; }
        if (tokens[j] == ";") break;
        if (tokens[j] == ",") commaBeforeEq = true;
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
        while (pos < tokens.length) {
          var t = tokens[pos];
          if (t == "(") depth++;
          else if (t == ")") depth--;
          else if (t == "," && depth == 0) {
            exprs.push(tokens.slice(currentExprStart, pos));
            currentExprStart = pos + 1;
          } else if (t == ";" && depth == 0) {
            break;
          }
          pos++;
        }
        exprs.push(tokens.slice(currentExprStart, pos));
        if (pos < tokens.length && tokens[pos] == ";") pos++;
        
        for (expr in exprs) {
          parseExpressionTokens(expr);
        }
        
        for (i in 0...targets.length) {
          var target = targets[targets.length - 1 - i];
          var vIdx = getVarIndex(target);
          code.push(OnValue.SET_VAR);
          code.push(Int64.ofInt(vIdx));
        }
      } else {
        var exprStart = pos;
        while (pos < tokens.length && tokens[pos] != ";") pos++;
        parseExpressionTokens(tokens.slice(exprStart, pos));
        if (pos < tokens.length && tokens[pos] == ";") pos++;
      }
    }
  }

  var currentPos:Int = 0;

  function tokenize(codeStr:String):Array<String> {
    var tokens:Array<String> = [];
    var current = "";
    for (i in 0...codeStr.length) {
      var c = codeStr.charAt(i);
      if (c == " " || c == "\t" || c == "\n" || c == "\r") {
        if (current != "") {
          tokens.push(current);
          current = "";
        }
      } else if (c == "+" || c == "-" || c == "*" || c == "/" || c == "%" || c == "(" || c == ")" || c == "=" || c == "," || c == ";") {
        if (current != "") {
          tokens.push(current);
          current = "";
        }
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
    var output:Array<Int64> = [];
    var operators:Array<String> = [];
    
    while (currentPos < tokens.length) {
      var token = tokens[currentPos];
      if (token == ";") break;
      
      if (isNumber(token)) {
        var val = Std.parseFloat(token);
        var cIdx = constants.length;
        constants.push(val);
        output.push(OnValue.PUSH_CONST);
        output.push(Int64.ofInt(cIdx));
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
        output.push(OnValue.PUSH_VAR);
        output.push(Int64.ofInt(vIdx));
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
        
        if (operators.length > 0 && isFunction(operators[operators.length - 1])) {
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
      else if (isOperator(token) || token.toLowerCase() == "and" || token.toLowerCase() == "or") {
        if ((token == "-" || token == "+") && (currentPos == 0 || isPrevTokenOperator(tokens, currentPos))) {
          if (token == "-") {
            output.push(OnValue.PUSH_CONST);
            output.push(Int64.ofInt(constants.length));
            constants.push(0.0);
            token = "-"; 
          } else {
            currentPos++;
            continue; 
          }
        }
        
        while (operators.length > 0 && precedence(operators[operators.length - 1]) >= precedence(token)) {
          output.push(getOpOpcode(operators.pop()));
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
    
    // OPTIMIZATION: Avoid array concatenation allocation
    for (j in 0...output.length) code.push(output[j]);
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
    return s == "sin" || s == "cos" || s == "min" || s == "max" ||
           s == "math.sin" || s == "math.cos" || s == "math.min" || s == "math.max" ||
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
      case "not", "sin", "cos", "min", "max", "math.sin", "math.cos", "math.min", "math.max", 
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
      case "not": OnValue.NOT;
      case "and": OnValue.AND;
      case "or": OnValue.OR;
      case "__abort": OnValue.ABORT;
      case "__abort_if_not_eq": OnValue.ABORT_IF_NOT_EQ;
      case "__abort_if_eq": OnValue.ABORT_IF_EQ;
      default: OnValue.PLUS;
    }
  }

  // STRICTLY INLINED FOR ZERO OVERHEAD
  public inline function run(diff:Float, scrollSpeed:Float, receptorX:Float, receptorY:Float, index:Float, type:Float, baseResult:NoteFormulaResult):NoteFormulaResult {
    // Initialize locals (Zero allocation, direct memory write)
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
    var aborted = false;
    var i = 0;
    var codeLen = code.length;
    
    while (i < codeLen) {
      var op = code[i];
      
      if (op == OnValue.PUSH_CONST) {
        i++;
        stack[stackPtr++] = constants[Int64.toInt(code[i])];
      }
      else if (op == OnValue.PUSH_VAR) {
        i++;
        stack[stackPtr++] = locals[Int64.toInt(code[i])];
      }
      else if (op == OnValue.SET_VAR) {
        i++;
        locals[Int64.toInt(code[i])] = stack[--stackPtr];
      }
      else if (op == OnValue.ABORT) { aborted = true; break; }
      else if (op == OnValue.ABORT_IF_NOT_EQ) { 
          var b = stack[--stackPtr]; var a = stack[--stackPtr]; 
          if (a != b) { aborted = true; break; } 
      }
      else if (op == OnValue.ABORT_IF_EQ) { 
          var b = stack[--stackPtr]; var a = stack[--stackPtr]; 
          if (a == b) { aborted = true; break; } 
      }
      // Math & Logic (In-place stack mutations to avoid pop/push overhead)
      else if (op == OnValue.PLUS) { var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a + b; }
      else if (op == OnValue.MINUS) { var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a - b; }
      else if (op == OnValue.TIMES) { var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = a * b; }
      else if (op == OnValue.DIVIDE) { var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = b != 0 ? a / b : 0; }
      else if (op == OnValue.MOD) { var b = stack[--stackPtr]; var a = stack[--stackPtr]; stack[stackPtr++] = b != 0 ? a % b : 0; }
      else if (op == OnValue.SIN) { stack[stackPtr - 1] = Math.sin(stack[stackPtr - 1]); }
      else if (op == OnValue.COS) { stack[stackPtr - 1] = Math.cos(stack[stackPtr - 1]); }
      else if (op == OnValue.MIN) { 
          var b = stack[--stackPtr]; 
          if (b < stack[stackPtr - 1]) stack[stackPtr - 1] = b; 
      }
      else if (op == OnValue.MAX) { 
          var b = stack[--stackPtr]; 
          if (b > stack[stackPtr - 1]) stack[stackPtr - 1] = b; 
      }
      else if (op == OnValue.NOT) { stack[stackPtr - 1] = stack[stackPtr - 1] == 0 ? 1.0 : 0.0; }
      else if (op == OnValue.AND) { var b = stack[--stackPtr]; var a = stack[stackPtr - 1]; stack[stackPtr - 1] = a != 0 ? b : 0.0; }
      else if (op == OnValue.OR)  { var b = stack[--stackPtr]; var a = stack[stackPtr - 1]; stack[stackPtr - 1] = a != 0 ? a : b; }
      
      i++;
    }
    
    if (aborted) {
    //   trace("=== [NoteMovementInterp] Execution Result ===");
    //   trace("Status: ABORTED (Falling back to default engine movement)");
      return null;
    }
    
    baseResult.x = locals[0];
    baseResult.y = locals[1];
    baseResult.scale = locals[2];
    baseResult.sustainRot = locals[3];
    baseResult.scrollMultiplier = locals[4];
    
    // trace("=== [NoteMovementInterp] Execution Result ===");
    // trace("Status: SUCCESS");
    // trace("Output Array: [" + locals[0] + ", " + locals[1] + ", " + locals[2] + ", " + locals[3] + ", " + locals[4] + "]");
    
    return baseResult;
  }
}