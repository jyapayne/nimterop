##[
This is the main nimterop import file to help with wrapping C/C++ source code.

Check out `template.nim <https://github.com/nimterop/nimterop/blob/master/nimterop/template.nim>`_
as a starting point for wrapping a new library. The template can be copied and
trimmed down and modified as required. `templite.nim <https://github.com/nimterop/nimterop/blob/master/nimterop/templite.nim>`_ is a shorter
version for more experienced users.

All `{.compileTime.}` procs must be used in a compile time context, e.g. using:

.. code-block:: c

   static:
     cAddStdDir()

]##

import hashes, macros, os, strformat, strutils

import regex

import "."/[build, globals, paths, types]
export types

proc interpPath(dir: string): string=
  # TODO: more robust: needs a DirSep after "$projpath"
  # disabling this interpolation as this is error prone, but other less
  # interpolations can be added, eg see https://github.com/nim-lang/Nim/pull/10530
  # result = dir.replace("$projpath", getProjectPath())
  result = dir

proc joinPathIfRel(path1: string, path2: string): string =
  if path2.isAbsolute:
    result = path2
  else:
    result = joinPath(path1, path2)

proc findPath(path: string, fail = true): string =
  # Relative to project path
  result = joinPathIfRel(getProjectPath(), path).replace("\\", "/")
  if not fileExists(result) and not dirExists(result):
    doAssert (not fail), "File or directory not found: " & path
    result = ""

proc walkDirImpl(indir, inext: string, file=true): seq[string] =
  let
    dir = joinPathIfRel(getProjectPath(), indir)
    ext =
      if inext.nBl:
        when not defined(Windows):
          "-name " & inext
        else:
          "\\" & inext
      else:
        ""

  let
    cmd =
      when defined(Windows):
        if file:
          "cmd /c dir /s/b/a-d " & dir.replace("/", "\\") & ext
        else:
          "cmd /c dir /s/b/ad " & dir.replace("/", "\\")
      else:
        if file:
          "find $1 -type f $2" % [dir, ext]
        else:
          "find $1 -type d" % dir

    (output, ret) = execAction(cmd, die = false)

  if ret == 0:
    result = output.splitLines()

proc getFileDate(fullpath: string): string =
  var
    ret = 0
    cmd =
      when defined(Windows):
        &"cmd /c for %a in ({fullpath.sanitizePath}) do echo %~ta"
      elif defined(Linux):
        &"stat -c %y {fullpath.sanitizePath}"
      elif defined(OSX) or defined(FreeBSD):
        &"stat -f %m {fullpath.sanitizePath}"

  (result, ret) = execAction(cmd)

proc getCacheValue(fullpath: string): string =
  if not gStateCT.nocache:
    result = fullpath.getFileDate()

proc getCacheValue(fullpaths: seq[string]): string =
  if not gStateCT.nocache:
    for fullpath in fullpaths:
      result &= getCacheValue(fullpath)

proc getToastError(output: string): string =
  # Filter out preprocessor errors
  for line in output.splitLines():
    if "fatal error:" in line.toLowerAscii:
      if result.len == 0:
        result = "\n\nFailed in preprocessing, check if `cIncludeDir()` is needed or compiler `mode` is correct (c/cpp)"
      result &= "\n\nERROR:$1\n" % line.split("fatal error:")[1]

  # Toast error
  if result.Bl:
    result = "\n\n" & output

proc getNimCheckError(output: string): tuple[tmpFile, errors: string] =
  let
    hash = output.hash().abs()

  result.tmpFile = getProjectCacheDir("failed", forceClean = false) / "nimterop_" & $hash & ".nim"

  if not fileExists(result.tmpFile) or gStateCT.nocache or compileOption("forceBuild"):
    mkDir(result.tmpFile.parentDir())
    writeFile(result.tmpFile, output)

  doAssert fileExists(result.tmpFile), "Failed to write to cache dir: " & result.tmpFile

  let
    (check, _) = execAction(
      &"{getCurrentNimCompiler()} check {result.tmpFile.sanitizePath}",
      die = false
    )

  result.errors = "\n\n" & check

proc getToast(fullpaths: seq[string], recurse: bool = false, dynlib: string = "",
  mode = "c", flags = "", noNimout = false): string =
  var
    ret = 0
    cmd = when defined(Windows): "cmd /c " else: ""

  let toastExe = toastExePath()
  doAssert fileExists(toastExe), "toast not compiled: " & toastExe.sanitizePath &
    " make sure 'nimble build' or 'nimble install' built it"
  cmd &= &"{toastExe} --preprocess -m:{mode}"

  if recurse:
    cmd.add " --recurse"

  if flags.nBl:
    cmd.add " " & flags

  for i in gStateCT.defines:
    cmd.add &" --defines+={i.quoteShell}"

  for i in gStateCT.includeDirs:
    cmd.add &" --includeDirs+={i.sanitizePath}"

  if not noNimout:
    cmd.add &" --pnim"

    if dynlib.nBl:
      cmd.add &" --dynlib={dynlib}"

    if gStateCT.symOverride.nBl:
      cmd.add &" --symOverride={gStateCT.symOverride.join(\",\")}"

    cmd.add &" --nim:{getCurrentNimCompiler().sanitizePath}"

    if gStateCT.pluginSourcePath.nBl:
      cmd.add &" --pluginSourcePath={gStateCT.pluginSourcePath.sanitizePath}"

  for fullpath in fullpaths:
    cmd.add &" {fullpath.sanitizePath}"

  # see https://github.com/nimterop/nimterop/issues/69
  (result, ret) = execAction(cmd, die = false, cache = (not gStateCT.nocache),
                             cacheKey = getCacheValue(fullpaths))
  doAssert ret == 0, getToastError(result)

macro cOverride*(body): untyped =
  ## When the wrapper code generated by nimterop is missing certain symbols or not
  ## accurate, it may be required to hand wrap them. Define them in a
  ## `cOverride() <cimport.html#cOverride.m>`_ macro block so that Nimterop uses
  ## these definitions instead.
  ##
  ## For example:
  ##
  ## .. code-block:: c
  ##
  ##    int svGetCallerInfo(const char** fileName, int *lineNumber);
  ##
  ## This might map to:
  ##
  ## .. code-block:: nim
  ##
  ##    proc svGetCallerInfo(fileName: ptr cstring; lineNumber: var cint)
  ##
  ## Whereas it might mean:
  ##
  ## .. code-block:: nim
  ##
  ##    cOverride:
  ##      proc svGetCallerInfo(fileName: var cstring; lineNumber: var cint)
  ##
  ## Using the `cOverride() <cimport.html#cOverride.m>`_ block, nimterop
  ## can be instructed to use this definition of `svGetCallerInfo()` instead.
  ## This works for procs, consts and types.
  ##
  ## `cOverride()` only affects the next `cImport()` call. This is because any
  ## recognized symbols get overridden in place and any remaining symbols get
  ## added to the top. If reused, the next `cImport()` would add those symbols
  ## again leading to redefinition errors.

  iterator findOverrides(node: NimNode): tuple[name, override: string, kind: NimNodeKind] =
    for child in node:
      case child.kind
      of nnkTypeSection, nnkConstSection:
        # Types, const
        for inst in child:
          let name =
            if inst[0].kind == nnkPragmaExpr:
              $inst[0][0]
            else:
              $inst[0]

          yield (name.strip(chars={'*'}), inst.repr, child.kind)
      of nnkProcDef:
        let
          name = $child[0]

        yield (name.strip(chars={'*'}), child.repr, child.kind)
      else:
        discard

  if gStateCT.overrides.Bl:
    gStateCT.overrides = """
import sets, tables

proc onSymbolOverride*(sym: var Symbol) {.exportc, dynlib.} =
"""

  # If cPlugin called before cOverride
  if gStateCT.pluginSourcePath.nBl:
    gStateCT.pluginSourcePath = ""

  var
    names: seq[string]
  for name, override, kind in body.findOverrides():
    let
      typ =
        case kind
        of nnkTypeSection: "nskType"
        of nnkConstSection: "nskConst"
        of nnkProcDef: "nskProc"
        else: ""

    gStateCT.overrides &= &"""
  if sym.name == "{name}" and sym.kind == {typ} and "{name}" in cOverrides["{typ}"]:
    sym.override = """ & "\"\"\"" & override & "\"\"\"\n"

    gStateCT.overrides &= &"    cOverrides[\"{typ}\"].excl \"{name}\"\n"

    gStateCT.overrides = gStateCT.overrides.replace("proc onSymbolOverride",
      &"cOverrides[\"{typ}\"].incl \"{name}\"\nproc onSymbolOverride")

    names.add name

    gStateCT.symOverride.add name

  if gStateCT.debug and names.nBl:
    echo "# Overriding " & names.join(" ")

proc cSkipSymbol*(skips: seq[string]) {.compileTime.} =
  ## Similar to `cOverride() <cimport.html#cOverride.m>`_, this macro allows
  ## filtering out symbols not of interest from the generated output.
  ##
  ## `cSkipSymbol() <cimport.html#cSkipSymbol%2Cseq[T][string]>`_ only affects calls to
  ## `cImport() <cimport.html#cImport.m%2C%2Cstring%2Cstring%2Cstring>`_ that follow it.
  runnableExamples:
    static: cSkipSymbol @["proc1", "Type2"]
  gStateCT.symOverride.add skips

proc cPluginHelper(body: string, imports = "import macros, nimterop/plugin\n\n") =
  gStateCT.pluginSource = body

  if gStateCT.pluginSource.nBl or gStateCT.overrides.nBl:
    let
      data = imports & body & "\n\n" & gStateCT.overrides
      hash = data.hash().abs()
      path = getProjectCacheDir("cPlugins", forceClean = false) / "nimterop_" & $hash & ".nim"

    if not fileExists(path) or gStateCT.nocache or compileOption("forceBuild"):
      mkDir(path.parentDir())
      writeFile(path, data)
      writeNimConfig(path & ".cfg")

    doAssert fileExists(path), "Unable to write plugin file: " & path

    gStateCT.pluginSourcePath = path

macro cPlugin*(body): untyped =
  ## When `cOverride() <cimport.html#cOverride.m>`_ and
  ## `cSkipSymbol() <cimport.html#cSkipSymbol%2Cseq[T][string]>`_
  ## are not adequate, the `cPlugin() <cimport.html#cPlugin.m>`_ macro can be used
  ## to customize the generated Nim output. The following callbacks are available at
  ## this time.
  ##
  ## .. code-block:: nim
  ##
  ##     proc onSymbol(sym: var Symbol) {.exportc, dynlib.}
  ##
  ## `onSymbol()` can be used to handle symbol name modifications required due
  ## to invalid characters in identifiers or to rename symbols that would clash
  ## due to Nim's style insensitivity. The symbol name and type is provided to
  ## the callback and the name can be modified.
  ##
  ## While `cPlugin` can easily remove leading/trailing `_` or prefixes and
  ## suffixes like `SDL_`, passing `--prefix` or `--suffix` flags to `cImport`
  ## in the `flags` parameter is much easier. However, these flags will only be
  ## considered when no `cPlugin` is specified.
  ##
  ## Returning a blank name will result in the symbol being skipped. This will
  ## fail for `nskParam` and `nskField` since the generated Nim code will be wrong.
  ##
  ## Symbol types can be any of the following:
  ## - `nskConst` for constants
  ## - `nskType` for type identifiers, including primitive
  ## - `nskParam` for param names
  ## - `nskField` for struct field names
  ## - `nskEnumField` for enum (field) names, though they are in the global namespace as `nskConst`
  ## - `nskProc` - for proc names
  ##
  ## `macros` and `nimterop/plugins` are implicitly imported to provide access to standard
  ## plugin facilities.
  ##
  ## `cPlugin() <cimport.html#cPlugin.m>`_  only affects calls to
  ## `cImport() <cimport.html#cImport.m%2C%2Cstring%2Cstring%2Cstring>`_ that
  ## follow it.
  runnableExamples:
    cPlugin:
      import strutils

      # Strip leading and trailing underscores
      proc onSymbol*(sym: var Symbol) {.exportc, dynlib.} =
        sym.name = sym.name.strip(chars={'_'})

  runnableExamples:
    cPlugin:
      import strutils

      # Strip prefix from procs
      proc onSymbol*(sym: var Symbol) {.exportc, dynlib.} =
        if sym.kind == nskProc and sym.name.contains("SDL_"):
          sym.name = sym.name.replace("SDL_", "")

  cPluginHelper(body.repr)

macro cPluginPath*(path: static[string]): untyped =
  ## Rather than embedding the `cPlugin()` code within the wrapper, it might be
  ## preferable to have it stored in a separate source file. This allows for reuse
  ## across multiple wrappers when applicable.
  ##
  ## The `cPluginPath()` macro enables this functionality - specify the path to the
  ## plugin file and it will be consumed in the same way as `cPlugin()`.
  ##
  ## `path` is relative to the current dir and not necessarily relative to the
  ## location of the wrapper file. Use `currentSourcePath` to specify a path relative
  ## to the wrapper file.
  ##
  ## Unlike `cPlugin()`, this macro also does not implicitly import any other modules
  ## since the standalone plugin file will need explicit imports for `nim check` and
  ## suggestions to work. `import nimterop/plugin` is required for all plugins.
  doAssert fileExists(path), "Plugin file not found: " & path
  cPluginHelper(readFile(path), imports = "")

proc cSearchPath*(path: string): string {.compileTime.}=
  ## Get full path to file or directory `path` in search path configured
  ## using `cAddSearchDir() <cimport.html#cAddSearchDir%2Cstring>`_ and
  ## `cAddStdDir() <cimport.html#cAddStdDir,string>`_.
  ##
  ## This can be used to locate files or directories that can be passed onto
  ## `cCompile() <cimport.html#cCompile.m%2C%2Cstring%2Cstring>`_,
  ## `cIncludeDir() <cimport.html#cIncludeDir.m>`_ and
  ## `cImport() <cimport.html#cImport.m%2C%2Cstring%2Cstring%2Cstring>`_.

  result = findPath(path, fail = false)
  if result.Bl:
    var found = false
    for inc in gStateCT.searchDirs:
      result = findPath(inc / path, fail = false)
      if result.nBl:
        found = true
        break
    doAssert found, "File or directory not found: " & path &
      " gStateCT.searchDirs: " & $gStateCT.searchDirs

proc cDebug*() {.compileTime.} =
  ## Enable debug messages and display the generated Nim code
  gStateCT.debug = true
  build.gDebugCT = true

proc cDisableCaching*() {.compileTime.} =
  ## Disable caching of generated Nim code - useful during wrapper development
  ##
  ## If files included by header being processed by
  ## `cImport() <cimport.html#cImport.m%2C%2Cstring%2Cstring%2Cstring>`_
  ## change and affect the generated content, they will be ignored and the cached
  ## value will continue to be used . Use `cDisableCaching() <cimport.html#cDisableCaching>`_
  ## to avoid this scenario during development.
  ##
  ## `nim -f` was broken prior to 0.19.4 but can also be used to flush the cached content.

  gStateCT.nocache = true

macro cDefine*(name: static string, val: static string = ""): untyped =
  ## `#define` an identifer that is forwarded to the C/C++ preprocessor if
  ## called within `cImport() <cimport.html#cImport.m%2C%2Cstring%2Cstring%2Cstring>`_
  ## or `c2nImport() <cimport.html#c2nImport.m%2C%2Cstring%2Cstring%2Cstring>`_
  ## as well as to the C/C++ compiler during Nim compilation using `{.passC: "-DXXX".}`

  result = newNimNode(nnkStmtList)

  var str = name
  # todo: see https://github.com/nimterop/nimterop/issues/100 for
  # edge case of empty strings
  if val.nBl:
    str &= &"={val.quoteShell}"

  if str notin gStateCT.defines:
    gStateCT.defines.add(str)
    str = "-D" & str

    result.add quote do:
      {.passC: `str`.}

    if gStateCT.debug:
      echo result.repr & "\n"

proc cAddSearchDir*(dir: string) {.compileTime.} =
  ## Add directory `dir` to the search path used in calls to
  ## `cSearchPath() <cimport.html#cSearchPath,string>`_.
  runnableExamples:
    import nimterop/paths, os
    static:
      cAddSearchDir testsIncludeDir()
    doAssert cSearchPath("test.h").existsFile
  var dir = interpPath(dir)
  if dir notin gStateCT.searchDirs:
    gStateCT.searchDirs.add(dir)

macro cIncludeDir*(dir: static string): untyped =
  ## Add an include directory that is forwarded to the C/C++ preprocessor if
  ## called within `cImport() <cimport.html#cImport.m%2C%2Cstring%2Cstring%2Cstring>`_
  ## or `c2nImport() <cimport.html#c2nImport.m%2C%2Cstring%2Cstring%2Cstring>`_
  ## as well as to the C/C++ compiler during Nim compilation using `{.passC: "-IXXX".}`.

  var dir = interpPath(dir)
  result = newNimNode(nnkStmtList)

  let fullpath = findPath(dir)
  if fullpath notin gStateCT.includeDirs:
    gStateCT.includeDirs.add(fullpath)
    let str = &"-I{fullpath.quoteShell}"
    result.add quote do:
      {.passC: `str`.}
    if gStateCT.debug:
      echo result.repr

proc cAddStdDir*(mode = "c") {.compileTime.} =
  ## Add the standard `c` [default] or `cpp` include paths to search
  ## path used in calls to `cSearchPath() <cimport.html#cSearchPath,string>`_
  runnableExamples:
    static: cAddStdDir()
    import os
    doAssert cSearchPath("math.h").existsFile
  for inc in getGccPaths(mode):
    cAddSearchDir inc

macro cCompile*(path: static string, mode = "c", exclude = ""): untyped =
  ## Compile and link C/C++ implementation into resulting binary using `{.compile.}`
  ##
  ## `path` can be a specific file or contain wildcards:
  ##
  ## .. code-block:: nim
  ##
  ##     cCompile("file.c")
  ##     cCompile("path/to/*.c")
  ##
  ## `mode` recursively searches for code files in `path`.
  ##
  ## `c` searches for `*.c` whereas `cpp` searches for `*.C *.cpp *.c++ *.cc *.cxx`
  ##
  ## .. code-block:: nim
  ##
  ##    cCompile("path/to/dir", "cpp")
  ##
  ## `exclude` can be used to exclude files by partial string match. Comma separated to
  ## specify multiple exclude strings
  ##
  ## .. code-block:: nim
  ##
  ##    cCompile("path/to/dir", exclude="test2.c")

  result = newNimNode(nnkStmtList)

  var
    stmt = ""

  proc fcompile(file: string): string =
    let
      (_, fn, ext) = file.splitFile()
    var
      ufn = fn
      uniq = 1
    while ufn in gStateCT.compile:
      ufn = fn & $uniq
      uniq += 1

    # - https://github.com/nim-lang/Nim/issues/10299
    # - https://github.com/nim-lang/Nim/issues/10486
    gStateCT.compile.add(ufn)
    if fn == ufn:
      return "{.compile: \"$#\".}\n" % file.replace("\\", "/")
    else:
      # - https://github.com/nim-lang/Nim/issues/9370
      let
        hash = file.hash().abs()
        tmpFile = file.parentDir() / &"_nimterop_{$hash}_{ufn}{ext}"
      if not tmpFile.fileExists() or file.getFileDate() > tmpFile.getFileDate():
        cpFile(file, tmpFile)
      return "{.compile: \"$#\".}\n" % tmpFile.replace("\\", "/")

  # Due to https://github.com/nim-lang/Nim/issues/9863
  # cannot use seq[string] for excludes
  proc notExcluded(file, exclude: string): bool =
    result = true
    if "_nimterop_" in file:
      result = false
    elif exclude.nBl:
      for excl in exclude.split(","):
        if excl in file:
          result = false

  proc dcompile(dir, exclude: string, ext=""): string =
    let
      files = walkDirImpl(dir, ext)

    for f in files:
      if f.nBl and f.notExcluded(exclude):
        result &= fcompile(f)

  if path.contains("*") or path.contains("?"):
    stmt &= dcompile(path, exclude.strVal())
  else:
    let fpath = findPath(path)
    if fileExists(fpath) and fpath.notExcluded(exclude.strVal()):
      stmt &= fcompile(fpath)
    elif dirExists(fpath):
      if mode.strVal().contains("cpp"):
        for i in @["*.cpp", "*.c++", "*.cc", "*.cxx"]:
          stmt &= dcompile(fpath, exclude.strVal(), i)
        when not defined(Windows):
          stmt &= dcompile(fpath, exclude.strVal(), "*.C")
      else:
        stmt &= dcompile(fpath, exclude.strVal(), "*.c")

  result.add stmt.parseStmt()

  if gStateCT.debug:
    echo result.repr

macro cImport*(filenames: static seq[string], recurse: static bool = false, dynlib: static string = "",
  mode: static string = "c", flags: static string = ""): untyped =
  ## Import multiple headers in one shot
  ##
  ## This macro is preferable over multiple individual `cImport()` calls, especially
  ## when the headers might `#include` the same headers and result in duplicate symbols.
  result = newNimNode(nnkStmtList)

  var
    fullpaths: seq[string]

  for filename in filenames:
    fullpaths.add findPath(filename)

  # In case cOverride called after cPlugin
  if gStateCT.pluginSourcePath.Bl:
    cPluginHelper(gStateCT.pluginSource)

  echo "# Importing " & fullpaths.join(", ").sanitizePath

  let
    output = getToast(fullpaths, recurse, dynlib, mode, flags)

  # Reset plugin and overrides for next cImport
  if gStateCT.overrides.nBl:
    gStateCT.pluginSourcePath = ""
    gStateCT.overrides = ""

  if gStateCT.debug:
    echo output

  try:
    let body = parseStmt(output)

    result.add body
  except:
    let
      (tmpFile, errors) = getNimCheckError(output)
    doAssert false, errors & "\n\nNimterop codegen limitation or error - review 'nim check' output above generated for " & tmpFile

macro cImport*(filename: static string, recurse: static bool = false, dynlib: static string = "",
  mode: static string = "c", flags: static string = ""): untyped =
  ## Import all supported definitions from specified header file. Generated
  ## content is cached in `nimcache` until `filename` changes unless
  ## `cDisableCaching() <cimport.html#cDisableCaching>`_ is set. `nim -f`
  ## can also be used after Nim v0.19.4 to flush the cache.
  ##
  ## `recurse` can be used to generate Nim wrappers from `#include` files
  ## referenced in `filename`. This is only done for files in the same
  ## directory as `filename` or in a directory added using
  ## `cIncludeDir() <cimport.html#cIncludeDir.m>`_
  ##
  ## `dynlib` can be used to specify the Nim string to use to specify the dynamic
  ## library to load the imported symbols from. For example:
  ##
  ## .. code-block:: nim
  ##
  ##    const
  ##      dynpcre =
  ##        when defined(Windows):
  ##          when defined(cpu64):
  ##            "pcre64.dll"
  ##          else:
  ##            "pcre32.dll"
  ##        elif hostOS == "macosx":
  ##          "libpcre(.3|.1|).dylib"
  ##        else:
  ##          "libpcre.so(.3|.1|)"
  ##
  ##    cImport("pcre.h", dynlib="dynpcre")
  ##
  ## If `dynlib` is not specified, the C/C++ implementation files can be compiled in
  ## with `cCompile() <cimport.html#cCompile.m%2C%2Cstring%2Cstring>`_, or the
  ## `{.passL.}` pragma can be used to specify the static lib to link.
  ##
  ## `mode` selects the preprocessor and tree-sitter parser to be used to process
  ## the header.
  ##
  ## `flags` can be used to pass any other command line arguments to `toast`. A
  ## good example would be `--prefix` and `--suffix` which strip leading and
  ## trailing strings from identifiers, `_` being quite common.
  ##
  ## `cImport()` consumes and resets preceding `cOverride()` calls. `cPlugin()`
  ## is retained for the next `cImport()` call unless a new `cPlugin()` call is
  ## defined.
  return quote do:
    cImport(@[`filename`], bool(`recurse`), `dynlib`, `mode`, `flags`)

macro c2nImport*(filename: static string, recurse: static bool = false, dynlib: static string = "",
  mode: static string = "c", flags: static string = ""): untyped =
  ## Import all supported definitions from specified header file using `c2nim`
  ##
  ## Similar to `cImport() <cimport.html#cImport.m%2C%2Cstring%2Cstring%2Cstring>`_
  ## but uses `c2nim` to generate the Nim wrapper instead of `toast`. Note that neither
  ## `cOverride() <cimport.html#cOverride.m>`_, `cSkipSymbol() <cimport.html#cSkipSymbol%2Cseq[T][string]>`_
  ## nor `cPlugin() <cimport.html#cPlugin.m>`_ have any impact on `c2nim`.
  ##
  ## `toast` is only used to preprocess the header file and recurse
  ## if specified.
  ##
  ## `mode` should be set to `cpp` for c2nim to wrap C++ headers.
  ##
  ## `flags` can be used to pass other command line arguments to `c2nim`.
  ##
  ## `nimterop` does not depend on `c2nim` as a `nimble` dependency so it
  ## does not get installed automatically. Any wrapper or library that requires this proc
  ## needs to install `c2nim` with `nimble install c2nim` or add it as a dependency in
  ## its own `.nimble` file.

  result = newNimNode(nnkStmtList)

  let
    fullpath = findPath(filename)

  echo "# Importing " & fullpath & " with c2nim"

  let
    output = getToast(@[fullpath], recurse, dynlib, mode, noNimout = true)
    hash = output.hash().abs()
    hpath = getProjectCacheDir("c2nimCache", forceClean = false) / "nimterop_" & $hash & ".h"
    npath = hpath[0 .. hpath.rfind('.')] & "nim"
    header = ("header" & fullpath.splitFile().name.replace(re"[-.]+", ""))

  if not fileExists(hpath) or gStateCT.nocache or compileOption("forceBuild"):
    mkDir(hpath.parentDir())
    writeFile(hpath, output)

  doAssert fileExists(hpath), "Unable to write temporary header file: " & hpath

  var
    cmd = when defined(Windows): "cmd /c " else: ""
  cmd &= &"c2nim {hpath} --header:{header}"

  if dynlib.nBl:
    cmd.add &" --dynlib:{dynlib}"
  if mode.contains("cpp"):
    cmd.add " --cpp"
  if flags.nBl:
    cmd.add &" {flags}"

  for i in gStateCT.defines:
    cmd.add &" --assumedef:{i.quoteShell}"

  let
    (c2nimout, ret) = execAction(cmd, cache = not gStateCT.nocache,
                                 cacheKey = getCacheValue(hpath))

  doAssert ret == 0, "\n\nc2nim codegen limitation or error - " & c2nimout

  var
    nimout = &"const {header} = \"{fullpath}\"\n\n" & readFile(npath)

  nimout = nimout.
    replace(re"([u]?int[\d]+)_t", "$1").
    replace(re"([u]?int)ptr_t", "ptr $1")

  if gStateCT.debug:
    echo nimout

  try:
    let body = parseStmt(nimout)

    result.add body
  except:
    let
      (tmpFile, errors) = getNimCheckError(nimout)
    doAssert false, errors & "\n\nc2nim codegen limitation or error - review 'nim check' output above generated for " & tmpFile
