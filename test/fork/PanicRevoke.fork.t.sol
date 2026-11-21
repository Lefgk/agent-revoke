// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PanicRevoke} from "../../src/PanicRevoke.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {ISpendPermissionManager} from "../../src/interfaces/ISpendPermissionManager.sol";
import {DeployConfig} from "../../script/DeployConfig.sol";
import {OwnerAccount} from "../mocks/Mocks.sol";

interface IFiatToken {
    function masterMinter() external view returns (address);
    function configureMinter(address minter, uint256 minterAllowedAmount) external returns (bool);
    function mint(address to, uint256 amount) external returns (bool);
}

/// @dev Fork tests against real Circle USDC and canonical Permit2 / SpendPermissionManager.
abstract contract PanicRevokeForkBase is Test {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant SPM = 0xf85210B21cC50302F477BA56686d2019dC9b67Ad;

    PanicRevoke registry;
    IERC20Metadata usdc;
    OwnerAccount owner;
    address agent;
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

        usdc = IERC20Metadata(DeployConfig.get(block.chainid).usdc);
        registry = new PanicRevoke();
        owner = new OwnerAccount();
        agent = makeAddr("fork-agent");
        _fundUsdc(address(owner), 10_000e6);
        vm.deal(address(owner), 1 ether);
    }

    modifier onFork() {
        if (!active) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _fundUsdc(address to, uint256 amount) internal {
        deal(address(usdc), to, amount, true);
        if (usdc.balanceOf(to) >= amount) return;
        address minter = IFiatToken(address(usdc)).masterMinter();
        vm.prank(minter);
        IFiatToken(address(usdc)).configureMinter(minter, type(uint256).max);
        vm.prank(minter);
        IFiatToken(address(usdc)).mint(to, amount);
        assertGe(usdc.balanceOf(to), amount, "USDC funding failed");
    }

    function test_fork_canonicalTokensAndManagersExist() public onFork {
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
        assertGt(address(usdc).code.length, 0);
        assertGt(PERMIT2.code.length, 0);
        assertGt(SPM.code.length, 0);
        assertEq(PERMIT2, 0x000000000022D473030F116dDEE9F6B43aC78BA3);
    }

    function test_fork_panicClearsRealUsdcAndPermit2() public onFork {
        // ERC-20 approval
        owner.call(address(usdc), abi.encodeCall(IERC20.approve, (agent, 1_000e6)));
        assertEq(usdc.allowance(address(owner), agent), 1_000e6);

        // Permit2 allowance
        owner.call(address(usdc), abi.encodeCall(IERC20.approve, (PERMIT2, type(uint256).max)));
        owner.call(
            PERMIT2,
            abi.encodeCall(IPermit2.approve, (address(usdc), agent, uint160(250e6), uint48(block.timestamp + 14 days)))
        );
        (uint160 amt, uint48 exp,) = IPermit2(PERMIT2).allowance(address(owner), address(usdc), agent);
        assertEq(amt, 250e6);
        assertGt(exp, block.timestamp);

        // Coinbase Spend Permission (approve/revoke only; spend would need a smart wallet)
        ISpendPermissionManager.SpendPermission memory p = ISpendPermissionManager.SpendPermission({
            account: address(owner),
            spender: agent,
            token: address(usdc),
            allowance: 50e6,
            period: 1 days,
            start: uint48(block.timestamp),
            end: uint48(block.timestamp + 30 days),
            salt: 42,
            extraData: ""
        });
        owner.call(SPM, abi.encodeCall(ISpendPermissionManager.approve, (p)));
        assertTrue(ISpendPermissionManager(SPM).isApproved(p));

        owner.call(address(registry), abi.encodeCall(PanicRevoke.registerErc20, (address(usdc), agent)));
        owner.call(address(registry), abi.encodeCall(PanicRevoke.registerPermit2, (address(usdc), agent)));
        owner.call(address(registry), abi.encodeCall(PanicRevoke.registerSpendPermission, (p)));

        owner.run(address(registry), abi.encodeCall(PanicRevoke.panic, ()));

        assertEq(usdc.allowance(address(owner), agent), 0, "erc20 allowance");
        (amt,,) = IPermit2(PERMIT2).allowance(address(owner), address(usdc), agent);
        assertEq(amt, 0, "permit2 allowance");
        assertTrue(ISpendPermissionManager(SPM).isRevoked(p), "spend permission revoked");
        assertFalse(ISpendPermissionManager(SPM).isValid(p), "spend permission still valid");
        // owner still holds its USDC
        assertEq(usdc.balanceOf(address(owner)), 10_000e6);
    }

    function test_fork_registryPanicReverts() public onFork {
        vm.expectRevert(PanicRevoke.NotAccountContext.selector);
        registry.panic();
    }
}

contract EthereumPanicRevokeForkTest is PanicRevokeForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "MAINNET_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 1;
    }
}

contract BasePanicRevokeForkTest is PanicRevokeForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "BASE_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 8453;
    }
}
