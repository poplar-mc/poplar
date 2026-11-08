## `poplar lsp`: JSON-RPC messages with a `Content-Length` header, over stdin and stdout.

import std/[json, options, strutils]
import ../lsp
import command_line, root

type HeaderError = object of IOError

proc readHeaderLine(): Option[string] =
  ## One header line with its `\r\n`, or none at the end of stdin.
  var line = ""
  var ch: char
  while stdin.readBuffer(ch.addr, 1) == 1:
    line.add ch
    if ch == '\n': return some(line)
  none(string)

proc readMessage(): Option[string] =
  ## The body of the next message, or none at the end of stdin.
  var contentLength = -1
  while true:
    let header = readHeaderLine()
    if header.isNone: return none(string)
    var line = header.get
    if not line.endsWith("\r\n"): raise newException(HeaderError, "InvalidHeaderField")
    line.setLen(line.len - 2)
    if line.len == 0: break
    let colon = line.find(": ")
    if colon < 0: raise newException(HeaderError, "InvalidHeaderField")
    if line[0 ..< colon].toLowerAscii != "content-length": continue
    if contentLength >= 0: raise newException(HeaderError, "DuplicateContentLength")
    try:
      contentLength = parseInt(line[colon + 2 .. ^1])
    except ValueError:
      raise newException(HeaderError, "InvalidContentLength")
  if contentLength < 0: raise newException(HeaderError, "MissingContentLength")
  var body = newString(contentLength)
  if contentLength > 0 and stdin.readBuffer(body[0].addr, contentLength) != contentLength: return none(string)
  some(body)

proc writeMessage(message: JsonNode) =
  let body = $message
  stdout.write "Content-Length: " & $body.len & "\r\n\r\n" & body
  stdout.flushFile()

proc errorResponse(id: JsonNode, code: int, message: string): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}

proc serve(shared: Shared) =
  proc notify(meth: string, params: JsonNode) =
    writeMessage(%*{"jsonrpc": "2.0", "method": meth, "params": params})
  let server = newLanguageServer(shared.stdPath, notify)
  while true:
    let body = readMessage()
    if body.isNone: return
    var message: JsonNode
    try:
      message = parseJson(body.get)
    except JsonParsingError as error:
      writeMessage(errorResponse(newJNull(), -32700, error.msg))
      continue

    if not message.hasKey("method"):
      stderr.write "warning: unexpected response from the editor: " & $message{"id"} & "\n"
      continue
    let meth = message["method"].getStr
    let params = message{"params"}
    if not message.hasKey("id"):
      try:
        discard server.handle(meth, params)
      except CatchableError as error:
        stderr.write "error: failed to handle '" & meth & "' notification: " & error.msg & "\n"
      if meth == "exit": return
      continue
    try:
      writeMessage(%*{"jsonrpc": "2.0", "id": message["id"], "result": server.handle(meth, params)})
    except CatchableError as error:
      writeMessage(errorResponse(message["id"], -32603, error.msg))

proc register*(shared: Shared): Command =
  proc run(invocation: Invocation) = serve(shared)
  newCommand("lsp", "Run the language server. An editor starts it and talks to it over stdin and stdout", run)
