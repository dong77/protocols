// SPDX-License-Identifier: Apache-2.0
// Copyright 2017 Loopring Technology Limited.
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "../../../lib/ERC20.sol";
import "../../../lib/MathUint.sol";
import "./AmmUtil.sol";
import "./AmmData.sol";


/// @title AmmExchange
library AmmExchange
{
    using MathUint          for uint;

    // Only used to withdraw from the pool when shutdown.
    // Otherwise LPs should withdraw by doing normal queued exit requests.
    function withdrawFromPoolWhenShutdown(
        AmmData.State storage S,
        uint                  poolAmountIn,
        uint                  poolTokenTotalSupply
        )
        public
    {
        require(poolAmountIn <= poolTokenTotalSupply, "INVALID_POOL_AMOUNT");
        require(poolTokenTotalSupply > 0, "NO_LP_SUPPLY");

        // Currently commented out to make the contract size smaller...
        uint size = S.tokens.length;
        if (S.exchange.isInWithdrawalMode()) {
            // Check if all tokens were withdrawn using Merkle proofs
            for (uint i = 0; i < size; i++) {
                // Question(Brecht): I removed a "!" isWithdrawnInWithdrawalMode
                require(
                    S.exchange.isWithdrawnInWithdrawalMode(S.accountID, S.tokens[i].addr),
                    "PENDING_WITHDRAWAL_MODE"
                );
            }
        } else {
            // Check if all forced withdrawals are done
            for (uint i = 0; i < size; i++) {
                require(
                    !S.exchange.isForcedWithdrawalPending(S.accountID, S.tokens[i].addr),
                    "PENDING_FORCED_WITHDRAWAL"
                );
            }
        }
        // Check that nothing is withdrawable anymore.
        for (uint i = 0; i < size; i++) {
            require(
                S.exchange.getAmountWithdrawable(address(this), S.tokens[i].addr) == 0,
                "MORE_TO_WITHDRAWAL"
            );
        }

        // Withdraw proportionally to the liquidity owned
        for (uint i = 0; i < size; i++) {
            address token = S.tokens[i].addr;

            // Calculate the balance inside the pool
            uint balance = token == address(0) ?
                address(this).balance :
                ERC20(token).balanceOf(address(this));

            // Withdraw the part owned
            uint amount = balance.mul(poolAmountIn) / poolTokenTotalSupply;
            AmmUtil.tranferOut(token, amount, msg.sender);
        }
    }
}
