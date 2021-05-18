# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  os, strformat, strutils, sequtils, tables, algorithm


proc collectImports(file: string): string =
  var
    importIndent = 0
    importOpenOk = false

  for line in file.readFile.string.splitLines:
    var
      stripped = line.strip(trailing = false)
    if stripped.len == 0 or stripped[0] == '#':
      continue
    var
      indent = line.len - stripped.len
      token = stripped.splitWhitespace[0]

    if token in ["import", "include"]:
      stripped = stripped.strip
      importOpenOk = true
      if stripped.len <= token.len + 1:
        continue
      stripped = stripped[token.len ..< stripped.len]
      importIndent = indent + 1
    elif importOpenOk and importIndent <= indent:
      importIndent = indent
    else:
      importOpenOk = false
      continue

    if 0 < result.len:
      result &= ","
    result &= stripped.split(',').mapIt(it.strip).filterIt(it != "").join(",")


proc splitFileList(list: string): seq[string] =
  var q = list
  while 0 < q.len:
    var
      comma = q.find(",")
      bracket = q.find("/[")

    if comma == 0:
      if q.len == 1:
        break
      q = q[1 ..< q.len]
      continue

    if 0 <= comma and (bracket < 0 or comma < bracket):
      result.add q[0 ..< comma]
      q = q[comma+1 ..< q.len]
      continue

    if comma < 0 and bracket < 0:
      result.add q
      break

    var
      prefix = q[0 ..< bracket]
      sublist = q[bracket+2 ..< q.len]
      tekcarb = sublist.find("]")

    if 0 < tekcarb:
      if tekcarb+2 < sublist.len:
        q = sublist[tekcarb+2 ..< sublist.len]
      else:
        q = ""
      sublist = sublist[0 ..< tekcarb]
    else:
      q = ""

    for item in sublist.split(','):
      result.add prefix & "/" & item


proc processLocalFiles(list: seq[string]): seq[string] =
  for item in list:
    var file = item.split[0]
    if (file.len > 2 and file[0 .. 1] ==      "./") or
       (file.len > 4 and file[0 .. 3] ==  "\".\"/") or
       (file.len > 3 and file[0 .. 2] ==     "../") or
       (file.len > 5 and file[0 .. 4] == "\"..\"/"):
      result.add file.splitPath[1] & ".nim"
    elif file[0] != '#':
      result.add file


proc process_nim_folder(dir: string) =
  # collect <file.nim> => <import-list>
  var fileTab = newTable[string,TableRef[string,bool]]()
  for file in dir.walkDirRec:
    var fLen = file.len
    if fLen < 5 or file[fLen-4 ..< fLen] != ".nim":
      continue
    var baseName = file.splitPath[1]
    if not fileTab.hasKey(baseName):
      fileTab[baseName] = newTable[string,bool]()
    for imp in file.collectImports.splitFileList.processLocalFiles:
      fileTab[baseName][imp] = false

  var
    errors: seq[string]
    rename: seq[(string,string)]
    fileTabKeys = toSeq(fileTab.keys)

  # correct some mis-nomers
  for file in fileTabKeys.sorted:
    for imp in fileTab[file].keys:
      var fLen = imp.len
      if 4 < fLen and imp[fLen-4 ..< fLen] == ".nim":
        continue
      if fileTab.hasKey(imp & ".nim"):
        rename.add (file,imp)
        errors.add &"misnomer in {file}? " &
          &"mapped {imp} => {imp}.nim (maybe add path prefix)"
  for (file,imp) in rename:
    fileTab[file].del(imp)
    fileTab[file][imp & ".nim"] = false

  # sort of greedy algorithm for detecting import loop
  for file in fileTabKeys.sorted:
    var
      recent = toSeq(fileTab[file].keys)
      collected = newTable[string,bool]()
      actionOK = true

    while actionOK:
      actionOK = false

      # merge recent[] into collected[]
      var importList = recent
      recent = newSeq[string]()
      for importFile in importList:
        if not collected.hasKey(importFile):
          collected[importFile] = false

      # greedily collect ...
      for importFile in importList:
        if fileTab.hasKey(importFile):
          for followUp in fileTab[importFile].keys:
            if not collected.hasKey(followUp):
              if followUp == file:
                errors.add &"loop alert: {file} .. {importFile} -> {followUp}"
                continue
              actionOK = true
              recent.add followUp

    echo &"*** file {file}:"
    var collectedkeys = toSeq(collected.keys)
    for item in collectedKeys.sorted:
      echo &"      {item}"
    echo ""

  if 0 < errors.len:
    for w in errors:
      echo "*** ", w
    echo ""

# MAIN

let folder = if paramCount() == 0:
               "."
             elif paramCount() == 1:
               paramStr(1)
             else:
               "-"

if folder[0] == '-':
  stderr.write "" &
    &"Usage: {getAppFilename().splitPath.tail} [<source-folder>]\n"
  quit()

folder.process_nim_folder

# End
