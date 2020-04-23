import unittest
import nimterop/cimport

cOverride:
  type
    locale_t = object
    mingw_ldbl_type_t = object
    mingw_dbl_type_t = object

when defined(windows):
  cOverride:
    type
      complex = object

static:
  cSkipSymbols = @["mingw_choose_expr", "EXCEPTION_DEFINED"]
  cDebug()
  cDisableCaching()
  cAddStdDir()

cPlugin:
  import strutils

  proc onSymbol*(sym: var Symbol) {.exportc, dynlib.} =
    sym.name = sym.name.strip(chars={'_'}).replace("__", "_")

const FLAGS {.strdefine.} = ""
cImport(cSearchPath("math.h"), flags = FLAGS)

check sin(5) == -0.9589242746631385
check abs(-5) == 5
check sqrt(4.00) == 2.0
