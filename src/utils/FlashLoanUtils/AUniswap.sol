// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Errors} from "./Errors.sol";
import {ISwapRouter} from "./uniswap/ISwapRouter.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {EtherUtils} from "./EtherUtils.sol";
import {console2} from "forge-std/console2.sol";
import {IQuoterV2} from "./uniswap/IQuoterV2.sol";
import {TransferHelper} from "v4-periphery/libraries/TransferHelper.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

 

/// @title AUniswap
/// @author centonze.eth
/// @notice Utility functions related to Uniswap operations.
abstract contract AUniswap is EtherUtils {
    using SafeTransferLib for ERC20;

    // The uniswap pool fee for each token.
    mapping(address => uint24) public uniswapFees;
    // Address of Uniswap V3 router
    ISwapRouter public swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IQuoterV2 public quoteRouter = IQuoterV2(0x61fFE014bA17989E743c5F6cB21bF9697530B21e);

    address GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;


    uint24 fee1 = 3000; //fee tier of 0.05%
    uint24 fee2 = 500; //fee tier of 0.05%

    /// @notice Emitted when the Uniswap router address is updated.
    /// @param newRouter The address of the new router.
    event SetUniswapRouter(address newRouter);

    /// @notice Emitted when the Uniswap fee for a token is updated.
    /// @param token The token whose fee has been updated.
    /// @param fee The new fee value.
    event SetUniswapFee(address indexed token, uint24 fee);

    /// @notice Sets a new address for the Uniswap router.
    /// @param _swapRouter The address of the new router.
    function setUniswapRouter(address _swapRouter) external onlyOwner {
        if (_swapRouter == address(0)) revert Errors.ZeroAddress();
        swapRouter = ISwapRouter(_swapRouter);

        emit SetUniswapRouter(_swapRouter);
    }

    /// @dev Internal function to set Uniswap fee for a token.
    /// @param token The token for which to set the fee.
    /// @param fee The fee to be set.
    function _setUniswapFee(address token, uint24 fee) internal {
        uniswapFees[token] = fee;

        emit SetUniswapFee(token, fee);
    }

    /// @dev Resets allowance for the Uniswap router for a specific token.
    /// @param token The token for which to reset the allowance.
    function _resetUniswapAllowance(address token) internal {
        ERC20(token).safeApprove(address(swapRouter), type(uint256).max);
    }

    /// @dev Removes allowance for the Uniswap router for a specific token.
    /// @param token The token for which to remove the allowance.
    function _removeUniswapAllowance(address token) internal {
        ERC20(token).safeApprove(address(swapRouter), 0);
    }

    /// @dev Converts a given amount of GHO into DAI using Uniswap.
    /// @param amountIn The amount of token to be swapped.
    /// @param minAmountOut The minimum amount of GHO expected in return.
    /// @return amountOut The amount of DAI received from the swap.
    function _swapWETHtoGHO(uint256 amountIn, uint256 minAmountOut) internal returns (uint256 amountOut) {
        ISwapRouter.ExactInputParams memory params =
            ISwapRouter.ExactInputParams({
                path: abi.encodePacked(WETH, fee1, USDC, fee2, DAI),
                recipient: msg.sender,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut
        });

        amountOut = swapRouter.exactInput(params);
    }

     function _swapExactInputMultihop(uint256 amountIn) internal returns (uint256 amountOut) {
        // Transfer `amountIn` of DAI to this contract.
        bool isSuccess = IERC20(WETH).transferFrom(msg.sender, address(this), amountIn);

        // Approve the router to spend DAI.
        IERC20(WETH).approve(address(swapRouter), amountIn);

        console2.log("msg sender", msg.sender);

        // Multiple pool swaps are encoded through bytes called a `path`. A path is a sequence of token addresses and poolFees that define the pools used in the swaps.
        // The format for pool encoding is (tokenIn, fee, tokenOut/tokenIn, fee, tokenOut) where tokenIn/tokenOut parameter is the shared token across the pools.
        // Since we are swapping DAI to USDC and then USDC to WETH9 the path encoding is (DAI, 0.3%, USDC, 0.3%, WETH9).
        ISwapRouter.ExactInputParams memory params =
            ISwapRouter.ExactInputParams({
                path: abi.encodePacked(WETH, fee1, USDC, fee2, GHO),
                recipient: msg.sender,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0
            });

        // Executes the swap.
        amountOut = swapRouter.exactInput(params);
    }


    function _quoteSwapToGHOfromWETH(uint256 amountIn) internal returns (uint256 amountOut, uint256 gasEstimate) {
        (amountOut,,, gasEstimate) =
            quoteRouter.quoteExactOutput(bytes(abi.encodePacked(GHO, fee1, USDC, fee2, WETH)), amountIn);
    }

    function _quoteSwapToGHOfromUSDC(uint256 amountIn) internal returns (uint256 amountOut, uint256 gasEstimate) {
        (amountOut,,, gasEstimate) =
            quoteRouter.quoteExactOutput(bytes(abi.encodePacked(GHO, fee1, USDC)), amountIn);
    }

    /// @dev Converts a given amount of DAI into GHO using Uniswap.
    /// @param amountIn The amount of token to be swapped.
    /// @return amountOut The amount of USDC required from the swap.
    function _swapUSDCToGHO(uint256 amountIn, uint256 minAmountOut) internal returns (uint256 amountOut) {

        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: USDC,
                tokenOut: GHO,
                fee: fee1,
                recipient: msg.sender,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            });
         // Executes the swap 
        amountOut = swapRouter.exactInputSingle(params);



       
    }
}
