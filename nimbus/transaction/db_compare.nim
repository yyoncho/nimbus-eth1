# Nimbus - Steps towards a fast and small Ethereum data store
#
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  sets, tables,
  stint, chronicles, stew/byteutils,
  eth/common/eth_types,
  ../constants,
  ./host_types, ./db_query

template toHex(hash: Hash256): string = hash.data.toHex

type
  DbSeenAccount* = ref object
    seenNonce*:       bool
    seenBalance*:     bool
    seenCodeHash*:    bool
    seenExists*:      bool
    seenStorages*:    HashSet[UInt256]
    seenAllStorages*: bool

  DbSeenAccounts* = ref Table[EthAddress, DbSeenAccount]

  DbSeenBlocks* = ref Table[BlockNumber, DbSeenAccounts]

  DbCompare = object
    ethDb: EthDB
    errorCount: int
    seen: DBSeenBlocks

var dbCompare {.threadvar.}: DbCompare
  # `dbCompare` is cross-cutting; a global is fine for these tests.
  # This is thread-local for Nim simplicity.

template dbCompareEnabled*: bool =
  dbCompare.ethDb != nil

template dbCompareErrorCount*: int =
  dbCompare.errorCount

proc dbCompareResetSeen*() =
  dbCompare.seen = nil
  dbCompare.ethDb.ethDbShowStats()

proc dbCompareOpen*(path: string) {.raises: [IOError, OSError, Defect].} =
  # Raises `OSError` on error, good enough for this versipn.
  dbCompare.ethDb = ethDbOpen(path)
  info "DB: Verifying all EVM inputs against compressed state history database",
    file=path, size=dbCompare.ethDb.ethDbSize()

proc lookupAccount(blockNumber: BlockNumber, address: EthAddress,
                   field: string, accountResult: var DbAccount): bool =
  debug "DB COMPARE: Looking up account field",
    `block`=blockNumber, account=address, field
  return dbCompare.ethDb.ethDbQueryAccount(blockNumber, address, accountResult)

proc lookupStorage(blockNumber: BlockNumber, address: EthAddress,
                   slot: UInt256, slotResult: var DbSlotResult): bool =
  debug "DB COMPARE: Looking up account storage slot",
    `block`=blockNumber, account=address, slot=slot.toHex
  return dbCompare.ethDb.ethDbQueryStorage(blockNumber, address, slot, slotResult)

proc getSeenAccount(host: TransactionHost, address: EthAddress): DBSeenAccount =
  # Keep track of what fields have been read already, so that later requests
  # for the same address etc during the processing of a block are not checked.
  # Because later requests are intermediate values, not based on the parent
  # block's `stateRoot`, their values are not expected to match the DB.
  let blockNumber = host.txContext.block_number.toBlockNumber
  if dbCompare.seen.isNil:
    dbCompare.seen = newTable[BlockNumber, DbSeenAccounts]()
  let seenAccountsRef = dbCompare.seen.mgetOrPut(blockNumber, nil).addr
  if seenAccountsRef[].isNil:
    seenAccountsRef[] = newTable[EthAddress, DBSeenAccount]()
  let seenAccountRef = seenAccountsRef[].mgetOrPut(address, nil).addr
  if seenAccountRef[].isNil:
    seenAccountRef[] = DBSeenAccount()
  return seenAccountRef[]

template dbCompareFail() =
  inc dbCompare.errorCount
  if dbCompare.errorCount < 100 or dbCompare.errorCount mod 100 == 0:
    error "*** DB COMPARE: Error count", errorCount=dbCompare.errorCount
  doAssert dbCompare.errorCount < 10000

proc dbCompareNonce*(host: TransactionHost, address: EthAddress,
                     nonce: AccountNonce) =
  let seenAccount = getSeenAccount(host, address)
  if seenAccount.seenNonce:
    return
  seenAccount.seenNonce = true

  let blockNumber = host.txContext.block_number.toBlockNumber
  var accountResult {.noinit.}: DbAccount
  let found = lookupAccount(blockNumber, address, "nonce", accountResult)
  if not found:
    if nonce != 0:
      error "*** DB MISMATCH: Account missing, expected nonce != 0",
        `block`=blockNumber, account=address, expectedNonce=nonce
      dbCompareFail()
  else:
    if nonce != accountResult.nonce:
      error "*** DB MISMATCH: Account found, nonce does not match",
        `block`=blockNumber, account=address, expectedNonce=nonce,
        foundNonce=accountResult.nonce
      dbCompareFail()

proc dbCompareBalance*(host: TransactionHost, address: EthAddress,
                       balance: UInt256) =
  let seenAccount = getSeenAccount(host, address)
  if seenAccount.seenBalance:
    return
  seenAccount.seenBalance = true

  let blockNumber = host.txContext.block_number.toBlockNumber
  var accountResult {.noinit.}: DbAccount
  let found = lookupAccount(blockNumber, address, "balance", accountResult)
  if not found:
    if balance != 0:
      error "*** DB MISMATCH: Account missing, expected balance != 0",
        `block`=blockNumber, account=address, expectedBalance=balance.toHex
      dbCompareFail()
  else:
    if balance != accountResult.balance:
      error "*** DB MISMATCH: Account found, balance does not match",
        `block`=blockNumber, account=address, expectedBalance=balance.toHex,
        foundBalance=accountResult.balance.toHex
      dbCompareFail()

proc dbCompareCodeHash*(host: TransactionHost, address: EthAddress,
                        codeHash: Hash256) =
  let seenAccount = getSeenAccount(host, address)
  if seenAccount.seenCodeHash:
    return
  seenAccount.seenCodeHash = true

  let blockNumber = host.txContext.block_number.toBlockNumber
  var accountResult {.noinit.}: DbAccount
  let found = lookupAccount(blockNumber, address, "codeHash", accountResult)
  if not found:
    if codeHash != ZERO_HASH256:
      error "*** DB MISMATCH: Account missing, expected codeHash != 0",
        `block`=blockNumber, account=address, expectedCodeHash=codeHash.toHex
      dbCompareFail()
  else:
    if codeHash != accountResult.codeHash:
      error "*** DB MISMATCH: Account found, codeHash does not match",
        `block`=blockNumber, account=address, expectedCodeHash=codeHash.toHex,
        foundCodeHash=accountResult.codeHash.toHex
      dbCompareFail()

proc dbCompareExists*(host: TransactionHost, address: EthAddress,
                      exists: bool, forkSpurious: bool) =
  let seenAccount = getSeenAccount(host, address)
  if seenAccount.seenExists:
    return
  seenAccount.seenExists = true

  let blockNumber = host.txContext.block_number.toBlockNumber
  var accountResult {.noinit.}: DbAccount
  let found = lookupAccount(blockNumber, address, "exists", accountResult)
  if found != exists:
    if exists:
      error "*** DB MISMATCH: Account missing, expected exists=true",
        `block`=blockNumber, account=address
    else:
      error "*** DB MISMATCH: Account found, expected exists=false",
        `block`=blockNumber, account=address
    dbCompareFail()

proc dbCompareStorage*(host: TransactionHost, address: EthAddress,
                       slot: UInt256, value: UInt256) =
  let seenAccount = getSeenAccount(host, address)
  if seenAccount.seenAllStorages:
    return
  if seenAccount.seenStorages.containsOrIncl(slot):
    return

  let blockNumber = host.txContext.block_number.toBlockNumber
  var slotResult {.noinit.}: DbSlotResult
  let found = lookupStorage(blockNumber, address, slot, slotResult)
  if not found:
    if slotResult.value != 0.u256:
      error "*** DB MISMATCH: Storage slot missing, expecting value != 0",
        `block`=blockNumber, account=address, slot=slot.toHex,
        expectedValue=slotResult.value.toHex
      dbCompareFail()
  else:
    if value != slotResult.value:
      error "*** DB MISMATCH: Storage slot found, value does not match",
        `block`=blockNumber, account=address, slot=slot.toHex,
        expectedValue=value.toHex, foundValue=slotResult.value.toHex
      dbCompareFail()

proc dbCompareClearStorage*(host: TransactionHost, address: EthAddress) =
  let seenAccount = getSeenAccount(host, address)
  seenAccount.seenAllStorages = true
  seenAccount.seenStorages.init()
  let blockNumber = host.txContext.block_number.toBlockNumber
  debug "DB COMPARE: Clearing all storage slots for self-destruct",
    `block`=blockNumber, account=address
