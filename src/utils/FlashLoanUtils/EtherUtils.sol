// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title EtherUtils
/// @author centonze.eth
/// @dev Utility contract providing functions to manage WETH allowances.
/// Inherits from Ownable2Step to provide two-step ownership management.
abstract contract EtherUtils is Ownable2Step {
    using SafeTransferLib for ERC20;

    // The WETH token address on Ethereum mainnet.
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @dev Internal function to maximize the WETH allowance for a target address.
    /// @param target The address for which the WETH allowance will be set to max.
    function _resetWethAllowance(address target) internal {
        ERC20(WETH).safeApprove(target, type(uint256).max);
    }

    /// @dev Internal function to remove the WETH allowance for a target address.
    /// @param target The address for which the WETH allowance will be removed.
    function _removeWethAllowance(address target) internal {
        ERC20(WETH).safeApprove(target, 0);
    }
}
