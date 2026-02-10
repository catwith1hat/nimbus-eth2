# beacon_chain
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[algorithm, sequtils, typetraits, sets, tables],
  stew/base10,
  chronicles, metrics,
  ./rest_utils,
  ../beacon_node,
  ../consensus_object_pools/[blockchain_dag, spec_cache, validator_change_pool],
  ../spec/[forks, state_transition, state_transition_epoch]

export rest_utils

logScope: topics = "rest_rewardsapi"

func isGenesis(node: BeaconNode,
               blockId: BlockIdent,
               genesisBsid: BlockSlotId): bool =
  case blockId.kind
  of BlockQueryKind.Named:
    case blockId.value
    of BlockIdentType.Genesis:
      true
    of BlockIdentType.Head:
      node.dag.head.bid.slot == GENESIS_SLOT
    of BlockIdentType.Finalized:
      node.dag.finalizedHead.slot == GENESIS_SLOT
  of BlockQueryKind.Slot:
    blockId.slot == GENESIS_SLOT
  of BlockQueryKind.Root:
    blockId.root == genesisBsid.bid.root

proc decodeAttestationRewardIdents(
    contentBody: Option[ContentBody]): Result[seq[ValidatorIdent], RestApiResponse] =
  # Spec allows omitting the request body to request all validators.
  if contentBody.isNone():
    return ok(newSeq[ValidatorIdent]())

  let res = decodeBody(seq[ValidatorIdent], contentBody.get()).valueOr:
    return err(RestApiResponse.jsonError(Http400, InvalidRequestBodyError, $error))
  ok(res)

proc getAttestationRewardsTargetBlock(
    node: BeaconNode, qepoch: Epoch): Result[BlockSlotId, RestApiResponse] =
  if qepoch == high(Epoch):
    return err(RestApiResponse.jsonError(Http400, InvalidEpochValueError))

  # Rewards are calculated at the end of an epoch, so we need the state
  # at the start of the next epoch.
  let targetEpoch = qepoch + 1

  if targetEpoch > node.dag.head.slot.epoch + 1:
    return err(RestApiResponse.jsonError(
      Http400, "Requested epoch is too far in the future"))

  let targetSlot = targetEpoch.start_slot()

  # Retrieve canonical block reference for the target slot. If the slot is
  # empty, this resolves to the last canonical block before it, while keeping
  # `bsi.slot == targetSlot`, so `updateState` can still advance through the
  # empty slot(s) and produce the correct epoch-start state.
  let bsi = node.dag.getBlockIdAtSlot(targetSlot).valueOr:
    return err(RestApiResponse.jsonError(Http404, StateNotFoundError))
  ok(bsi)

proc collectRequestedValidatorKeys(
    state: ForkedHashedBeaconState,
    idents: openArray[ValidatorIdent]
): Result[HashSet[ValidatorPubKey], RestApiResponse] =
  # Resolve mixed index/pubkey selector input into a single pubkey filter set.
  var keys: HashSet[ValidatorPubKey]
  if idents.len == 0:
    return ok(keys)

  withState(state):
    for item in idents:
      case item.kind
      of ValidatorQueryKind.Index:
        let vindex = item.index.toValidatorIndex().valueOr:
          case error
          of ValidatorIndexError.TooHighValue:
            return err(RestApiResponse.jsonError(
              Http400, TooHighValidatorIndexValueError))
          of ValidatorIndexError.UnsupportedValue:
            return err(RestApiResponse.jsonError(
              Http500, UnsupportedValidatorIndexValueError))
        if uint64(vindex) >= lenu64(forkyState.data.validators):
          return err(RestApiResponse.jsonError(Http400, ValidatorNotFoundError))
        keys.incl(forkyState.data.validators.item(vindex).pubkey)
      of ValidatorQueryKind.Key:
        keys.incl(item.key)
  ok(keys)

proc sortedEffectiveBalances[T](rewardsMap: Table[Gwei, T]): seq[Gwei] =
  # Keep ideal rewards deterministic across runs/peers.
  result = toSeq(rewardsMap.keys)
  result.sort(
    proc(a, b: Gwei): int =
      cmp(distinctBase(a), distinctBase(b)))

proc addTotalAttestationReward(
    totalRewards: var seq[RestAttestationReward],
    keys: HashSet[ValidatorPubKey],
    pubkey: ValidatorPubKey,
    validatorIndex: RestValidatorIndex,
    head, target, source: int64,
    inclusionDelay: Opt[RestReward],
    inactivity: int64) =
  if keys.len == 0 or pubkey in keys:
    totalRewards.add(RestAttestationReward(
      validator_index: validatorIndex,
      head: RestReward(head),
      target: RestReward(target),
      source: RestReward(source),
      inclusion_delay: inclusionDelay,
      inactivity: RestReward(inactivity)
    ))

proc computeAttestationRewards(
    cfg: RuntimeConfig,
    state: ForkyBeaconState,
    cache: var StateCache,
    keys: HashSet[ValidatorPubKey]): RestAttestationsRewards =
  type IdealReward = tuple[
    head: int64, target: int64, source: int64,
    inclusion_delay: int64, inactivity: int64]

  var idealRewardsMap: Table[Gwei, IdealReward]
  var totalRewards: seq[RestAttestationReward]
  var filteredBalances: HashSet[Gwei]

  when state is phase0.BeaconState:
    var info = phase0.EpochInfo()
    info.init(state)
    doAssert info.validators.len == state.validators.len

    # Populate previous/current epoch attestation participation.
    info.process_attestations(state, cache)

    let
      finality_delay = get_finality_delay(state)
      total_balance = info.balances.current_epoch
      total_balance_sqrt = integer_squareroot(distinctBase(total_balance))

    for index in 0 ..< info.validators.len:
      let validator = addr info.validators[index]
      if not is_eligible_validator(validator[]):
        continue

      let
        base_reward = get_base_reward_sqrt(
          state, ValidatorIndex(index), total_balance_sqrt)
        eff_balance = validator[].current_epoch_effective_balance

      # Ideal rewards are grouped by effective balance per API schema.
      if eff_balance notin idealRewardsMap:
        var ideal_validator = RewardStatus(
          current_epoch_effective_balance: eff_balance,
          flags: {
            RewardFlags.isActiveInPreviousEpoch,
            RewardFlags.isPreviousEpochTargetAttester,
            RewardFlags.isPreviousEpochHeadAttester
          },
          is_previous_epoch_attester: Opt.some(InclusionInfo(
            delay: 1, proposer_index: 0))
        )

        let
          ideal_source = get_source_delta(
            ideal_validator, base_reward, info.balances, finality_delay)
          ideal_target = get_target_delta(
            ideal_validator, base_reward, info.balances, finality_delay)
          ideal_head = get_head_delta(
            ideal_validator, base_reward, info.balances, finality_delay)
          (ideal_inclusion, _) = get_inclusion_delay_delta(
            ideal_validator, base_reward)
          ideal_inactivity = get_inactivity_penalty_delta(
            ideal_validator, base_reward, finality_delay)

        idealRewardsMap[eff_balance] = (
          head: int64(ideal_head.rewards) - int64(ideal_head.penalties),
          target: int64(ideal_target.rewards) - int64(ideal_target.penalties),
          source: int64(ideal_source.rewards) - int64(ideal_source.penalties),
          inclusion_delay: int64(ideal_inclusion.rewards),
          inactivity: int64(ideal_inactivity.rewards) - int64(ideal_inactivity.penalties)
        )

      let
        source_delta = get_source_delta(
          validator[], base_reward, info.balances, finality_delay)
        target_delta = get_target_delta(
          validator[], base_reward, info.balances, finality_delay)
        head_delta = get_head_delta(
          validator[], base_reward, info.balances, finality_delay)
        (inclusion_delay_delta, _) = get_inclusion_delay_delta(
          validator[], base_reward)
        inactivity_delta = get_inactivity_penalty_delta(
          validator[], base_reward, finality_delay)

      let pubkey = state.validators.item(ValidatorIndex(index)).pubkey
      if keys.len == 0 or pubkey in keys:
        filteredBalances.incl(eff_balance)
      addTotalAttestationReward(
        totalRewards, keys, pubkey, RestValidatorIndex(index),
        int64(head_delta.rewards) - int64(head_delta.penalties),
        int64(target_delta.rewards) - int64(target_delta.penalties),
        int64(source_delta.rewards) - int64(source_delta.penalties),
        Opt.some(RestReward(int64(inclusion_delay_delta.rewards))),
        int64(inactivity_delta.rewards) - int64(inactivity_delta.penalties))

  else: # Altair+
    var info = altair.EpochInfo()
    info.init(state)

    let
      total_active_balance = info.balances.current_epoch
      base_reward_per_increment = get_base_reward_per_increment(
        total_active_balance)
      finality_delay = get_finality_delay(state)
      active_increments = get_active_increments(info)

    const INACTIVITY_PENALTY_QUOTIENT =
      when state is altair.BeaconState:
        INACTIVITY_PENALTY_QUOTIENT_ALTAIR
      else:
        INACTIVITY_PENALTY_QUOTIENT_BELLATRIX

    let
      penalty_denominator =
        cfg.INACTIVITY_SCORE_BIAS * INACTIVITY_PENALTY_QUOTIENT
      previous_epoch = get_previous_epoch(state)
      epoch_participation =
        if previous_epoch == get_current_epoch(state):
          unsafeAddr state.current_epoch_participation
        else:
          unsafeAddr state.previous_epoch_participation
      participating_increments = [
        get_unslashed_participating_increment(info, TIMELY_SOURCE_FLAG_INDEX),
        get_unslashed_participating_increment(info, TIMELY_TARGET_FLAG_INDEX),
        get_unslashed_participating_increment(info, TIMELY_HEAD_FLAG_INDEX)]

    for vidx in state.validators.vindices:
      if not is_eligible_validator(info.validators[vidx]):
        continue

      let
        eff_balance = state.validators.item(vidx).effective_balance
        base_reward = get_base_reward_increment(
          state, vidx, base_reward_per_increment)
        pflags =
          if  is_active_validator(state.validators.item(vidx), previous_epoch) and
              not state.validators.item(vidx).slashed:
            epoch_participation[].item(vidx)
          else:
            0

      # Ideal rewards are grouped by effective balance per API schema.
      if eff_balance notin idealRewardsMap:
        let
          ideal_source = get_flag_index_reward(
            state, base_reward, active_increments,
            participating_increments[ord(TIMELY_SOURCE_FLAG_INDEX)],
            TIMELY_SOURCE_WEIGHT, finality_delay)
          ideal_target = get_flag_index_reward(
            state, base_reward, active_increments,
            participating_increments[ord(TIMELY_TARGET_FLAG_INDEX)],
            TIMELY_TARGET_WEIGHT, finality_delay)
          ideal_head = get_flag_index_reward(
            state, base_reward, active_increments,
            participating_increments[ord(TIMELY_HEAD_FLAG_INDEX)],
            TIMELY_HEAD_WEIGHT, finality_delay)

        idealRewardsMap[eff_balance] = (
          head: int64(ideal_head),
          target: int64(ideal_target),
          source: int64(ideal_source),
          inclusion_delay: 0'i64,
          inactivity: 0'i64
        )

      let
        source_reward =
          if has_flag(pflags, TIMELY_SOURCE_FLAG_INDEX):
            get_flag_index_reward(
              state, base_reward, active_increments,
              participating_increments[ord(TIMELY_SOURCE_FLAG_INDEX)],
              TIMELY_SOURCE_WEIGHT, finality_delay)
          else:
            0.Gwei
        target_reward =
          if has_flag(pflags, TIMELY_TARGET_FLAG_INDEX):
            get_flag_index_reward(
              state, base_reward, active_increments,
              participating_increments[ord(TIMELY_TARGET_FLAG_INDEX)],
              TIMELY_TARGET_WEIGHT, finality_delay)
          else:
            0.Gwei
        head_reward =
          if has_flag(pflags, TIMELY_HEAD_FLAG_INDEX):
            get_flag_index_reward(
              state, base_reward, active_increments,
              participating_increments[ord(TIMELY_HEAD_FLAG_INDEX)],
              TIMELY_HEAD_WEIGHT, finality_delay)
          else:
            0.Gwei
        inactivity_penalty =
          if not has_flag(pflags, TIMELY_TARGET_FLAG_INDEX):
            state.validators.item(vidx).effective_balance *
                 state.inactivity_scores.item(vidx) div
                 penalty_denominator
          else:
            0.Gwei

      let pubkey = state.validators.item(vidx).pubkey
      if keys.len == 0 or pubkey in keys:
        filteredBalances.incl(eff_balance)
      addTotalAttestationReward(
        totalRewards, keys, pubkey, RestValidatorIndex(vidx),
        int64(head_reward),
        int64(target_reward),
        int64(source_reward),
        Opt.none(RestReward),
        -int64(inactivity_penalty))

  # Shared output assembly: convert ideal rewards map to sorted REST response.
  # When a validator filter is active, only include effective balance tiers that
  # are present among the requested validators, matching Prysm/Lodestar behavior.
  var idealRewards: seq[RestIdealAttestationReward]
  for effBalance in sortedEffectiveBalances(idealRewardsMap):
    if filteredBalances.len > 0 and effBalance notin filteredBalances:
      continue
    let rewards = idealRewardsMap.getOrDefault(effBalance)
    idealRewards.add(RestIdealAttestationReward(
      effective_balance: effBalance,
      head: RestReward(rewards.head),
      target: RestReward(rewards.target),
      source: RestReward(rewards.source),
      inclusion_delay:
        when state is phase0.BeaconState:
          Opt.some(RestReward(rewards.inclusion_delay))
        else:
          Opt.none(RestReward),
      inactivity: RestReward(rewards.inactivity)
    ))

  RestAttestationsRewards(
    ideal_rewards: idealRewards,
    total_rewards: totalRewards
  )

proc installRewardsApiHandlers*(router: var RestRouter, node: BeaconNode) =
  let
    genesisBlockRewardsResponse =
      RestApiResponse.prepareJsonResponseFinalized(
        (
          proposer_index: "0", total: "0", attestations: "0",
          sync_aggregate: "0", proposer_slashings: "0", attester_slashings: "0"
        ),
        Opt.some(false),
        true,
      )
    genesisBsid = node.dag.getBlockIdAtSlot(GENESIS_SLOT).get()

  # https://ethereum.github.io/beacon-APIs/#/Rewards/getAttestationsRewards
  router.api2(MethodPost, "/eth/v1/beacon/rewards/attestations/{epoch}") do (
    epoch: Epoch, contentBody: Option[ContentBody]) -> RestApiResponse:
    let qepoch =
      if epoch.isErr():
        return RestApiResponse.jsonError(Http400, InvalidEpochValueError,
                                         $epoch.error())
      else:
        epoch.get()

    let idents = decodeAttestationRewardIdents(contentBody).valueOr:
      return error

    let bsi = getAttestationRewardsTargetBlock(node, qepoch).valueOr:
      return error

    # Rewards for epoch N are derived from state at the start of epoch N+1.
    node.withStateForBlockSlotId(bsi):
      let keys = collectRequestedValidatorKeys(state, idents).valueOr:
        return error

      let response =
        withState(state):
          computeAttestationRewards(
            node.dag.cfg, forkyState.data, cache, keys)

      return RestApiResponse.jsonResponseFinalized(
        response,
        node.getStateOptimistic(state),
        node.dag.isFinalized(bsi.bid)
      )

    return RestApiResponse.jsonError(Http404, StateNotFoundError)

  # https://ethereum.github.io/beacon-APIs/#/Rewards/getBlockRewards
  router.api2(MethodGet, "/eth/v1/beacon/rewards/blocks/{block_id}") do (
    block_id: BlockIdent) -> RestApiResponse:
    let
      bident = block_id.valueOr:
        return RestApiResponse.jsonError(Http400, InvalidBlockIdValueError,
                                         $error)

    if node.isGenesis(bident, genesisBsid):
      return RestApiResponse.response(
        genesisBlockRewardsResponse, Http200, "application/json")

    let
      bdata = node.getForkedBlock(bident).valueOr:
        return RestApiResponse.jsonError(Http404, BlockNotFoundError)

      bid = BlockId(slot: bdata.slot, root: bdata.root)

      targetBlock =
        withBlck(bdata):
          let parentBid =
            node.dag.getBlockId(forkyBlck.message.parent_root).valueOr:
              return RestApiResponse.jsonError(Http404, BlockParentUnknownError)
          if parentBid.slot >= forkyBlck.message.slot:
            return RestApiResponse.jsonError(Http404, BlockOlderThanParentError)
          BlockSlotId.init(parentBid, forkyBlck.message.slot)

    var
      cache = StateCache()
      tmpState = assignClone(node.dag.headState)

    if not updateState(
      node.dag, tmpState[], targetBlock, false, cache, node.dag.updateFlags):
        return RestApiResponse.jsonError(Http404, ParentBlockMissingStateError)

    func rollbackProc(state: var ForkedHashedBeaconState) {.
         gcsafe, noSideEffect, raises: [].} =
      discard

    let
      rewards =
        withBlck(bdata):
          state_transition_block(
            node.dag.cfg, tmpState[], forkyBlck,
            cache, node.dag.updateFlags, rollbackProc).valueOr:
              return RestApiResponse.jsonError(Http400, BlockInvalidError)
      total = rewards.attestations + rewards.sync_aggregate +
              rewards.proposer_slashings + rewards.attester_slashings
      proposerIndex =
        withBlck(bdata):
          forkyBlck.message.proposer_index

    RestApiResponse.jsonResponseFinalized(
      (
        proposer_index: Base10.toString(uint64(proposerIndex)),
        total: Base10.toString(uint64(total)),
        attestations: Base10.toString(uint64(rewards.attestations)),
        sync_aggregate: Base10.toString(uint64(rewards.sync_aggregate)),
        proposer_slashings: Base10.toString(uint64(rewards.proposer_slashings)),
        attester_slashings: Base10.toString(uint64(rewards.attester_slashings))
      ),
      node.getBlockOptimistic(bdata),
      node.dag.isFinalized(bid)
    )

  # https://ethereum.github.io/beacon-APIs/#/Rewards/getSyncCommitteeRewards
  router.api2(
    MethodPost, "/eth/v1/beacon/rewards/sync_committee/{block_id}") do (
      block_id: BlockIdent,
      contentBody: Option[ContentBody]) -> RestApiResponse:
    let
      idents =
        block:
          if contentBody.isNone():
            return RestApiResponse.jsonError(Http400, EmptyRequestBodyError)
          let res = decodeBody(seq[ValidatorIdent], contentBody.get()).valueOr:
            return RestApiResponse.jsonError(
              Http400, InvalidRequestBodyError, $error)
          res

      bident = block_id.valueOr:
        return RestApiResponse.jsonError(Http400, InvalidBlockIdValueError,
                                         $error)
      bdata = node.getForkedBlock(bident).valueOr:
        return RestApiResponse.jsonError(Http404, BlockNotFoundError)

      bid = BlockId(slot: bdata.slot, root: bdata.root)

      sync_aggregate =
        withBlck(bdata):
          when consensusFork > ConsensusFork.Phase0:
            forkyBlck.message.body.sync_aggregate
          else:
            default(TrustedSyncAggregate)

      targetBlock =
        withBlck(bdata):
          if node.isGenesis(bident, genesisBsid):
            genesisBsid
          else:
            let parentBid =
              node.dag.getBlockId(forkyBlck.message.parent_root).valueOr:
                return RestApiResponse.jsonError(
                  Http404, BlockParentUnknownError)
            if parentBid.slot >= forkyBlck.message.slot:
              return RestApiResponse.jsonError(
                Http404, BlockOlderThanParentError)
            BlockSlotId.init(parentBid, forkyBlck.message.slot)

    var
      cache = StateCache()
      tmpState = assignClone(node.dag.headState)

    if not updateState(
      node.dag, tmpState[], targetBlock, false, cache, node.dag.updateFlags):
        return RestApiResponse.jsonError(Http404, ParentBlockMissingStateError)

    let response =
      withState(tmpState[]):
        var resp: seq[RestSyncCommitteeReward]
        when consensusFork > ConsensusFork.Phase0:
          let
            total_active_balance =
              get_total_active_balance(forkyState.data, cache)
            keys =
              block:
                var res: HashSet[ValidatorPubKey]
                for item in idents:
                  case item.kind
                  of ValidatorQueryKind.Index:
                    let vindex = item.index.toValidatorIndex().valueOr:
                      case error
                      of ValidatorIndexError.TooHighValue:
                        return RestApiResponse.jsonError(
                          Http400, TooHighValidatorIndexValueError)
                      of ValidatorIndexError.UnsupportedValue:
                        return RestApiResponse.jsonError(
                          Http500, UnsupportedValidatorIndexValueError)
                    if uint64(vindex) >= lenu64(forkyState.data.validators):
                      return RestApiResponse.jsonError(
                        Http400, ValidatorNotFoundError)
                    res.incl(forkyState.data.validators.item(vindex).pubkey)
                  of ValidatorQueryKind.Key:
                    res.incl(item.key)
                res

            committeeKeys =
              toHashSet(forkyState.data.current_sync_committee.pubkeys.data)

            pubkeyIndices =
              block:
                var res: Table[ValidatorPubKey, ValidatorIndex]
                for vindex in forkyState.data.validators.vindices:
                  let pubkey = forkyState.data.validators.item(vindex).pubkey
                  if pubkey in committeeKeys:
                    res[pubkey] = vindex
                res
            reward =
              block:
                let res = uint64(get_participant_reward(total_active_balance))
                if res > uint64(high(int64)):
                  return RestApiResponse.jsonError(
                    Http500, RewardOverflowError)
                res

          for i in 0 ..< min(
            len(forkyState.data.current_sync_committee.pubkeys),
            len(sync_aggregate.sync_committee_bits)):
            let
              pubkey = forkyState.data.current_sync_committee.pubkeys.data[i]
              vindex =
                try:
                  pubkeyIndices[pubkey]
                except KeyError:
                  raiseAssert "Unknown sync committee pubkey encountered!"
              vreward =
                if sync_aggregate.sync_committee_bits[i]:
                  cast[int64](reward)
                else:
                  -cast[int64](reward)

            if (len(idents) == 0) or (pubkey in keys):
              resp.add(RestSyncCommitteeReward(
                validator_index: RestValidatorIndex(vindex),
                reward: RestReward(vreward)))

        resp

    RestApiResponse.jsonResponseFinalized(
      response,
      node.getBlockOptimistic(bdata),
      node.dag.isFinalized(bid)
    )
