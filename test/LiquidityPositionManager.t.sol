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
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {Position as PoolPosition} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {LiquidityHelpers} from "../src/lens/LiquidityHelpers.sol";
import { BorrowHook } from "../../src/hook/BorrowHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IGhoToken} from '@aave/gho/gho/interfaces/IGhoToken.sol';

contract LiquidityPositionManagerTest is HookTest, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using PositionIdLibrary for Position;

    LiquidityPositionManager lpm;
    LiquidityHelpers helper;

    BorrowHook internal deployedHooks;


    PoolKey poolKey;
    PoolId poolId;

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

        console2.log("deployedHooks: %s", address(deployedHooks));

        // Create the pool
        poolKey =
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 300, 60, IHooks(address(deployedHooks)));
        poolId = poolKey.toId();
         
        lpm = new LiquidityPositionManager(IPoolManager(address(manager)), owner, poolKey);
        helper = new LiquidityHelpers(IPoolManager(address(manager)), lpm);

        manager.initialize(poolKey, SQRT_RATIO_1_1, ZERO_BYTES);
        AddFacilitator(address(lpm)); //whitelist lpm to mint gho

        token0.approve(address(lpm), type(uint256).max);
        token1.approve(address(lpm), type(uint256).max);


        _mintTokens(1000000000000000000000e18);

      
    }

    function test_borrow() public{
        test_addLiquidity();
        console2.log("test liquidity is %e", lpm.getLiquidityforUser(address(this)));
        lpm.borrowGho(236e18, address(this));
    }

    function test_withdrawWhileDebt() public{
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e10;
        addLiquidity(poolKey, tickLower, tickUpper, liquidity);
        console2.log("test liquidity is %e", lpm.getLiquidityforUser(address(this)));
        lpm.borrowGho(1e18, address(this));

        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        uint256 balanceBefore = lpm.balanceOf(address(this), position.toTokenId());
        removeLiquidity(poolKey, tickLower, tickUpper, liquidity / 2); // remove half of the position

    }

    function test_withdrawWhileTooMuchDebt() public{
       
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e10;
        addLiquidity(poolKey, tickLower, tickUpper, liquidity);

        console2.log("test liquidity is %e", lpm.getLiquidityforUser(address(this)));
        lpm.borrowGho(230e18, address(this)); //max borrow is 236 usd worth of gho, we borrow 4e5 usd worth of gho

        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        uint256 balanceBefore = lpm.balanceOf(address(this), position.toTokenId());
        removeLiquidity(poolKey, tickLower, tickUpper, liquidity / 2); // remove half of the position
    }

    function test_addLiquidity() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e10;

        console2.log("token0 balance before", token0.balanceOf(address(this)));
        console2.log("token1 balance before", token1.balanceOf(address(this)));

        lpm.modifyPosition(
            address(this),
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
        uint128 liquidityTest = manager.getLiquidity(poolKey.toId(),address(lpm), tickLower, tickUpper);
        console2.log("liquidity for test borrow %e", liquidityTest);
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(address(this), position.toTokenId()), liquidity);
    }

    function test_removeFullLiquidity() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e10;
        addLiquidity(poolKey, tickLower, tickUpper, liquidity);
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(address(this), position.toTokenId()), liquidity);
        lpm.modifyPosition(
            address(this),
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(liquidity)
            }),
            ZERO_BYTES
        );
        assertEq(lpm.balanceOf(address(this), position.toTokenId()), 0);
    }

    function test_removePartialLiquidity() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e10;
        addLiquidity(poolKey, tickLower, tickUpper, liquidity);

        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        uint256 balanceBefore = lpm.balanceOf(address(this), position.toTokenId());
        removeLiquidity(poolKey, tickLower, tickUpper, liquidity / 2); // remove half of the position

        assertEq(lpm.balanceOf(address(this), position.toTokenId()), balanceBefore / 2);
    }

    function test_addPartialLiquidity() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e10;
        addLiquidity(poolKey, tickLower, tickUpper, liquidity);

        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        uint256 balanceBefore = lpm.balanceOf(address(this), position.toTokenId());
        addLiquidity(poolKey, tickLower, tickUpper, liquidity / 2); // add half of the position

        assertEq(lpm.balanceOf(address(this), position.toTokenId()), balanceBefore + liquidity / 2);
    }

    function test_expandLiquidity() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        int256 liquidity = 1e10;
        addLiquidity(poolKey, tickLower, tickUpper, uint256(liquidity));
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});

        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        int24 newTickLower = -1200;
        int24 newTickUpper = 1200;

        assertEq(lpm.balanceOf(address(this), position.toTokenId()), uint256(liquidity));

        uint128 newLiquidity = helper.getNewLiquidity(position, -liquidity, newTickLower, newTickUpper);
        lpm.rebalancePosition(
            address(this),
            position,
            -liquidity, // fully unwind
            IPoolManager.ModifyPositionParams({
                tickLower: newTickLower,
                tickUpper: newTickUpper,
                liquidityDelta: int256(uint256(newLiquidity))
            }),
            ZERO_BYTES,
            ZERO_BYTES
        );

        // new liquidity position did not require net-new tokens
        assertEq(token0.balanceOf(address(this)), balance0Before);
        assertEq(token1.balanceOf(address(this)), balance1Before);

        // old position was unwound entirely
        assertEq(lpm.balanceOf(address(this), position.toTokenId()), 0);

        // new position was created
        Position memory newPosition = Position({poolKey: poolKey, tickLower: newTickLower, tickUpper: newTickUpper});
        assertEq(lpm.balanceOf(address(this), newPosition.toTokenId()), uint256(newLiquidity));
    }

    function addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity) internal {
        lpm.modifyPosition(
            address(this),
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
    }

    function removeLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity) internal {
        lpm.modifyPosition(
            address(this),
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
