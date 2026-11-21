// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Gnosis Safe / Safe{Wallet} module surface.
interface ISafe {
    function isModuleEnabled(address module) external view returns (bool);

    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next);

    function execTransactionFromModule(address to, uint256 value, bytes memory data, uint8 operation)
        external
        returns (bool success);

    function disableModule(address prevModule, address module) external;
}
