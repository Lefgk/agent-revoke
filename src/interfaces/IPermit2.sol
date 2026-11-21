// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Permit2 AllowanceTransfer surface used by AgentRevoke.
/// Canonical address (Ethereum and Base): 0x000000000022D473030F116dDEE9F6B43aC78BA3
interface IPermit2 {
    struct TokenSpenderPair {
        address token;
        address spender;
    }

    function approve(address token, address spender, uint160 amount, uint48 expiration) external;

    function lockdown(TokenSpenderPair[] calldata approvals) external;

    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}
