// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/contracts/test/PoolDonateTest.sol";
import {MockERC20} from "@uniswap/v4-core/test/foundry-tests/utils/MockERC20.sol";
import { PRBTest } from "@prb/test/PRBTest.sol";
import { console2 } from "forge-std/console2.sol";
import { StdCheats } from "forge-std/StdCheats.sol";

import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";

import {IGhoToken} from '@aave/gho/gho/interfaces/IGhoToken.sol';


/// @notice Contract to initialize some test helpers
/// @dev Minimal initialization. Inheriting contract should set up pools and provision liquidity
contract HookTest is Test {
    PoolManager manager;
    PoolModifyPositionTest modifyPositionRouter;
    PoolSwapTest swapRouter;
    PoolDonateTest donateRouter;
    MockERC20 token0;
    MockERC20 token1;
    address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address gho = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;

    address owner = 0x388C818CA8B9251b393131C08a736A67ccB19297; //address of owner of hook



    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_RATIO + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_RATIO - 1;

    function initHookTestEnv() public {
        uint256 amount = 2 ** 128;
        MockERC20 _tokenA = MockERC20(WETH);
        MockERC20 _tokenB = MockERC20(USDC);

        _mintTokens(amount);

        // pools alphabetically sort tokens by address
        // so align `token0` with `pool.token0` for consistency
        if (address(_tokenA) < address(_tokenB)) {
            token0 = _tokenA;
            token1 = _tokenB;
        } else {
            token0 = _tokenB;
            token1 = _tokenA;
        }
        manager = new PoolManager(500000);

        // Helpers for interacting with the pool
        modifyPositionRouter = new PoolModifyPositionTest(IPoolManager(address(manager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        donateRouter = new PoolDonateTest(IPoolManager(address(manager)));

        // Approve for liquidity provision
        token0.approve(address(modifyPositionRouter), amount);
        token1.approve(address(modifyPositionRouter), amount);

        // Approve for swapping
        token0.approve(address(swapRouter), amount);
        token1.approve(address(swapRouter), amount);
    }

    function swap(PoolKey memory key, int256 amountSpecified, bool zeroForOne, bytes memory hookData) internal {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT // unlimited impact
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(key, params, testSettings, hookData);
    }

    //helper function to mint tokens
    function _mintTokens(uint256 amount) internal{
       
 
        //mint Aeth and Ausdc by depositing into pool
        deal(WETH, address(this), amount);
        deal(USDC, address(this), amount);

    
    }

    //helper function to mint tokens
    function _mintTo( address recipient, uint256 amount) internal{
       
 
        //mint Aeth and Ausdc by depositing into pool
        deal(WETH, recipient, amount);
        deal(USDC, recipient, amount);

    
    }


    //Helper function to add hook as faciliator
    function AddFacilitator(address faciliator) internal{
        //need FACILITATOR_MANAGER_ROLE to address to add hook as faciliator
        address whitelistedManager = 0x5300A1a15135EA4dc7aD5a167152C01EFc9b192A; //whitelisted address of aave dao

        bytes32 FacilitatorRole = (IGhoToken(gho).FACILITATOR_MANAGER_ROLE());

        
        address hookAddress = address(this);
        uint128 bucketCapacity = 1000000e18; //1 million GHO
        vm.startPrank(whitelistedManager);
        IGhoToken(gho).addFacilitator(faciliator, "BorrowHook", bucketCapacity);
       
        vm.stopPrank();

        console2.log("GHO balance", IGhoToken(gho).balanceOf(hookAddress));

    }
}
