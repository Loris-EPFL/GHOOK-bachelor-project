// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {ERC6909} from "ERC-6909/ERC6909.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Position, PositionId, PositionIdLibrary} from "./types/PositionId.sol";
import {Position as PoolPosition} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {UD60x18} from "@prb-math/UD60x18.sol";
import {IterableMapping} from "./utils/IterableMapping.sol";
import {EACAggregatorProxy} from "./interfaces/EACAggregatorProxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IGhoToken} from '@aave/gho/gho/interfaces/IGhoToken.sol';
import {SqrtPriceMath} from "@uniswap/v4-core/contracts/libraries/SqrtPriceMath.sol";





contract LiquidityPositionManager is ERC6909 {
    using CurrencyLibrary for Currency;
    using PositionIdLibrary for Position;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable manager;

    struct CallbackData {
        address sender;
        address owner;
        PoolKey key;
        IPoolManager.ModifyPositionParams params;
        bytes hookData;
    }

    struct BorrowerPosition{
        Position position;
        uint128 liquidity;
        uint256 debt;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

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

    //max bucket capacity (= max total mintable gho capacity)
    uint128 public ghoBucketCapacity = 100000e18; //100k gho

    mapping(address => BorrowerPosition) public userPosition; //user position todo need to be private ?
    address[] private users; //all users list, used to iterate through mapping after each swap to verify if user is liquidable

    IterableMapping.Map private usersDebt; //users



    PoolKey private poolKey; //current hook pool key


    /// @notice Given an existing position, readjust it to a new range, optionally using net-new tokens
    ///     This function supports partially withdrawing tokens from an LP to open up a new position
    /// @param owner The owner of the position
    /// @param position The position to rebalance
    /// @param existingLiquidityDelta How much liquidity to remove from the existing position
    /// @param params The new position parameters
    /// @param hookDataOnBurn the arbitrary bytes to provide to hooks when the existing position is modified
    /// @param hookDataOnMint the arbitrary bytes to provide to hooks when the new position is created
    function rebalancePosition(
        address owner,
        Position memory position,
        int256 existingLiquidityDelta,
        IPoolManager.ModifyPositionParams memory params,
        bytes calldata hookDataOnBurn,
        bytes calldata hookDataOnMint
    ) external returns (BalanceDelta delta) {
        if (!(msg.sender == owner || isOperator[owner][msg.sender])) revert InsufficientPermission();
        delta = abi.decode(
            manager.lock(
                abi.encodeCall(
                    this.handleRebalancePosition,
                    (msg.sender, owner, position, existingLiquidityDelta, params, hookDataOnBurn, hookDataOnMint)
                )
            ),
            (BalanceDelta)
        );

        // adjust 6909 balances
        _burn(owner, position.toTokenId(), uint256(-existingLiquidityDelta));
        uint256 newPositionTokenId =
            Position({poolKey: position.poolKey, tickLower: params.tickLower, tickUpper: params.tickUpper}).toTokenId();
        _mint(owner, newPositionTokenId, uint256(params.liquidityDelta));

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    /// @notice Given an existing position, liquidate position by repaying debt with a flashloan, then withdrawing collateral
    ///     This function supports partially withdrawing tokens from an LP to open up a new position
    /// @param owner The owner of the position
    /// @param position The position to liquidate
    /// @param existingLiquidityDelta How much liquidity to remove from the existing position
    /// @param params The new position parameters
    /// @param hookDataOnBurn the arbitrary bytes to provide to hooks when the existing position is modified
    /// @param hookDataOnMint the arbitrary bytes to provide to hooks when the new position is created
    function liquidateUser(
        address owner,
        Position memory position,
        int256 existingLiquidityDelta,
        IPoolManager.ModifyPositionParams memory params,
        bytes calldata hookDataOnBurn,
        bytes calldata hookDataOnMint
    ) external returns (BalanceDelta delta) {
        if (!(msg.sender == owner || isOperator[owner][msg.sender])) revert InsufficientPermission();
        delta = abi.decode(
            manager.lock(
                abi.encodeCall(
                    this.handleRebalancePosition,
                    (msg.sender, owner, position, existingLiquidityDelta, params, hookDataOnBurn, hookDataOnMint)
                )
            ),
            (BalanceDelta)
        );

        // adjust 6909 balances
        _burn(owner, position.toTokenId(), uint256(-existingLiquidityDelta));
        uint256 newPositionTokenId =
            Position({poolKey: position.poolKey, tickLower: params.tickLower, tickUpper: params.tickUpper}).toTokenId();
        _mint(owner, newPositionTokenId, uint256(params.liquidityDelta));

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    function handleRebalancePosition(
        address sender,
        address owner,
        Position memory position,
        int256 existingLiquidityDelta,
        IPoolManager.ModifyPositionParams memory params,
        bytes memory hookDataOnBurn,
        bytes memory hookDataOnMint
    ) external returns (BalanceDelta delta) {
        PoolKey memory key = position.poolKey;

        // unwind the old position
        BalanceDelta deltaBurn = manager.modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                liquidityDelta: existingLiquidityDelta
            }),
            hookDataOnBurn
        );
        BalanceDelta deltaMint = manager.modifyPosition(key, params, hookDataOnMint);

        delta = deltaBurn + deltaMint;

        processBalanceDelta(sender, owner, key.currency0, key.currency1, delta);
    }

    function handleModifyPosition(bytes memory rawData) external returns (BalanceDelta delta) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        delta = manager.modifyPosition(data.key, data.params, data.hookData);
        processBalanceDelta(data.sender, data.owner, data.key.currency0, data.key.currency1, delta);
    }

    function modifyPosition(
        address owner,
        PoolKey memory key,
        IPoolManager.ModifyPositionParams memory params,
        bytes calldata hookData
    ) external returns (BalanceDelta delta) {
        // checks & effects
        uint256 tokenId = Position({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper}).toTokenId();
        if (params.liquidityDelta < 0) {
            // only the operator or owner can burn
            if (!(msg.sender == owner || isOperator[owner][msg.sender])){
                revert InsufficientPermission();
            } 

            uint256 liquidity = uint256(-params.liquidityDelta);
            console2.log("liquidity to withdraw %e", uint128(liquidity));
            if(!_canUserWithdraw(owner, params.tickLower, params.tickUpper, uint128(liquidity))){
                 revert("Cannot Withdraw because LTV is inferior to min LTV"); //todo allow partial withdraw according to debt
            }

            userPosition[owner] = BorrowerPosition(Position({poolKey: key, tickLower: 0, tickUpper: 0}), 0, userPosition[owner].debt); //todo check if this is the right way to remove user position
            _burn(owner, tokenId, uint256(-params.liquidityDelta));
        } else {
            // allow anyone to mint to a destination address
            // TODO: guarantee that k is less than int256 max
            // TODO: proper book keeping to avoid double-counting
            uint256 liquidity = uint256(params.liquidityDelta);
            userPosition[owner] = BorrowerPosition(Position({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper}),uint128(liquidity), userPosition[owner].debt) ;
            _mint(owner, tokenId, uint256(params.liquidityDelta));
        }

        // interactions
        delta = abi.decode(
            manager.lock(
                abi.encodeCall(
                    this.handleModifyPosition, abi.encode(CallbackData(msg.sender, owner, key, params, hookData))
                )
            ),
            (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(owner, ethBalance);
        }
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));

        (bool success, bytes memory returnData) = address(this).call(data);
        if (success) return returnData;
        if (returnData.length == 0) revert("LockFailure");
        // if the call failed, bubble up the reason
        /// @solidity memory-safe-assembly
        assembly {
            revert(add(returnData, 32), mload(returnData))
        }
    }

    function processBalanceDelta(
        address sender,
        address recipient,
        Currency currency0,
        Currency currency1,
        BalanceDelta delta
    ) internal {
        if (delta.amount0() > 0) {
            if (currency0.isNative()) {
                manager.settle{value: uint128(delta.amount0())}(currency0);
            } else {
                IERC20(Currency.unwrap(currency0)).transferFrom(sender, address(manager), uint128(delta.amount0()));
                manager.settle(currency0);
            }
        }
        if (delta.amount1() > 0) {
            if (currency1.isNative()) {
                manager.settle{value: uint128(delta.amount1())}(currency1);
            } else {
                IERC20(Currency.unwrap(currency1)).transferFrom(sender, address(manager), uint128(delta.amount1()));
                manager.settle(currency1);
            }
        }

        if (delta.amount0() < 0) {
            manager.take(currency0, recipient, uint128(-delta.amount0()));
        }
        if (delta.amount1() < 0) {
            manager.take(currency1, recipient, uint128(-delta.amount1()));
        }
    }

    function borrowGho(uint256 amount, address user) public returns (bool, uint256){

        //todo add caller is owner check
        //if amount is inferior to min amount, revert
        if(amount < minBorrowAmount){
            revert("Borrow amount to borrow is inferior to 1 GHO");
        }
        //TODO : implement logic to check if user has enough collateral to borrow
        console2.log("Borrow amount requested %e", amount);    
        console2.log("user collateral value in USD %e", _getUserLiquidityPriceUSD(user).unwrap() / 10**18);
        console2.log("Max borrow amount %e", _getUserLiquidityPriceUSD(user).sub((UD60x18.wrap(userPosition[user].debt)).div(UD60x18.wrap(10**ERC20(gho).decimals()))).mul(maxLTVUD60x18).unwrap());
        //get user position price in USD, then check if borrow amount + debt already owed (adjusted to gho decimals) is inferior to maxLTV (80% = maxLTV/100)
        if(_getUserLiquidityPriceUSD(user).lte((UD60x18.wrap((amount+ userPosition[user].debt)).div(UD60x18.wrap(10**ERC20(gho).decimals()))).mul(maxLTVUD60x18))){ 
            revert("user LTV is superior to maximum LTV"); //TODO add proper error message
        }
        userPosition[user].debt =  userPosition[user].debt + amount;
        IGhoToken(gho).mint(user, amount);
    
    }

    function viewGhoDebt(address user) public view returns (uint256){
        return userPosition[user].debt;
    }

    function repayGho(uint256 amount, address user) public returns (bool){
        //check if user has debt already
        if(userPosition[user].debt < amount){
            revert("user debt is inferior to amount to repay");
        }
        //check if user has enough gho to repay, need to approve first then repay 
        bool isSuccess = ERC20(gho).transferFrom(user, address(this), amount); //send gho to this address then burning it
        if(!isSuccess){
            revert("transferFrom failed");
            return false;
        }else{
            IGhoToken(gho).burn(amount);
            userPosition[user].debt = userPosition[user].debt - amount;
            return true;
        }
        
    }

    function _getUserLiquidityPriceUSD(address user) internal view returns (UD60x18){
        
        //PoolKey memory key = _getPoolKey();
        BorrowerPosition memory borrowerPosition = userPosition[user];
        Position memory positionParams = borrowerPosition.position;
        PoolKey memory key = positionParams.poolKey;

        console2.log("user tick lower %e", positionParams.tickLower);
        console2.log("user tick upper %e", positionParams.tickUpper);
        console2.log("poolkey %s", address(poolKey.hooks));
        (uint160 sqrtPriceX96, int24 currentTick, ,  ) = manager.getSlot0(key.toId()); //curent price and tick of the pool
        //get user liquidity position stored when adding liquidity
        //UserLiquidity memory userCurrentPosition = userPosition[user];
        //uint128 liquidity = manager.getLiquidity(key.toId(),user, userPos.tickLower, userPos.tickUpper); //get user liquidity

        

        return _getPositionUsdPrice(positionParams.tickLower, positionParams.tickUpper, borrowerPosition.liquidity, key);
    }   


    function _getPositionUsdPrice(int24 tickLower, int24 tickUpper, uint128 liquidity, PoolKey memory key) internal view returns (UD60x18){
        //PoolKey memory key = _getPoolKey();

        (uint160 sqrtPriceX96, int24 currentTick, ,  ) = manager.getSlot0(key.toId()); //curent price and tick of the pool
        
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


    function _checkLiquidationsAfterSwap() internal{
        for (uint i = 0; i < users.length; i++) {
            address key = users[i];

            //check if user is liquidable
            if(_getUserLiquidityPriceUSD(key).mul(maxLTVUD60x18).lte((UD60x18.wrap(userPosition[key].debt)).div(UD60x18.wrap(10**ERC20(gho).decimals())))){ 
                //isUserLiquidable[key] = true;
                //_liquidateUser(key);
        }
    }
    }

    function liquidateUser(address user, address liquidator) public{
        manager.take(Currency.wrap(address(USDC)), address(this), 1);
    }

    function getUserPositonPriceUSD(address user) public view returns (uint256){
        return _getUserLiquidityPriceUSD(user).unwrap() / 10**18;
    }

    function getUserCurrentLTV(address user) public view returns (uint256){
        UD60x18 userPositionValueUDx60 = _getUserLiquidityPriceUSD(user); //user position value
        UD60x18 userDebtUDx60 = UD60x18.wrap(userPosition[user].debt).div(UD60x18.wrap(10**ERC20(gho).decimals())); //user debt, adjusted to gho decimals

        return userDebtUDx60.div(userPositionValueUDx60).mul(UD60x18.wrap(100)).unwrap(); //return LTV 0 < LTV < 100
    }

    
    function modifyPriceFeed(address _ETHPriceFeed, address _USDCPriceFeed) public onlyOwner{
        ETHPriceFeed = EACAggregatorProxy(_ETHPriceFeed);
        USDCPriceFeed = EACAggregatorProxy(_USDCPriceFeed);
    }

    function _canUserWithdraw(address user, int24 tickLower, int24 tickUpper, uint128 liquidity) internal view returns (bool){
        PoolKey memory key = userPosition[user].position.poolKey;
        
        //check if debt / (position price - withdraw liquidity amount) is inferior to maxLTV (=77%)
        console2.log("user debt before trying withdraw %e", userPosition[user].debt / 10**18);
        console2.log("position value user wants to withdraw %e", _getPositionUsdPrice(tickLower, tickUpper, liquidity, key).unwrap()/ 10**18);
        //Theorically, position value after withdraw should be superior to 0, but we check just in case
        UD60x18 _positionValueAfterWithdraw = _getUserLiquidityPriceUSD(user).gte(_getPositionUsdPrice(tickLower, tickUpper, liquidity, key)) ? _getUserLiquidityPriceUSD(user).sub(_getPositionUsdPrice(tickLower, tickUpper, liquidity, key)) : UD60x18.wrap(0);
        
        if(_positionValueAfterWithdraw.isZero() && userPosition[user].debt == 0){
            //If user has no debt and withdraw all his position, he can withdraw
            return true;
        }else if(_positionValueAfterWithdraw.isZero() && userPosition[user].debt > 0){
            //If user has debt and withdraw all his position, he cannot withdraw
            return false;
        }
        if(!_positionValueAfterWithdraw.isZero() && (UD60x18.wrap(userPosition[user].debt).div(UD60x18.wrap((10**ERC20(gho).decimals()))).div(_positionValueAfterWithdraw).lte(maxLTVUD60x18))){
            //If user has debt and withdraw part of his position, check if debt / (position price - withdraw liquidity amount) is inferior to maxLTV (=77%)
            return true;
        }else{
            //unhandled case, default to false to avoid user withdrawing more than he should
            return false;
        }
    }

    function getLiquidityforUser(address user) public view returns (uint128){
        return userPosition[user].liquidity;
    }

    // --- ERC-6909 --- //
    function _mint(address owner, uint256 tokenId, uint256 amount) internal {
        balanceOf[owner][tokenId] += amount;
        emit Transfer(msg.sender, address(this), owner, tokenId, amount);
    }

    function _burn(address owner, uint256 tokenId, uint256 amount) internal {
        balanceOf[owner][tokenId] -= amount;
        emit Transfer(msg.sender, owner, address(this), tokenId, amount);
    }

    //Helper function to return PoolKey
    function _getPoolKey() private view returns (PoolKey memory) {
        return poolKey;
    }

    //todo add modifier to prevent non owner to call this function
    function setPoolKey(PoolKey memory _poolKey) public {
        poolKey = _poolKey;
    }
}
