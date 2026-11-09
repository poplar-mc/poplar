## The tokens that the lexer gives the parser, and the keywords of the language.

type
  TokenTag* = enum
    tkLeftParen = "left_paren"
    tkRightParen = "right_paren"
    tkLeftBrace = "left_brace"
    tkRightBrace = "right_brace"
    tkLeftBracket = "left_bracket"
    tkRightBracket = "right_bracket"
    tkColon = "colon"            ## The `:` of `magic:heal` or `{hp: 20}`.
    tkBlockColon = "block_colon"
      ## The `:` that starts a block: outside brackets, and followed by a space or the end of the
      ## line.
    tkComma = "comma"
    tkDot = "dot"
    tkDotDot = "dot_dot"
    tkMinus = "minus"
    tkPlus = "plus"
    tkSemicolon = "semicolon" ## Not part of the language, but lexed to give a clear error.
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
    tkNewline = "newline" ## The end of a line that has a statement or declaration.
    tkIndent = "indent" ## A line that is indented more than the line before: a block starts.
    tkDedent = "dedent" ## A line that is indented less: one block ends.
    tkIdentifier = "identifier"
    tkScoreIdentifier = "score_identifier"
    tkDataIdentifier = "data_identifier"
    tkEntityData = "entity_data" ## The NBT path after `@s.$`, for example `Inventory[0].count`.
    tkCommand = "command"
    tkSelector = "selector"
    tkExecuteSubcommands = "execute_subcommands"
    tkConditionText = "condition_text"
      ## `block ~ ~-1 ~ stone` in an `if` or `while` condition: an `execute if` subcommand as raw
      ## text.
    tkJsonBody = "json_body"
      ## The JSON body of a data file, from `{` or `[` to the matching bracket.
    tkMacroKey = "macro_key" ## `$(name)`: a macro argument of the mcfun. The literal is the name.
    tkWithSource = "with_source"
      ## `entity @s` or `block ~ ~ ~` after `with`: raw text to the end of the line.
    tkString = "string"
    tkNumber = "number"
    tkAnd = "and"
    tkBreak = "break"
    tkConst = "const"
    tkContinue = "continue"
    tkElif = "elif"
    tkElse = "else"
    tkExecute = "execute"
    tkFalse = "false"
    tkMcfun = "mcfun"
    tkNamespace = "namespace"
    tkSelf = "self"
    tkFor = "for"
    tkIf = "if"
    tkImport = "import"
    tkIn = "in"
    tkNull = "null"
    tkOr = "or"
    tkReturn = "return"
    tkTrue = "true"
    tkVar = "var"
    tkWhile = "while"
    tkWith = "with"
    tkEof = "eof"
    tkIllegal = "illegal"
    tkUnclosed = "unclosed"
      ## A string, `(`, `[` or JSON body that is not closed. The literal is the missing character.
    tkLayoutError = "layout_error"
      ## A line whose indentation is wrong, such as a tab. The literal is the message.

  Token* = object
    tag*: TokenTag
    literal*: string
    line*, column*: int

const keywords* = [tkAnd, tkBreak, tkConst, tkContinue, tkElif, tkElse, tkExecute, tkFalse, tkFor,
                   tkMcfun, tkNamespace, tkSelf, tkIf, tkImport, tkIn, tkNull, tkOr, tkReturn,
                   tkVar, tkTrue, tkWhile, tkWith]

func keywordTag*(word: string): TokenTag =
  ## The tag of a keyword, or `tkIdentifier` for any other word.
  for keyword in keywords:
    if $keyword == word: return keyword
  tkIdentifier
