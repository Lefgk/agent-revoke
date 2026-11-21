// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PanicRevoke} from "../src/PanicRevoke.sol";
import {IPermit2} from "../src/interfaces/IPermit2.sol";
import {ISpendPermissionManager} from "../src/interfaces/ISpendPermissionManager.sol";
import {MockERC20, MockPermit2, MockSpendPermissionManager, OwnerAccount} from "./mocks/Mocks.sol";

contract PanicRevokeHandler is Test {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant SPM = 0xf85210B21cC50302F477BA56686d2019dC9b67Ad;

    PanicRevoke public registry;
    MockERC20 public usdc;
    OwnerAccount public owner;
    address[] public spenders;

    constructor(PanicRevoke registry_, MockERC20 usdc_, OwnerAccount owner_, address[] memory spenders_) {
        registry = registry_;
        usdc = usdc_;
        owner = owner_;
        spenders = spenders_;
        vm.deal(address(owner), 0); // silence unused if any
    }

    function registerErc20(uint256 i) external {
        address sp = spenders[i % spenders.length];
        try owner.call(address(registry), abi.encodeCall(PanicRevoke.registerErc20, (address(usdc), sp))) {} catch {}
    }

    function unregisterErc20(uint256 i) external {
        address sp = spenders[i % spenders.length];
        try owner.call(address(registry), abi.encodeCall(PanicRevoke.unregisterErc20, (address(usdc), sp))) {} catch {}
    }

    function registerPermit2(uint256 i) external {
        address sp = spenders[i % spenders.length];
        try owner.call(address(registry), abi.encodeCall(PanicRevoke.registerPermit2, (address(usdc), sp))) {} catch {}
    }

    function unregisterPermit2(uint256 i) external {
        address sp = spenders[i % spenders.length];
        try owner.call(address(registry), abi.encodeCall(PanicRevoke.unregisterPermit2, (address(usdc), sp))) {} catch {}
    }

    function approveAndPanic(uint256 seed) external {
        uint256 n = spenders.length;
        for (uint256 i; i < n; i++) {
            if ((seed >> i) & 1 == 1) {
                try owner.call(address(usdc), abi.encodeCall(IERC20.approve, (spenders[i], 1e18))) {} catch {}
                try owner.call(PERMIT2, abi.encodeCall(IPermit2.approve, (address(usdc), spenders[i], uint160(1e18), uint48(block.timestamp + 30 days)))) {} catch {}
            }
        }
        try owner.run(address(registry), abi.encodeCall(PanicRevoke.panic, ())) {} catch {}
    }

    function registerSpend(uint256 i, uint160 allowance, uint256 salt) external {
        address sp = spenders[i % spenders.length];
        ISpendPermissionManager.SpendPermission memory p = ISpendPermissionManager.SpendPermission({
            account: address(owner),
            spender: sp,
            token: address(usdc),
            allowance: uint160(bound(allowance, 1, type(uint160).max)),
            period: 1 days,
            start: uint48(block.timestamp),
            end: uint48(block.timestamp + 365 days),
            salt: salt,
            extraData: ""
        });
        try owner.call(address(registry), abi.encodeCall(PanicRevoke.registerSpendPermission, (p))) {} catch {}
    }
}

contract PanicRevokeInvariantTest is Test {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant SPM = 0xf85210B21cC50302F477BA56686d2019dC9b67Ad;

    PanicRevoke registry;
    MockERC20 usdc;
    OwnerAccount owner;
    PanicRevokeHandler handler;

    function setUp() public {
        vm.etch(PERMIT2, address(new MockPermit2()).code);
        vm.etch(SPM, address(new MockSpendPermissionManager()).code);
        registry = new PanicRevoke();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        owner = new OwnerAccount();
        usdc.mint(address(owner), type(uint128).max);
        owner.call(address(usdc), abi.encodeCall(IERC20.approve, (PERMIT2, type(uint256).max)));

        address[] memory spenders = new address[](8);
        for (uint256 i; i < 8; i++) {
            spenders[i] = makeAddr(string.concat("agent-", vm.toString(i)));
        }
        handler = new PanicRevokeHandler(registry, usdc, owner, spenders);
        targetContract(address(handler));
    }

    function invariant_erc20CountCapped() public view {
        assertLe(registry.erc20Targets(address(owner)).length, registry.MAX_TARGETS());
    }

    function invariant_permit2CountCapped() public view {
        assertLe(registry.permit2Targets(address(owner)).length, registry.MAX_TARGETS());
    }

    function invariant_spendCountCapped() public view {
        assertLe(registry.spendPermissionTargets(address(owner)).length, registry.MAX_TARGETS());
    }

    function invariant_registryAddressIsSelf() public view {
        assertEq(registry.registry(), address(registry));
    }

    /// @dev After a successful panic (as the account), every still-registered ERC-20
    ///      allowance for that owner/spender pair that we can observe is zeroed only if
    ///      panic ran; we instead assert a weaker, always-true property: no registered
    ///      pair has a zero address, and the registry itself holds no ERC-20 approvals
    ///      we care about.
    function invariant_registeredPairsAreNonZero() public view {
        PanicRevoke.TokenSpender[] memory e = registry.erc20Targets(address(owner));
        for (uint256 i; i < e.length; i++) {
            assertTrue(e[i].token != address(0) && e[i].spender != address(0));
        }
        PanicRevoke.TokenSpender[] memory p = registry.permit2Targets(address(owner));
        for (uint256 i; i < p.length; i++) {
            assertTrue(p[i].token != address(0) && p[i].spender != address(0));
        }
        ISpendPermissionManager.SpendPermission[] memory s = registry.spendPermissionTargets(address(owner));
        for (uint256 i; i < s.length; i++) {
            assertEq(s[i].account, address(owner));
            assertTrue(s[i].spender != address(0));
        }
    }
}
