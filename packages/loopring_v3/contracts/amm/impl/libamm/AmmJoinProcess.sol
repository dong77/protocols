// SPDX-License-Identifier: Apache-2.0
// Copyright 2017 Loopring Technology Limited.
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "./AmmCommon.sol";
import "./AmmJoinRequest.sol";
import "../AmmData.sol";
import "../../../lib/EIP712.sol";
import "../../../lib/ERC20SafeTransfer.sol";
import "../../../lib/MathUint.sol";
import "../../../lib/MathUint96.sol";
import "../../../thirdparty/SafeCast.sol";

import "../../../aux/transactions/TransactionReader.sol";
import "../../../core/impl/libtransactions/TransferTransaction.sol";

/// @title AmmJoinProcess
library AmmJoinProcess
{
    using ERC20SafeTransfer for address;
    using MathUint          for uint;
    using MathUint96        for uint96;
    using SafeCast          for uint;
    using AmmCommon         for AmmData.State;
    using TransactionReader for ExchangeData.Block;

    bytes32 constant public POOLJOIN_TYPEHASH = keccak256(
        "PoolJoin(address owner,bool fromLayer2,uint256 minPoolAmountOut,uint256[] maxAmountsIn,uint32[] storageIDs,uint256 validUntil)"
    );

    function processJoin(
        AmmData.State    storage S,
        AmmData.Context  memory  ctx,
        AmmData.PoolJoin memory  join,
        bytes            memory  signature
        )
        internal
    {
        S.authenticatePoolTx(
            join.owner,
            AmmJoinRequest.hashPoolJoin(ctx.DOMAIN_SEPARATOR, join),
            signature
        );

        // Check if the requirements are fulfilled
        (bool valid, uint poolAmountOut, uint96[] memory amounts) = validateJoinAmounts(ctx, join);
        if (!valid) {
            return;
        }

        for (uint i = 0; i < ctx.tokens.length; i++) {
            uint96 amount = amounts[i];
            if (join.fromLayer2) {
                TransferTransaction.Transfer memory transfer = ctx._block.readTransfer(ctx.txIdx++);
                require(transfer.from == join.owner, "INVALID_TX_DATA");
                require(transfer.toAccountID == S.accountID, "INVALID_TX_DATA");
                require(transfer.tokenID == ctx.tokens[i].tokenID, "INVALID_TX_DATA");
                require(AmmCommon.isAlmostEqual(transfer.amount, amount), "INVALID_TX_DATA");
                require(transfer.fee == 0, "INVALID_TX_DATA");

                // Replay protection (only necessary when using a signature)
                if (signature.length > 0) {
                    require(transfer.storageID == join.storageIDs[i], "INVALID_TX_DATA");
                }

                // Now approve this transfer
                transfer.validUntil = 0xffffffff;
                bytes32 txHash = TransferTransaction.hashTx(ctx.exchangeDomainSeparator, transfer);
                S.exchange.approveTransaction(join.owner, txHash);

                ctx.numTransactionsConsumed++;
                // Update the amount to the actual amount transferred (which can have some some small rounding errors)
                amount = transfer.amount;
                // Update the balances in the account
                // Q: 为什么更新这个呢？
                ctx.ammActualL2Balances[i] = ctx.ammActualL2Balances[i].add(amount);
            } else {
                // Make the amount unavailable for withdrawing
                address token = ctx.tokens[i].addr;
                S.lockedBalance[token][join.owner] = S.lockedBalance[token][join.owner].sub(amount);
            }
            ctx.ammExpectedL2Balances[i] = ctx.ammExpectedL2Balances[i].add(amount);
        }

        // // Mint liquidity tokens
        // TODO
        // mint(join.owner, poolAmountOut);
    }


    function validateJoinAmounts(
        AmmData.Context  memory ctx,
        AmmData.PoolJoin memory join
        )
        private
        view
        returns(
            bool /* valid */,
            uint /*poolAmountOut*/,
            uint96[] memory /* amounts */
        )
    {
        // Check if we can still use this join
        uint96[] memory amounts = new uint96[](ctx.tokens.length);
        if (block.timestamp > join.validUntil) {
            return (false, 0, amounts);
        }

        if (ctx.totalSupply == 0) {
            return(true, ctx.initialSupply, join.maxAmountsIn);
        }

        // Calculate the amount of liquidity tokens that should be minted
        uint poolAmountOut = 0;
        bool initialValueSet = false;
        for (uint i = 0; i < ctx.tokens.length; i++) {
            if (ctx.ammExpectedL2Balances[i] > 0) {
                uint amountOut = uint(join.maxAmountsIn[i]).mul(ctx.totalSupply) / uint(ctx.ammExpectedL2Balances[i]);
                if (!initialValueSet || amountOut < poolAmountOut) {
                    poolAmountOut = amountOut;
                    initialValueSet = true;
                }
            }
        }

        if (poolAmountOut == 0) {
            return (false, 0, amounts);
        }

        // Calculate the amounts to deposit
        uint ratio = poolAmountOut.mul(ctx.base) / ctx.totalSupply;

        for (uint i = 0; i < ctx.tokens.length; i++) {
            amounts[i] = (ratio.mul(ctx.ammExpectedL2Balances[i]) / ctx.base).toUint96();
        }

        bool valid = (poolAmountOut >= join.minPoolAmountOut);
        return (valid, poolAmountOut, amounts);
    }
}