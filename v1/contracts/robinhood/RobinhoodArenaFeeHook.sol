// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

import {IArenaFeeHelperMinimal} from "./interfaces/IArenaFeeHelperMinimal.sol";
import {RobinhoodBaseHookFee} from "./libraries/RobinhoodBaseHookFee.sol";

/// @dev Robinhood Chain post-bond fee hook.
import {RobinhoodCurrencySettler} from "./libraries/RobinhoodCurrencySettler.sol";

/// @notice Robinhood source-shaped port of Arena's verified ArenaHook.
contract RobinhoodArenaFeeHook is
    RobinhoodBaseHookFee,
    Ownable2Step,
    ReentrancyGuard
{
    using PoolIdLibrary for PoolKey;
    using RobinhoodCurrencySettler for Currency;

    IArenaFeeHelperMinimal public arenaFeeHelper;
    mapping(address => bool) public isDeployer;

    constructor(
        address owner_,
        address arenaFeeHelper_,
        IPoolManager poolManager_
    ) Ownable(owner_) BaseHook(poolManager_) {
        arenaFeeHelper = IArenaFeeHelperMinimal(arenaFeeHelper_);
    }

    function setArenaFeeHelper(address arenaFeeHelper_) public onlyOwner {
        arenaFeeHelper = IArenaFeeHelperMinimal(arenaFeeHelper_);
    }

    function setDeployer(address deployer, bool authorized) public onlyOwner {
        isDeployer[deployer] = authorized;
    }

    function _getHookFee(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal view override returns (uint24 fee) {
        return uint24(arenaFeeHelper.getTotalFeePpm(key.toId()));
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override nonReentrant returns (bytes4 selector, int128 feeAmount) {
        (Currency unspecified, int128 unspecifiedAmount) =
            (params.amountSpecified < 0 == params.zeroForOne)
                ? (key.currency1, delta.amount1())
                : (key.currency0, delta.amount0());
        if (unspecifiedAmount == 0) return (this.afterSwap.selector, 0);
        if (unspecifiedAmount < 0) unspecifiedAmount = -unspecifiedAmount;

        (selector, feeAmount) =
            super._afterSwap(sender, key, params, delta, hookData);
        _takeFees(
            unspecified,
            uint256(uint128(unspecifiedAmount)),
            uint256(uint128(feeAmount)),
            key.toId()
        );
        return (selector, feeAmount);
    }

    function _takeFees(
        Currency output,
        uint256 amountOut,
        uint256 projectedFeeAmount,
        PoolId poolId
    ) internal {
        uint256 totalFee;
        IArenaFeeHelperMinimal.Fee[] memory fees =
            arenaFeeHelper.getFeesForPool(poolId);
        output.settle(poolManager, address(this), projectedFeeAmount, true);

        for (uint256 i; i < fees.length; ++i) {
            uint256 feeToTake =
                (amountOut * fees[i].feePpm) / MAX_HOOK_FEE;
            totalFee += feeToTake;
            if (i == fees.length - 1 && totalFee < projectedFeeAmount) {
                feeToTake += projectedFeeAmount - totalFee;
            }
            output.take(poolManager, fees[i].recipient, feeToTake, false);
        }
    }

    function handleHookFees(Currency[] memory) public pure override {
        revert("Not implemented");
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory permissions)
    {
        permissions.beforeInitialize = true;
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    function _beforeInitialize(address sender, PoolKey calldata, uint160)
        internal
        override
        returns (bytes4)
    {
        require(isDeployer[sender], "Only deployer can call this function");
        return IHooks.beforeInitialize.selector;
    }
}
