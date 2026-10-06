// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ALL_HOOK_FLAGS, FEE_HOOK_FLAGS, FeeHook} from "./FeeHook.sol";
import {IFeeWaterfall} from "./interfaces/IIndex.sol";

/// @title FeeHookDeployer
/// @notice Deploys the FeeHook at an address that carries the Uniswap v4 permission bits.
/// @dev A v4 hook's permissions are read from the low bits of its address, so it has to be created
/// with a mined CREATE2 salt. This contract fixes the hook's constructor arguments at launch and lets
/// anyone supply the salt afterwards: the salt only chooses the address, nothing else, and a salt that
/// yields the wrong bits reverts. There is one hook per deployer and no privileged caller.
contract FeeHookDeployer {
    address public immutable poolManager;
    address public immutable projectToken;
    address public immutable quoteCurrency;
    address public immutable waterfall;

    /// @notice The deployed hook; zero until `deploy` succeeds.
    address public hook;

    event HookDeployed(address indexed hook, bytes32 salt);

    error ZeroAddress();
    error IncompatibleQuote();
    error AlreadyDeployed();

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
    }

    /// @notice Deploys the hook with `salt`. Reverts unless the resulting address has exactly the
    /// required permission bits.
    function deploy(bytes32 salt) external returns (address deployed) {
        if (hook != address(0)) revert AlreadyDeployed();
        deployed = address(new FeeHook{salt: salt}(poolManager, projectToken, quoteCurrency, waterfall));
        hook = deployed;
        emit HookDeployed(deployed, salt);
    }

    /// @notice The address `deploy(salt)` would create.
    function computeAddress(bytes32 salt) public view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash())))));
    }

    function initCodeHash() public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                type(FeeHook).creationCode, abi.encode(poolManager, projectToken, quoteCurrency, waterfall)
            )
        );
    }

    /// @notice Searches `iterations` salts from `start` for one that yields a valid hook address.
    /// Meant for `eth_call`; about one salt in 16,384 qualifies.
    function findSalt(uint256 start, uint256 iterations) external view returns (bytes32 salt, bool found) {
        bytes32 codeHash = initCodeHash();
        for (uint256 i = start; i < start + iterations; ++i) {
            address candidate = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), codeHash))))
            );
            if (uint160(candidate) & ALL_HOOK_FLAGS == FEE_HOOK_FLAGS) return (bytes32(i), true);
        }
    }

    /// @notice The pool key to initialise and trade the hooked pool with, once the hook exists.
    function poolKey() external view returns (PoolKey memory) {
        return FeeHook(hook).poolKey();
    }
}
