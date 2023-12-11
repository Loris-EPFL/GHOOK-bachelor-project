// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import {
   IPoolManager,  Hooks, IHooks, BaseHook, BalanceDelta
} from "v4-periphery/BaseHook.sol";
import { IHookFeeManager } from "@uniswap/v4-core/contracts/interfaces/IHookFeeManager.sol";
import { IDynamicFeeManager } from "@uniswap/v4-core/contracts/interfaces/IDynamicFeeManager.sol";
import { console2 } from "forge-std/console2.sol";
import {IGhoToken} from '@aave/gho/gho/interfaces/IGhoToken.sol';
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import { PoolManager, Currency } from "@uniswap/v4-core/contracts/PoolManager.sol";
import { TickMath } from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import { Fees } from "@uniswap/v4-core/contracts/Fees.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/contracts/libraries/SqrtPriceMath.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EACAggregatorProxy} from "../interfaces/EACAggregatorProxy.sol";
import {UD60x18} from "@prb-math/UD60x18.sol";
import {IterableMapping} from "../utils/IterableMapping.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";


contract BorrowHook is BaseHook, IHookFeeManager, IDynamicFeeManager {
    
    
    using PoolIdLibrary for PoolKey;
    using IterableMapping for IterableMapping.Map;

    // Modifier to check that the caller is the owner of
    // the contract.
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        // Underscore is a special character only used inside
        // a function modifier and it tells Solidity to
        // execute the rest of the code.
        _;
    }

    address public owner;

    uint8 maxLTV = 80; //80%

    UD60x18 maxLTVUD60x18 = UD60x18.wrap(maxLTV).div(UD60x18.wrap(100)); //80% as UD60x18
    uint256 minBorrowAmount = 1e18; //1 GHO
    address public gho = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    EACAggregatorProxy public ETHPriceFeed = EACAggregatorProxy(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419); //chainlink ETH price feed
    EACAggregatorProxy public USDCPriceFeed = EACAggregatorProxy(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6); //chainlink USDC price feed

    struct UserLiquidity{
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
    }


    //max bucket capacity (= max total mintable gho capacity)
    uint128 public ghoBucketCapacity = 100000e18; //100k gho

    IterableMapping.Map private usersDebt; //users
    mapping(address => UserLiquidity) public userPosition; //user collateral

    mapping(address => bool) public isUserLiquidable; //flag to see if user is liquidable


    constructor(address _owner, IPoolManager _poolManager) BaseHook(_poolManager) {
        owner = _owner;
    }

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: true,
            afterInitialize: true,
            beforeModifyPosition: true,
            afterModifyPosition: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: true
        });
    }

    /// @inheritdoc IHooks
    function beforeInitialize(
        address, // sender
        PoolKey calldata, // key
        uint160, // sqrtPriceX96
        bytes calldata // data
    )
        external
        override
        returns (bytes4)
    {
        console2.log("beforeInitialize");
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    function afterInitialize(
        address , // sender
        PoolKey calldata, // key
        uint160, // sqrtPriceX96
        int24, // tick
        bytes calldata // data
    )
        external
        pure
        override
        returns (bytes4)
    {
        console2.log("afterInitialize");
        return IHooks.afterInitialize.selector;
    }

    /// @inheritdoc IHooks
    function beforeModifyPosition(
        address owner, // sender
        PoolKey calldata, // key
        IPoolManager.ModifyPositionParams calldata params,// params
        bytes calldata // data
    )
        external
        override
        returns (bytes4)
    {

        

        if(params.liquidityDelta < 0 ){
            //If user try to withdraw (delta negative) and has debt, revert
            uint256 liquidity = uint256(-params.liquidityDelta);
            console2.log("liquidity to withdraw %e", uint128(liquidity));
            if(!_canUserWithdraw(owner, params.tickLower, params.tickUpper, uint128(liquidity))){
                 revert("Cannot Withdraw because LTV is inferior to min LTV"); //todo allow partial withdraw according to debt
            }


            

        }

        console2.log("beforeModifyPosition");
        return IHooks.beforeModifyPosition.selector;
    }

    /// @inheritdoc IHooks
    function afterModifyPosition(
        address owner, // sender
        PoolKey calldata, // key
        IPoolManager.ModifyPositionParams calldata params, // params
        BalanceDelta, // delta
        bytes calldata // data
    )
        external
        override
        returns (bytes4)
    {
        //store user position
        _storeUserPosition(owner, params);
        console2.log("userPosition in usd %e", _getUserLiquidityPriceUSD(owner).unwrap() / 10**18);
        console2.log("afterModifyPosition");
        return IHooks.afterModifyPosition.selector;
    }

    /// @inheritdoc IHooks
    function beforeSwap(
        address, // sender
        PoolKey calldata, // key
        IPoolManager.SwapParams calldata, // params
        bytes calldata // data
    )
        external
        pure
        override
        returns (bytes4)
    {
        console2.log("beforeSwap");
        return IHooks.beforeSwap.selector;
    }

    /// @inheritdoc IHooks
    function afterSwap(
        address sender, // sender
        PoolKey calldata, // key
        IPoolManager.SwapParams calldata, // params
        BalanceDelta, // delta
        bytes calldata // data
    )
        external
        override
        returns (bytes4)
    {
        console2.log("afterSwap");
        console2.log("user position price in USD after swap %e", _getUserLiquidityPriceUSD(sender).unwrap() / 10**18);
        return IHooks.afterSwap.selector;
    }

    /// @inheritdoc IHooks
    function beforeDonate(
        address, // sender
        PoolKey calldata, // key
        uint256, // amount0
        uint256, // amount1
        bytes calldata // data
    )
        external
        pure
        override
        returns (bytes4)
    {
        console2.log("beforeDonate");
        return IHooks.beforeDonate.selector;
    }

    /// @inheritdoc IHooks
    function afterDonate(
        address, // sender
        PoolKey calldata, // key
        uint256, // amount0
        uint256, // amount1
        bytes calldata // data
    )
        external
        pure
        override
        returns (bytes4)
    {
        console2.log("afterDonate");
        return IHooks.afterDonate.selector;
    }

    function getHookSwapFee(PoolKey calldata) external pure returns (uint8) {
        console2.log("getHookSwapFee");
        return 100;
    }

    function getHookWithdrawFee(PoolKey calldata) external pure returns (uint8) {
        console2.log("getHookWithdrawFee");
        return 100;
    }

    function getHookFees(PoolKey calldata key) external override view returns (uint24){
        console2.log("getHookFees");
        return 100;
    }



    /// @inheritdoc IDynamicFeeManager
    function getFee(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata data) external override returns (uint24){
        console2.log("getFee");
        return 10_000;
    }

    function borrowGho(uint256 amount, address user) public returns (bool, uint256){
        //if amount is inferior to min amount, revert
        if(amount < minBorrowAmount){
            revert("Borrow amount to borrow is inferior to 1 GHO");
        }
        //TODO : implement logic to check if user has enough collateral to borrow
        console2.log("Borrow amount requested %e", amount);    
        console2.log("Max borrow amount %e", _getUserLiquidityPriceUSD(user).sub((UD60x18.wrap(usersDebt.get(user))).div(UD60x18.wrap(10**ERC20(gho).decimals()))).mul(maxLTVUD60x18).unwrap());
        //get user position price in USD, then check if borrow amount + debt already owed (adjusted to gho decimals) is inferior to maxLTV (80% = maxLTV/100)
        if(_getUserLiquidityPriceUSD(user).lte((UD60x18.wrap((amount+ usersDebt.get(user))).div(UD60x18.wrap(10**ERC20(gho).decimals()))).mul(maxLTVUD60x18))){ 
            revert("user LTV is superior to maximum LTV"); //TODO add proper error message
        }
        usersDebt.set(user, usersDebt.get(user) + amount);
        IGhoToken(gho).mint(user, amount);
    
    }

    function viewGhoDebt(address user) public view returns (uint256){
        return usersDebt.get(user);
    }

    function repayGho(uint256 amount, address user) public returns (bool){
        //check if user has debt already
        if(usersDebt.get(user) < amount){
            revert("user debt is inferior to amount to repay");
        }
        //check if user has enough gho to repay, need to approve first then repay 
        bool isSuccess = ERC20(gho).transferFrom(user, address(this), amount); //send gho to this address then burning it
        if(!isSuccess){
            revert("transferFrom failed");
            return false;
        }else{
            IGhoToken(gho).burn(amount);
            usersDebt.set(user, usersDebt.get(user) - amount);
            return true;
        }
        
    }

    function _getUserLiquidityPriceUSD(address user) internal view returns (UD60x18){
        
        PoolKey memory key = _getPoolKey();
        (uint160 sqrtPriceX96, int24 currentTick, ,  ) = poolManager.getSlot0(key.toId()); //curent price and tick of the pool
        //get user liquidity position stored when adding liquidity
        UserLiquidity memory userCurrentPosition = userPosition[user];

        return _getPositionUsdPrice(userCurrentPosition.tickLower, userCurrentPosition.tickUpper, userCurrentPosition.liquidity);
    }   


    function _getPositionUsdPrice(int24 tickLower, int24 tickUpper, uint128 liquidity) internal view returns (UD60x18){
        PoolKey memory key = _getPoolKey();
        (uint160 sqrtPriceX96, int24 currentTick, ,  ) = poolManager.getSlot0(key.toId()); //curent price and tick of the pool
        
        //Lower and Upper tick of the position
        uint160 sqrtPriceLower = TickMath.getSqrtRatioAtTick(tickLower); //get price as decimal from Q64.96 format
        uint160 sqrtPriceUpper = TickMath.getSqrtRatioAtTick(tickUpper);
        uint256 token0amount;
        uint256 token1amount;

        //Price calculations on https://blog.uniswap.org/uniswap-v3-math-primer-2#how-to-calculate-current-holdings
        //Out of range, on the downside
        if(currentTick < tickLower){
            token0amount = SqrtPriceMath.getAmount0Delta(
                sqrtPriceLower,
                sqrtPriceUpper,
                liquidity,
                false
            );
            token1amount = 0;
        //Out of range, on the upside
        }else if(currentTick >= tickUpper){
            token0amount = 0;
            token1amount = SqrtPriceMath.getAmount1Delta(
                sqrtPriceLower,
                sqrtPriceUpper,
                liquidity,
                false
            );
        //in range position
        }else{
            token0amount = SqrtPriceMath.getAmount0Delta(
                sqrtPriceX96,
                sqrtPriceUpper,
                liquidity,
                false
            );
            token1amount = SqrtPriceMath.getAmount1Delta(
                sqrtPriceLower,
                sqrtPriceX96,
                liquidity,
                false
            );
        }
    
        //Use UD60x18 to convert token amount to decimal adjusted to avoid overflow errors
        UD60x18 token0amountUD60x18 = UD60x18.wrap(token0amount).div(UD60x18.wrap(10**ERC20(Currency.unwrap(key.currency0)).decimals()));
        UD60x18 token1amountUD60x18 = UD60x18.wrap(token1amount).div(UD60x18.wrap(10**ERC20(Currency.unwrap(key.currency1)).decimals()));

        //Price feed from Chainlink, convert to UD60x18 to avoid overflow errors
        UD60x18 ETHPrice = UD60x18.wrap(uint256(ETHPriceFeed.latestAnswer())).div(UD60x18.wrap(10**ETHPriceFeed.decimals()));
        UD60x18 USDCPrice = UD60x18.wrap(uint256(USDCPriceFeed.latestAnswer())).div(UD60x18.wrap(10**USDCPriceFeed.decimals()));

        //Price value of each token in the position
        UD60x18 token0Price = token0amountUD60x18.mul(ETHPrice);
        UD60x18 token1Price = token1amountUD60x18.mul(USDCPrice);
      
        //return price value of the position as UD60x18
        return token0Price.add(token1Price);

    }

    function _storeUserPosition(address user, IPoolManager.ModifyPositionParams calldata params) internal{
        //get user liquidity
        int24 tickLower = params.tickLower;
        int24 tickUpper = params.tickUpper;

        PoolKey memory key = _getPoolKey();
        (uint160 sqrtPriceX96, int24 currentTick, ,  ) = poolManager.getSlot0(key.toId());
        uint128 userLiquidity = poolManager.getLiquidity(key.toId(),user,  tickLower, tickUpper);

        userPosition[user] = UserLiquidity(
            userLiquidity,
            tickLower,
            tickUpper
        );


    }

    function _checkLiquidationsAfterSwap() internal{
        for (uint i = 0; i < usersDebt.size(); i++) {
            address key = usersDebt.getKeyAtIndex(i);

            //check if user is liquidable
            if(_getUserLiquidityPriceUSD(key).mul(maxLTVUD60x18).lte((UD60x18.wrap(usersDebt.get(key))).div(UD60x18.wrap(10**ERC20(gho).decimals())))){ 
                isUserLiquidable[key] = true;
                //_liquidateUser(key);
        }
    }
    }

    function liquidateUser(address user, address liquidator) public{
        poolManager.take(Currency.wrap(address(USDC)), address(this), 1);
    }

    function getUserPositonPriceUSD(address user) public view returns (uint256){
        return _getUserLiquidityPriceUSD(user).unwrap() / 10**18;
    }

    function getUserCurrentLTV(address user) public view returns (uint256){
        UD60x18 userPositionValueUDx60 = _getUserLiquidityPriceUSD(user); //user position value
        UD60x18 userDebtUDx60 = UD60x18.wrap(usersDebt.get(user)).div(UD60x18.wrap(10**ERC20(gho).decimals())); //user debt, adjusted to gho decimals

        return userDebtUDx60.div(userPositionValueUDx60).mul(UD60x18.wrap(100)).unwrap(); //return LTV 0 < LTV < 100
    }

    function _canUserWithdraw(address user, int24 tickLower, int24 tickUpper, uint128 liquidity) internal view returns (bool){
        //check if debt / (position price - withdraw liquidity amount) is inferior to maxLTV (=77%)
        console2.log("user debt before trying withdraw %e", usersDebt.get(user) / 10**18);
        console2.log("position value user wants to withdraw %e", _getPositionUsdPrice(tickLower, tickUpper, liquidity).unwrap()/ 10**18);
        //Theorically, position value after withdraw should be superior to 0, but we check just in case
        UD60x18 _positionValueAfterWithdraw = _getUserLiquidityPriceUSD(user).gte(_getPositionUsdPrice(tickLower, tickUpper, liquidity)) ? _getUserLiquidityPriceUSD(user).sub(_getPositionUsdPrice(tickLower, tickUpper, liquidity)) : UD60x18.wrap(0);
        
        if(_positionValueAfterWithdraw.isZero() && usersDebt.get(user) == 0){
            //If user has no debt and withdraw all his position, he can withdraw
            return true;
        }else if(_positionValueAfterWithdraw.isZero() && usersDebt.get(user) > 0){
            //If user has debt and withdraw all his position, he cannot withdraw
            return false;
        }
        if(!_positionValueAfterWithdraw.isZero() && (UD60x18.wrap(usersDebt.get(user)).div(UD60x18.wrap((10**ERC20(gho).decimals()))).div(_positionValueAfterWithdraw).lte(maxLTVUD60x18))){
            //If user has debt and withdraw part of his position, check if debt / (position price - withdraw liquidity amount) is inferior to maxLTV (=77%)
            return true;
        }else{
            //unhandled case, default to false to avoid user withdrawing more than he should
            return false;
        }
    }

    function modifyPriceFeed(address _ETHPriceFeed, address _USDCPriceFeed) public onlyOwner{
        ETHPriceFeed = EACAggregatorProxy(_ETHPriceFeed);
        USDCPriceFeed = EACAggregatorProxy(_USDCPriceFeed);
    }


    //Helper function to return PoolKey
    function _getPoolKey() private view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(WETH)),
            currency1: Currency.wrap(address(USDC)),
            fee:  300, // 0xE00000 = 111 //todo change fee accordingly
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });
    }
}
