// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {PanicRevoke} from "../src/PanicRevoke.sol";
import {ISpendPermissionManager} from "../src/interfaces/ISpendPermissionManager.sol";
import {MockERC20, MockPermit2, MockSpendPermissionManager, MockSafe, OwnerAccount} from "./mocks/Mocks.sol";

/// @dev ERC-721 whose approve(address,uint256) shares the ERC-20 selector.
contract MockNFT is ERC721 {
    constructor() ERC721("N", "N") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// @dev USDT-style token: approve() returns nothing.
contract NoReturnToken {
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }
}

/// @dev Token whose approve always reverts (paused / broken token).
contract RevertingToken {
    function approve(address, uint256) external pure returns (bool) {
        revert("paused");
    }
}

/// @dev Smart account that keeps meaningful data in storage slot 8 and delegatecalls PanicRevoke.
contract SlotEightAccount {
    function setSlot8(uint256 v) external {
        assembly {
            sstore(8, v)
        }
    }

    function slot8() external view returns (uint256 v) {
        assembly {
            v := sload(8)
        }
    }

    function run(address target, bytes memory data) external {
        (bool ok, bytes memory ret) = target.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function call(address to, bytes memory data) external {
        (bool ok,) = to.call(data);
        require(ok);
    }
}

contract Audit20261123Test is Test {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant SPM = 0xf85210B21cC50302F477BA56686d2019dC9b67Ad;

    PanicRevoke registry;
    MockERC20 usdc;
    address agent = makeAddr("agent");
    address attacker = makeAddr("attacker");

    function setUp() public {
        vm.etch(PERMIT2, address(new MockPermit2()).code);
        vm.etch(SPM, address(new MockSpendPermissionManager()).code);
        registry = new PanicRevoke();
        usdc = new MockERC20("USD Coin", "USDC", 6);
    }

    // ── H-01: panicWith is callable by anyone on a 7702-delegated EOA ─────────

    function test_H01_strangerCannotPanicWithOn7702Eoa_nftTheft() public {
        vm.setEvmVersion("prague");
        (address alice, uint256 pk) = makeAddrAndKey("alice");
        MockNFT nft = new MockNFT();
        nft.mint(alice, 0);
        vm.signAndAttachDelegation(address(registry), pk);
        assertEq(bytes3(alice.code), bytes3(0xef0100));

        PanicRevoke.TokenSpender[] memory e = new PanicRevoke.TokenSpender[](1);
        e[0] = PanicRevoke.TokenSpender(address(nft), attacker); // approve(attacker, 0) == approve tokenId 0
        PanicRevoke.TokenSpender[] memory none;
        ISpendPermissionManager.SpendPermission[] memory noSp;

        vm.prank(attacker);
        try PanicRevoke(alice).panicWith(e, none, noSp) {} catch {}
        assertTrue(nft.getApproved(0) != attacker, "attacker got NFT #0 approval");
        assertEq(nft.ownerOf(0), alice);
    }

    function test_H01_strangerCannotRevokeArbitraryApprovalsOn7702Eoa() public {
        vm.setEvmVersion("prague");
        (address alice, uint256 pk) = makeAddrAndKey("alice");
        vm.prank(alice);
        usdc.approve(agent, 500e6); // NOT registered for panic
        vm.signAndAttachDelegation(address(registry), pk);

        PanicRevoke.TokenSpender[] memory e = new PanicRevoke.TokenSpender[](1);
        e[0] = PanicRevoke.TokenSpender(address(usdc), agent);
        PanicRevoke.TokenSpender[] memory none;
        ISpendPermissionManager.SpendPermission[] memory noSp;

        vm.prank(attacker);
        vm.expectRevert(PanicRevoke.NotAuthorized.selector);
        PanicRevoke(alice).panicWith(e, none, noSp);
        assertEq(usdc.allowance(alice, agent), 500e6);
    }

    function test_H01_ownerSelfCallPanicWithStillWorksOn7702() public {
        vm.setEvmVersion("prague");
        (address alice, uint256 pk) = makeAddrAndKey("alice");
        vm.prank(alice);
        usdc.approve(agent, 500e6);
        vm.signAndAttachDelegation(address(registry), pk);

        PanicRevoke.TokenSpender[] memory e = new PanicRevoke.TokenSpender[](1);
        e[0] = PanicRevoke.TokenSpender(address(usdc), agent);
        PanicRevoke.TokenSpender[] memory none;
        ISpendPermissionManager.SpendPermission[] memory noSp;

        vm.prank(alice, alice);
        PanicRevoke(alice).panicWith(e, none, noSp);
        assertEq(usdc.allowance(alice, agent), 0);
    }

    function testFuzz_H01_onlySelfCanPanicWith(address caller) public {
        vm.setEvmVersion("prague");
        (address alice, uint256 pk) = makeAddrAndKey("alice");
        vm.assume(caller != alice);
        vm.prank(alice);
        usdc.approve(agent, 1e6);
        vm.signAndAttachDelegation(address(registry), pk);
        PanicRevoke.TokenSpender[] memory e = new PanicRevoke.TokenSpender[](1);
        e[0] = PanicRevoke.TokenSpender(address(usdc), agent);
        PanicRevoke.TokenSpender[] memory none;
        ISpendPermissionManager.SpendPermission[] memory noSp;
        vm.prank(caller);
        try PanicRevoke(alice).panicWith(e, none, noSp) {} catch {}
        assertEq(usdc.allowance(alice, agent), 1e6);
    }

    // ── M-01: USDT-style approve (no return value) makes panic() revert ───────

    function test_M01_panicHandlesNoReturnApprove() public {
        OwnerAccount owner = new OwnerAccount();
        NoReturnToken usdt = new NoReturnToken();
        owner.call(address(usdt), abi.encodeCall(NoReturnToken.approve, (agent, 1e6)));
        owner.call(address(usdc), abi.encodeCall(IERC20.approve, (agent, 2e6)));
        owner.call(address(registry), abi.encodeCall(PanicRevoke.registerErc20, (address(usdt), agent)));
        owner.call(address(registry), abi.encodeCall(PanicRevoke.registerErc20, (address(usdc), agent)));

        owner.run(address(registry), abi.encodeCall(PanicRevoke.panic, ()));
        assertEq(usdt.allowance(address(owner), agent), 0);
        assertEq(usdc.allowance(address(owner), agent), 0);
    }

    // ── M-02: one failing target blocks the whole panic ───────────────────────

    function test_M02_revertingTokenDoesNotBlockAccountPanic() public {
        OwnerAccount owner = new OwnerAccount();
        RevertingToken bad = new RevertingToken();
        owner.call(address(usdc), abi.encodeCall(IERC20.approve, (agent, 2e6)));
        owner.call(address(registry), abi.encodeCall(PanicRevoke.registerErc20, (address(bad), agent)));
        owner.call(address(registry), abi.encodeCall(PanicRevoke.registerErc20, (address(usdc), agent)));

        owner.run(address(registry), abi.encodeCall(PanicRevoke.panic, ()));
        assertEq(usdc.allowance(address(owner), agent), 0);
    }

    function test_M02_staleModuleDoesNotBlockSafePanic() public {
        MockSafe safe = new MockSafe();
        safe.exec(address(usdc), abi.encodeCall(IERC20.approve, (agent, 77e6)));
        safe.enableModule(address(registry));
        address stale = makeAddr("stale-module");
        safe.enableModule(stale);
        safe.exec(address(registry), abi.encodeCall(PanicRevoke.registerSafeModule, (stale)));
        safe.exec(address(registry), abi.encodeCall(PanicRevoke.registerErc20, (address(usdc), agent)));
        // Owner later disables the module by hand but forgets to unregister it.
        address prev = _prev(safe, stale);
        vm.prank(address(safe));
        safe.disableModule(prev, stale);
        assertFalse(safe.isModuleEnabled(stale));

        registry.panicAsModule(address(safe));
        assertEq(usdc.allowance(address(safe), agent), 0);
    }

    function test_M02_failingModuleCallDoesNotBlockSafePanic() public {
        MockSafe safe = new MockSafe();
        RevertingToken bad = new RevertingToken();
        safe.exec(address(usdc), abi.encodeCall(IERC20.approve, (agent, 77e6)));
        safe.enableModule(address(registry));
        safe.exec(address(registry), abi.encodeCall(PanicRevoke.registerErc20, (address(bad), agent)));
        safe.exec(address(registry), abi.encodeCall(PanicRevoke.registerErc20, (address(usdc), agent)));

        registry.panicAsModule(address(safe));
        assertEq(usdc.allowance(address(safe), agent), 0);
    }

    function _prev(MockSafe safe, address module) internal view returns (address prev) {
        (address[] memory page,) = safe.getModulesPaginated(address(0x1), 64);
        prev = address(0x1);
        for (uint256 i; i < page.length; i++) {
            if (page[i] == module) return prev;
            prev = page[i];
        }
    }

    // ── M-03: persistent reentrancy lock writes the account's storage slot 8 ──

    function testFuzz_M03_panicDoesNotTouchAccountStorage(uint256 v) public {
        SlotEightAccount acct = new SlotEightAccount();
        acct.setSlot8(v);
        acct.call(address(usdc), abi.encodeCall(IERC20.approve, (agent, 3e6)));
        acct.call(address(registry), abi.encodeCall(PanicRevoke.registerErc20, (address(usdc), agent)));

        acct.run(address(registry), abi.encodeCall(PanicRevoke.panic, ()));
        assertEq(acct.slot8(), v, "account storage slot 8 clobbered");
        assertEq(usdc.allowance(address(acct), agent), 0);
    }

    function test_M03_slot8EqualOneDoesNotBrickPanic() public {
        SlotEightAccount acct = new SlotEightAccount();
        acct.setSlot8(1);
        acct.call(address(usdc), abi.encodeCall(IERC20.approve, (agent, 3e6)));
        acct.call(address(registry), abi.encodeCall(PanicRevoke.registerErc20, (address(usdc), agent)));
        acct.run(address(registry), abi.encodeCall(PanicRevoke.panic, ()));
        assertEq(usdc.allowance(address(acct), agent), 0);
    }
}
