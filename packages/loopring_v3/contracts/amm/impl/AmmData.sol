// SPDX-License-Identifier: Apache-2.0
// Copyright 2017 Loopring Technology Limited.
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "../../core/iface/ExchangeData.sol";

/// @title AmmData
contract AmmData
{
    enum PoolTransactionType
    {
        NOOP,
        JOIN,
        EXIT
    }

    struct PoolJoin
    {
        address  owner;
        bool     fromLayer2;
        uint     minPoolAmountOut;
        uint96[] maxAmountsIn;
        uint32[] storageIDs;
        uint     validUntil;
    }

    struct PoolExit
    {
        address  owner;
        bool     toLayer2;
        uint     poolAmountIn;
        uint96[] minAmountsOut;
        uint32[] storageIDs;
        uint     validUntil;
    }

    struct PoolTransaction
    {
        PoolTransactionType txType;
        bytes               data;
        bytes               signature;
    }

    struct QueueItem
    {
        uint64              timestamp;
        PoolTransactionType txType;
        bytes32             txHash;
    }

    struct Token
    {
        address addr;
        uint96  weight;
        uint16  tokenID;
    }

    struct Context
    {
        ExchangeData.Block _block;
        uint     txIdx;
        bytes32  DOMAIN_SEPARATOR;
        bytes32  exchangeDomainSeparator;
        uint96[] ammActualL2Balances;
        uint96[] ammExpectedL2Balances;
        uint     numTransactionsConsumed;
        Token[]  tokens;
    }

    struct State {
        // Liquidity token state variables
        uint  totalSupply;
        mapping(address => uint) balanceOf;
        mapping(address => mapping(address => uint)) allowance;

        // AMM state variables
        uint8   feeBips;
        Token[] tokens;

        // A map of approved transaction hashes to the timestamp it was created
        mapping (bytes32 => uint) approvedTx;

        // A map from an owner to a token to the balance
        mapping (address => mapping (address => uint)) lockedBalance;
        // A map from an owner to the timestamp until all funds of the user are locked
        // A zero value == locked indefinitely.
        mapping (address => uint) lockedUntil;
        // A map from a token to the total balance owned directly by LPs (so NOT owned by the pool itself)
        mapping (address => uint) totalLockedBalance;

        // A map from an address to a nonce.
        mapping(address => uint) nonces;

        // A map from an owner to if a user is currently exiting using an onchain approval.
        mapping (address => bool) isExiting;
    }
}