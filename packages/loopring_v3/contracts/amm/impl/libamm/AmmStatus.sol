// SPDX-License-Identifier: Apache-2.0
// Copyright 2017 Loopring Technology Limited.
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "../AmmData.sol";
import "../../../core/iface/IExchangeV3.sol";
import "../../../lib/EIP712.sol";
import "../../../lib/ERC20.sol";


/// @title LPToken
library AmmStatus
{
    function isOnline(AmmData.State storage S)
        public
        view
        returns (bool)
    {
        return S.shutdownTimestamp == 0;
    }

    function setupPool(
        AmmData.State storage S,
        IExchangeV3        _exchange,
        uint32             _accountID,
        address[] calldata _tokens,
        uint96[]  calldata _weights,
        uint8              _feeBips
        )
        external
    {
        require(S.tokens.length == 0, "ALREADY_INITIALIZED");
        require(_tokens.length == _weights.length, "INVALID_DATA");
        require(_tokens.length >= 2, "INVALID_DATA");

        S.DOMAIN_SEPARATOR = EIP712.hash(EIP712.Domain("AMM Pool", "1.0.0", address(this)));

        S.exchange = _exchange;
        S.accountID = _accountID;
        S.feeBips = _feeBips;

        address depositContract = address(S.exchange.getDepositContract());

        for (uint i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            uint16 tokenID = S.exchange.getTokenID(token);
            S.tokens.push(AmmData.Token({
                addr: token,
                tokenID: tokenID,
                weight: _weights[i]
            }));

            ERC20(token).approve(depositContract, ~uint(0));
        }
    }

    // Anyone is able to shut down the pool when requests aren't being processed any more.
    function shutdown(
        AmmData.State storage S,
        bytes32               txHash
        )
        external
    {
        // // TODO
        // require(
        //     block.timestamp > S.approvedTx[txHash] + AmmData.MAX_AGE_REQUEST_UNTIL_POOL_SHUTDOWN(),
        //     "REQUEST_NOT_TOO_OLD"
        // );

        if (!S.exchange.isInWithdrawalMode()) {
            for (uint i = 0; i < S.tokens.length; i++) {
                S.exchange.forceWithdraw{value: msg.value/S.tokens.length}(
                    address(this),
                    S.tokens[i].addr,
                    S.accountID
                );
            }
        }

        S.shutdownTimestamp = block.timestamp;
    }
}