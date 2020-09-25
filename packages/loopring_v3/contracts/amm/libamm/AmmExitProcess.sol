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
import "./AmmUtil.sol";
import "./AmmData.sol";
import "./AmmExitRequest.sol";
import "./AmmPoolToken.sol";
import "./AmmStatus.sol";


/// @title AmmExitProcess
library AmmExitProcess
{
    using AmmPoolToken      for AmmData.State;
    using AmmStatus         for AmmData.State;
    using AmmUtil           for uint96;
    using ERC20SafeTransfer for address;
    using MathUint          for uint;
    using MathUint96        for uint96;
    using SafeCast          for uint;
    using TransactionReader for ExchangeData.Block;

    function proxcessExchangeWithdrawal(
        AmmData.State    storage S,
        AmmData.Context  memory  ctx,
        AmmData.Token    memory  token,
        uint                     amount
        )
        internal
    {
        // Check that the withdrawal in the block matches the expected withdrawal
        WithdrawTransaction.Withdrawal memory withdrawal = ctx._block.readWithdrawal(ctx.txIdx++);
        ctx.numTransactionsConsumed++;

        // These fields are not read by readWithdrawal:
        withdrawal.minGas = 0;
        withdrawal.to = address(this);
        withdrawal.extraData = new bytes(0);
        withdrawal.validUntil = 0xffffffff;

        require(
            withdrawal.withdrawalType == 1 && // Question(brecht): should this be 1?
            withdrawal.owner == address(this) &&
            withdrawal.accountID == S.accountID &&
            withdrawal.tokenID == token.tokenID &&
            // withdrawal.amount.isAlmostEqual(amount) && // Question(brecht):should we use isAlmostEqual?
            withdrawal.amount == amount &&
            withdrawal.feeTokenID == 0 &&
            withdrawal.fee == 0 &&
            withdrawal.storageID == 0 && // Question(brecht):should we check this ID?
            withdrawal.onchainDataHash == WithdrawTransaction.hashOnchainData(
                withdrawal.minGas,
                withdrawal.to,
                withdrawal.extraData
            ),
            "INVALID_TX_DATA"
        );

        // Now approve this withdrawal
        bytes32 txHash = WithdrawTransaction.hashTx(ctx.exchangeDomainSeparator, withdrawal);
        ctx.exchange.approveTransaction(address(this), txHash);

        // Total balance in this contract increases by the amount withdrawn
        S.totalLockedBalance[token.addr] = S.totalLockedBalance[token.addr].add(amount);
    }

    function processExit(
        AmmData.State    storage S,
        AmmData.Context  memory  ctx,
        AmmData.PoolExit memory  exit,
        bytes            memory  signature
        )
        internal
        returns (bool valid)
    {
        S.validatePoolTransaction(
            exit.owner,
            AmmUtil.hashPoolExit(ctx.domainSeperator, exit),
            signature
        );
        if (signature.length == 0) {
            // This is an onchain exit, we're processing it now so stop tracking it.
            S.isExiting[msg.sender] = false;
        }
        uint96[] memory amounts;
        (valid, amounts) = _validateExitAmounts(S, ctx, exit);

        if (!valid) { return false; }

        S.burn(exit.owner, exit.poolAmountIn);

        for (uint i = 0; i < ctx.size; i++) {
            uint96 amount = amounts[i];
            if (exit.toLayer2) {
                TransferTransaction.Transfer memory transfer = ctx._block.readTransfer(ctx.txIdx++);
                ctx.numTransactionsConsumed++;

                require(transfer.fromAccountID == S.accountID, "INVALID_TX_DATA");
                require(transfer.from == address(this), "INVALID_TX_DATA");
                require(transfer.to == exit.owner, "INVALID_TX_DATA");
                require(transfer.tokenID == ctx.tokens[i].tokenID, "INVALID_TX_DATA");
                require(transfer.amount.isAlmostEqual(amount), "INVALID_TX_DATA");
                require(transfer.fee == 0, "INVALID_TX_DATA");

                if (signature.length != 0) {
                    // Replay protection (only necessary when using a signature)
                    require(transfer.storageID == exit.storageIDs[i], "INVALID_TX_DATA");
                }

                // Now approve this transfer
                transfer.validUntil = 0xffffffff;
                bytes32 txHash = TransferTransaction.hashTx(ctx.exchangeDomainSeparator, transfer);
                ctx.exchange.approveTransaction(address(this), txHash);

                // Update the amount to the actual amount transferred (which can have some some small rounding errors)
                amount = transfer.amount;

                // Update the balances in the account
                ctx.ammActualL2Balances[i] = ctx.ammActualL2Balances[i].sub(amount);
            } else {
                address token = ctx.tokens[i].addr;
                // Make the amount available for withdrawing
                S.lockedBalance[token][exit.owner] = S.lockedBalance[token][exit.owner].add(amount);
            }

            ctx.ammExpectedL2Balances[i] = ctx.ammExpectedL2Balances[i].sub(amount);
        }
    }

    function _validateExitAmounts(
        AmmData.State    storage S,
        AmmData.Context  memory  ctx,
        AmmData.PoolExit memory  exit
        )
        private
        view
        returns(
            bool /* valid */,
            uint96[] memory amounts
        )
    {
        amounts = new uint96[](ctx.size);

        // Check if we can still use this exit
        if (block.timestamp > exit.validUntil) {
            return (false, amounts);
        }

        // Check if the user has enough pool tokens
        if (S.lockedBalance[address(this)][exit.owner] < exit.poolAmountIn) {
            return (false, amounts);
        }

        // Calculate how much will be withdrawn
        uint ratio = exit.poolAmountIn.mul(ctx.poolTokenBase) / ctx.poolTokenTotalSupply;

        for (uint i = 0; i < ctx.size; i++) {
            amounts[i] = (ratio.mul(ctx.ammExpectedL2Balances[i]) / ctx.poolTokenBase).toUint96();
            if (amounts[i] < exit.minAmountsOut[i]) {
                return (false, amounts);
            }
        }

        return (true, amounts);
    }
}
