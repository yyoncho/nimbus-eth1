# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[sequtils, strutils, tables],
  eth/[common/eth_types, trie/nibbles],
  stew/results,
  "."/[hexary_defs, hexary_desc]

{.push raises: [Defect].}

const
  HexaryImportDebugging = false or true

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

proc pp(q: openArray[byte]): string =
  q.toSeq.mapIt(it.toHex(2)).join.toLowerAscii.pp(hex = true)

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

proc hexaryImport*(
    db: var HexaryTreeDB;
    recData: Blob
      ): Result[void,HexaryDbError]
      {.gcsafe, raises: [Defect, RlpError].} =
  ## Decode a single trie item for adding to the table and add it to the
  ## database. Branch and exrension record links are collected.
  let
    nodeKey = recData.digestTo(NodeKey)
    repairKey = nodeKey.to(RepairKey) # for repair table
  var
    rlp = recData.rlpFromBytes
    blobs = newSeq[Blob](2)         # temporary, cache
    links: array[16,RepairKey]      # reconstruct branch node
    blob16: Blob                    # reconstruct branch node
    top = 0                         # count entries
    rNode: RNodeRef                 # repair tree node

  # Collect lists of either 2 or 17 blob entries.
  for w in rlp.items:
    case top
    of 0, 1:
      if not w.isBlob:
        return err(RlpBlobExpected)
      blobs[top] = rlp.read(Blob)
    of 2 .. 15:
      var key: NodeKey
      if not key.init(rlp.read(Blob)):
        return err(RlpBranchLinkExpected)
      # Update ref pool
      links[top] = key.to(RepairKey)
    of 16:
      if not w.isBlob:
        return err(RlpBlobExpected)
      blob16 = rlp.read(Blob)
    else:
      return err(Rlp2Or17ListEntries)
    top.inc

  # Verify extension data
  case top
  of 2:
    if blobs[0].len == 0:
      return err(RlpNonEmptyBlobExpected)
    let (isLeaf, pathSegment) = hexPrefixDecode blobs[0]
    if isLeaf:
      rNode = RNodeRef(
        kind:  Leaf,
        lPfx:  pathSegment,
        lData: blobs[1])
    else:
      var key: NodeKey
      if not key.init(blobs[1]):
        return err(RlpExtPathEncoding)
      # Update ref pool
      rNode = RNodeRef(
        kind:  Extension,
        ePfx:  pathSegment,
        eLink: key.to(RepairKey))
  of 17:
    for n in [0,1]:
      var key: NodeKey
      if not key.init(blobs[n]):
        return err(RlpBranchLinkExpected)
      # Update ref pool
      links[n] = key.to(RepairKey)
    rNode = RNodeRef(
      kind:  Branch,
      bLink: links,
      bData: blob16)
  else:
    discard

  # Add to repair database
  db.tab[repairKey] = rNode

  # Add to hexary trie database -- disabled, using bulk import later
  #ps.base.db.put(nodeKey.ByteArray32, recData)

  when HexaryImportDebugging:
    # Rebuild blob from repair record
    let nodeBlob = rNode.convertTo(Blob)
    if nodeBlob != recData:
      echo "*** hexaryImport oops:",
        " kind=", rNode.kind,
        " key=", repairKey.pp(db),
        " nodeBlob=", nodeBlob.pp,
        " recData=", recData.pp
    doAssert nodeBlob == recData

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
