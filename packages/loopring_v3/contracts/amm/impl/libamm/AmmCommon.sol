// SPDX-License-Identifier: Apache-2.0
// Copyright 2017 Loopring Technology Limited.
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "../AmmData.sol";
import "../../../lib/AddressUtil.sol";
import "../../../lib/ERC20SafeTransfer.sol";
import "../../../lib/SignatureUtil.sol";

/// @title AmmCommon
library AmmCommon
{
    using ERC20SafeTransfer for address;
    using AddressUtil       for address;
    using SignatureUtil     for bytes32;

    function isAlmostEqual(
        uint96 amount,
        uint96 targetAmount
        )
        public
        pure
        returns (bool)
    {
        if (targetAmount == 0) {
            return amount == 0;
        } else {
            // Max rounding error for a float24 is 2/100000
            uint ratio = (amount * 100000) / targetAmount;
            return (100000 - 2) <= ratio && ratio <= (100000 + 2);
        }
    }

    function tranferOut(
        address token,
        uint    amount,
        address to
        )
        internal
    {
        if (token == address(0)) {
            to.sendETHAndVerify(amount, gasleft());
        } else {
            token.safeTransferAndVerify(to, amount);
        }
    }

    function authenticatePoolTx(
        AmmData.State storage S,
        address        owner,
        bytes32        poolTxHash,
        bytes   memory signature
        )
        internal
    {
        if (signature.length == 0) {
            require(S.approvedTx[poolTxHash] != 0, "NOT_APPROVED");
            delete S.approvedTx[poolTxHash];
        } else {
            require(poolTxHash.verifySignature(owner, signature), "INVALID_SIGNATURE");
        }
    }
}