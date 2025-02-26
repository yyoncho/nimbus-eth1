import
  macrocache, strutils, sequtils, unittest2, times,
  stew/byteutils, chronicles, eth/[common, keys],
  stew/shims/macros

import
  options, eth/trie/[db, hexary],
  ../nimbus/db/[db_chain, accounts_cache],
  ../nimbus/vm_internals, ../nimbus/forks,
  ../nimbus/transaction/call_evm,
  ../nimbus/[transaction, chain_config, genesis, vm_types, vm_state],
  ../nimbus/utils/difficulty

export byteutils
{.experimental: "dynamicBindSym".}

# backported from Nim 0.19.9
# remove this when we use newer Nim
proc newLitFixed*(arg: enum): NimNode {.compileTime.} =
  result = newCall(
    arg.type.getTypeInst[1],
    newLit(int(arg))
  )

type
  VMWord* = array[32, byte]
  Storage* = tuple[key, val: VMWord]

  Assembler* = object
    title*: string
    stack*: seq[VMWord]
    memory*: seq[VMWord]
    storage*: seq[Storage]
    code*: seq[byte]
    logs*: seq[Log]
    success*: bool
    gasLimit*: GasInt
    gasUsed*: GasInt
    data*: seq[byte]
    output*: seq[byte]
    fork*: Fork

const
  idToOpcode = CacheTable"NimbusMacroAssembler"

static:
  for n in Op:
    idToOpcode[$n] = newLit(ord(n))

  # EIP-4399 new opcode
  idToOpcode["PrevRandao"] = newLit(ord(Difficulty))

proc validateVMWord(val: string, n: NimNode): VMWord =
  if val.len <= 2 or val.len > 66: error("invalid hex string", n)
  if not (val[0] == '0' and val[1] == 'x'): error("invalid hex string", n)
  let zerosLen = 64 - (val.len - 2)
  let value = repeat('0', zerosLen) & val.substr(2)
  hexToByteArray(value, result)

proc validateVMWord(val: NimNode): VMWord =
  val.expectKind(nnkStrLit)
  validateVMWord(val.strVal, val)

proc parseVMWords(list: NimNode): seq[VMWord] =
  result = @[]
  list.expectKind nnkStmtList
  for val in list:
    result.add validateVMWord(val)

proc validateStorage(val: NimNode): Storage =
  val.expectKind(nnkCall)
  val[0].expectKind(nnkStrLit)
  val[1].expectKind(nnkStmtList)
  doAssert(val[1].len == 1)
  val[1][0].expectKind(nnkStrLit)
  result = (validateVMWord(val[0]), validateVMWord(val[1][0]))

proc parseStorage(list: NimNode): seq[Storage] =
  result = @[]
  list.expectKind nnkStmtList
  for val in list:
    result.add validateStorage(val)

proc parseSuccess(list: NimNode): bool =
  list.expectKind nnkStmtList
  list[0].expectKind(nnkIdent)
  $list[0] == "true"

proc parseData(list: NimNode): seq[byte] =
  result = @[]
  list.expectKind nnkStmtList
  for n in list:
    n.expectKind(nnkStrLit)
    result.add hexToSeqByte(n.strVal)

proc parseLog(node: NimNode): Log =
  node.expectKind(nnkPar)
  for item in node:
    item.expectKind(nnkExprColonExpr)
    let label = item[0].strVal
    let body  = item[1]
    case label.normalize
    of "address":
      body.expectKind(nnkStrLit)
      let value = body.strVal
      if value.len < 20:
        error("bad address format", body)
      hexToByteArray(value, result.address)
    of "topics":
      body.expectKind(nnkBracket)
      for x in body:
        result.topics.add validateVMWord(x.strVal, x)
    of "data":
      result.data = hexToSeqByte(body.strVal)
    else:error("unknown log section '" & label & "'", item[0])

proc parseLogs(list: NimNode): seq[Log] =
  result = @[]
  list.expectKind nnkStmtList
  for n in list:
    result.add parseLog(n)

proc validateOpcode(sym: NimNode) =
  let typ = getTypeInst(sym)
  typ.expectKind(nnkSym)
  if $typ != "Op":
    error("unknown opcode '" & $sym & "'", sym)

proc addOpCode(code: var seq[byte], node, params: NimNode) =
  node.expectKind nnkSym
  let opcode = Op(idToOpcode[node.strVal].intVal)
  case opcode
  of Push1..Push32:
    if params.len != 1:
      error("expect 1 param, but got " & $params.len, node)
    let paramWidth = (opcode.ord - 95) * 2
    params[0].expectKind nnkStrLit
    var val = params[0].strVal
    if val[0] == '0' and val[1] == 'x':
      val = val.substr(2)
      if val.len != paramWidth:
        error("expected param with " & $paramWidth & " hex digits, got " & $val.len, node)
      code.add byte(opcode)
      code.add hexToSeqByte(val)
    else:
      error("invalid hex format", node)
  else:
    if params.len > 0:
      error("there should be no param for this instruction", node)
    code.add byte(opcode)

proc parseCode(codes: NimNode): seq[byte] =
  let emptyNode = newEmptyNode()
  codes.expectKind nnkStmtList
  for pc, line in codes:
    line.expectKind({nnkCommand, nnkIdent, nnkStrLit})
    if line.kind == nnkStrLit:
      result.add hexToSeqByte(line.strVal)
    elif line.kind == nnkIdent:
      let sym = bindSym(line)
      validateOpcode(sym)
      result.addOpCode(sym, emptyNode)
    elif line.kind == nnkCommand:
      let sym = bindSym(line[0])
      validateOpcode(sym)
      var params = newNimNode(nnkBracket)
      for i in 1 ..< line.len:
        params.add line[i]
      result.addOpCode(sym, params)
    else:
      error("unknown syntax: " & line.toStrLit.strVal, line)

proc parseFork(fork: NimNode): Fork =
  fork[0].expectKind({nnkIdent, nnkStrLit})
  # Normalise whitespace and capitalize each word because `parseEnum` matches
  # enum string values not symbols, and the strings are capitalized in `Fork`.
  parseEnum[Fork](fork[0].strVal.splitWhitespace().map(capitalizeAscii).join(" "))

proc parseGasUsed(gas: NimNode): GasInt =
  gas[0].expectKind(nnkIntLit)
  result = gas[0].intVal

proc generateVMProxy(boa: Assembler): NimNode =
  let
    vmProxy = genSym(nskProc, "vmProxy")
    chainDB = ident("chainDB")
    vmState = ident("vmState")
    title = boa.title
    body = newLitFixed(boa)

  result = quote do:
    test `title`:
      proc `vmProxy`(): bool =
        let boa = `body`
        runVM(`vmState`, `chainDB`, boa)
      {.gcsafe.}:
        check `vmProxy`()

  when defined(macro_assembler_debug):
    echo result.toStrLit.strVal

proc initDatabase*(networkId = MainNet): (BaseVMState, BaseChainDB) =
  let db = newBaseChainDB(newMemoryDB(), false, networkId, networkParams(networkId))
  initializeEmptyDb(db)

  let
    parent = getCanonicalHead(db)
    coinbase = hexToByteArray[20]("bb7b8287f3f0a933474a79eae42cbca977791171")
    timestamp = parent.timestamp + initDuration(seconds = 1)
    header = BlockHeader(
      blockNumber: 1.u256,
      stateRoot: parent.stateRoot,
      parentHash: parent.blockHash,
      coinbase: coinbase,
      timestamp: timestamp,
      difficulty: db.config.calcDifficulty(timestamp, parent),
      gasLimit: 100_000
    )
    vmState = BaseVMState.new(header, db)

  (vmState, db)

proc runVM*(vmState: BaseVMState, chainDB: BaseChainDB, boa: Assembler): bool =
  const codeAddress = hexToByteArray[20]("460121576cc7df020759730751f92bd62fd78dd6")
  let privateKey = PrivateKey.fromHex("7a28b5ba57c53603b0b07b56bba752f7784bf506fa95edc395f5cf6c7514fe9d")[]

  vmState.mutateStateDB:
    db.setCode(codeAddress, boa.code)
    db.setBalance(codeAddress, 1_000_000.u256)

  let unsignedTx = Transaction(
    txType: TxLegacy,
    nonce: 0,
    gasPrice: 1.GasInt,
    gasLimit: 500_000_000.GasInt,
    to: codeAddress.some,
    value: 500.u256,
    payload: boa.data
  )
  let tx = signTransaction(unsignedTx, privateKey, chainDB.config.chainId, false)
  let asmResult = testCallEvm(tx, tx.getSender, vmState, boa.fork)

  if not asmResult.isError:
    if boa.success == false:
      error "different success value", expected=boa.success, actual=true
      return false
  else:
    if boa.success == true:
      error "different success value", expected=boa.success, actual=false
      return false

  if boa.gasUsed != -1:
    if boa.gasUsed != asmResult.gasUsed:
      error "different gasUsed", expected=boa.gasUsed, actual=asmResult.gasUsed
      return false

  if boa.stack.len != asmResult.stack.values.len:
    error "different stack len", expected=boa.stack.len, actual=asmResult.stack.values.len
    return false

  for i, v in asmResult.stack.values:
    let actual = v.dumpHex()
    let val = boa.stack[i].toHex()
    if actual != val:
      error "different stack value", idx=i, expected=val, actual=actual
      return false

  const chunkLen = 32
  let numChunks = asmResult.memory.len div chunkLen

  if numChunks != boa.memory.len:
    error "different memory len", expected=boa.memory.len, actual=numChunks
    return false

  for i in 0 ..< numChunks:
    let actual = asmResult.memory.bytes.toOpenArray(i * chunkLen, (i + 1) * chunkLen - 1).toHex()
    let mem = boa.memory[i].toHex()
    if mem != actual:
      error "different memory value", idx=i, expected=mem, actual=actual
      return false

  var stateDB = vmState.stateDB
  stateDB.persist()

  var
    storageRoot = stateDB.getStorageRoot(codeAddress)
    trie = initSecureHexaryTrie(chainDB.db, storageRoot)

  for kv in boa.storage:
    let key = kv[0].toHex()
    let val = kv[1].toHex()
    let keyBytes = (@(kv[0]))
    let actual = trie.get(keyBytes).toHex()
    let zerosLen = 64 - (actual.len)
    let value = repeat('0', zerosLen) & actual
    if val != value:
      error "storage has different value", key=key, expected=val, actual=value
      return false

  let logs = vmState.logEntries
  if logs.len != boa.logs.len:
    error "different logs len", expected=boa.logs.len, actual=logs.len
    return false

  for i, log in boa.logs:
    let eAddr = log.address.toHex()
    let aAddr = logs[i].address.toHex()
    if eAddr != aAddr:
      error "different address", expected=eAddr, actual=aAddr, idx=i
      return false
    let eData = log.data.toHex()
    let aData = logs[i].data.toHex()
    if eData != aData:
      error "different data", expected=eData, actual=aData, idx=i
      return false
    if log.topics.len != logs[i].topics.len:
      error "different topics len", expected=log.topics.len, actual=logs[i].topics.len, idx=i
      return false
    for x, t in log.topics:
      let eTopic = t.toHex()
      let aTopic = logs[i].topics[x].toHex()
      if eTopic != aTopic:
        error "different topic in log entry", expected=eTopic, actual=aTopic, logIdx=i, topicIdx=x
        return false

  if boa.output.len > 0:
    let actual = asmResult.output.toHex()
    let expected = boa.output.toHex()
    if expected != actual:
      error "different output detected", expected=expected, actual=actual
      return false

  result = true

macro assembler*(list: untyped): untyped =
  var boa = Assembler(success: true, fork: FkFrontier, gasUsed: -1)
  list.expectKind nnkStmtList
  for callSection in list:
    callSection.expectKind(nnkCall)
    let label = callSection[0].strVal
    let body  = callSection[1]
    case label.normalize
    of "title":
      let title = body[0]
      title.expectKind(nnkStrLit)
      boa.title = title.strVal
    of "code"  : boa.code = parseCode(body)
    of "memory": boa.memory = parseVMWords(body)
    of "stack" : boa.stack = parseVMWords(body)
    of "storage": boa.storage = parseStorage(body)
    of "logs": boa.logs = parseLogs(body)
    of "success": boa.success = parseSuccess(body)
    of "data": boa.data = parseData(body)
    of "output": boa.output = parseData(body)
    of "fork": boa.fork = parseFork(body)
    of "gasused": boa.gasUsed = parseGasUsed(body)
    else: error("unknown section '" & label & "'", callSection[0])
  result = boa.generateVMProxy()

macro evmByteCode*(list: untyped): untyped =
  list.expectKind nnkStmtList
  var code = parseCode(list)
  result = newLitFixed(code)
