import std/[options, strutils, unittest]
import ../src/[config, diagnostic]

const latest = PackFormat(major: 121)

proc problem(json: string): ref ConfigError =
  try:
    discard parseConfig(json, "hello", latest)
  except ConfigError as error:
    return error
  raiseAssert "expected a ConfigError for " & json

test "parses poplar.json":
  let defaults = parseConfig("{}", "hello", latest)
  check defaults.namespace == "hello"
  check defaults.description == "\"hello\""
  check defaults.maxFormat.major == 121

  let full = parseConfig("""{
  "$schema": "https://example.com/poplar.schema.json",
  "zipName": "My Pack",
  "namespace": "demo",
  "description": {"text": "Hi", "color": "green"},
  "minFormat": [101, 1],
  "maxFormat": 121
}""", "hello", latest)
  check full.zipName == "My Pack"
  check full.description == """{"text":"Hi","color":"green"}"""
  check full.minFormat.minor == 1

  check problem("{\"zip\": true}").msg.startsWith("unknown field 'zip'")
  let misspelled = problem("{\n  \"nmae\": \"x\"\n}")
  check misspelled.position.get.line == 2
  check misspelled.msg.startsWith("unknown field 'nmae'")
  check problem("{\"name\":\"t\"}").position.get == diagnostic.Position(line: 1, column: 8)

  discard problem("{\"minFormat\": 80}")
  discard problem("{\"minFormat\": 121, \"maxFormat\": 101}")

test "writes the description in compact form":
  check parseConfig("{\"description\": [1e-7, 2.0, -0, 1E400, \"é\\u0001\"]}", "hello", latest).description ==
    "[0.0000001,2,-0,1E400,\"é\\u0001\"]"
  check problem("{\"description\": {\"a\": 1, \"a\": 2}}").msg == "invalid JSON"
