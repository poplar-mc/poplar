## The names that are visible in a scope: compile-time vars and the locals of an mcfun.

import std/[options, tables]
import ast

type
  Value* = object
    case
    of StringValue: text*: string
    of NumberValue: number*: int64
    of TypedNumberValue: typedNumber*: TypedNumber
    of BooleanValue: boolean*: bool
    of NullValue: discard
    of ListValue: elements*: seq[Value]
    of CompoundValue: entries*: seq[ValueEntry]

  ValueEntry* = object
    key*: string
    value*: Value

  LocalKind* = enum
    lkScore, lkData

  Local* = object
    ## A local is a global with a generated name: `#i_countdown` for a score, `i_countdown` in `<ns>:data` for data.
    kind*: LocalKind
    generatedName*: string
    ## The mcfun that the local belongs to.
    owner*: string

  AssignResult* = enum
    arAssigned, arNotFound, arCrossesRuntimeBranch

  Environment* = ref object
    store: Table[string, Value]
    scoreLocals: Table[string, Local]
    dataLocals: Table[string, Local]
    outer*: Environment
    ## True for the scope of a runtime `if` body. Compile-time vars from outside it cannot change.
    runtimeBranch*: bool

func get*(environment: Environment, name: string): Option[Value] =
  if name in environment.store: return some(environment.store[name])
  if environment.outer != nil: return environment.outer.get(name)
  none(Value)

proc declare*(environment: Environment, name: string, value: Value): bool =
  ## Returns false if the name is already visible, so names cannot be shadowed.
  if environment.get(name).isSome: return false
  environment.store[name] = value
  true

func getLocal*(environment: Environment, kind: LocalKind, name: string): Option[Local] =
  ## The local `#name` or `$name` that is visible here.
  let locals = if kind == lkScore: environment.scoreLocals else: environment.dataLocals
  if name in locals: return some(locals[name])
  if environment.outer != nil: return environment.outer.getLocal(kind, name)
  none(Local)

proc declareLocal*(environment: Environment, name: string, local: Local) =
  if local.kind == lkScore: environment.scoreLocals[name] = local
  else: environment.dataLocals[name] = local

proc assign*(environment: Environment, name: string, value: Value): AssignResult =
  if name in environment.store:
    environment.store[name] = value
    return arAssigned

  let outer = environment.outer
  if outer == nil: return arNotFound
  if environment.runtimeBranch and outer.get(name).isSome: return arCrossesRuntimeBranch
  outer.assign(name, value)
