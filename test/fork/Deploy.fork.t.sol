// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PanicRevoke} from "../../src/PanicRevoke.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployConfig} from "../../script/DeployConfig.sol";

/// @dev Runs the production Deploy script against a live-chain fork (no broadcast to a real network).
abstract contract DeployForkBase is Test {
    bool active;

    function _rpcEnv() internal pure virtual returns (string memory);
    function _chainId() internal pure virtual returns (uint256);

    function setUp() public {
        if (block.chainid == _chainId()) {
            // already on this chain's fork
        } else if (block.chainid == 31337) {
            string memory rpc = vm.envOr(_rpcEnv(), string(""));
            if (bytes(rpc).length == 0) return;
            vm.createSelectFork(rpc);
        } else {
            return;
        }
        active = true;
        assertEq(block.chainid, _chainId(), "wrong fork chain");
    }

    modifier onFork() {
        if (!active) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_deployScript_panicRevokeAndCanonicalUsdc() public onFork {
        Deploy script = new Deploy();
        (PanicRevoke panic, address usdc) = script.run();

        assertTrue(address(panic).code.length > 0, "PanicRevoke not deployed");
        assertEq(panic.registry(), address(panic));
        assertEq(usdc, DeployConfig.get(block.chainid).usdc, "must use canonical USDC");
        assertEq(IERC20Metadata(usdc).symbol(), "USDC");
        assertEq(IERC20Metadata(usdc).decimals(), 6);

        address user = makeAddr("revoker");
        vm.prank(user);
        panic.registerErc20(usdc, makeAddr("agent"));
        assertEq(panic.erc20Targets(user).length, 1);
    }

    function test_fork_deployScript_confirmMainnetNotSetIsDryRunSafe() public onFork {
        vm.setEnv("CONFIRM_MAINNET", "");
        Deploy script = new Deploy();
        (PanicRevoke panic,) = script.run();
        assertTrue(address(panic).code.length > 0);
    }
}

contract EthereumDeployForkTest is DeployForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "MAINNET_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 1;
    }
}

contract BaseDeployForkTest is DeployForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "BASE_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 8453;
    }
}
