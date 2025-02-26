# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

{.push raises: [Defect].}

import
  unittest2, stint, stew/byteutils,
  eth/common/eth_types,
  ../populate_db,
  ../network/history/[history_content, accumulator]

func buildProof(
    accumulator: Accumulator,
    epochAccumulators: seq[(ContentKey, EpochAccumulator)],
    header: BlockHeader):
    Result[seq[Digest], string] =
  let
    epochIndex = getEpochIndex(header)
    epochAccumulator = epochAccumulators[epochIndex][1]

    headerRecordIndex = getHeaderRecordIndex(header, epochIndex)
    gIndex = GeneralizedIndex(epochSize*2*2 + (headerRecordIndex*2))

  return epochAccumulator.build_proof(gIndex)

suite "Header Accumulator":
  test "Header Accumulator Update":
    const
      hashTreeRoots = [
        "b629833240bb2f5eabfb5245be63d730ca4ed30d6a418340ca476e7c1f1d98c0",
        "00cbebed829e1babb93f2300bebe7905a98cb86993c7fc09bb5b04626fd91ae5",
        "88cce8439ebc0c1d007177ffb6831c15c07b4361984cc52235b6fd728434f0c7"]

      dataFile = "./fluffy/tests/blocks/mainnet_blocks_1-2.json"

    let blockDataRes = readJsonType(dataFile, BlockDataTable)

    check blockDataRes.isOk()
    let blockData = blockDataRes.get()

    var headers: seq[BlockHeader]
    # Len of headers from blockdata + genesis header
    headers.setLen(blockData.len() + 1)

    headers[0] = getGenesisHeader()

    for k, v in blockData.pairs:
      let res = v.readBlockHeader()
      check res.isOk()
      let header = res.get()
      headers[header.blockNumber.truncate(int)] = header

    var accumulator: Accumulator

    for i, hash in hashTreeRoots:
      updateAccumulator(accumulator, headers[i])

      check accumulator.hash_tree_root().data.toHex() == hashTreeRoots[i]

  test "Header Accumulator Proofs":
    const
      # Amount of headers to be created and added to the accumulator
      amount = 25000
      # Headers to test verification for
      headersToTest = [
        0,
        epochSize - 1,
        epochSize,
        epochSize*2 - 1,
        epochSize*2,
        epochSize*3 - 1,
        epochSize*3,
        epochSize*3 + 1,
        amount - 1]

    var headers: seq[BlockHeader]
    for i in 0..<amount:
      # Note: These test headers will not be a blockchain, as the parent hashes
      # are not properly filled in. That's fine however for this test, as that
      # is not the way the headers are verified with the accumulator.
      headers.add(BlockHeader(
        blockNumber: i.stuint(256), difficulty: 1.stuint(256)))

    let
      accumulator = buildAccumulator(headers)
      epochAccumulators = buildAccumulatorData(headers)

    block: # Test valid headers
      for i in headersToTest:
        let header = headers[i]
        let proofOpt =
          if header.inCurrentEpoch(accumulator):
            none(seq[Digest])
          else:
            let proof = buildProof(accumulator, epochAccumulators, header)
            check proof.isOk()

            some(proof.get())

        check verifyHeader(accumulator, header, proofOpt).isOk()

    block: # Test some invalid headers
      # Test a header with block number > than latest in accumulator
      let header = BlockHeader(blockNumber: 25000.stuint(256))
      check verifyHeader(accumulator, header, none(seq[Digest])).isErr()

      # Test different block headers by altering the difficulty
      for i in headersToTest:
        let header = BlockHeader(
          blockNumber: i.stuint(256), difficulty: 2.stuint(256))

        check verifyHeader(accumulator, header, none(seq[Digest])).isErr()

  test "Header Accumulator header hash for blocknumber":
    var acc = Accumulator.init()

    let
      numEpochs = 2
      numHeadersInCurrentEpoch = 5
      numHeaders = numEpochs * epochSize + numHeadersInCurrentEpoch

    var headerHashes: seq[Hash256] = @[]

    for i in 0..numHeaders:
      var bh = BlockHeader()
      bh.blockNumber = u256(i)
      bh.difficulty = u256(1)
      headerHashes.add(bh.blockHash())
      acc.updateAccumulator(bh)

    # get valid response for epoch 0
    block:
      for i in 0..epochSize-1:
        let res = acc.getHeaderHashForBlockNumber(u256(i))
        check:
          res.kind == HEpoch
          res.epochIndex == 0

    # get valid response for epoch 1
    block:
      for i in epochSize..(2 * epochSize)-1:
        let res = acc.getHeaderHashForBlockNumber(u256(i))
        check:
          res.kind == HEpoch
          res.epochIndex == 1

    # get valid response from current epoch (epoch 3)
    block:
      for i in (2 * epochSize)..(2 * epochSize) + numHeadersInCurrentEpoch:
        let res = acc.getHeaderHashForBlockNumber(u256(i))
        check:
          res.kind == BHash
          res.blockHash == headerHashes[i]

    # get valid response when getting unknown hash
    block:
      let firstUknownBlockNumber = (2 * epochSize) + numHeadersInCurrentEpoch + 1
      let res = acc.getHeaderHashForBlockNumber(u256(firstUknownBlockNumber))

      check:
        res.kind == UnknownBlockNumber

      let res1 = acc.getHeaderHashForBlockNumber(u256(3 * epochSize))
      check:
        res1.kind == UnknownBlockNumber
