# Nimbus - Ethereum Wire Protocol, version eth/65
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## This module implements Ethereum Wire Protocol version 65, `eth/65`.
## Specification:
##   https://github.com/ethereum/devp2p/blob/master/caps/eth.md

import
  chronos, stint, chronicles, stew/byteutils, macros,
  eth/[common/eth_types, rlp, p2p],
  eth/p2p/[rlpx, private/p2p_types, blockchain_utils],
  ./sync_types

export
  tracePackets, tracePacket,
  traceGossips, traceGossip,
  traceTimeouts, traceTimeout,
  traceNetworkErrors, traceNetworkError,
  tracePacketErrors, tracePacketError

type
  NewBlockHashesAnnounce* = object
    hash: BlockHash
    number: BlockNumber

  NewBlockAnnounce* = EthBlock

  ForkId* = object
    forkHash: array[4, byte] # The RLP encoding must be exactly 4 bytes.
    forkNext: BlockNumber    # The RLP encoding must be variable-length

  PeerState = ref object
    initialized*: bool
    bestBlockHash*: BlockHash
    bestDifficulty*: DifficultyInt

const
  maxStateFetch* = 384
  maxBodiesFetch* = 128
  maxReceiptsFetch* = 256
  maxHeadersFetch* = 192
  ethVersion = 65

func toHex*(hash: Hash256): string = hash.data.toHex

func traceStep*(request: BlocksRequest): string =
  result = if request.reverse: "-" else: "+"
  if request.skip < high(typeof(request.skip)):
    result.add($(request.skip + 1))
  else:
    result.add(static($(high(typeof(request.skip)).u256 + 1)))

p2pProtocol eth(version = ethVersion,
                peerState = PeerState,
                useRequestIds = false):

  onPeerConnected do (peer: Peer):
    let
      network = peer.network
      chain = network.chain
      bestBlock = chain.getBestBlockHeader
      chainForkId = chain.getForkId(bestBlock.blockNumber)
      forkId = ForkId(
        forkHash: chainForkId.crc.toBytesBe,
        forkNext: chainForkId.nextFork.toBlockNumber,
      )

    tracePacket ">> Sending eth.Status (0x00) [eth/" & $ethVersion & "]",
      td=bestBlock.difficulty,
      bestHash=bestBlock.blockHash.toHex,
      networkId=network.networkId,
      genesis=chain.genesisHash.toHex,
      forkHash=forkId.forkHash.toHex, forkNext=forkId.forkNext,
      peer

    let m = await peer.status(ethVersion,
                              network.networkId,
                              bestBlock.difficulty,
                              bestBlock.blockHash,
                              chain.genesisHash,
                              forkId,
                              timeout = chronos.seconds(10))

    if traceHandshakes:
      trace "Handshake: Local and remote networkId",
        local=network.networkId, remote=m.networkId
      trace "Handshake: Local and remote genesisHash",
        local=chain.genesisHash.toHex, remote=m.genesisHash.toHex
      trace "Handshake: Local and remote forkId",
        local=(forkId.forkHash.toHex & "/" & $forkId.forkNext),
        remote=(m.forkId.forkHash.toHex & "/" & $m.forkId.forkNext)

    if m.networkId != network.networkId:
      trace "Peer for a different network (networkId)",
        expectNetworkId=network.networkId, gotNetworkId=m.networkId, peer
      raise newException(UselessPeerError, "Eth handshake for different network")

    if m.genesisHash != chain.genesisHash:
      trace "Peer for a different network (genesisHash)",
        expectGenesis=chain.genesisHash.toHex, gotGenesis=m.genesisHash.toHex,
        peer
      raise newException(UselessPeerError, "Eth handshake for different network")

    trace "Peer matches our network", peer
    peer.state.initialized = true
    peer.state.bestDifficulty = m.totalDifficulty
    peer.state.bestBlockHash = m.bestHash

  handshake:
    # User message 0x00: Status.
    proc status(peer: Peer,
                ethVersionArg: uint,
                networkId: NetworkId,
                totalDifficulty: DifficultyInt,
                bestHash: BlockHash,
                genesisHash: BlockHash,
                forkId: ForkId) =
      tracePacket "<< Received eth.Status (0x00) [eth/" & $ethVersion & "]",
        td=totalDifficulty, bestHash=bestHash.toHex,
        networkId, genesis=genesisHash.toHex,
        forkHash=forkId.forkHash.toHex, forkNext=forkId.forkNext,
        peer

  # User message 0x01: NewBlockHashes.
  proc newBlockHashes(peer: Peer, hashes: openArray[NewBlockHashesAnnounce]) =
    traceGossip "<< Discarding eth.NewBlockHashes (0x01)",
      got=hashes.len, peer
    discard

  # User message 0x02: Transactions.
  proc transactions(peer: Peer, transactions: openArray[Transaction]) =
    traceGossip "<< Discarding eth.Transactions (0x02)",
      got=transactions.len, peer
    discard

  requestResponse:
    # User message 0x03: GetBlockHeaders.
    proc getBlockHeaders(peer: Peer, request: BlocksRequest) =
      if tracePackets:
        if request.maxResults == 1 and request.startBlock.isHash:
          tracePacket "<< Received eth.GetBlockHeaders/Hash (0x03)",
            blockHash=($request.startBlock.hash), count=1, peer
        elif request.maxResults == 1:
          tracePacket "<< Received eth.GetBlockHeaders (0x03)",
            `block`=request.startBlock.number, count=1, peer
        elif request.startBlock.isHash:
          tracePacket "<< Received eth.GetBlockHeaders/Hash (0x03)",
            firstBlockHash=($request.startBlock.hash), count=request.maxResults,
            step=traceStep(request), peer
        else:
          tracePacket "<< Received eth.GetBlockHeaders (0x03)",
            firstBlock=request.startBlock.number, count=request.maxResults,
            step=traceStep(request), peer

      if request.maxResults > uint64(maxHeadersFetch):
        debug "eth.GetBlockHeaders (0x03) requested too many headers",
          requested=request.maxResults, max=maxHeadersFetch, peer
        await peer.disconnect(BreachOfProtocol)
        return

      let headers = peer.network.chain.getBlockHeaders(request)
      if headers.len > 0:
        tracePacket ">> Replying with eth.BlockHeaders (0x04)",
          sent=headers.len, requested=request.maxResults, peer
      else:
        tracePacket ">> Replying EMPTY eth.BlockHeaders (0x04)",
          sent=0, requested=request.maxResults, peer

      await response.send(headers)

    # User message 0x04: BlockHeaders.
    proc blockHeaders(p: Peer, headers: openArray[BlockHeader])

  requestResponse:
    # User message 0x05: GetBlockBodies.
    proc getBlockBodies(peer: Peer, hashes: openArray[BlockHash]) =
      tracePacket "<< Received eth.GetBlockBodies (0x05)",
        hashCount=hashes.len, peer
      if hashes.len > maxBodiesFetch:
        debug "eth.GetBlockBodies (0x05) requested too many bodies",
          requested=hashes.len, max=maxBodiesFetch, peer
        await peer.disconnect(BreachOfProtocol)
        return

      let bodies = peer.network.chain.getBlockBodies(hashes)
      if bodies.len > 0:
        tracePacket ">> Replying with eth.BlockBodies (0x06)",
          sent=bodies.len, requested=hashes.len, peer
      else:
        tracePacket ">> Replying EMPTY eth.BlockBodies (0x06)",
          sent=0, requested=hashes.len, peer

      await response.send(bodies)

    # User message 0x06: BlockBodies.
    proc blockBodies(peer: Peer, blocks: openArray[BlockBody])

  # User message 0x07: NewBlock.
  proc newBlock(peer: Peer, bh: EthBlock, totalDifficulty: DifficultyInt) =
    # (Note, needs to use `EthBlock` instead of its alias `NewBlockAnnounce`
    # because either `p2pProtocol` or RLPx doesn't work with an alias.)
    traceGossip "<< Discarding eth.NewBlock (0x07)",
      blockNumber=bh.header.blockNumber, blockDifficulty=bh.header.difficulty,
      totalDifficulty, peer
    discard

  # User message 0x08: NewPooledTransactionHashes.
  proc newPooledTransactionHashes(peer: Peer, hashes: openArray[TxHash]) =
    traceGossip "<< Discarding eth.NewPooledTransactionHashes (0x08)",
      hashCount=hashes.len, peer
    discard

  requestResponse:
    # User message 0x09: GetPooledTransactions.
    proc getPooledTransactions(peer: Peer, hashes: openArray[TxHash]) =
      tracePacket "<< Received eth.GetPooledTransactions (0x09)",
        hashCount=hashes.len, peer

      tracePacket ">> Replying EMPTY eth.PooledTransactions (0x10)",
        sent=0, requested=hashes.len, peer
      await response.send([])

    # User message 0x0a: PooledTransactions.
    proc pooledTransactions(peer: Peer, transactions: openArray[Transaction])

  nextId 0x0d

  requestResponse:
    # User message 0x0d: GetNodeData.
    proc getNodeData(peer: Peer, hashes: openArray[NodeHash]) =
      tracePacket "<< Received eth.GetNodeData (0x0d)",
        hashCount=hashes.len, peer

      let blobs = peer.network.chain.getStorageNodes(hashes)
      if blobs.len > 0:
        tracePacket ">> Replying with eth.NodeData (0x0e)",
          sent=blobs.len, requested=hashes.len, peer
      else:
        tracePacket ">> Replying EMPTY eth.NodeData (0x0e)",
          sent=0, requested=hashes.len, peer

      await response.send(blobs)

    # User message 0x0e: NodeData.
    proc nodeData(peer: Peer, data: openArray[Blob])

  requestResponse:
    # User message 0x0f: GetReceipts.
    proc getReceipts(peer: Peer, hashes: openArray[BlockHash]) =
      tracePacket "<< Received eth.GetReceipts (0x0f)",
        hashCount=hashes.len, peer

      tracePacket ">> Replying EMPTY eth.Receipts (0x10)",
        sent=0, requested=hashes.len, peer
      await response.send([])
      # TODO: implement `getReceipts` and reactivate this code
      # await response.send(peer.network.chain.getReceipts(hashes))

    # User message 0x10: Receipts.
    proc receipts(peer: Peer, receipts: openArray[Receipt])
