## An error in the user's files.

import std/options

type
  Position* = object
    ## A place in a source file. Lines and columns start at 1.
    line*, column*: int

  Diagnostic* = object
    path*: string
    position*: Option[Position]
      ## None when the error is not about one place in a file, such as a missing folder.
    message*: string

  ReportedError* = object of CatchableError
    ## A diagnostic is already recorded, so the caller only has to stop what it is doing.

template recover*(body: untyped) =
  ## Ends the stop that `ReportedError` asked for, so that the next statement or declaration is checked.
  try:
    body
  except ReportedError:
    discard
