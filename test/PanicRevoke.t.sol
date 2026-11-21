// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PanicRevoke} from "../src/PanicRevoke.sol";
import {IPermit2} from "../src/interfaces/IPermit2.sol";
import {ISpendPermissionManager} from "../src/interfaces/ISpendPermissionManager.sol";
import {MockERC20, MockPermit2, MockSpendPermissionManager, MockSafe, OwnerAccount} from "./mocks/Mocks.sol";

contract PanicRevokeTest is Test {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant SPM = 0xf85210B21cC50302F477BA56686d2019dC9b67Ad;

    PanicRevoke registry;
    MockERC20 usdc;
    OwnerAccount owner;
    address agent;
    address stranger;

    function setUp() public {
        _etchMocks();
        registry = new PanicRevoke();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        owner = new OwnerAccount();
        agent = makeAddr("agent");
        stranger = makeAddr("stranger");
        usdc.mint(address(owner), 1_000_000e6);
    }

    function _etchMocks() internal {
        vm.etch(PERMIT2, address(new MockPermit2()).code);
        vm.etch(SPM, address(new MockSpendPermissionManager()).code);
    }

    function _approveErc20(uint256 amount) internal {
        owner.call(address(usdc), abi.encodeCall(IERC20.approve, (agent, amount)));
    }

    function _approvePermit2(uint160 amount, uint48 exp) internal {
        owner.call(address(usdc), abi.encodeCall(IERC20.approve, (PERMIT2, type(uint256).max)));
        owner.call(PERMIT2, abi.encodeCall(IPermit2.approve, (address(usdc), agent, amount, exp)));
    }

    function _perm() internal view returns (ISpendPermissionManager.SpendPermission memory p) {
        p = ISpendPermissionManager.SpendPermission({
            account: address(owner),
            spender: agent,
            token: address(usdc),
            allowance: 100e6,
            period: 1 days,
            start: uint48(block.timestamp),
            end: uint48(block.timestamp + 30 days),
            salt: 1,
            extraData: ""
        });
    }

    function _approveSpend() internal {
        owner.call(SPM, abi.encodeCall(ISpendPermissionManager.approve, (_perm())));
    }

    function _registerAll() internal {
        owner.call(address(registry), abi.encodeCall(PanicRevoke.registerErc20, (address(usdc), agent)));
        owner.call(address(registry), abi.encodeCall(PanicRevoke.registerPermit2, (address(usdc), agent)));
        owner.call(address(registry), abi.encodeCall(PanicRevoke.registerSpendPermission, (_perm())));
    }

    function _panic() internal {
        owner.run(address(registry), abi.encodeCall(PanicRevoke.panic, ()));
    }

    function test_registerAndGetTargets() public {
        _registerAll();
        PanicRevoke.Targets memory t = registry.getTargets(address(owner));
        assertEq(t.erc20.length, 1);
        assertEq(t.erc20[0].token, address(usdc));
        assertEq(t.erc20[0].spender, agent);
        assertEq(t.permit2.length, 1);
        assertEq(t.spendPermissions.length, 1);
        assertEq(t.spendPermissions[0].spender, agent);
        assertEq(t.safeModules.length, 0);
    }

    function test_registerZeroAddressReverts() public {
        vm.expectRevert(PanicRevoke.ZeroAddress.selector);
        registry.registerErc20(address(0), agent);
        vm.expectRevert(PanicRevoke.ZeroAddress.selector);
        registry.registerErc20(address(usdc), address(0));
        vm.expectRevert(PanicRevoke.ZeroAddress.selector);
        registry.registerPermit2(address(usdc), address(0));
        vm.expectRevert(PanicRevoke.ZeroAddress.selector);
        registry.registerSafeModule(address(0));
        vm.expectRevert(PanicRevoke.ZeroAddress.selector);
        registry.registerSafeModule(address(0x1));
    }

    function test_duplicateRegisterReverts() public {
        registry.registerErc20(address(usdc), agent);
        vm.expectRevert(PanicRevoke.AlreadyRegistered.selector);
        registry.registerErc20(address(usdc), agent);
    }

    function test_unregisterUnknownReverts() public {
        vm.expectRevert(PanicRevoke.UnknownTarget.selector);
        registry.unregisterErc20(address(usdc), agent);
    }

    function test_unregisterSwapAndPop() public {
        address agent2 = makeAddr("agent2");
        address agent3 = makeAddr("agent3");
        registry.registerErc20(address(usdc), agent);
        registry.registerErc20(address(usdc), agent2);
        registry.registerErc20(address(usdc), agent3);
        registry.unregisterErc20(address(usdc), agent);
        PanicRevoke.TokenSpender[] memory list = registry.erc20Targets(address(this));
        assertEq(list.length, 2);
        registry.unregisterErc20(address(usdc), agent3);
        list = registry.erc20Targets(address(this));
        assertEq(list.length, 1);
        assertEq(list[0].spender, agent2);
        registry.unregisterErc20(address(usdc), agent2);
        assertEq(registry.erc20Targets(address(this)).length, 0);
    }

    function test_strangerCannotUnregisterOwnersTargets() public {
        _registerAll();
        vm.prank(stranger);
        vm.expectRevert(PanicRevoke.UnknownTarget.selector);
        registry.unregisterErc20(address(usdc), agent);
        assertEq(registry.erc20Targets(address(owner)).length, 1);
    }

    function test_registerSpendWrongAccountReverts() public {
        ISpendPermissionManager.SpendPermission memory p = _perm();
        p.account = stranger;
        vm.expectRevert(PanicRevoke.SpendAccountMismatch.selector);
        registry.registerSpendPermission(p);
    }

    function test_maxTargetsReverts() public {
        uint256 cap = registry.MAX_TARGETS();
        for (uint256 i = 1; i <= cap; i++) {
            registry.registerErc20(address(usdc), address(uint160(i)));
        }
        vm.expectRevert(PanicRevoke.MaxTargets.selector);
        registry.registerErc20(address(usdc), address(uint160(cap + 1)));
    }

    function test_panicOnRegistryReverts() public {
        vm.expectRevert(PanicRevoke.NotAccountContext.selector);
        registry.panic();
    }

    function test_panicWithOnRegistryReverts() public {
        PanicRevoke.TokenSpender[] memory empty;
        ISpendPermissionManager.SpendPermission[] memory none;
        vm.expectRevert(PanicRevoke.NotAccountContext.selector);
        registry.panicWith(empty, empty, none);
    }

    function test_panicClearsErc20Permit2AndSpend() public {
        _approveErc20(500e6);
        _approvePermit2(200e6, uint48(block.timestamp + 7 days));
        _approveSpend();
        _registerAll();

        assertEq(usdc.allowance(address(owner), agent), 500e6);
        (uint160 amt,,) = IPermit2(PERMIT2).allowance(address(owner), address(usdc), agent);
        assertEq(amt, 200e6);
        assertTrue(ISpendPermissionManager(SPM).isApproved(_perm()));

        _panic();

        assertEq(usdc.allowance(address(owner), agent), 0);
        (amt,,) = IPermit2(PERMIT2).allowance(address(owner), address(usdc), agent);
        assertEq(amt, 0);
        assertTrue(ISpendPermissionManager(SPM).isRevoked(_perm()));
        assertFalse(ISpendPermissionManager(SPM).isValid(_perm()));
    }

    function test_panicWithClearsWithoutRegistry() public {
        _approveErc20(10e6);
        _approvePermit2(10e6, uint48(block.timestamp + 1 days));
        _approveSpend();

        PanicRevoke.TokenSpender[] memory e = new PanicRevoke.TokenSpender[](1);
        e[0] = PanicRevoke.TokenSpender(address(usdc), agent);
        PanicRevoke.TokenSpender[] memory p = new PanicRevoke.TokenSpender[](1);
        p[0] = PanicRevoke.TokenSpender(address(usdc), agent);
        ISpendPermissionManager.SpendPermission[] memory s = new ISpendPermissionManager.SpendPermission[](1);
        s[0] = _perm();

        owner.run(address(registry), abi.encodeCall(PanicRevoke.panicWith, (e, p, s)));

        assertEq(usdc.allowance(address(owner), agent), 0);
        (uint160 amt,,) = IPermit2(PERMIT2).allowance(address(owner), address(usdc), agent);
        assertEq(amt, 0);
        assertTrue(ISpendPermissionManager(SPM).isRevoked(_perm()));
    }

    function test_encodeRevokeCalls() public {
        _registerAll();
        PanicRevoke.Call[] memory calls = registry.encodeRevokeCalls(address(owner));
        // 1 erc20 + 1 combined permit2 lockdown + 1 spend
        assertEq(calls.length, 3);
        assertEq(calls[0].to, address(usdc));
        assertEq(calls[1].to, PERMIT2);
        assertEq(calls[2].to, SPM);
    }

    function test_panicAsModuleClearsThroughSafe() public {
        MockSafe safe = new MockSafe();
        usdc.mint(address(safe), 1000e6);

        // Safe sets approvals as itself
        safe.exec(address(usdc), abi.encodeCall(IERC20.approve, (agent, 77e6)));
        safe.exec(address(usdc), abi.encodeCall(IERC20.approve, (PERMIT2, type(uint256).max)));
        safe.exec(PERMIT2, abi.encodeCall(IPermit2.approve, (address(usdc), agent, uint160(40e6), uint48(block.timestamp + 3 days))));

        ISpendPermissionManager.SpendPermission memory p = ISpendPermissionManager.SpendPermission({
            account: address(safe),
            spender: agent,
            token: address(usdc),
            allowance: 10e6,
            period: 1 days,
            start: uint48(block.timestamp),
            end: uint48(block.timestamp + 10 days),
            salt: 7,
            extraData: hex"01"
        });
        safe.exec(SPM, abi.encodeCall(ISpendPermissionManager.approve, (p)));

        // Enable PanicRevoke as a module and register targets as the Safe
        safe.enableModule(address(registry));
        safe.exec(address(registry), abi.encodeCall(PanicRevoke.registerErc20, (address(usdc), agent)));
        safe.exec(address(registry), abi.encodeCall(PanicRevoke.registerPermit2, (address(usdc), agent)));
        safe.exec(address(registry), abi.encodeCall(PanicRevoke.registerSpendPermission, (p)));

        address extra = makeAddr("extra-module");
        // put a dummy module on the Safe and register it for disable
        safe.enableModule(extra);
        safe.exec(address(registry), abi.encodeCall(PanicRevoke.registerSafeModule, (extra)));
        assertTrue(safe.isModuleEnabled(extra));

        registry.panicAsModule(address(safe));

        assertEq(usdc.allowance(address(safe), agent), 0);
        (uint160 amt,,) = IPermit2(PERMIT2).allowance(address(safe), address(usdc), agent);
        assertEq(amt, 0);
        assertTrue(ISpendPermissionManager(SPM).isRevoked(p));
        assertFalse(safe.isModuleEnabled(extra));
        assertTrue(safe.isModuleEnabled(address(registry)));
    }

    function test_panicAsModuleRequiresEnabled() public {
        MockSafe safe = new MockSafe();
        vm.expectRevert(PanicRevoke.NotSafeModule.selector);
        registry.panicAsModule(address(safe));
    }

    function testFuzz_registerUnregisterErc20(address token, address spender) public {
        vm.assume(token != address(0) && spender != address(0));
        registry.registerErc20(token, spender);
        assertEq(registry.erc20Targets(address(this)).length, 1);
        registry.unregisterErc20(token, spender);
        assertEq(registry.erc20Targets(address(this)).length, 0);
        // re-register works after unregister
        registry.registerErc20(token, spender);
        assertEq(registry.erc20Targets(address(this))[0].token, token);
        assertEq(registry.erc20Targets(address(this))[0].spender, spender);
    }

    function testFuzz_panicZerosAllowances(uint256 ercAmt, uint160 pmtAmt) public {
        ercAmt = bound(ercAmt, 1, type(uint256).max);
        pmtAmt = uint160(bound(uint256(pmtAmt), 1, type(uint160).max));
        _approveErc20(ercAmt);
        _approvePermit2(pmtAmt, uint48(block.timestamp + 100 days));
        _registerAll();
        // spend optional
        _approveSpend();
        _panic();
        assertEq(usdc.allowance(address(owner), agent), 0);
        (uint160 amt,,) = IPermit2(PERMIT2).allowance(address(owner), address(usdc), agent);
        assertEq(amt, 0);
    }

    function testFuzz_maxTargetsCap(uint8 n) public {
        n = uint8(bound(n, 1, 80));
        uint256 ok;
        for (uint256 i = 1; i <= n; i++) {
            if (ok >= registry.MAX_TARGETS()) {
                vm.expectRevert(PanicRevoke.MaxTargets.selector);
                registry.registerPermit2(address(usdc), address(uint160(i)));
            } else {
                registry.registerPermit2(address(usdc), address(uint160(i)));
                ok++;
            }
        }
        assertEq(registry.permit2Targets(address(this)).length, ok);
        assertLe(ok, registry.MAX_TARGETS());
    }
}
