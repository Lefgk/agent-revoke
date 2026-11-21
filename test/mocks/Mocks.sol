// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {ISpendPermissionManager} from "../../src/interfaces/ISpendPermissionManager.sol";
import {ISafe} from "../../src/interfaces/ISafe.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Runtime-compatible Permit2 mock; etched at the canonical Permit2 address in tests.
contract MockPermit2 {
    mapping(address => mapping(address => mapping(address => uint160))) public amounts;
    mapping(address => mapping(address => mapping(address => uint48))) public expirations;
    mapping(address => mapping(address => mapping(address => uint48))) public nonces;

    event Approval(address indexed owner, address indexed token, address indexed spender, uint160 amount, uint48 expiration);
    event Lockdown(address indexed owner, address token, address spender);

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        amounts[msg.sender][token][spender] = amount;
        expirations[msg.sender][token][spender] = expiration;
        emit Approval(msg.sender, token, spender, amount, expiration);
    }

    function lockdown(IPermit2.TokenSpenderPair[] calldata approvals) external {
        for (uint256 i; i < approvals.length; i++) {
            address token = approvals[i].token;
            address spender = approvals[i].spender;
            amounts[msg.sender][token][spender] = 0;
            expirations[msg.sender][token][spender] = 0;
            emit Lockdown(msg.sender, token, spender);
        }
    }

    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce)
    {
        return (amounts[owner][token][spender], expirations[owner][token][spender], nonces[owner][token][spender]);
    }
}

contract MockSpendPermissionManager {
    mapping(bytes32 => bool) public approved;
    mapping(bytes32 => bool) public revoked;

    event SpendPermissionApproved(bytes32 indexed hash, ISpendPermissionManager.SpendPermission spendPermission);
    event SpendPermissionRevoked(bytes32 indexed hash, ISpendPermissionManager.SpendPermission spendPermission);

    error Unauthorized();

    function approve(ISpendPermissionManager.SpendPermission calldata p) external returns (bool) {
        if (msg.sender != p.account) revert Unauthorized();
        bytes32 h = getHash(p);
        approved[h] = true;
        revoked[h] = false;
        emit SpendPermissionApproved(h, p);
        return true;
    }

    function revoke(ISpendPermissionManager.SpendPermission calldata p) external {
        if (msg.sender != p.account) revert Unauthorized();
        bytes32 h = getHash(p);
        revoked[h] = true;
        emit SpendPermissionRevoked(h, p);
    }

    function revokeAsSpender(ISpendPermissionManager.SpendPermission calldata p) external {
        if (msg.sender != p.spender) revert Unauthorized();
        bytes32 h = getHash(p);
        revoked[h] = true;
        emit SpendPermissionRevoked(h, p);
    }

    function isApproved(ISpendPermissionManager.SpendPermission memory p) external view returns (bool) {
        return approved[getHash(p)];
    }

    function isRevoked(ISpendPermissionManager.SpendPermission memory p) external view returns (bool) {
        return revoked[getHash(p)];
    }

    function isValid(ISpendPermissionManager.SpendPermission memory p) external view returns (bool) {
        bytes32 h = getHash(p);
        return approved[h] && !revoked[h] && block.timestamp >= p.start && block.timestamp < p.end;
    }

    function getHash(ISpendPermissionManager.SpendPermission memory p) public pure returns (bytes32) {
        return keccak256(
            abi.encode(p.account, p.spender, p.token, p.allowance, p.period, p.start, p.end, p.salt, keccak256(p.extraData))
        );
    }
}

/// @dev Minimal Safe mock that can enable a module and execute through it.
contract MockSafe {
    address internal constant SENTINEL = address(0x1);
    mapping(address => address) public modules; // linked list: SENTINEL -> m1 -> m2 -> SENTINEL
    address public moduleHead = SENTINEL;
    uint256 public moduleCount;

    event ExecutionFromModule(address indexed module, address to, bool success);

    function enableModule(address module) external {
        require(module != address(0) && module != SENTINEL, "bad module");
        require(modules[module] == address(0), "already");
        modules[module] = modules[SENTINEL] == address(0) ? SENTINEL : modules[SENTINEL];
        if (modules[SENTINEL] == address(0) || moduleHead == SENTINEL) {
            modules[SENTINEL] = module;
            modules[module] = SENTINEL;
            moduleHead = module;
        } else {
            modules[module] = modules[SENTINEL];
            modules[SENTINEL] = module;
        }
        moduleCount++;
    }

    function isModuleEnabled(address module) external view returns (bool) {
        return module != SENTINEL && modules[module] != address(0);
    }

    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next)
    {
        array = new address[](pageSize);
        uint256 i;
        address cur = modules[start];
        if (start == SENTINEL && cur == address(0)) {
            address[] memory empty;
            return (empty, SENTINEL);
        }
        while (cur != address(0) && cur != SENTINEL && i < pageSize) {
            array[i++] = cur;
            cur = modules[cur];
        }
        assembly {
            mstore(array, i)
        }
        next = cur == address(0) ? SENTINEL : cur;
    }

    function execTransactionFromModule(address to, uint256 value, bytes memory data, uint8)
        external
        returns (bool success)
    {
        require(modules[msg.sender] != address(0), "not module");
        (success,) = to.call{value: value}(data);
        emit ExecutionFromModule(msg.sender, to, success);
    }

    function disableModule(address prevModule, address module) external {
        require(msg.sender == address(this), "only self");
        require(modules[prevModule] == module, "bad prev");
        modules[prevModule] = modules[module];
        modules[module] = address(0);
        if (moduleCount > 0) moduleCount--;
    }

    /// @notice Helper so tests can have the Safe call an external function as itself.
    function exec(address to, bytes memory data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call(data);
        require(ok, string(ret));
        return ret;
    }
}

/// @dev Owner account that can delegatecall PanicRevoke.panic / panicWith.
contract OwnerAccount {
    function run(address target, bytes memory data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    /// @notice Lets the account make an ordinary call (register, approve, etc.).
    function call(address to, bytes memory data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}
