// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Coinbase SpendPermissionManager surface used by AgentRevoke.
/// Canonical address (Ethereum and Base): 0xf85210B21cC50302F477BA56686d2019dC9b67Ad
interface ISpendPermissionManager {
    struct SpendPermission {
        address account;
        address spender;
        address token;
        uint160 allowance;
        uint48 period;
        uint48 start;
        uint48 end;
        uint256 salt;
        bytes extraData;
    }

    function approve(SpendPermission calldata spendPermission) external returns (bool);

    function revoke(SpendPermission calldata spendPermission) external;

    function revokeAsSpender(SpendPermission calldata spendPermission) external;

    function isApproved(SpendPermission memory spendPermission) external view returns (bool);

    function isRevoked(SpendPermission memory spendPermission) external view returns (bool);

    function isValid(SpendPermission memory spendPermission) external view returns (bool);

    function getHash(SpendPermission memory spendPermission) external view returns (bytes32);
}
