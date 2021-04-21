# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handlers: Call Operations
## ====================================
##

const
  kludge {.intdefine.}: int = 0
  breakCircularDependency {.used.} = kludge > 0

import
  ../../../errors,
  ../../stack,
  ../../v2memory,
  ../forks_list,
  ../op_codes,
  ../utils/v2utils_numeric,
  chronicles,
  eth/common/eth_types,
  stint

# ------------------------------------------------------------------------------
# Kludge BEGIN
# ------------------------------------------------------------------------------

when not breakCircularDependency:
  import
    ./oph_defs,
    ../../../constants,
    ../../../db/accounts_cache,
    ../../compu_helper,
    ../../v2computation,
    ../../v2state,
    ../../v2types,
    ../gas_costs,
    ../gas_meter,
    eth/common

else:
  import
    ./oph_defs_kludge,
    ./oph_helpers_kludge

# ------------------------------------------------------------------------------
# Kludge END
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Private
# ------------------------------------------------------------------------------

type
  LocalParams = tuple
    gas:             UInt256
    value:           UInt256
    destination:     EthAddress
    sender:          EthAddress
    memInPos:        int
    memInLen:        int
    memOutPos:       int
    memOutLen:       int
    flags:           MsgFlags
    memOffset:       int
    memLength:       int
    contractAddress: EthAddress


proc updateStackAndParams(q: var LocalParams; c: Computation) =
  c.stack.push(0)

  let
    outLen = calcMemSize(q.memOutPos, q.memOutLen)
    inLen = calcMemSize(q.memInPos, q.memInLen)

  # get the bigger one
  if outLen < inLen:
    q.memOffset = q.memInPos
    q.memLength = q.memInLen
  else:
    q.memOffset = q.memOutPos
    q.memLength = q.memOutLen

  # EIP2929: This came before old gas calculator
  #           because it will affect `c.gasMeter.gasRemaining`
  #           and further `childGasLimit`
  if FkBerlin <= c.fork:
    c.vmState.mutateStateDB:
      if not db.inAccessList(q.destination):
        db.accessList(q.destination)

        # The WarmStorageReadCostEIP2929 (100) is already deducted in
        # the form of a constant `gasCall`
        c.gasMeter.consumeGas(
          ColdAccountAccessCost - WarmStorageReadCost,
          reason = "EIP2929 gasCall")


proc callParams(c: Computation): LocalParams =
  ## Helper for callOp()
  result.gas             = c.stack.popInt()
  result.destination     = c.stack.popAddress()
  result.value           = c.stack.popInt()
  result.memInPos        = c.stack.popInt().cleanMemRef
  result.memInLen        = c.stack.popInt().cleanMemRef
  result.memOutPos       = c.stack.popInt().cleanMemRef
  result.memOutLen       = c.stack.popInt().cleanMemRef

  result.sender          = c.msg.contractAddress
  result.flags           = c.msg.flags
  result.contractAddress = result.destination

  result.updateStackAndParams(c)


proc callCodeParams(c: Computation): LocalParams =
  ## Helper for callCodeOp()
  result = c.callParams
  result.contractAddress = c.msg.contractAddress


proc delegateCallParams(c: Computation): LocalParams =
  ## Helper for delegateCall()
  result.gas             = c.stack.popInt()
  result.destination     = c.stack.popAddress()
  result.memInPos        = c.stack.popInt().cleanMemRef
  result.memInLen        = c.stack.popInt().cleanMemRef
  result.memOutPos       = c.stack.popInt().cleanMemRef
  result.memOutLen       = c.stack.popInt().cleanMemRef

  result.value           = c.msg.value
  result.sender          = c.msg.sender
  result.flags           = c.msg.flags
  result.contractAddress = c.msg.contractAddress

  result.updateStackAndParams(c)


proc staticCallParams(c: Computation):  LocalParams =
  ## Helper for staticCall()
  result.gas             = c.stack.popInt()
  result.destination     = c.stack.popAddress()
  result.memInPos        = c.stack.popInt().cleanMemRef
  result.memInLen        = c.stack.popInt().cleanMemRef
  result.memOutPos       = c.stack.popInt().cleanMemRef
  result.memOutLen       = c.stack.popInt().cleanMemRef

  result.value           = 0.u256
  result.sender          = c.msg.contractAddress
  result.flags           = emvcStatic
  result.contractAddress = result.destination

  result.updateStackAndParams(c)

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

const
  callOp: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## 0xf1, Message-Call into an account

    if emvcStatic == k.cpt.msg.flags and k.cpt.stack[^3, UInt256] > 0.u256:
      raise newException(
        StaticContextError,
        "Cannot modify state while inside of a STATICCALL context")
    let
      p = k.cpt.callParams

    var (gasCost, childGasLimit) = k.cpt.gasCosts[Call].c_handler(
      p.value,
      GasParams(
        kind:             Call,
        c_isNewAccount:   not k.cpt.accountExists(p.contractAddress),
        c_gasBalance:     k.cpt.gasMeter.gasRemaining,
        c_contractGas:    p.gas,
        c_currentMemSize: k.cpt.memory.len,
        c_memOffset:      p.memOffset,
        c_memLength:      p.memLength))

    # EIP 2046: temporary disabled
    # reduce gas fee for precompiles
    # from 700 to 40
    if gasCost >= 0:
      k.cpt.gasMeter.consumeGas(gasCost, reason = $Call)

    k.cpt.returnData.setLen(0)

    if k.cpt.msg.depth >= MaxCallDepth:
      debug "Computation Failure",
        reason = "Stack too deep",
        maximumDepth = MaxCallDepth,
        depth = k.cpt.msg.depth
      k.cpt.gasMeter.returnGas(childGasLimit)
      return

    if gasCost < 0 and childGasLimit <= 0:
      raise newException(
        OutOfGas, "Gas not enough to perform calculation (call)")

    k.cpt.memory.extend(p.memInPos, p.memInLen)
    k.cpt.memory.extend(p.memOutPos, p.memOutLen)

    let senderBalance = k.cpt.getBalance(p.sender)
    if senderBalance < p.value:
      debug "Insufficient funds",
        available = senderBalance,
        needed = k.cpt.msg.value
      k.cpt.gasMeter.returnGas(childGasLimit)
      return

    let msg = Message(
      kind:            evmcCall,
      depth:           k.cpt.msg.depth + 1,
      gas:             childGasLimit,
      sender:          p.sender,
      contractAddress: p.contractAddress,
      codeAddress:     p.destination,
      value:           p.value,
      data:            k.cpt.memory.read(p.memInPos, p.memInLen),
      flags:           p.flags)

    # call -- need to un-capture k
    var
      c = k.cpt
      child = newComputation(c.vmState, msg)
    c.chainTo(child):
      if not child.shouldBurnGas:
        c.gasMeter.returnGas(child.gasMeter.gasRemaining)

      if child.isSuccess:
        c.merge(child)
        c.stack.top(1)

      c.returnData = child.output
      let actualOutputSize = min(p.memOutLen, child.output.len)
      if actualOutputSize > 0:
        c.memory.write(p.memOutPos,
                       child.output.toOpenArray(0, actualOutputSize - 1))

  # ---------------------

  callCodeOp: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## 0xf2, Message-call into this account with an alternative account's code.
    let
      p = k.cpt.callCodeParams

    var (gasCost, childGasLimit) = k.cpt.gasCosts[CallCode].c_handler(
      p.value,
      GasParams(
        kind:             CallCode,
        c_isNewAccount:   not k.cpt.accountExists(p.contractAddress),
        c_gasBalance:     k.cpt.gasMeter.gasRemaining,
        c_contractGas:    p.gas,
        c_currentMemSize: k.cpt.memory.len,
        c_memOffset:      p.memOffset,
        c_memLength:      p.memLength))

    # EIP 2046: temporary disabled
    # reduce gas fee for precompiles
    # from 700 to 40
    if gasCost >= 0:
      k.cpt.gasMeter.consumeGas(gasCost, reason = $CallCode)

    k.cpt.returnData.setLen(0)

    if k.cpt.msg.depth >= MaxCallDepth:
      debug "Computation Failure",
        reason = "Stack too deep",
        maximumDepth = MaxCallDepth,
        depth = k.cpt.msg.depth
      k.cpt.gasMeter.returnGas(childGasLimit)
      return

    # EIP 2046: temporary disabled
    # reduce gas fee for precompiles
    # from 700 to 40
    if gasCost < 0 and childGasLimit <= 0:
      raise newException(
        OutOfGas, "Gas not enough to perform calculation (callCode)")

    k.cpt.memory.extend(p.memInPos, p.memInLen)
    k.cpt.memory.extend(p.memOutPos, p.memOutLen)

    let senderBalance = k.cpt.getBalance(p.sender)
    if senderBalance < p.value:
      debug "Insufficient funds",
        available = senderBalance,
        needed = k.cpt.msg.value
      k.cpt.gasMeter.returnGas(childGasLimit)
      return

    let msg = Message(
      kind:            evmcCallCode,
      depth:           k.cpt.msg.depth + 1,
      gas:             childGasLimit,
      sender:          p.sender,
      contractAddress: p.contractAddress,
      codeAddress:     p.destination,
      value:           p.value,
      data:            k.cpt.memory.read(p.memInPos, p.memInLen),
      flags:           p.flags)

    # call -- need to un-capture k
    var
      c = k.cpt
      child = newComputation(c.vmState, msg)
    c.chainTo(child):
      if not child.shouldBurnGas:
        c.gasMeter.returnGas(child.gasMeter.gasRemaining)

      if child.isSuccess:
        c.merge(child)
        c.stack.top(1)

      c.returnData = child.output
      let actualOutputSize = min(p.memOutLen, child.output.len)
      if actualOutputSize > 0:
        c.memory.write(p.memOutPos,
                       child.output.toOpenArray(0, actualOutputSize - 1))

  # ---------------------

  delegateCallOp: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## 0xf4, Message-call into this account with an alternative account's
    ##       code, but persisting the current values for sender and value.
    let
      p = k.cpt.delegateCallParams

    var (gasCost, childGasLimit) = k.cpt.gasCosts[DelegateCall].c_handler(
      p.value,
      GasParams(
        kind: DelegateCall,
        c_isNewAccount:   not k.cpt.accountExists(p.contractAddress),
        c_gasBalance:     k.cpt.gasMeter.gasRemaining,
        c_contractGas:    p.gas,
        c_currentMemSize: k.cpt.memory.len,
        c_memOffset:      p.memOffset,
        c_memLength:      p.memLength))

    # EIP 2046: temporary disabled
    # reduce gas fee for precompiles
    # from 700 to 40
    if gasCost >= 0:
      k.cpt.gasMeter.consumeGas(gasCost, reason = $DelegateCall)

    k.cpt.returnData.setLen(0)
    if k.cpt.msg.depth >= MaxCallDepth:
      debug "Computation Failure",
        reason = "Stack too deep",
        maximumDepth = MaxCallDepth,
        depth = k.cpt.msg.depth
      k.cpt.gasMeter.returnGas(childGasLimit)
      return

    if gasCost < 0 and childGasLimit <= 0:
      raise newException(
        OutOfGas, "Gas not enough to perform calculation (delegateCall)")

    k.cpt.memory.extend(p.memInPos, p.memInLen)
    k.cpt.memory.extend(p.memOutPos, p.memOutLen)

    let msg = Message(
      kind:            evmcDelegateCall,
      depth:           k.cpt.msg.depth + 1,
      gas:             childGasLimit,
      sender:          p.sender,
      contractAddress: p.contractAddress,
      codeAddress:     p.destination,
      value:           p.value,
      data:            k.cpt.memory.read(p.memInPos, p.memInLen),
      flags:           p.flags)

    # call -- need to un-capture k
    var
      c = k.cpt
      child = newComputation(c.vmState, msg)
    c.chainTo(child):
      if not child.shouldBurnGas:
        c.gasMeter.returnGas(child.gasMeter.gasRemaining)

      if child.isSuccess:
        c.merge(child)
        c.stack.top(1)

      c.returnData = child.output
      let actualOutputSize = min(p.memOutLen, child.output.len)
      if actualOutputSize > 0:
        c.memory.write(p.memOutPos,
                       child.output.toOpenArray(0, actualOutputSize - 1))

  # ---------------------

  staticCallOp: Vm2OpFn = proc(k: var Vm2Ctx) =
    ## 0xfa, Static message-call into an account.

    let
      p = k.cpt.staticCallParams

    var (gasCost, childGasLimit) = k.cpt.gasCosts[StaticCall].c_handler(
      p.value,
      GasParams(
        kind: StaticCall,
        c_isNewAccount:   not k.cpt.accountExists(p.contractAddress),
        c_gasBalance:     k.cpt.gasMeter.gasRemaining,
        c_contractGas:    p.gas,
        c_currentMemSize: k.cpt.memory.len,
        c_memOffset:      p.memOffset,
        c_memLength:      p.memLength))

    # EIP 2046: temporary disabled
    # reduce gas fee for precompiles
    # from 700 to 40
    #
    # when opCode == StaticCall:
    #  if k.cpt.fork >= FkBerlin and destination.toInt <= MaxPrecompilesAddr:
    #    gasCost = gasCost - 660.GasInt
    if gasCost >= 0:
      k.cpt.gasMeter.consumeGas(gasCost, reason = $StaticCall)

    k.cpt.returnData.setLen(0)

    if k.cpt.msg.depth >= MaxCallDepth:
      debug "Computation Failure",
        reason = "Stack too deep",
        maximumDepth = MaxCallDepth,
        depth = k.cpt.msg.depth
      k.cpt.gasMeter.returnGas(childGasLimit)
      return

    if gasCost < 0 and childGasLimit <= 0:
      raise newException(
        OutOfGas, "Gas not enough to perform calculation (staticCall)")

    k.cpt.memory.extend(p.memInPos, p.memInLen)
    k.cpt.memory.extend(p.memOutPos, p.memOutLen)

    let msg = Message(
      kind:            evmcCall,
      depth:           k.cpt.msg.depth + 1,
      gas:             childGasLimit,
      sender:          p.sender,
      contractAddress: p.contractAddress,
      codeAddress:     p.destination,
      value:           p.value,
      data:            k.cpt.memory.read(p.memInPos, p.memInLen),
      flags:           p.flags)

    # call -- need to un-capture k
    var
      c = k.cpt
      child = newComputation(c.vmState, msg)
    c.chainTo(child):
      if not child.shouldBurnGas:
        c.gasMeter.returnGas(child.gasMeter.gasRemaining)

      if child.isSuccess:
        c.merge(child)
        c.stack.top(1)

      c.returnData = child.output
      let actualOutputSize = min(p.memOutLen, child.output.len)
      if actualOutputSize > 0:
        c.memory.write(p.memOutPos,
                       child.output.toOpenArray(0, actualOutputSize - 1))

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  vm2OpExecCall*: seq[Vm2OpExec] = @[

    (opCode: Call,         ## 0xf1, Message-Call into an account
     forks: Vm2OpAllForks,
     name: "call",
     info: "Message-Call into an account",
     exec: (prep: vm2OpIgnore,
            run: callOp,
            post: vm2OpIgnore)),

    (opCode: CallCode,     ## 0xf2, Message-Call with alternative code
     forks: Vm2OpAllForks,
     name: "callCode",
     info: "Message-call into this account with alternative account's code",
     exec: (prep: vm2OpIgnore,
            run: callCodeOp,
            post: vm2OpIgnore)),

    (opCode: DelegateCall, ## 0xf4, CallCode with persisting sender and value
     forks: Vm2OpHomesteadAndLater,
     name: "delegateCall",
     info: "Message-call into this account with an alternative account's " &
           "code but persisting the current values for sender and value.",
     exec: (prep: vm2OpIgnore,
            run: delegateCallOp,
            post: vm2OpIgnore)),

    (opCode: StaticCall,   ## 0xfa, Static message-call into an account
     forks: Vm2OpByzantiumAndLater,
     name: "staticCall",
     info: "Static message-call into an account",
     exec: (prep: vm2OpIgnore,
            run: staticCallOp,
            post: vm2OpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
