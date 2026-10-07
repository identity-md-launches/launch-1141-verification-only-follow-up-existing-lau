// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {ALL_HOOK_FLAGS, FEE_HOOK_FLAGS, FeeHook} from "./FeeHook.sol";
import {IFeeWaterfall} from "./interfaces/IIndex.sol";

/// @title FeeHookDeployer
/// @notice Deploys the FeeHook at an address that carries the Uniswap v4 permission bits.
/// @dev A v4 hook's permissions are read from the low bits of its address, so it has to be created
/// with a mined CREATE2 salt. This contract fixes the hook's constructor arguments at launch and lets
/// anyone supply the salt and hash-checked creation code afterwards. Only the compiled FeeHook is
/// accepted, with this deployer's fixed arguments. Keeping its code out of this contract's runtime
/// saves launch gas. There is one hook per deployer and no privileged caller.
contract FeeHookDeployer {
    address public immutable poolManager;
    address public immutable projectToken;
    address public immutable quoteCurrency;
    address public immutable waterfall;
    bytes32 public immutable creationCodeHash;
    bytes32 private immutable _initCodeHash;

    /// @notice The deployed hook; zero until `deploy` succeeds.
    address public hook;

    event HookDeployed(address indexed hook, bytes32 salt);

    error ZeroAddress();
    error IncompatibleQuote();
    error AlreadyDeployed();
    error InvalidCreationCode();
    error HookDeploymentFailed();
    error HookNotDeployed();

    /// @param quoteCurrency_ The pool's other currency: zero for native ETH, otherwise an ERC-20. It
    /// must be what the waterfall can account for: its reserve asset, or native ETH when the reserve
    /// asset is the wrapped native token.
    constructor(address poolManager_, address projectToken_, address quoteCurrency_, address waterfall_) {
        if (poolManager_ == address(0) || projectToken_ == address(0) || waterfall_ == address(0)) {
            revert ZeroAddress();
        }
        address reserve = IFeeWaterfall(waterfall_).reserveAsset();
        bool native = quoteCurrency_ == address(0);
        if (native ? IFeeWaterfall(waterfall_).weth() != reserve : quoteCurrency_ != reserve) {
            revert IncompatibleQuote();
        }
        if (projectToken_ == quoteCurrency_) revert IncompatibleQuote();
        poolManager = poolManager_;
        projectToken = projectToken_;
        quoteCurrency = quoteCurrency_;
        waterfall = waterfall_;
        bytes memory creationCode = type(FeeHook).creationCode;
        creationCodeHash = keccak256(creationCode);
        _initCodeHash =
            keccak256(bytes.concat(creationCode, abi.encode(poolManager_, projectToken_, quoteCurrency_, waterfall_)));
    }

    /// @notice Deploys the hook with `salt`. Reverts unless the resulting address has exactly the
    /// required permission bits. `creationCode` must be the exact FeeHook creation bytecode from the
    /// launch build, without constructor arguments; the deployer appends its immutable arguments.
    function deploy(bytes32 salt, bytes calldata creationCode) external returns (address deployed) {
        if (hook != address(0)) revert AlreadyDeployed();
        if (keccak256(creationCode) != creationCodeHash) revert InvalidCreationCode();
        bytes memory initCode =
            bytes.concat(creationCode, abi.encode(poolManager, projectToken, quoteCurrency, waterfall));
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        if (deployed == address(0)) revert HookDeploymentFailed();
        hook = deployed;
        emit HookDeployed(deployed, salt);
    }

    /// @notice The address `deploy(salt, creationCode)` creates with the authenticated code.
    function computeAddress(bytes32 salt) public view returns (address) {
        return _computeAddress(salt, _initCodeHash);
    }

    function initCodeHash() public view returns (bytes32) {
        return _initCodeHash;
    }

    /// @notice Searches `iterations` salts from `start` for one that yields a valid hook address.
    /// Meant for `eth_call`; about one salt in 16,384 qualifies.
    function findSalt(uint256 start, uint256 iterations) external view returns (bytes32 salt, bool found) {
        bytes32 codeHash = initCodeHash();
        for (uint256 i = start; i < start + iterations; ++i) {
            address candidate = _computeAddress(bytes32(i), codeHash);
            if (uint160(candidate) & ALL_HOOK_FLAGS == FEE_HOOK_FLAGS) return (bytes32(i), true);
        }
    }

    /// @notice The pool key to initialise and trade the hooked pool with, once the hook exists.
    function poolKey() external view returns (PoolKey memory) {
        if (hook == address(0)) revert HookNotDeployed();
        (address currency0, address currency1) =
            quoteCurrency < projectToken ? (quoteCurrency, projectToken) : (projectToken, quoteCurrency);
        return
            PoolKey(Currency.wrap(currency0), Currency.wrap(currency1), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
    }

    function _computeAddress(bytes32 salt, bytes32 codeHash) private view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash)))));
    }
}
