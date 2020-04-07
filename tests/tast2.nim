import macros, os, sets, strutils

import nimterop/[cimport]

static:
  cDebug()

const
  path = currentSourcePath.parentDir() / "include" / "tast2.h"

when defined(HEADER):
  cDefine("HEADER")
  const
    flags = " -H"
    pHeader = @["header:" & path.replace("\\", "/")]
    pHeaderImp = @["importc"] & pHeader
else:
  const
    flags = ""
    pHeader: seq[string] = @[]
    pHeaderImp: seq[string] = @[]

const
  pHeaderImpBy = @["bycopy"] & pHeaderImp
  pHeaderBy = @["bycopy"] & pHeader
  pHeaderInc = @["incompleteStruct"] & pHeader

cOverride:
  const
    A* = 2

  type
    A1* = A0

cImport(path, flags="-f:ast2 -ENK_" & flags)

proc getPragmas(n: NimNode): HashSet[string] =
  # Find all pragmas in AST, return as "name" or "name:value" in set
  for i in 0 ..< n.len:
    if n[i].kind == nnkPragma:
      for j in 0 ..< n[i].len:
        if n[i][j].kind == nnkIdent:
          result.incl $n[i][j]
        elif n[i][j].kind == nnkExprColonExpr:
          result.incl $n[i][j][0] & ":" & $n[i][j][1]
    else:
      result.incl n[i].getPragmas()

proc getRecList(n: NimNode): NimNode =
  # Find nnkRecList in AST
  for i in 0 ..< n.len:
    if n[i].kind == nnkRecList:
      return n[i]
    elif n[i].len != 0:
      let
        rl = getRecList(n[i])
      if not rl.isNil:
        return rl

macro checkPragmas(t: typed, pragmas: static[seq[string]], istype: static[bool] = true): untyped =
  # Verify that type has expected pragmas defined
  # `istype` is true when typedef X
  var
    ast = t.getImpl()
    prag = ast.getPragmas()
    exprag = pragmas.toHashSet()
  when defined(HEADER):
    if not istype:
      if "union" in exprag:
        exprag.incl "importc:union " & $t
      else:
        exprag.incl "importc:struct " & $t
  doAssert symmetricDifference(prag, exprag).len == 0,
    "\nWrong number of pragmas in " & $t & "\n" & $prag & " vs " & $exprag

macro testFields(t: typed, fields: static[string] = "") =
  # Verify that type has expected fields
  var
    ast = t.getImpl()
    rl = ast.getRecList()
    fsplit = fields.split(":")
    names = fsplit[0].split("|")
    types =
      if fsplit.len > 1:
        fsplit[1].split("|")
      else:
        @[]
  if not rl.isNil:
    for i in 0 ..< rl.len:
      let
        name = ($rl[i][0]).strip(chars = {'*'})
        typ = $(rl[i][1].repr())
        n = names.find(name)
      assert n != -1, $t & "." & name & " invalid"
      assert types[n] == typ,
        "typeof(" & $t & ":" & name & ") != " & types[n] & ", is " & typ

assert A == 2
assert B == 1.0
assert C == 0x10
assert D == "hello"
assert E == 'c'

assert A0 is object
testFields(A0, "f1:cint")
checkPragmas(A0, pHeaderBy, istype = false)
var a0: A0
a0.f1 = 1

assert A1 is A0
testFields(A1, "f1:cint")
var a1: A1
a1.f1 = 2

assert A2 is object
testFields(A2)
checkPragmas(A2, pHeaderInc, istype = false)
when not defined(HEADER):
  # typedef struct X; is invalid
  var a2: A2

assert A3 is object
testFields(A3)
checkPragmas(A3, pHeaderInc, istype = false)
var a3: A3

assert A4 is object
testFields(A4, "f1:cfloat")
checkPragmas(A4, pHeaderImpBy)
var a4: A4
a4.f1 = 4.1

assert A4p is ptr A4
testFields(A4p, "f1:cfloat")
checkPragmas(A4p, pHeaderImp)
var a4p: A4p
a4p = addr a4

assert A5 is cint
checkPragmas(A5, pHeaderImp)
const a5: A5 = 5

assert A6 is ptr cint
checkPragmas(A6, pHeaderImp)
var
  a6: A6
  a6i = 6
a6 = cast[A6](addr a6i)

assert A7 is ptr ptr A0
checkPragmas(A7, pHeaderImp)
var
  a7: A7
  a7a = addr a0
a7 = addr a7a

assert A8 is pointer
checkPragmas(A8, pHeaderImp)
var a8: A8
a8 = nil

assert A9p is array[3, cstring]
checkPragmas(A9p, pHeaderImp)
var a9p: A9p
a9p[1] = nil
a9p[2] = "hello".cstring

assert A9 is array[4, cchar]
checkPragmas(A9, pHeaderImp)
var a9: A9
a9[2] = 'c'

assert A10 is array[3, array[6, cstring]]
checkPragmas(A10, pHeaderImp)
var a10: A10
a10[2][5] = "12345".cstring

assert A11 is ptr array[3, cstring]
checkPragmas(A11, pHeaderImp)
var a11: A11
a11 = addr a9p

assert A111 is array[12, ptr A1]
checkPragmas(A111, pHeaderImp)
var a111: A111
a111[11] = addr a0

assert A12 is proc(a1: cint, b: cint, c: ptr cint, a4: ptr cint, count: array[4, ptr cint], `func`: proc(a1: cint, a2: cint): cint {.cdecl.}): ptr ptr cint {.cdecl.}
checkPragmas(A12, pHeaderImp & "cdecl")
var a12: A12

assert A121 is proc(a1: cfloat, b: cfloat, c: ptr cfloat, a4: ptr cfloat, count: array[4, ptr cfloat], `func`: proc(a1: cfloat, a2: cfloat): cfloat {.cdecl.}): ptr ptr cint {.cdecl.}
checkPragmas(A121, pHeaderImp & "cdecl")
var a121: A121

assert A122 is proc(a1: cchar, b: cchar, c: cstring, a4: cstring, count: array[4, cstring], `func`: proc(a1: cchar, a2: cchar): cchar {.cdecl.}): ptr ptr cint {.cdecl.}
checkPragmas(A122, pHeaderImp & "cdecl")
var a122: A122

assert A13 is proc(a1: cint, a2: cint, `func`: proc() {.cdecl.}): cint {.cdecl.}
checkPragmas(A13, pHeaderImp & "cdecl")
var a13: A13

assert A14 is object
testFields(A14, "a1:cchar")
checkPragmas(A14, pHeaderBy, istype = false)
var a14: A14
a14.a1 = 'a'

assert A15 is object
testFields(A15, "a1|a2:cstring|array[1, ptr cint]")
checkPragmas(A15, pHeaderBy, istype = false)
var
  a15: A15
  a15i = 15.cint
a15.a1 = "hello".cstring
a15.a2[0] = addr a15i

assert A16 is object
testFields(A16, "f1:cchar")
checkPragmas(A16, pHeaderBy, istype = false)
var a16: A16
a16.f1 = 's'

assert A17 is object
testFields(A17, "a1|a2:cstring|array[1, ptr cint]")
checkPragmas(A17, pHeaderBy, istype = false)
var a17: A17
a17.a1 = "hello".cstring
a17.a2[0] = addr a15i

assert A18 is A17
checkPragmas(A18, pHeaderImp)
var a18: A18

assert A18p is ptr A17
checkPragmas(A18p, pHeaderImp)
var a18p: A18p
a18p = addr a18

assert A19 is object
testFields(A19, "a1|a2:cstring|array[1, ptr cint]")
checkPragmas(A19, pHeaderImpBy)
var a19: A19
a19.a1 = "hello".cstring
a19.a2[0] = addr a15i

assert A19p is ptr A19
checkPragmas(A19p, pHeaderImp)
var a19p: A19p
a19p = addr a19

assert A20 is object
testFields(A20, "a1:cchar")
checkPragmas(A20, pHeaderBy, istype = false)
var a20: A20
a20.a1 = 'a'

assert A21 is A20
checkPragmas(A21, pHeaderImp)
var a21: A21
a21 = a20

assert A21p is ptr A20
checkPragmas(A21p, pHeaderImp)
var a21p: A21p
a21p = addr a20

assert A22 is object
testFields(A22, "f1|f2:ptr ptr cint|array[123 + 132, ptr cint]")
checkPragmas(A22, pHeaderBy, istype = false)
var a22: A22
a22.f1 = addr a15.a2[0]

assert U1 is object
assert sizeof(U1) == sizeof(cfloat)
checkPragmas(U1, pHeaderBy & @["union"], istype = false)
var u1: U1
u1.f1 = 5

assert U2 is object
assert sizeof(U2) == 256 * sizeof(cint)
checkPragmas(U2, pHeaderBy & @["union"], istype = false)
var u2: U2
u2.f1 = addr a15.a2[0]

assert PANEL_WINDOW == 1
assert PANEL_GROUP == 2
assert PANEL_POPUP == 4
assert PANEL_CONTEXTUAL == 16
assert PANEL_COMBO == 32
assert PANEL_MENU == 64
assert PANEL_TOOLTIP == 128
assert PANEL_SET_NONBLOCK == 240
assert PANEL_SET_POPUP == 244
assert PANEL_SET_SUB == 246

assert cmGray == 1000000
assert pfGray16 == 1000011
assert pfYUV422P8 == pfYUV420P8 + 1
assert pfRGB27 == cmRGB.VSPresetFormat + 11
assert pfCompatYUY2 == pfCompatBGR32 + 1

assert pcre_malloc is proc(a1: uint): pointer {.cdecl.}
checkPragmas(pcre_malloc, @["importc", "cdecl"] & pHeader)

assert pcre_free is proc(a1: pointer) {.cdecl.}
checkPragmas(pcre_free, @["importc", "cdecl"] & pHeader)

assert pcre_stack_malloc is proc(a1: uint): pointer {.cdecl.}
checkPragmas(pcre_stack_malloc, @["importc", "cdecl"] & pHeader)

assert DuplexTransferImageViewMethod is
  proc (a1: ptr ImageView; a2: ptr ImageView; a3: ptr ImageView; a4: uint;
        a5: cint; a6: pointer): MagickBooleanType {.cdecl.}

assert GetImageViewMethod is
  proc (a1: ptr ImageView; a2: uint; a3: cint; a4: pointer): MagickBooleanType {.cdecl.}

assert SetImageViewMethod is
  proc (a1: ptr ImageView; a2: uint; a3: cint; a4: pointer): MagickBooleanType {.cdecl.}

assert TransferImageViewMethod is
  proc (a1: ptr ImageView; a2: ptr ImageView; a3: uint; a4: cint; a5: pointer): MagickBooleanType {.cdecl.}

assert UpdateImageViewMethod is
  proc (a1: ptr ImageView; a2: uint; a3: cint; a4: pointer): MagickBooleanType {.cdecl.}