type
  TokenTag* = enum
    tkLeftParen = "left_paren"
    tkRightParen = "right_paren"
    tkLeftBrace = "left_brace"
    tkRightBrace = "right_brace"
    tkLeftBracket = "left_bracket"
    tkRightBracket = "right_bracket"
    tkColon = "colon"
    tkComma = "comma"
    tkDot = "dot"
    tkDotDot = "dot_dot"
    tkPipe = "pipe"
    tkMinus = "minus"
    tkPlus = "plus"
    tkSemicolon = "semicolon"
    tkSlash = "slash"
    tkStar = "star"
    tkPercent = "percent"
    tkBang = "bang"
    tkBangEql = "bang_eql"
    tkEql = "eql"
    tkEqlEql = "eql_eql"
    tkGreater = "greater"
    tkGreaterEql = "greater_eql"
    tkLess = "less"
    tkLessEql = "less_eql"
    tkIdentifier = "identifier"
    tkScoreIdentifier = "score_identifier"
    tkDataIdentifier = "data_identifier"
    ## The NBT path after `@s.$`, for example `Inventory[0].count`.
    tkEntityData = "entity_data"
    tkCommand = "command"
    tkSelector = "selector"
    tkExecuteSubcommands = "execute_subcommands"
    ## `block ~ ~-1 ~ stone` in an `if` or `while` condition: an `execute if` subcommand as raw text.
    tkConditionText = "condition_text"
    ## The JSON body of a data file, from `{` or `[` to the matching bracket.
    tkJsonBody = "json_body"
    ## `$(name)`: a macro argument of the mcfun. The literal is the name.
    tkMacroKey = "macro_key"
    ## `entity @s` or `block ~ ~ ~` after `with`: raw text to the `;`.
    tkWithSource = "with_source"
    tkString = "string"
    tkNumber = "number"
    tkAnd = "and"
    tkBreak = "break"
    tkContinue = "continue"
    tkElse = "else"
    tkExecute = "execute"
    tkFalse = "false"
    tkMcfun = "mcfun"
    tkNamespace = "namespace"
    tkSelf = "self"
    tkFor = "for"
    tkIf = "if"
    tkImport = "import"
    tkNull = "null"
    tkOr = "or"
    tkReturn = "return"
    tkTrue = "true"
    tkVar = "var"
    tkWhile = "while"
    tkWith = "with"
    tkEof = "eof"
    tkIllegal = "illegal"
    ## A string, `(`, `[` or JSON body that is not closed. The literal is the missing character.
    tkUnclosed = "unclosed"

  Token* = object
    tag*: TokenTag
    literal*: string
    line*, column*: int

const keywords = [tkAnd, tkBreak, tkContinue, tkElse, tkExecute, tkFalse, tkFor, tkMcfun, tkNamespace, tkSelf, tkIf,
                  tkImport, tkNull, tkOr, tkReturn, tkVar, tkTrue, tkWhile, tkWith]

func keywordTag*(word: string): TokenTag =
  ## The tag of a keyword, or `tkIdentifier` for any other word.
  for keyword in keywords:
    if $keyword == word: return keyword
  tkIdentifier
