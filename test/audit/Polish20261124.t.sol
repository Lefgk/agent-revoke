// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PanicRevoke} from "../../src/PanicRevoke.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {ISpendPermissionManager} from "../../src/interfaces/ISpendPermissionManager.sol";
import {MockERC20, MockPermit2, MockSpendPermissionManager, MockSafe, OwnerAccount} from "../mocks/Mocks.sol";

/// @dev approve() returns false (non-reverting failure).
contract FalseToken {
    function approve(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev approve() tries to re-enter panic() on the calling account (delegatecall path),
///      or panicAsModule(safe) on the registry, and records the outcome.
contract ReenterToken {
    address public registry;
    address public safe;
    bool public attempted;
    bool public reenterOk;
    bytes public reenterRet;

    constructor(address registry_, address safe_) {
        registry = registry_;
        safe = safe_;
    }

    function approve(address, uint256) external returns (bool) {
        attempted = true;
        bool ok;
        bytes memory ret;
        if (safe == address(0)) {
            (ok, ret) = msg.sender.call(
                abi.encodeCall(OwnerAccount.run, (registry, abi.encodeCall(PanicRevoke.panic, ())))
            );
        } else {
            (ok, ret) = registry.call(abi.encodeCall(PanicRevoke.panicAsModule, (safe)));
        }
        reenterOk = ok;
        reenterRet = ret;
        return true;
    }
}

/// @dev Permit2 stand-in whose lockdown always reverts.
contract RevertingPermit2 {
    function lockdown(IPermit2.TokenSpenderPair[] calldata) external pure {
        revert("nope");
    }
}

contract Polish20261124Test is Test {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant SPM = 0xf85210B21cC50302F477BA56686d2019dC9b67Ad;

    event RevokeFailed(address indexed account, uint8 indexed kind, address target, uint256 index);
    event PanicExecuted(
        address indexed account, uint256 erc20Count, uint256 permit2Count, uint256 spendCount, uint256 moduleCount
    );

    PanicRevoke registry;
    MockERC20 usdc; // 6 decimals like Base USDC
    OwnerAccount acct;
    address agent = makeAddr("agent");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.etch(PERMIT2, address(new MockPermit2()).code);
        vm.etch(SPM, address(new MockSpendPermissionManager()).code);
        registry = new PanicRevoke();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        acct = new OwnerAccount();
        usdc.mint(address(acct), 1_000_000e6);
    }

    function _perm(address account, uint256 salt, bytes memory extra)
        internal
        view
        returns (ISpendPermissionManager.SpendPermission memory p)
    {
        p = ISpendPermissionManager.SpendPermission({
            account: account,
            spender: agent,
            token: address(usdc),
            allowance: 100e6,
            period: 1 days,
            start: uint48(block.timestamp),
            end: uint48(block.timestamp + 30 days),
            salt: salt,
            extraData: extra
        });
    }

    function _reg(bytes memory data) internal {
        acct.call(address(registry), data);
    }

    function _panic() internal {
        acct.run(address(registry), abi.encodeCall(PanicRevoke.panic, ()));
    }

    // ── registry access / edge cases ──────────────────────────────────────────

    function test_registerSafeModuleRejectsSentinelAndZero() public {
        vm.startPrank(stranger);
        vm.expectRevert(PanicRevoke.ZeroAddress.selector);
        registry.registerSafeModule(address(0));
        vm.expectRevert(PanicRevoke.ZeroAddress.selector);
        registry.registerSafeModule(address(1));
        vm.stopPrank();
    }

    function test_registerSpendZeroSpenderReverts() public {
        ISpendPermissionManager.SpendPermission memory p = _perm(stranger, 1, "");
        p.spender = address(0);
        vm.prank(stranger);
        vm.expectRevert(PanicRevoke.ZeroAddress.selector);
        registry.registerSpendPermission(p);
    }

    function test_unregisterSpendUnknownAndWrongCaller() public {
        ISpendPermissionManager.SpendPermission memory p = _perm(stranger, 1, "");
        vm.prank(stranger);
        vm.expectRevert(PanicRevoke.UnknownTarget.selector);
        registry.unregisterSpendPermission(p);

        vm.prank(stranger);
        registry.registerSpendPermission(p);
        // another account cannot remove it
        vm.prank(agent);
        vm.expectRevert(PanicRevoke.UnknownTarget.selector);
        registry.unregisterSpendPermission(p);
        assertEq(registry.spendPermissionTargets(stranger).length, 1);
    }

    function test_unregisterModuleUnknownAndWrongCaller() public {
        vm.prank(stranger);
        vm.expectRevert(PanicRevoke.UnknownTarget.selector);
        registry.unregisterSafeModule(address(0xBEEF));

        vm.prank(stranger);
        registry.registerSafeModule(address(0xBEEF));
        vm.prank(agent);
        vm.expectRevert(PanicRevoke.UnknownTarget.selector);
        registry.unregisterSafeModule(address(0xBEEF));
    }

    function test_unregisterPermit2UnknownReverts() public {
        vm.prank(stranger);
        vm.expectRevert(PanicRevoke.UnknownTarget.selector);
        registry.unregisterPermit2(address(usdc), agent);
    }

    function test_registryIsPerAccount() public {
        vm.prank(stranger);
        registry.registerErc20(address(usdc), agent);
        // a different account may register the same pair, lists are independent
        vm.prank(agent);
        registry.registerErc20(address(usdc), agent);
        assertEq(registry.erc20Targets(stranger).length, 1);
        assertEq(registry.erc20Targets(agent).length, 1);
        vm.prank(stranger);
        registry.unregisterErc20(address(usdc), agent);
        assertEq(registry.erc20Targets(agent).length, 1);
    }

    function test_spendKeyDistinguishesSaltAndExtraData() public {
        vm.startPrank(stranger);
        registry.registerSpendPermission(_perm(stranger, 1, ""));
        registry.registerSpendPermission(_perm(stranger, 2, ""));
        registry.registerSpendPermission(_perm(stranger, 1, hex"01"));
        vm.expectRevert(PanicRevoke.AlreadyRegistered.selector);
        registry.registerSpendPermission(_perm(stranger, 1, hex"01"));
        vm.stopPrank();
        assertEq(registry.spendPermissionTargets(stranger).length, 3);
    }

    function test_spendAndModuleMaxTargets() public {
        vm.startPrank(stranger);
        for (uint256 i; i < 64; i++) {
            registry.registerSpendPermission(_perm(stranger, i, ""));
            registry.registerSafeModule(address(uint160(0x1000 + i)));
            registry.registerPermit2(address(usdc), address(uint160(0x2000 + i)));
        }
        vm.expectRevert(PanicRevoke.MaxTargets.selector);
        registry.registerSpendPermission(_perm(stranger, 999, ""));
        vm.expectRevert(PanicRevoke.MaxTargets.selector);
        registry.registerSafeModule(address(0x9999));
        vm.expectRevert(PanicRevoke.MaxTargets.selector);
        registry.registerPermit2(address(usdc), address(0x9999));
        // freeing a slot allows a new registration
        registry.unregisterSafeModule(address(0x1000));
        registry.registerSafeModule(address(0x9999));
        vm.stopPrank();
    }

    function test_registerEmitsEvents() public {
        vm.startPrank(stranger);
        vm.expectEmit(true, false, false, true, address(registry));
        emit PanicRevoke.Erc20Registered(stranger, address(usdc), agent);
        registry.registerErc20(address(usdc), agent);
        vm.expectEmit(true, false, false, true, address(registry));
        emit PanicRevoke.Erc20Unregistered(stranger, address(usdc), agent);
        registry.unregisterErc20(address(usdc), agent);
        vm.expectEmit(true, false, false, true, address(registry));
        emit PanicRevoke.SafeModuleRegistered(stranger, address(0xBEEF));
        registry.registerSafeModule(address(0xBEEF));
        vm.stopPrank();
    }

    /// @dev Swap-and-pop must keep every index consistent for arbitrary removal order.
    function testFuzz_spendSwapAndPopConsistent(uint8 n, uint256 seed) public {
        n = uint8(bound(n, 1, 20));
        vm.startPrank(stranger);
        ISpendPermissionManager.SpendPermission[] memory perms =
            new ISpendPermissionManager.SpendPermission[](n);
        for (uint256 i; i < n; i++) {
            perms[i] = _perm(stranger, i, "");
            registry.registerSpendPermission(perms[i]);
        }
        bool[] memory removed = new bool[](n);
        uint256 remaining = n;
        while (remaining > 0) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint256 pick = seed % n;
            if (removed[pick]) continue;
            registry.unregisterSpendPermission(perms[pick]);
            removed[pick] = true;
            remaining--;
            assertEq(registry.spendPermissionTargets(stranger).length, remaining);
            // survivors still unregisterable-checked via duplicate-register revert
            for (uint256 j; j < n; j++) {
                if (!removed[j]) {
                    vm.expectRevert(PanicRevoke.AlreadyRegistered.selector);
                    registry.registerSpendPermission(perms[j]);
                }
            }
        }
        vm.stopPrank();
    }

    function testFuzz_moduleSwapAndPopConsistent(uint8 n, uint256 seed) public {
        n = uint8(bound(n, 1, 20));
        vm.startPrank(stranger);
        for (uint256 i; i < n; i++) {
            registry.registerSafeModule(address(uint160(0x5000 + i)));
        }
        bool[] memory removed = new bool[](n);
        uint256 remaining = n;
        while (remaining > 0) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint256 pick = seed % n;
            if (removed[pick]) continue;
            registry.unregisterSafeModule(address(uint160(0x5000 + pick)));
            removed[pick] = true;
            remaining--;
            address[] memory left = registry.safeModuleTargets(stranger);
            assertEq(left.length, remaining);
            for (uint256 j; j < n; j++) {
                if (!removed[j]) {
                    vm.expectRevert(PanicRevoke.AlreadyRegistered.selector);
                    registry.registerSafeModule(address(uint160(0x5000 + j)));
                }
            }
        }
        vm.stopPrank();
    }

    // ── panic: context and unhappy paths ──────────────────────────────────────

    function test_panicAsModuleZeroSafeReverts() public {
        vm.expectRevert(PanicRevoke.ZeroAddress.selector);
        registry.panicAsModule(address(0));
    }

    function test_panicAsModuleViaDelegatecallReverts() public {
        MockSafe safe = new MockSafe();
        safe.enableModule(address(registry));
        vm.expectRevert(PanicRevoke.NotAccountContext.selector);
        acct.run(address(registry), abi.encodeCall(PanicRevoke.panicAsModule, (address(safe))));
    }

    function test_panicWithSpendAccountMismatchReverts() public {
        PanicRevoke.TokenSpender[] memory none = new PanicRevoke.TokenSpender[](0);
        ISpendPermissionManager.SpendPermission[] memory s = new ISpendPermissionManager.SpendPermission[](1);
        s[0] = _perm(stranger, 1, ""); // account != acct
        vm.expectRevert(PanicRevoke.SpendAccountMismatch.selector);
        acct.run(address(registry), abi.encodeCall(PanicRevoke.panicWith, (none, none, s)));
    }

    function test_panicAsModuleWithSpendPermissionHappyPath() public {
        MockSafe safe = new MockSafe();
        safe.enableModule(address(registry));
        vm.prank(address(safe));
        registry.registerSpendPermission(_perm(address(safe), 1, ""));
        registry.panicAsModule(address(safe)); // happy path does not revert
    }

    function test_panicEmptyRegistryEmitsPanicExecutedZero() public {
        vm.expectEmit(true, false, false, true, address(acct));
        emit PanicExecuted(address(acct), 0, 0, 0, 0);
        _panic();
    }

    function test_nonContractTokenEmitsRevokeFailedAndContinues() public {
        address eoaToken = makeAddr("eoaToken");
        acct.call(address(usdc), abi.encodeCall(IERC20.approve, (agent, 5e6)));
        _reg(abi.encodeCall(PanicRevoke.registerErc20, (eoaToken, agent)));
        _reg(abi.encodeCall(PanicRevoke.registerErc20, (address(usdc), agent)));

        vm.expectEmit(true, true, false, true, address(acct));
        emit RevokeFailed(address(acct), 0, eoaToken, 0);
        _panic();
        assertEq(usdc.allowance(address(acct), agent), 0);
    }

    function test_falseReturningTokenEmitsRevokeFailed() public {
        FalseToken f = new FalseToken();
        _reg(abi.encodeCall(PanicRevoke.registerErc20, (address(f), agent)));
        vm.expectEmit(true, true, false, true, address(acct));
        emit RevokeFailed(address(acct), 0, address(f), 0);
        _panic();
    }

    function test_permit2LockdownRevertEmitsRevokeFailedKind1() public {
        vm.etch(PERMIT2, address(new RevertingPermit2()).code);
        _reg(abi.encodeCall(PanicRevoke.registerPermit2, (address(usdc), agent)));
        _reg(abi.encodeCall(PanicRevoke.registerErc20, (address(usdc), agent)));
        acct.call(address(usdc), abi.encodeCall(IERC20.approve, (agent, 5e6)));
        vm.expectEmit(true, true, false, true, address(acct));
        emit RevokeFailed(address(acct), 1, PERMIT2, 0);
        _panic();
        assertEq(usdc.allowance(address(acct), agent), 0, "erc20 still revoked");
    }

    function test_spendRevokeFailureEmitsKind2() public {
        // mock SPM reverts Unauthorized when msg.sender != account; register a perm whose
        // account is acct but run panicWith under an account context that differs is not
        // possible, so make SPM revert for all calls instead.
        vm.etch(SPM, address(new RevertingPermit2()).code);
        _reg(abi.encodeCall(PanicRevoke.registerSpendPermission, (_perm(address(acct), 1, ""))));
        vm.expectEmit(true, true, false, true, address(acct));
        emit RevokeFailed(address(acct), 2, SPM, 0);
        _panic();
    }

    function test_panicClearsMaxAllowance() public {
        acct.call(address(usdc), abi.encodeCall(IERC20.approve, (agent, type(uint256).max)));
        _reg(abi.encodeCall(PanicRevoke.registerErc20, (address(usdc), agent)));
        _panic();
        assertEq(usdc.allowance(address(acct), agent), 0);
    }

    function test_panicIsIdempotent() public {
        acct.call(address(usdc), abi.encodeCall(IERC20.approve, (agent, 1e6)));
        _reg(abi.encodeCall(PanicRevoke.registerErc20, (address(usdc), agent)));
        _panic();
        _panic();
        assertEq(usdc.allowance(address(acct), agent), 0);
    }

    function test_panicOnlyAffectsRegisteredPairs() public {
        address other = makeAddr("other");
        acct.call(address(usdc), abi.encodeCall(IERC20.approve, (agent, 1e6)));
        acct.call(address(usdc), abi.encodeCall(IERC20.approve, (other, 2e6)));
        _reg(abi.encodeCall(PanicRevoke.registerErc20, (address(usdc), agent)));
        _panic();
        assertEq(usdc.allowance(address(acct), agent), 0);
        assertEq(usdc.allowance(address(acct), other), 2e6);
    }

    function test_panicUsesCallersOwnRegistryNotAnothers() public {
        // stranger registers a target; acct's panic must ignore it
        vm.prank(stranger);
        registry.registerErc20(address(usdc), agent);
        acct.call(address(usdc), abi.encodeCall(IERC20.approve, (agent, 9e6)));
        _panic();
        assertEq(usdc.allowance(address(acct), agent), 9e6);
    }

    function testFuzz_panicWithZeroesArbitraryAllowances(uint256 amt, address spender) public {
        vm.assume(spender != address(0) && spender != address(acct));
        amt = bound(amt, 0, type(uint256).max);
        acct.call(address(usdc), abi.encodeCall(IERC20.approve, (spender, amt)));
        PanicRevoke.TokenSpender[] memory e = new PanicRevoke.TokenSpender[](1);
        e[0] = PanicRevoke.TokenSpender(address(usdc), spender);
        PanicRevoke.TokenSpender[] memory none = new PanicRevoke.TokenSpender[](0);
        ISpendPermissionManager.SpendPermission[] memory s = new ISpendPermissionManager.SpendPermission[](0);
        acct.run(address(registry), abi.encodeCall(PanicRevoke.panicWith, (e, none, s)));
        assertEq(usdc.allowance(address(acct), spender), 0);
    }

    // ── reentrancy ────────────────────────────────────────────────────────────

    function test_reentrantPanicFromTokenIsBlocked() public {
        ReenterToken evil = new ReenterToken(address(registry), address(0));
        acct.call(address(usdc), abi.encodeCall(IERC20.approve, (agent, 4e6)));
        _reg(abi.encodeCall(PanicRevoke.registerErc20, (address(evil), agent)));
        _reg(abi.encodeCall(PanicRevoke.registerErc20, (address(usdc), agent)));
        _panic();
        assertTrue(evil.attempted());
        assertFalse(evil.reenterOk(), "reentrant panic must revert");
        assertEq(bytes4(evil.reenterRet()), PanicRevoke.Reentrancy.selector);
        assertEq(usdc.allowance(address(acct), agent), 0);
    }

    function test_reentrantPanicAsModuleIsBlocked() public {
        MockSafe safe = new MockSafe();
        safe.enableModule(address(registry));
        ReenterToken evil = new ReenterToken(address(registry), address(safe));
        safe.exec(address(usdc), abi.encodeCall(IERC20.approve, (agent, 4e6)));
        safe.exec(address(registry), abi.encodeCall(PanicRevoke.registerErc20, (address(evil), agent)));
        safe.exec(address(registry), abi.encodeCall(PanicRevoke.registerErc20, (address(usdc), agent)));
        registry.panicAsModule(address(safe));
        assertTrue(evil.attempted());
        assertFalse(evil.reenterOk());
        assertEq(bytes4(evil.reenterRet()), PanicRevoke.Reentrancy.selector);
        assertEq(usdc.allowance(address(safe), agent), 0);
    }

    function test_lockReleasedAfterPanic() public {
        _panic();
        _panic(); // would revert Reentrancy if lock leaked within the tx
    }

    // ── Safe module paths ─────────────────────────────────────────────────────

    function test_panicAsModuleDisablesAllRegisteredModulesButSelf() public {
        MockSafe safe = new MockSafe();
        address m1 = address(0xA1);
        address m2 = address(0xA2);
        address m3 = address(0xA3);
        safe.enableModule(m1);
        safe.enableModule(address(registry));
        safe.enableModule(m2);
        safe.enableModule(m3);
        safe.exec(address(registry), abi.encodeCall(PanicRevoke.registerSafeModule, (m1)));
        safe.exec(address(registry), abi.encodeCall(PanicRevoke.registerSafeModule, (m2)));
        safe.exec(address(registry), abi.encodeCall(PanicRevoke.registerSafeModule, (address(registry))));
        safe.exec(address(registry), abi.encodeCall(PanicRevoke.registerSafeModule, (m3)));

        vm.expectEmit(true, false, false, true, address(registry));
        emit PanicExecuted(address(safe), 0, 0, 0, 4);
        vm.prank(stranger); // permissionless by design
        registry.panicAsModule(address(safe));

        assertFalse(safe.isModuleEnabled(m1));
        assertFalse(safe.isModuleEnabled(m2));
        assertFalse(safe.isModuleEnabled(m3));
        assertTrue(safe.isModuleEnabled(address(registry)), "panic module stays enabled");
    }

    function test_panicAsModuleRevokesAllKindsThroughSafe() public {
        MockSafe safe = new MockSafe();
        safe.enableModule(address(registry));
        safe.exec(address(usdc), abi.encodeCall(IERC20.approve, (agent, 7e6)));
        ISpendPermissionManager.SpendPermission memory p = _perm(address(safe), 3, "");
        safe.exec(SPM, abi.encodeCall(ISpendPermissionManager.approve, (p)));
        safe.exec(PERMIT2, abi.encodeCall(IPermit2.approve, (address(usdc), agent, 5e6, uint48(block.timestamp + 1 days))));
        safe.exec(address(registry), abi.encodeCall(PanicRevoke.registerErc20, (address(usdc), agent)));
        safe.exec(address(registry), abi.encodeCall(PanicRevoke.registerPermit2, (address(usdc), agent)));
        safe.exec(address(registry), abi.encodeCall(PanicRevoke.registerSpendPermission, (p)));

        registry.panicAsModule(address(safe));

        assertEq(usdc.allowance(address(safe), agent), 0);
        (uint160 amt,,) = IPermit2(PERMIT2).allowance(address(safe), address(usdc), agent);
        assertEq(amt, 0);
        assertTrue(MockSpendPermissionManager(SPM).isRevoked(p));
    }

    function test_panicAsModuleStrangerSafeNotEnabledReverts() public {
        MockSafe safe = new MockSafe();
        vm.expectRevert(PanicRevoke.NotSafeModule.selector);
        vm.prank(stranger);
        registry.panicAsModule(address(safe));
    }

    // ── views ─────────────────────────────────────────────────────────────────

    function test_encodeRevokeCallsAllKinds() public {
        vm.startPrank(stranger);
        registry.registerErc20(address(usdc), agent);
        registry.registerPermit2(address(usdc), agent);
        registry.registerPermit2(address(usdc), stranger);
        registry.registerSpendPermission(_perm(stranger, 1, ""));
        registry.registerSafeModule(address(0xBEEF));
        vm.stopPrank();

        PanicRevoke.Call[] memory calls = registry.encodeRevokeCalls(stranger);
        // 1 erc20 + 1 batched permit2 + 1 spend + 1 module
        assertEq(calls.length, 4);
        assertEq(calls[0].to, address(usdc));
        assertEq(calls[0].data, abi.encodeCall(IERC20.approve, (agent, 0)));
        assertEq(calls[1].to, PERMIT2);
        assertEq(bytes4(calls[1].data), IPermit2.lockdown.selector);
        assertEq(calls[2].to, SPM);
        assertEq(bytes4(calls[2].data), ISpendPermissionManager.revoke.selector);
        assertEq(calls[3].to, stranger);
    }

    function test_encodeRevokeCallsEmptyAndNoPermit2() public view {
        assertEq(registry.encodeRevokeCalls(stranger).length, 0);
    }

    function test_registryImmutableAndConstants() public view {
        assertEq(registry.registry(), address(registry));
        assertEq(registry.MAX_TARGETS(), 64);
        assertEq(registry.PERMIT2(), PERMIT2);
        assertEq(registry.SPEND_PERMISSION_MANAGER(), SPM);
    }

    /// @dev Panic through delegatecall keeps working when the account holds the real-scale
    ///      (6-dec) USDC supply and a max allowance; balances are never touched.
    function testFuzz_panicNeverMovesBalances(uint256 bal, uint256 allowance_) public {
        bal = bound(bal, 0, 1e15 * 1e6);
        allowance_ = bound(allowance_, 0, type(uint256).max);
        address a = makeAddr("fuzzAcct");
        OwnerAccount o = new OwnerAccount();
        usdc.mint(address(o), bal);
        o.call(address(usdc), abi.encodeCall(IERC20.approve, (a, allowance_)));
        o.call(address(registry), abi.encodeCall(PanicRevoke.registerErc20, (address(usdc), a)));
        uint256 before_ = usdc.balanceOf(address(o));
        o.run(address(registry), abi.encodeCall(PanicRevoke.panic, ()));
        assertEq(usdc.balanceOf(address(o)), before_);
        assertEq(usdc.allowance(address(o), a), 0);
    }
}
