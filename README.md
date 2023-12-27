# 🇬HOOk
### **An experimental Liquidity Position Manager for Uniswap v4 that allows a user to mint GHO**

> The codebase is tested on happy paths only. This should not be used in any production capacity

Add it to your project
```bash
forge install saucepoint/bungi
```

---

This project is part of my Bachelor's project at the Distributed Computing Laboratory of EPFL.
See the full report in GHOOK_Bachelor_Project_Report pdf.

[GHOOK_Bachelor_Project_Report.pdf](https://github.com/Loris-EPFL/bungi-position-manager-hook/files/13778277/GHOOK_Bachelor_Project_Report.pdf)



# Features

Until Uniswap Labs releases a canonical LP router (equivalent to v3's [NonfungiblePositionManager](https://github.com/Uniswap/v3-periphery/blob/main/contracts/NonfungiblePositionManager.sol)), there was a growing need for **an advanced LP router** with more features than the baseline [PoolModifyPositionTest](https://github.com/Uniswap/v4-core/blob/main/contracts/test/PoolModifyPositionTest.sol)


## 🇬HOOK liquidity position manager (LPM) supports:


- [x] Semi-fungible LP tokens ([ERC-6909](https://github.com/jtriley-eth/ERC-6909))

- [x] Gas efficient rebalancing. Completely (or partially) move assets from an existing position into a new range

- [x] Permissioned operators and managers. Delegate to a trusted party to manage your liquidity positions
    - **Allow a hook to modify and adjust your position(s)!**

- Mint GHO against your LP


---

# Usage

Deploy for tests

```solidity
// -- snip --
// (other imports)

import {Position, PositionId, PositionIdLibrary} from "bungi/src/types/PositionId.sol";
import {LiquidityPositionManager} from "bungi/src/LiquidityPositionManager.sol";

contract CounterTest is Test {
    using PositionIdLibrary for Position;
    LiquidityPositionManager lpm;

    function setUp() public {
        // -- snip --
        // (deploy v4 PoolManager)

        lpm = new LiquidityPositionManager(IPoolManager(address(manager)));
    }
}

```

Add Liquidity
```solidity
    // Mint 1e18 worth of liquidity on range [-600, 600]
    int24 tickLower = -600;
    int24 tickUpper = 600;
    uint256 liquidity = 1e18;
    
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

    // recieved 1e18 LP tokens (6909)
    Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
    assertEq(lpm.balanceOf(address(this), position.toTokenId()), liquidity);
```

Remove Liquidity
```solidity
    // assume liquidity has been provisioned
    int24 tickLower = -600;
    int24 tickUpper = 600;
    uint256 liquidity = 1e18;

    // remove all liquidity
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
```

Rebalance Liquidity
```solidity
    // lens-style contract to help with liquidity math
    LiquidityHelpers helper = new LiquidityHelpers(IPoolManager(address(manager)), lpm);

    // assume existing position has liquidity already provisioned
    Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});

    // removing all `liquidity`` from an existing position and moving it into a new range
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
```



---

Additional resources:

[v4-periphery](https://github.com/uniswap/v4-periphery)

[v4-core](https://github.com/uniswap/v4-core)

