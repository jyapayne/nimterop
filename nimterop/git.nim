import macros, os, osproc, regex, strformat, strutils

import "."/[paths, compat]

when not defined(buildOS):
  const buildOS* {.magic: "BuildOS".} = ""

proc execAction*(cmd: string, nostderr=false): string =
  var
    ccmd = ""
    ret = 0
  when buildOS == "windows":
    ccmd = "cmd /c " & cmd
  elif defined(posix):
    ccmd = cmd
  else:
    doAssert false

  when nimvm:
    (result, ret) = gorgeEx(ccmd)
  else:
    let opt = if nostderr: {poUsePath} else: {poStdErrToStdOut, poUsePath}
    (result, ret) = execCmdEx(ccmd, opt)
  doAssert ret == 0, "Command failed: " & $(ret, nostderr) & "\nccmd: " & ccmd & "\nresult:\n" & result

proc mkDir*(dir: string) =
  if not dirExists(dir):
    let
      flag = if buildOS != "windows": "-p" else: ""
    discard execAction(&"mkdir {flag} {dir.quoteShell}")

proc cpFile*(source, dest: string, move=false) =
  let
    source = source.replace("/", $DirSep)
    dest = dest.replace("/", $DirSep)
    cmd =
      if buildOS == "windows":
        if move:
          "move /y"
        else:
          "copy /y"
      else:
        if move:
          "mv -f"
        else:
          "cp -f"

  discard execAction(&"{cmd} {source.quoteShell} {dest.quoteShell}")

proc mvFile*(source, dest: string) =
  cpFile(source, dest, move=true)

proc extractZip*(zipfile, outdir: string) =
  var cmd = "unzip -o $#"
  if buildOS == "windows":
    cmd = "powershell -nologo -noprofile -command \"& { Add-Type -A " &
          "'System.IO.Compression.FileSystem'; " &
          "[IO.Compression.ZipFile]::ExtractToDirectory('$#', '.'); }\""

  echo "Extracting " & zipfile
  discard execAction(&"cd {outdir.quoteShell} && {cmd % zipfile}")

proc downloadUrl*(url, outdir: string) =
  let
    file = url.extractFilename()
    ext = file.splitFile().ext.toLowerAscii()

  if not (ext == ".zip" and fileExists(outdir/file)):
    echo "Downloading " & file
    mkDir(outdir)
    var cmd = if buildOS == "windows":
      "powershell [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; wget $# -OutFile $#"
    else:
      "curl $# -o $#"
    discard execAction(cmd % [url, (outdir/file).quoteShell])

    if ext == ".zip":
      extractZip(file, outdir)

proc gitReset*(outdir: string) =
  echo "Resetting " & outdir

  let cmd = &"cd {outdir.quoteShell} && git reset --hard"
  while execAction(cmd).contains("Permission denied"):
    sleep(1000)
    echo "  Retrying ..."

proc gitCheckout*(file, outdir: string) =
  echo "Resetting " & file
  let file2 = file.relativePath outdir
  let cmd = &"cd {outdir.quoteShell} && git checkout {file2.quoteShell}"
  while execAction(cmd).contains("Permission denied"):
    sleep(500)
    echo "  Retrying ..."

proc gitPull*(url: string, outdir = "", plist = "", checkout = "") =
  if dirExists(outdir/".git"):
    gitReset(outdir)
    return

  let
    outdirQ = outdir.quoteShell

  mkDir(outdir)

  echo "Setting up Git repo: " & url
  discard execAction(&"cd {outdirQ} && git init .")
  discard execAction(&"cd {outdirQ} && git remote add origin {url}")

  if plist.len != 0:
    # TODO: document this, it's not clear
    let sparsefile = outdir / ".git/info/sparse-checkout"

    discard execAction(&"cd {outdirQ} && git config core.sparsecheckout true")
    writeFile(sparsefile, plist)

  if checkout.len != 0:
    echo "Checking out " & checkout
    discard execAction(&"cd {outdirQ} && git pull --tags origin master")
    discard execAction(&"cd {outdirQ} && git checkout {checkout}")
  else:
    echo "Pulling repository"
    discard execAction(&"cd {outdirQ} && git pull --depth=1 origin master")
