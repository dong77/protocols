// SPDX-License-Identifier: Apache-2.0
// Copyright 2017 Loopring Technology Limited.
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "../../aux/transactions/TransactionReader.sol";
import "../../core/impl/libtransactions/TransferTransaction.sol";
import "../../lib/EIP712.sol";
import "../../lib/ERC20SafeTransfer.sol";
import "../../lib/MathUint.sol";
import "../../lib/MathUint96.sol";
import "../../thirdparty/SafeCast.sol";
import "./AmmData.sol";
import "./AmmJoinRequest.sol";
import "./AmmPoolToken.sol";
import "./AmmStatus.sol";
import "./AmmUtil.sol";


/// @title AmmJoinProcess
library AmmJoinProcess
{
    using AmmPoolToken      for AmmData.State;
    using AmmStatus         for AmmData.State;
    using AmmUtil           for uint96;
    using ERC20SafeTransfer for address;
    using MathUint          for uint;
    using MathUint96        for uint96;
    using SafeCast          for uint;
    using TransactionReader for ExchangeData.Block;

    function proxcessExchangeDeposit(
        AmmData.State    storage S,
        AmmData.Context  memory  ctx,
        AmmData.Token    memory  token,
        uint96                   amount
        )
        internal
    {
        require(amount > 0, "INVALID_DEPOSIT_AMOUNT");

        // Check that the deposit in the block matches the expected deposit
        DepositTransaction.Deposit memory deposit = ctx._block.readDeposit(ctx.txIdx++);
        ctx.numTransactionsConsumed++;

        require(deposit.owner == address(this), "INVALID_TX_DATA");
        require(deposit.accountID == S.accountID, "INVALID_TX_DATA");
        require(deposit.tokenID == token.tokenID, "INVALID_TX_DATA");
        // Question(Brecht):should use this:
        // require(deposit.amount.isAlmostEqual(amount), "INVALID_TX_DATA");
        require(deposit.amount == amount, "INVALID_TX_DATA");

        // Now do this deposit
        uint ethValue = 0;
        if (token.addr == address(0)) {
            ethValue = amount;
        } else {
            uint allowance = ERC20(token.addr).allowance(address(this), ctx.exchangeDepositContract);
            if (allowance < amount) {
                // Approve the deposit transfer
                ERC20(token.addr).approve(ctx.exchangeDepositContract, uint(-1));
            }
        }

        ctx.exchange.deposit{value: ethValue}(
            deposit.owner,
            deposit.owner,
            token.addr,
            deposit.amount,
            new bytes(0)
        );

        // Total balance in this contract decreases by the amount deposited
        S.totalLockedBalance[token.addr] = S.totalLockedBalance[token.addr].sub(amount);
    }

    function processJoin(
        AmmData.State    storage S,
        AmmData.Context  memory  ctx,
        AmmData.PoolJoin memory  join,
        bytes            memory  signature
        )
        internal
    {
        S.validatePoolTransaction(
            join.owner,
            AmmUtil.hashPoolJoin(ctx.domainSeperator, join),
            signature
        );

        // Check if the requirements are fulfilled
        (bool slippageRequirementMet, uint poolAmountOut, uint96[] memory amounts) = _calculateJoinAmounts(ctx, join);

        if (!slippageRequirementMet) return;

        for (uint i = 0; i < ctx.size; i++) {
            uint96 amount = amounts[i];

            if (join.fromLayer2) {
                TransferTransaction.Transfer memory transfer = ctx._block.readTransfer(ctx.txIdx++);
                ctx.numTransactionsConsumed++;

                require(transfer.from == join.owner, "INVALID_TX_DATA");
                require(transfer.toAccountID == S.accountID, "INVALID_TX_DATA");
                require(transfer.tokenID == ctx.tokens[i].tokenID, "INVALID_TX_DATA");
                require(transfer.fee == 0, "INVALID_TX_DATA");

                uint96 refundAmount = transfer.amount.isAlmostEqual(amount) ?
                    0 :
                    transfer.amount.sub(amount);

                {  // Process the inbound transfer
                    // Replay protection (only necessary when using a signature)
                    if (signature.length > 0) {
                        require(transfer.storageID == join.storageIDs[i], "INVALID_TX_DATA");
                    }

                    // Now approve this transfer
                    // Question(brecht):should we simply check the value is indeed 0xffffffff???
                    transfer.validUntil = 0xffffffff;
                    bytes32 txHash = TransferTransaction.hashTx(ctx.exchangeDomainSeparator, transfer);
                    ctx.exchange.approveTransaction(join.owner, txHash);

                    amount = transfer.amount;
                }

                if (refundAmount > 0) { // Process the outbound transfer
                    TransferTransaction.Transfer memory refundTransfer = ctx._block.readTransfer(ctx.txIdx++);
                    ctx.numTransactionsConsumed++;

                    require(refundTransfer.to == join.owner, "INVALID_TX_DATA");
                    require(refundTransfer.fromAccountID == S.accountID, "INVALID_TX_DATA");
                    require(refundTransfer.tokenID == ctx.tokens[i].tokenID, "INVALID_TX_DATA");
                    require(refundTransfer.fee == 0, "INVALID_TX_DATA");
                    require(refundTransfer.amount.isAlmostEqual(refundAmount), "INVALID_REFUND_VALUE");

                    // Question(brecht):should we simply check the value is indeed 0xffffffff???
                    refundTransfer.validUntil = 0xffffffff;
                    refundTransfer.storageID = 0;
                    bytes32 txHash = TransferTransaction.hashTx(ctx.exchangeDomainSeparator, refundTransfer);
                    ctx.exchange.approveTransaction(address(this), txHash);

                    amount = amount.sub(refundTransfer.amount);
                }

                ctx.ammActualL2Balances[i] = ctx.ammActualL2Balances[i].add(amount);

            } else {
                // Make the amount unavailable for withdrawing
                address token = ctx.tokens[i].addr;
                S.lockedBalance[token][join.owner] = S.lockedBalance[token][join.owner].sub(amount);
            }

            ctx.ammExpectedL2Balances[i] = ctx.ammExpectedL2Balances[i].add(amount);
        }

        S.mint(join.owner, poolAmountOut);
    }

    function _calculateJoinAmounts(
        AmmData.Context  memory ctx,
        AmmData.PoolJoin memory join
        )
        private
        view
        returns(
            bool            slippageRequirementMet,
            uint            poolAmountOut,
            uint96[] memory amounts
        )
    {
        // Check if we can still use this join
        amounts = new uint96[](ctx.size);

        if (block.timestamp > join.validUntil) {
            return (false, 0, amounts);
        }

        if (ctx.poolTokenTotalSupply == 0) {
            return(true, ctx.poolTokenInitialSupply, join.maxAmountsIn);
        }

        // Calculate the amount of liquidity tokens that should be minted
        for (uint i = 0; i < ctx.size; i++) {
            if (ctx.ammExpectedL2Balances[i] > 0) {
                uint amountOut = uint(join.maxAmountsIn[i])
                    .mul(ctx.poolTokenTotalSupply) / uint(ctx.ammExpectedL2Balances[i]);

                if (poolAmountOut == 0 || amountOut < poolAmountOut) {
                    poolAmountOut = amountOut;
                }
            }
        }

        if (poolAmountOut == 0) {
            return (false, 0, amounts);
        }

        // Calculate the amounts to deposit
        uint ratio = poolAmountOut.mul(ctx.poolTokenBase) / ctx.poolTokenTotalSupply;

        for (uint i = 0; i < ctx.size; i++) {
            amounts[i] = ratio.mul(ctx.ammExpectedL2Balances[i] / ctx.poolTokenBase).toUint96();
        }

        slippageRequirementMet = (poolAmountOut >= join.minPoolAmountOut);
        return (slippageRequirementMet, poolAmountOut, amounts);
    }
}
