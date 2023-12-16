// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {HookTest} from "./utils/HookTest.sol";
import {LiquidityPositionManager} from "../src/LiquidityPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {Position, PositionId, PositionIdLibrary} from "../src/types/PositionId.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {Position as PoolPosition} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {LiquidityHelpers} from "../src/lens/LiquidityHelpers.sol";
import { BorrowHook } from "../../src/hook/BorrowHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IGhoToken} from '@aave/gho/gho/interfaces/IGhoToken.sol';


contract TokenFlowsTest is HookTest, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using PositionIdLibrary for Position;

    LiquidityPositionManager lpm;
    LiquidityHelpers helper;

    BorrowHook internal deployedHooks;

    PoolKey poolKey;
    PoolId poolId;

    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    function setUp() public {
        HookTest.initHookTestEnv();
        address owner = makeAddr("owner");

        uint160 flags = uint160(
           Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_MODIFY_POSITION_FLAG
                | Hooks.AFTER_MODIFY_POSITION_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG
        );
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(BorrowHook).creationCode, abi.encode(address(owner), address(manager)));
        deployedHooks = new BorrowHook{salt: salt}(address(owner),IPoolManager(address(manager)));
        require(address(deployedHooks) == hookAddress, "CounterTest: hook address mismatch");

        

        // Create the pool
        poolKey =
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, IHooks(address(deployedHooks)));
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_RATIO_1_1, ZERO_BYTES);

        lpm = new LiquidityPositionManager(IPoolManager(address(manager)), owner, poolKey);
        helper = new LiquidityHelpers(IPoolManager(address(manager)), lpm);

        token0.approve(address(lpm), type(uint256).max);
        token1.approve(address(lpm), type(uint256).max);

        AddFacilitator(address(deployedHooks));


        _mintTokens(1000000e18);
        _mintTo(alice, 1000000000000000000000e18);
        _mintTo(bob, 1000000000000000000000e18);

        vm.startPrank(alice);
        token0.approve(address(lpm), type(uint256).max);
        token1.approve(address(lpm), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        token0.approve(address(lpm), type(uint256).max);
        token1.approve(address(lpm), type(uint256).max);
        vm.stopPrank();
    }

    // alice closes her position, she gets her tokens back
    function test_removeTokenRecipient() public {
        uint256 token0BalanceBefore = token0.balanceOf(address(alice));
        uint256 token1BalanceBefore = token1.balanceOf(address(alice));

        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;

        // alice adds liquidity
        vm.prank(alice);
        addLiquidity(alice, poolKey, tickLower, tickUpper, liquidity);

        assertLt(token0.balanceOf(address(alice)), token0BalanceBefore);
        assertLt(token1.balanceOf(address(alice)), token1BalanceBefore);
        assertEq(
            lpm.balanceOf(
                address(alice), Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper}).toTokenId()
            ),
            liquidity
        );

        // alice removes liquidity
        vm.prank(alice);
        removeLiquidity(alice, poolKey, tickLower, tickUpper, liquidity);

        // alice gets her tokens back
        assertApproxEqAbs(token0.balanceOf(address(alice)), token0BalanceBefore, 3 wei);
        assertApproxEqAbs(token1.balanceOf(address(alice)), token1BalanceBefore, 3 wei);
        assertEq(
            lpm.balanceOf(
                address(alice), Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper}).toTokenId()
            ),
            0
        );
    }

    // bob closes alice position, alice gets the tokens
    function test_operatorRemoveTokenRecipient() public {
        uint256 token0BalanceBefore = token0.balanceOf(address(alice));
        uint256 token1BalanceBefore = token1.balanceOf(address(alice));

        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;

        // alice adds liquidity
        vm.startPrank(alice);
        addLiquidity(alice, poolKey, tickLower, tickUpper, liquidity);
        lpm.setOperator(bob, true);
        vm.stopPrank();

        assertLt(token0.balanceOf(address(alice)), token0BalanceBefore);
        assertLt(token1.balanceOf(address(alice)), token1BalanceBefore);
        assertEq(
            lpm.balanceOf(
                address(alice), Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper}).toTokenId()
            ),
            liquidity
        );

        // bob removes liquidity
        vm.prank(bob);
        removeLiquidity(alice, poolKey, tickLower, tickUpper, liquidity);

        // alice gets her tokens back
        assertApproxEqAbs(token0.balanceOf(address(alice)), token0BalanceBefore, 3 wei);
        assertApproxEqAbs(token1.balanceOf(address(alice)), token1BalanceBefore, 3 wei);
        assertEq(
            lpm.balanceOf(
                address(alice), Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper}).toTokenId()
            ),
            0
        );
    }

    // alice rebalances her position, excess tokens are received as 1155
    function test_rebalanceTokenRecipient() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;

        // alice adds liquidity
        vm.prank(alice);
        addLiquidity(alice, poolKey, tickLower, tickUpper, liquidity);
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(address(alice), position.toTokenId()), liquidity);

        uint256 token0BalanceBefore = token0.balanceOf(address(alice));
        uint256 token1BalanceBefore = token1.balanceOf(address(alice));

        // alice rebalances liquidity
        int24 newTickLower = -1200;
        int24 newTickUpper = 1200;
        int256 liquidityAdjustment = -int256(liquidity / 2);
        uint128 newLiquidity = helper.getNewLiquidity(position, liquidityAdjustment, newTickLower, newTickUpper);
        vm.prank(alice);
        lpm.rebalancePosition(
            alice,
            position,
            liquidityAdjustment, // partially unwind
            IPoolManager.ModifyPositionParams({
                tickLower: newTickLower,
                tickUpper: newTickUpper,
                liquidityDelta: int256(uint256(newLiquidity) / 2)
            }),
            ZERO_BYTES,
            ZERO_BYTES
        );

        // alice gets excess tokens back
        assertGt(token0.balanceOf(address(alice)), token0BalanceBefore);
        assertGt(token1.balanceOf(address(alice)), token1BalanceBefore);
    }

    // bob rebalances alice position, alice gets the excess tokens
    function test_operatorRebalanceTokenRecipient() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;

        // alice adds liquidity
        vm.startPrank(alice);
        addLiquidity(alice, poolKey, tickLower, tickUpper, liquidity);
        lpm.setOperator(bob, true);
        vm.stopPrank();
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(address(alice), position.toTokenId()), liquidity);

        uint256 token0BalanceBefore = token0.balanceOf(address(alice));
        uint256 token1BalanceBefore = token1.balanceOf(address(alice));

        // bob rebalances alice's liquidity
        int24 newTickLower = -1200;
        int24 newTickUpper = 1200;
        int256 liquidityAdjustment = -int256(liquidity / 2);
        uint128 newLiquidity = helper.getNewLiquidity(position, liquidityAdjustment, newTickLower, newTickUpper);
        vm.prank(bob);
        lpm.rebalancePosition(
            alice,
            position,
            liquidityAdjustment, // partially unwind
            IPoolManager.ModifyPositionParams({
                tickLower: newTickLower,
                tickUpper: newTickUpper,
                liquidityDelta: int256(uint256(newLiquidity) / 2)
            }),
            ZERO_BYTES,
            ZERO_BYTES
        );

        // alice gets excess tokens back
        assertGt(token0.balanceOf(address(alice)), token0BalanceBefore);
        assertGt(token1.balanceOf(address(alice)), token1BalanceBefore);
    }

    function addLiquidity(address recipient, PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity)
        internal
    {
        lpm.modifyPosition(
            recipient,
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
    }

    function removeLiquidity(address owner, PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity)
        internal
    {
        lpm.modifyPosition(
            owner,
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(liquidity)
            }),
            ZERO_BYTES
        );
    }
}
