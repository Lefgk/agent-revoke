// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "./interfaces/IPermit2.sol";
import {ISpendPermissionManager} from "./interfaces/ISpendPermissionManager.sol";
import {ISafe} from "./interfaces/ISafe.sol";

/// @title PanicRevoke
/// @notice Shared registry of revoke targets plus an executor that clears them in one
///         `panic()` call *when it runs as the owner account*.
///
///         ERC-20 `approve(0)`, Permit2 `lockdown`, and SpendPermission `revoke` all
///         require `msg.sender` to be the token/account owner. A third-party contract
///         cannot do this on the owner's behalf. So:
///         - `panic()` / `panicWith()` MUST be invoked in the owner's context
///           (EIP-7702 designation to this contract, or a delegatecall from the account).
///         - `panicAsModule(safe)` works when this contract is an enabled Safe module
///           (the Safe is then `msg.sender` of each revoke).
///         - Otherwise the dapp should send sequential owner txs, or a Safe MultiSend.
///         EIP-7702 delegation itself cannot be cleared here (needs a type-4 tx).
///         Permit2 lockdown does not invalidate already-signed SignatureTransfer permits.
contract PanicRevoke {
    struct TokenSpender {
        address token;
        address spender;
    }

    struct Call {
        address to;
        bytes data;
    }

    struct Targets {
        TokenSpender[] erc20;
        TokenSpender[] permit2;
        ISpendPermissionManager.SpendPermission[] spendPermissions;
        address[] safeModules;
    }

    uint256 public constant MAX_TARGETS = 64;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant SPEND_PERMISSION_MANAGER = 0xf85210B21cC50302F477BA56686d2019dC9b67Ad;
    address internal constant SENTINEL_MODULE = address(0x1);
    uint8 internal constant SAFE_CALL = 0;

    /// @notice Canonical registry address. Immutable so it still resolves when this
    ///         bytecode runs on an EOA via EIP-7702 (storage would be the EOA's).
    address public immutable registry;

    mapping(address => TokenSpender[]) internal _erc20;
    mapping(address => TokenSpender[]) internal _permit2;
    mapping(address => ISpendPermissionManager.SpendPermission[]) internal _spend;
    mapping(address => address[]) internal _modules;

    // 1-based indices for O(1) unregister
    mapping(address => mapping(bytes32 => uint256)) internal _erc20Index;
    mapping(address => mapping(bytes32 => uint256)) internal _permit2Index;
    mapping(address => mapping(bytes32 => uint256)) internal _spendIndex;
    mapping(address => mapping(address => uint256)) internal _moduleIndex;

    /// @dev Transient-storage slot for the reentrancy lock. Transient storage is used so
    ///      that `panic()` running in an account's context (EIP-7702 or delegatecall) never
    ///      reads or writes that account's persistent storage. keccak256("PanicRevoke.lock") - 1
    bytes32 private constant _LOCK_SLOT = 0x46848f0fbb7419c3ea5aa2ca5cb6a2ade160fb8571d0481377fe04209fc1905a;

    event Erc20Registered(address indexed owner, address token, address spender);
    event Erc20Unregistered(address indexed owner, address token, address spender);
    event Permit2Registered(address indexed owner, address token, address spender);
    event Permit2Unregistered(address indexed owner, address token, address spender);
    event SpendPermissionRegistered(address indexed owner, bytes32 indexed hashKey);
    event SpendPermissionUnregistered(address indexed owner, bytes32 indexed hashKey);
    event SafeModuleRegistered(address indexed owner, address module);
    event SafeModuleUnregistered(address indexed owner, address module);
    /// @notice A single revoke inside a panic failed and was skipped (best-effort panic).
    ///         kind: 0 = ERC-20 approve, 1 = Permit2 lockdown, 2 = SpendPermission revoke,
    ///         3 = Safe module disable.
    event RevokeFailed(address indexed account, uint8 indexed kind, address target, uint256 index);
    event PanicExecuted(
        address indexed account, uint256 erc20Count, uint256 permit2Count, uint256 spendCount, uint256 moduleCount
    );

    error NotAccountContext();
    error ZeroAddress();
    error MaxTargets();
    error AlreadyRegistered();
    error UnknownTarget();
    error SpendAccountMismatch();
    error NotSafeModule();
    error ModuleCallFailed(address to);
    error Reentrancy();
    error NotAuthorized();

    modifier nonReentrant() {
        bytes32 slot = _LOCK_SLOT;
        uint256 locked;
        assembly {
            locked := tload(slot)
        }
        if (locked != 0) revert Reentrancy();
        assembly {
            tstore(slot, 1)
        }
        _;
        assembly {
            tstore(slot, 0)
        }
    }

    constructor() {
        registry = address(this);
    }

    // ─── registry (msg.sender's list) ─────────────────────────────────────────

    function registerErc20(address token, address spender) external {
        if (token == address(0) || spender == address(0)) revert ZeroAddress();
        bytes32 key = _pairKey(token, spender);
        if (_erc20Index[msg.sender][key] != 0) revert AlreadyRegistered();
        if (_erc20[msg.sender].length >= MAX_TARGETS) revert MaxTargets();
        _erc20[msg.sender].push(TokenSpender(token, spender));
        _erc20Index[msg.sender][key] = _erc20[msg.sender].length;
        emit Erc20Registered(msg.sender, token, spender);
    }

    function unregisterErc20(address token, address spender) external {
        _unregisterPair(_erc20[msg.sender], _erc20Index[msg.sender], token, spender);
        emit Erc20Unregistered(msg.sender, token, spender);
    }

    function registerPermit2(address token, address spender) external {
        if (token == address(0) || spender == address(0)) revert ZeroAddress();
        bytes32 key = _pairKey(token, spender);
        if (_permit2Index[msg.sender][key] != 0) revert AlreadyRegistered();
        if (_permit2[msg.sender].length >= MAX_TARGETS) revert MaxTargets();
        _permit2[msg.sender].push(TokenSpender(token, spender));
        _permit2Index[msg.sender][key] = _permit2[msg.sender].length;
        emit Permit2Registered(msg.sender, token, spender);
    }

    function unregisterPermit2(address token, address spender) external {
        _unregisterPair(_permit2[msg.sender], _permit2Index[msg.sender], token, spender);
        emit Permit2Unregistered(msg.sender, token, spender);
    }

    function registerSpendPermission(ISpendPermissionManager.SpendPermission calldata perm) external {
        if (perm.account != msg.sender) revert SpendAccountMismatch();
        if (perm.spender == address(0)) revert ZeroAddress();
        bytes32 key = _spendKey(perm);
        if (_spendIndex[msg.sender][key] != 0) revert AlreadyRegistered();
        if (_spend[msg.sender].length >= MAX_TARGETS) revert MaxTargets();
        _spend[msg.sender].push(perm);
        _spendIndex[msg.sender][key] = _spend[msg.sender].length;
        emit SpendPermissionRegistered(msg.sender, key);
    }

    function unregisterSpendPermission(ISpendPermissionManager.SpendPermission calldata perm) external {
        bytes32 key = _spendKey(perm);
        uint256 i = _spendIndex[msg.sender][key];
        if (i == 0) revert UnknownTarget();
        uint256 last = _spend[msg.sender].length;
        if (i != last) {
            ISpendPermissionManager.SpendPermission storage moved = _spend[msg.sender][last - 1];
            _spend[msg.sender][i - 1] = moved;
            _spendIndex[msg.sender][_spendKeyMem(moved)] = i;
        }
        _spend[msg.sender].pop();
        delete _spendIndex[msg.sender][key];
        emit SpendPermissionUnregistered(msg.sender, key);
    }

    function registerSafeModule(address module) external {
        if (module == address(0) || module == SENTINEL_MODULE) revert ZeroAddress();
        if (_moduleIndex[msg.sender][module] != 0) revert AlreadyRegistered();
        if (_modules[msg.sender].length >= MAX_TARGETS) revert MaxTargets();
        _modules[msg.sender].push(module);
        _moduleIndex[msg.sender][module] = _modules[msg.sender].length;
        emit SafeModuleRegistered(msg.sender, module);
    }

    function unregisterSafeModule(address module) external {
        uint256 i = _moduleIndex[msg.sender][module];
        if (i == 0) revert UnknownTarget();
        uint256 last = _modules[msg.sender].length;
        if (i != last) {
            address moved = _modules[msg.sender][last - 1];
            _modules[msg.sender][i - 1] = moved;
            _moduleIndex[msg.sender][moved] = i;
        }
        _modules[msg.sender].pop();
        delete _moduleIndex[msg.sender][module];
        emit SafeModuleUnregistered(msg.sender, module);
    }

    // ─── views ────────────────────────────────────────────────────────────────

    function erc20Targets(address owner) external view returns (TokenSpender[] memory) {
        return _erc20[owner];
    }

    function permit2Targets(address owner) external view returns (TokenSpender[] memory) {
        return _permit2[owner];
    }

    function spendPermissionTargets(address owner)
        external
        view
        returns (ISpendPermissionManager.SpendPermission[] memory)
    {
        return _spend[owner];
    }

    function safeModuleTargets(address owner) external view returns (address[] memory) {
        return _modules[owner];
    }

    function getTargets(address owner) public view returns (Targets memory t) {
        t.erc20 = _erc20[owner];
        t.permit2 = _permit2[owner];
        t.spendPermissions = _spend[owner];
        t.safeModules = _modules[owner];
    }

    /// @notice Encodes the owner-signed calls the dapp should send (sequentially,
    ///         via EIP-7702 + `panic()`, or as a Safe MultiSend). Does not include
    ///         EIP-7702 type-4 revocation — that cannot be done from a contract.
    function encodeRevokeCalls(address owner) external view returns (Call[] memory calls) {
        TokenSpender[] memory e = _erc20[owner];
        TokenSpender[] memory p = _permit2[owner];
        ISpendPermissionManager.SpendPermission[] memory s = _spend[owner];
        address[] memory m = _modules[owner];

        uint256 n = e.length + (p.length == 0 ? 0 : 1) + s.length + m.length;
        calls = new Call[](n);
        uint256 k = 0;
        for (uint256 i; i < e.length; i++) {
            calls[k++] = Call(
                e[i].token, abi.encodeWithSelector(IERC20.approve.selector, e[i].spender, uint256(0))
            );
        }
        if (p.length != 0) {
            IPermit2.TokenSpenderPair[] memory pairs = new IPermit2.TokenSpenderPair[](p.length);
            for (uint256 i; i < p.length; i++) {
                pairs[i] = IPermit2.TokenSpenderPair({token: p[i].token, spender: p[i].spender});
            }
            calls[k++] = Call(PERMIT2, abi.encodeWithSelector(IPermit2.lockdown.selector, pairs));
        }
        for (uint256 i; i < s.length; i++) {
            calls[k++] =
                Call(SPEND_PERMISSION_MANAGER, abi.encodeCall(ISpendPermissionManager.revoke, (s[i])));
        }
        for (uint256 i; i < m.length; i++) {
            // prev is filled at execution time; this is a hint for the dapp
            calls[k++] = Call(
                owner, abi.encodeWithSelector(ISafe.disableModule.selector, SENTINEL_MODULE, m[i])
            );
        }
    }

    // ─── panic (must run as the owner account) ────────────────────────────────

    /// @notice Clears every registered target for `address(this)`.
    ///         Invoke by designating this contract via EIP-7702 and calling the EOA,
    ///         or by delegatecall from the owner account. Calling the registry
    ///         directly reverts — it would try to revoke the registry's own approvals.
    function panic() external nonReentrant {
        address account = address(this);
        if (account == registry) revert NotAccountContext();
        Targets memory t = PanicRevoke(registry).getTargets(account);
        _executeAsAccount(account, t);
    }

    /// @notice Same as `panic()` but uses caller-supplied targets (no registry read).
    ///         On an EIP-7702 EOA only the EOA itself (self-call) may use it.
    function panicWith(
        TokenSpender[] calldata erc20,
        TokenSpender[] calldata permit2Pairs,
        ISpendPermissionManager.SpendPermission[] calldata spendPerms
    ) external nonReentrant {
        address account = address(this);
        if (account == registry) revert NotAccountContext();
        // Caller-supplied targets: on an EIP-7702 EOA anyone can call this code, so only
        // the EOA itself may pass arbitrary targets. Under delegatecall the calling account
        // contract already authorised the call.
        if (_is7702Delegated(account) && msg.sender != account) revert NotAuthorized();
        Targets memory t;
        t.erc20 = erc20;
        t.permit2 = permit2Pairs;
        t.spendPermissions = spendPerms;
        _executeAsAccount(account, t);
    }

    /// @notice If this contract is an enabled module of `safe`, execute the Safe's
    ///         registered revokes through `execTransactionFromModule`. Anyone may
    ///         trigger it: the Safe opted in by enabling the module and registering.
    function panicAsModule(address safe) external nonReentrant {
        if (safe == address(0)) revert ZeroAddress();
        if (address(this) != registry) revert NotAccountContext();
        if (!ISafe(safe).isModuleEnabled(address(this))) revert NotSafeModule();
        Targets memory t = getTargets(safe);
        _executeAsModule(safe, t);
    }

    // ─── internals ────────────────────────────────────────────────────────────

    function _executeAsAccount(address account, Targets memory t) internal {
        uint256 i;
        for (i = 0; i < t.erc20.length; i++) {
            if (!_approveZero(t.erc20[i].token, t.erc20[i].spender)) {
                emit RevokeFailed(account, 0, t.erc20[i].token, i);
            }
        }
        if (t.permit2.length != 0) {
            IPermit2.TokenSpenderPair[] memory pairs = new IPermit2.TokenSpenderPair[](t.permit2.length);
            for (i = 0; i < t.permit2.length; i++) {
                pairs[i] = IPermit2.TokenSpenderPair({token: t.permit2[i].token, spender: t.permit2[i].spender});
            }
            try IPermit2(PERMIT2).lockdown(pairs) {}
            catch {
                emit RevokeFailed(account, 1, PERMIT2, 0);
            }
        }
        for (i = 0; i < t.spendPermissions.length; i++) {
            if (t.spendPermissions[i].account != account) revert SpendAccountMismatch();
            try ISpendPermissionManager(SPEND_PERMISSION_MANAGER).revoke(t.spendPermissions[i]) {}
            catch {
                emit RevokeFailed(account, 2, SPEND_PERMISSION_MANAGER, i);
            }
        }
        emit PanicExecuted(account, t.erc20.length, t.permit2.length, t.spendPermissions.length, 0);
    }

    function _executeAsModule(address safe, Targets memory t) internal {
        uint256 i;
        for (i = 0; i < t.erc20.length; i++) {
            if (
                !_moduleCall(
                    safe,
                    t.erc20[i].token,
                    abi.encodeWithSelector(IERC20.approve.selector, t.erc20[i].spender, uint256(0))
                )
            ) emit RevokeFailed(safe, 0, t.erc20[i].token, i);
        }
        if (t.permit2.length != 0) {
            IPermit2.TokenSpenderPair[] memory pairs = new IPermit2.TokenSpenderPair[](t.permit2.length);
            for (i = 0; i < t.permit2.length; i++) {
                pairs[i] = IPermit2.TokenSpenderPair({token: t.permit2[i].token, spender: t.permit2[i].spender});
            }
            if (!_moduleCall(safe, PERMIT2, abi.encodeWithSelector(IPermit2.lockdown.selector, pairs))) {
                emit RevokeFailed(safe, 1, PERMIT2, 0);
            }
        }
        for (i = 0; i < t.spendPermissions.length; i++) {
            if (t.spendPermissions[i].account != safe) revert SpendAccountMismatch();
            if (
                !_moduleCall(
                    safe,
                    SPEND_PERMISSION_MANAGER,
                    abi.encodeCall(ISpendPermissionManager.revoke, (t.spendPermissions[i]))
                )
            ) emit RevokeFailed(safe, 2, SPEND_PERMISSION_MANAGER, i);
        }
        for (i = 0; i < t.safeModules.length; i++) {
            address module = t.safeModules[i];
            if (module == address(this)) continue; // stay enabled until the Safe opts out
            (bool found, address prev) = _prevModule(safe, module);
            if (!found || !_moduleCall(safe, safe, abi.encodeWithSelector(ISafe.disableModule.selector, prev, module)))
            {
                emit RevokeFailed(safe, 3, module, i);
            }
        }
        emit PanicExecuted(safe, t.erc20.length, t.permit2.length, t.spendPermissions.length, t.safeModules.length);
    }

    function _moduleCall(address safe, address to, bytes memory data) internal returns (bool ok) {
        try ISafe(safe).execTransactionFromModule(to, 0, data, SAFE_CALL) returns (bool success) {
            ok = success;
        } catch {
            ok = false;
        }
    }

    /// @dev ERC-20 `approve(spender, 0)` that accepts tokens returning nothing (USDT) and
    ///      reports failure instead of reverting.
    function _approveZero(address token, address spender) internal returns (bool) {
        if (token.code.length == 0) return false;
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, uint256(0)));
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
    }

    /// @dev True when `account` is an EOA whose code is an EIP-7702 delegation designator.
    function _is7702Delegated(address account) internal view returns (bool) {
        if (account.code.length != 23) return false;
        bytes memory c = account.code;
        return c[0] == 0xef && c[1] == 0x01 && c[2] == 0x00;
    }

    function _prevModule(address safe, address module) internal view returns (bool found, address prev) {
        address start = SENTINEL_MODULE;
        while (true) {
            (address[] memory page, address next) = ISafe(safe).getModulesPaginated(start, 64);
            prev = start;
            for (uint256 i; i < page.length; i++) {
                if (page[i] == module) return (true, prev);
                prev = page[i];
            }
            if (next == address(0) || next == SENTINEL_MODULE || page.length == 0) break;
            start = next;
        }
        return (false, address(0));
    }

    function _unregisterPair(
        TokenSpender[] storage list,
        mapping(bytes32 => uint256) storage index,
        address token,
        address spender
    ) internal {
        bytes32 key = _pairKey(token, spender);
        uint256 i = index[key];
        if (i == 0) revert UnknownTarget();
        uint256 last = list.length;
        if (i != last) {
            TokenSpender storage moved = list[last - 1];
            list[i - 1] = moved;
            index[_pairKey(moved.token, moved.spender)] = i;
        }
        list.pop();
        delete index[key];
    }

    function _pairKey(address token, address spender) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(token, spender));
    }

    function _spendKey(ISpendPermissionManager.SpendPermission calldata p) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(p.account, p.spender, p.token, p.allowance, p.period, p.start, p.end, p.salt, keccak256(p.extraData))
        );
    }

    function _spendKeyMem(ISpendPermissionManager.SpendPermission memory p) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(p.account, p.spender, p.token, p.allowance, p.period, p.start, p.end, p.salt, keccak256(p.extraData))
        );
    }
}
