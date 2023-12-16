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
import { UniswapHooksFactory } from "../../src/utils/UniswapHooksFactory.sol";
import { BorrowHook } from "../../src/hook/BorrowHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IGhoToken} from '@aave/gho/gho/interfaces/IGhoToken.sol';
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
 




contract LiquidityOwnershipTest is HookTest, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using PositionIdLibrary for Position;

    UniswapHooksFactory internal uniswapHooksFactory;
    BorrowHook internal deployedHooks;

    bytes constant liquidate = abi.encode(true);


    LiquidityPositionManager lpm;
    LiquidityHelpers helper;

    PoolKey poolKey;
    PoolId poolId;

    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    address GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    


    function setUp() public {
        HookTest.initHookTestEnv();

        address owner = makeAddr("owner");

        console2.log("token0: %s", address(token0)); 
        console2.log("token1: %s", address(token1));

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
        manager.initialize(poolKey, SQRT_RATIO_1_1, ZERO_BYTES);

        lpm = new LiquidityPositionManager(IPoolManager(address(manager)), owner, poolKey);
        helper = new LiquidityHelpers(IPoolManager(address(manager)), lpm);

        AddFacilitator(address(lpm));

        token0.approve(address(lpm), type(uint256).max);
        token1.approve(address(lpm), type(uint256).max);


        _mintTokens(1000000000000000000000e18);
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

    

    
    function _doesAddressStartWith(address _address, uint160 _prefix) private pure returns (bool) {
        return uint160(_address) / (2 ** (8 * (19))) == _prefix;
    }

    function test_borrow() public{
        test_recipientAdd();

    }


    // bob *can* create a position for alice
    function test_recipientAdd() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e4;

        uint256 token0Alice = token0.balanceOf(alice);
        uint256 token1Alice = token1.balanceOf(alice);
        vm.prank(bob);
        lpm.modifyPosition(
            alice, // alice, the owner
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity);

        // bob paid for the LP, on behalf of alice
        assertEq(token0.balanceOf(alice), token0Alice);
        assertEq(token1.balanceOf(alice), token1Alice);
    }

    // bob can add to alice's position
    function test_recipientReadd() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e10;

        uint256 token0Alice = token0.balanceOf(alice);
        uint256 token1Alice = token1.balanceOf(alice);
        vm.prank(bob);
        lpm.modifyPosition(
            alice, // alice, the owner
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity);

        // readd to the liquidity
        vm.prank(bob);
        lpm.modifyPosition(
            alice, // alice, the owner
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity * 2);

        // bob paid for the LP, on behalf of alice
        assertEq(token0.balanceOf(alice), token0Alice);
        assertEq(token1.balanceOf(alice), token1Alice);
    }

    // bob cannot remove from alice's position
    function test_ownershipRemove() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e10;

        vm.prank(alice);
        lpm.modifyPosition(
            alice, // alice, the owner
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity);

        vm.startPrank(bob);
        vm.expectRevert();
        lpm.modifyPosition(
            alice, // bob, not the owner cannot modify without permission
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(liquidity)
            }),
            ZERO_BYTES
        );
        vm.stopPrank();

        // alice's LP still the same
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity);
    }

    // bob cannot rebalance alice's position
    function test_ownershipRebalance() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e10;

        vm.prank(alice);
        lpm.modifyPosition(
            alice, // alice, the owner
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity);

        vm.startPrank(bob);
        int24 newTickLower = -1200;
        int24 newTickUpper = 1200;
        uint128 newLiquidity = helper.getNewLiquidity(position, -int256(liquidity), newTickLower, newTickUpper);
        vm.expectRevert();
        lpm.rebalancePosition(
            alice, // bob cannot modify alice's position
            position,
            -int256(liquidity), // fully unwind
            IPoolManager.ModifyPositionParams({
                tickLower: newTickLower,
                tickUpper: newTickUpper,
                liquidityDelta: int256(uint256(newLiquidity))
            }),
            ZERO_BYTES,
            ZERO_BYTES
        );
        vm.stopPrank();

        // alice's LP still the same
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity);
    }

    // with operator set, bob can add to alice's position
    function test_operatorRemove() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e10;

        vm.prank(alice);
        lpm.modifyPosition(
            alice, // alice, the owner
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity);

        // alice allows bob as an operator
        vm.prank(alice);
        lpm.setOperator(bob, true);

        vm.startPrank(bob);
        lpm.modifyPosition(
            alice, // bob has operator permissions to close alice's LP
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(liquidity)
            }),
            ZERO_BYTES
        );
        vm.stopPrank();

        // alice's LP is closed
        assertEq(lpm.balanceOf(alice, position.toTokenId()), 0);

        // TODO: alice receives the underlying tokens
    }

    // with operator set, bob can liquidate to alice's position
    function test_liquidation() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e10;


        vm.startPrank(alice);
        lpm.modifyPosition(
            alice, // alice, the owner
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity);

        lpm.borrowGho(236e18, alice);
        
        lpm.setOperator(address(lpm), true);
        vm.stopPrank();

        _mintTo(address(this), 1000000000000000000000e18);

        // First we need two tokens
        ERC20 token1 = ERC20(Currency.unwrap(poolKey.currency0));
        ERC20 token2 = ERC20(Currency.unwrap(poolKey.currency1));

        token1.approve(address(manager), type(uint256).max);
        token2.approve(address(manager), type(uint256).max);

        console2.log("token1 balance: %s", token1.balanceOf(address(this)));
        console2.log("token2 balance: %s", token2.balanceOf(address(this)));

        //get current price, then swap enough to make pool price go down and liquidate user
        (uint160 sqrtPriceX96Current, int24 currentTick, , ) = IPoolManager(address(manager)).getSlot0(PoolIdLibrary.toId(poolKey));
        uint160 maxSlippage = 30;
        swap(poolKey, 1e18, false, ZERO_BYTES); //false = sell eth for usdc

        vm.startPrank(address(bob));
        ERC20(GHO).approve(address(lpm), type(uint256).max);
        _mintGHOTo(address(bob), 237e18);

        address[] memory liquidableUsers = lpm.getLiquidableUsers(4);
        
        for(uint i = 0; i < liquidableUsers.length; i++){
            console2.log("liquidable user: %s", liquidableUsers[i]);
        }

        console2.log("ETH balance before liquidation: %e", ERC20(WETH).balanceOf(address(bob)));
        console2.log("USDC balance before liquidation: %e", ERC20(USDC).balanceOf(address(bob)));
        console2.log("GHO balance before liquidation: %e", ERC20(GHO).balanceOf(address(bob)));

        
        lpm.liquidateUser(
            alice, // bob has operator permissions to close alice's LP
            position,
            ZERO_BYTES
        );
        console2.log("ETH balance after liquidation: %e", ERC20(WETH).balanceOf(address(bob)));
        console2.log("USDC balance after liquidation: %e", ERC20(USDC).balanceOf(address(bob)));
        console2.log("GHO balance after liquidation: %e", ERC20(GHO).balanceOf(address(bob)));


        vm.stopPrank();

        // alice's LP is closed
        //assertEq(lpm.balanceOf(alice, position.toTokenId()), 0);

        // TODO: alice receives the underlying tokens
    }

    // with operator set, bob can add to alice's position
    function test_operatorRebalance() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e10;

        vm.prank(alice);
        lpm.modifyPosition(
            alice, // alice, the owner
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity);

        // alice allows bob as an operator
        vm.prank(alice);
        lpm.setOperator(bob, true);

        vm.startPrank(bob);
        int24 newTickLower = -1200;
        int24 newTickUpper = 1200;
        uint128 newLiquidity = helper.getNewLiquidity(position, -int256(liquidity), newTickLower, newTickUpper);
        lpm.rebalancePosition(
            alice, // bob has permission to rebalance for alice
            position,
            -int256(liquidity), // fully unwind
            IPoolManager.ModifyPositionParams({
                tickLower: newTickLower,
                tickUpper: newTickUpper,
                liquidityDelta: int256(uint256(newLiquidity))
            }),
            ZERO_BYTES,
            ZERO_BYTES
        );
        vm.stopPrank();

        // alice's old LP is closed
        assertEq(lpm.balanceOf(alice, position.toTokenId()), 0);

        // alice has a new LP
        assertEq(
            lpm.balanceOf(
                alice, Position({poolKey: poolKey, tickLower: newTickLower, tickUpper: newTickUpper}).toTokenId()
            ),
            newLiquidity
        );
    }
}
