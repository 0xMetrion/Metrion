// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MetrionDirectAgentFeeHook} from "./MetrionDirectAgentFeeHook.sol";

/// @notice Deploys owner-authorized fee hooks. No JobBoard or stake dependency.
/// @dev No admin or upgrade path. Integrators verify the factory's fixed PoolManager.
contract MetrionDirectAgentFeeHookFactory {
    struct HookParams {
        Currency currency0;
        Currency currency1;
        int24 tickSpacing;
        address operator;
        MetrionDirectAgentFeeHook.Policy policy;
    }

    IPoolManager public immutable poolManager;
    mapping(address => bool) public isHook;

    event HookDeployed(address indexed hook, address indexed owner, bytes32 salt);
    error BadDependencies();

    constructor(IPoolManager poolManager_) {
        if (address(poolManager_).code.length == 0) revert BadDependencies();
        poolManager = poolManager_;
    }

    function deploy(bytes32 salt, HookParams calldata p) external returns (MetrionDirectAgentFeeHook hook) {
        hook = new MetrionDirectAgentFeeHook{salt: keccak256(abi.encode(msg.sender, salt))}(
            poolManager, msg.sender, p.operator, p.currency0, p.currency1, p.tickSpacing, p.policy
        );
        isHook[address(hook)] = true;
        emit HookDeployed(address(hook), msg.sender, salt);
    }

    function initCodeHash(address owner, HookParams calldata p) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                type(MetrionDirectAgentFeeHook).creationCode,
                abi.encode(poolManager, owner, p.operator, p.currency0, p.currency1, p.tickSpacing, p.policy)
            )
        );
    }

    function predict(address owner, bytes32 salt, HookParams calldata p) external view returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(this), keccak256(abi.encode(owner, salt)), initCodeHash(owner, p)
                        )
                    )
                )
            )
        );
    }
}
