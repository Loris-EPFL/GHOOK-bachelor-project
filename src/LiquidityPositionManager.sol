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
import {IterableMapping2} from "./utils/IterableMapping.sol";
import {EACAggregatorProxy} from "./interfaces/EACAggregatorProxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IGhoToken} from '@aave/gho/gho/interfaces/IGhoToken.sol';
import {SqrtPriceMath} from "@uniswap/v4-core/contracts/libraries/SqrtPriceMath.sol";
import {AUniswap} from "./utils/FlashLoanUtils/AUniswap.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";






contract LiquidityPositionManager is ERC6909, AUniswap{
    using CurrencyLibrary for Currency;
    using PositionIdLibrary for Position;
    using PoolIdLibrary for PoolKey;
    using IterableMapping2 for IterableMapping2.Map;

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

    constructor(IPoolManager _manager, address _owner, PoolKey memory _poolKey) Ownable(_owner){
        manager = _manager;
        poolKey = _poolKey;
    }

    uint8 maxLTV = 80; //80%

    UD60x18 maxLTVUD60x18 = UD60x18.wrap(maxLTV).div(UD60x18.wrap(100)); //80% as UD60x18
    uint256 minBorrowAmount = 1e18; //1 GHO

    bytes constant ZERO_BYTES = new bytes(0);


    EACAggregatorProxy public ETHPriceFeed = EACAggregatorProxy(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419); //chainlink ETH price feed
    EACAggregatorProxy public USDCPriceFeed = EACAggregatorProxy(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6); //chainlink USDC price feed

    mapping(address => BorrowerPosition) public userPosition; //user position todo need to be private ?
    IterableMapping2.Map private users; //list of users
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
        //if user don't exist yet, add him to the list
        if(users.get(owner) != false){
           users.set(owner, true);
        }


        uint256 tokenId = Position({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper}).toTokenId();
        console2.log("liquidity delta %e", params.liquidityDelta);
        if (params.liquidityDelta < 0) {
            // only the operator or owner can burn
            if (!(msg.sender == owner || isOperator[owner][msg.sender])){
                revert InsufficientPermission();
            } 

            uint256 liquidity = uint256(-params.liquidityDelta);
            console2.log("liquidity to withdraw %e", uint128(liquidity));
            console2.log("can user withdraw ? %s", _canUserWithdraw(owner, params.tickLower, params.tickUpper, uint128(liquidity)));
            if(!_canUserWithdraw(owner, params.tickLower, params.tickUpper, uint128(liquidity))){
                revert("Cannot Withdraw because LTV is inferior to min LTV"); //todo allow partial withdraw according to debt
            }


            userPosition[owner] = BorrowerPosition(Position({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper}), uint128(userPosition[owner].liquidity - liquidity), userPosition[owner].debt); //todo check if this is the right way to remove user position
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
        console2.log("ETH balance before actual modify position %e", ethBalance);
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

    /// @notice Given an existing position, liquidate position by repaying debt with a flashloan, then withdrawing collateral
    ///     This function supports partially withdrawing tokens from an LP to open up a new position
    /// @param owner The owner of the position
    /// @param position The position to liquidate
    /// @param hookLiquidationData the arbitrary bytes to provide to hooks when the existing position is modified
    function liquidateUser(
        address owner,
        Position memory position,
        bytes calldata hookLiquidationData
    ) external returns (bool liquidationSuccess) {
        
        if(getUserCurrentLTV(owner) < maxLTVUD60x18){
            revert("User LTV is not at risk of liquidation");
        }

        uint8 liquidationPremium = 20; //20% of GHO debt to liquidator



        //get user Current Position and debt
        BorrowerPosition storage currentParams = userPosition[owner];

        //send GHO to this address then burning it
        bool isTransferSuccess = ERC20(GHO).transferFrom(msg.sender, address(this), currentParams.debt); 

        if(!isTransferSuccess){
            revert("GHO transferFrom failed");
        }

        //burn GHO debt
        IGhoToken(GHO).burn(currentParams.debt);

        //reset user debt to 0
        userPosition[owner].debt = 0; 

        //burn ERC6909 position tokens
        _burn(owner, currentParams.position.toTokenId(), uint256(currentParams.liquidity));


        //Set Position params to 0 to liquidate
        IPoolManager.ModifyPositionParams memory liquidationParams = IPoolManager.ModifyPositionParams({
            tickLower: currentParams.position.tickLower,
            tickUpper: currentParams.position.tickUpper,
            liquidityDelta: -int256(int128(currentParams.liquidity))
        });//todo check safe conversion ?

       uint256 token0balance = ERC20(WETH).balanceOf(address(this));
       uint256 token1balance = ERC20(USDC).balanceOf(address(this));

        // interactions, second parameter is receiver of tokens.
        BalanceDelta delta = abi.decode(
            manager.lock(
                abi.encodeCall(
                    this.handleModifyPosition, abi.encode(CallbackData(msg.sender, address(this), poolKey, liquidationParams, hookLiquidationData))
                )
            ),
            (BalanceDelta)
        );

        //After the call, balances should be settled and we should receive positions tokens back here.
        token0balance = ERC20(WETH).balanceOf(address(this)) - token0balance; //get actual received token0 amount after withdrawing position
        token1balance = ERC20(USDC).balanceOf(address(this)) - token1balance; //get actual received token1 amount after withdrawing position

        console2.log("ETH balance after actual liquidation %e", token0balance);
        console2.log("USDC balance after actual liquidation %e", token1balance);
        
        IERC20(WETH).transferFrom(address(this), msg.sender, (token0balance*liquidationPremium)/100); //send 20% ETH to liquidator as liquidation premium
        IERC20(USDC).transferFrom(address(this), msg.sender, (token1balance*liquidationPremium)/100); //send 20% USDc to liquidator as liquidation premium

        IERC20(WETH).transferFrom(address(this),address(owner),(token0balance*(100-liquidationPremium)/100)); //send 80% ETH to original user 
        IERC20(USDC).transferFrom(address(this),address(owner),(token1balance*(100-liquidationPremium)/100)); //send 80% USDC to original user 

        return(userPosition[owner].debt == 0);
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
        console2.log("Max borrow amount %e", _getUserLiquidityPriceUSD(user).sub((UD60x18.wrap(userPosition[user].debt)).div(UD60x18.wrap(10**ERC20(GHO).decimals()))).mul(maxLTVUD60x18).unwrap());
        console2.log("user collateral value in USD %e", _getUserLiquidityPriceUSD(user).unwrap() / 10**18);
        console2.log("ahhhh %e", (UD60x18.wrap((amount+ userPosition[user].debt)).div(UD60x18.wrap(10**ERC20(GHO).decimals()))).div(maxLTVUD60x18).unwrap());
        //get user position price in USD, then check if borrow amount + debt already owed (adjusted to GHO decimals) is inferior to maxLTV (80% = maxLTV/100)
        if(_getUserLiquidityPriceUSD(user).lte((UD60x18.wrap((amount+ userPosition[user].debt)).div(UD60x18.wrap(10**ERC20(GHO).decimals()))).div(maxLTVUD60x18))){ 
            revert("user LTV is superior to maximum LTV"); //TODO add proper error message
        }
        userPosition[user].debt =  userPosition[user].debt + amount;
        console2.log("user debt after borrow %e", userPosition[user].debt);
        IGhoToken(GHO).mint(user, amount);
    
    }

    function viewGhoDebt(address user) public view returns (uint256){
        return userPosition[user].debt;
    }

    function repayGho(uint256 amount, address user) public returns (bool){
        //check if user has debt already
        if(userPosition[user].debt < amount){
            revert("user debt is inferior to amount to repay");
        }
        //check if user has enough GHO to repay, need to approve first then repay 
        bool isSuccess = ERC20(GHO).transferFrom(user, address(this), amount); //send GHO to this address then burning it
        if(!isSuccess){
            revert("transferFrom failed");
            return false;
        }else{
            IGhoToken(GHO).burn(amount);
            userPosition[user].debt = userPosition[user].debt - amount;
            return true;
        }
        
    }

    function _getUserLiquidityPriceUSD(address user) internal view returns (UD60x18){
        
        BorrowerPosition memory borrowerPosition = userPosition[user];
        Position memory positionParams = borrowerPosition.position;
        PoolKey memory key = positionParams.poolKey;

        (uint160 sqrtPriceX96, int24 currentTick, ,  ) = manager.getSlot0(key.toId()); //curent price and tick of the pool
        //get user liquidity position stored when adding liquidity
        
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

        console2.log("token0 amount %e", token0amountUD60x18.unwrap());
        console2.log("token1 amount %e", token1amountUD60x18.unwrap());

        //Price feed from Chainlink, convert to UD60x18 to avoid overflow errors
        UD60x18 ETHPrice = UD60x18.wrap(uint256(ETHPriceFeed.latestAnswer())).div(UD60x18.wrap(10**ETHPriceFeed.decimals()));
        UD60x18 USDCPrice = UD60x18.wrap(uint256(USDCPriceFeed.latestAnswer())).div(UD60x18.wrap(10**USDCPriceFeed.decimals()));

        //Price value of each token in the position
        UD60x18 token0Price = token0amountUD60x18.mul(USDCPrice);
        UD60x18 token1Price = token1amountUD60x18.mul(ETHPrice);

        console2.log("token0 price %e", token0Price.unwrap());
        console2.log("token1 price %e", token1Price.unwrap());
      
        //return price value of the position as UD60x18
        return token0Price.add(token1Price);

    }




    function getUserPositonPriceUSD(address user) public view returns (uint256){
        return _getUserLiquidityPriceUSD(user).unwrap() / 10**18;
    }

    function getUserCurrentLTV(address user) public view returns (UD60x18){
        UD60x18 userPositionValueUDx60 = _getUserLiquidityPriceUSD(user); //user position value
        UD60x18 userDebtUDx60 = UD60x18.wrap(userPosition[user].debt).div(UD60x18.wrap(10**ERC20(GHO).decimals())); //user debt, adjusted to GHO decimals

        return userDebtUDx60.div(userPositionValueUDx60); //return LTV 0 < LTV < 100
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
        UD60x18 userDebt = UD60x18.wrap(userPosition[user].debt).div(UD60x18.wrap(10**ERC20(GHO).decimals()));
        /*
        console2.log("position value after withdraw %e", _positionValueAfterWithdraw.unwrap());
        console2.log("ltv is %e", maxLTVUD60x18.unwrap());
        console2.log("user debt USD %e", userDebt.unwrap() );
        console2.log("withdraw ltv calc %s", userDebt.div(_positionValueAfterWithdraw).lte(maxLTVUD60x18));
        */
        if(_positionValueAfterWithdraw.isZero() && userPosition[user].debt == 0){
            //If user has no debt and withdraw all his position, he can withdraw
            return true;
        }else if(_positionValueAfterWithdraw.isZero() && userPosition[user].debt > 0){
            //If user has debt and withdraw all his position, he cannot withdraw
            return false;
        }
        if(!_positionValueAfterWithdraw.isZero() && userDebt.div(_positionValueAfterWithdraw).lte(maxLTVUD60x18)){
            //If user has debt and withdraw part of his position, check if debt / (position price - withdraw liquidity amount) is inferior to maxLTV (=77%)
            console2.log("user LTV after withdraw %e", UD60x18.wrap(userPosition[user].debt).div((UD60x18.wrap((10**ERC20(GHO).decimals()))).div(_positionValueAfterWithdraw)).unwrap());
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

    function getLiquidableUsers() public view returns (address[] memory){
        address[] memory liquidableUsers;
        //loop through users, see if they are liquidable
        uint24 liquidableUsersCount = 0;
         for (uint i = 0; i < users.size(); i++) {
           if(getUserCurrentLTV(users.getKeyAtIndex(i)) >= maxLTVUD60x18){
                console2.log("user %s is liquidable", users.getKeyAtIndex(i));
                liquidableUsers[liquidableUsersCount] = (users.getKeyAtIndex(i));
                liquidableUsersCount++;
           }
        }
        return liquidableUsers;
    }
}
