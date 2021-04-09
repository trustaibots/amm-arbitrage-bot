//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import 'hardhat/console.sol';

import './interfaces/IUniswapV2Pair.sol';
import './interfaces/IWETH.sol';
import './libraries/Decimal.sol';
import './libraries/SafeMath.sol';

struct OrderedReserves {
    uint256 a1; // base asset
    uint256 b1;
    uint256 a2;
    uint256 b2;
}

struct PoolReserves {
    uint256 pool0Reserve0;
    uint256 pool0Reserve1;
    uint256 pool1Reserve0;
    uint256 pool1Reserve1;
}

struct ArbitrageInfo {
    address baseToken;
    address quoteToken;
    bool baseTokenSmaller;
    address lowerPool; // pool with lower price, denominated in quote asset
    address higherPool; // pool with higher price, denominated in quote asset
}

struct CallbackData {
    address debtPool;
    address targetPool;
    bool debtTokenSmaller;
    address borrowedToken;
    address debtToken;
    uint256 debtAmount;
    uint256 debtTokenOutAmount;
}

contract FlashBot is Ownable {
    using Decimal for Decimal.D256;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ACCESS CONTROL
    // Only the `permissionedPairAddress` may call the `uniswapV2Call` function
    address permissionedPairAddress = address(1);

    // WETH on ETH or WBNB on BSC
    address WETH;

    // AVAILABLE BASE TOKENS
    EnumerableSet.AddressSet baseAssets;

    event Withdrawn(address indexed to, uint256 indexed value);
    event BaseAssetAdded(address indexed token);
    event BaseAssetRemoved(address indexed token);

    modifier validatePair(address pool0, address pool1) {
        require(pool0 != pool1, 'Same pair address');
        (address pool0Token0, address pool0Token1) = (IUniswapV2Pair(pool0).token0(), IUniswapV2Pair(pool0).token1());
        (address pool1Token0, address pool1Token1) = (IUniswapV2Pair(pool1).token0(), IUniswapV2Pair(pool1).token1());
        require(pool0Token0 == pool1Token0, 'Require same token0');
        require(pool0Token1 == pool1Token1, 'Require same token1');
        require(baseAssetsContains(pool0Token0) || baseAssetsContains(pool0Token1), 'No base asset in pair');
        _;
    }

    constructor(address _WETH) {
        WETH = _WETH;
        baseAssets.add(_WETH);
    }

    receive() external payable {}

    function withdraw() external {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            payable(owner()).transfer(balance);
            emit Withdrawn(owner(), balance);
        }
    }

    function addBaseAsset(address token) external onlyOwner {
        baseAssets.add(token);
        emit BaseAssetAdded(token);
    }

    function removeBaseAsset(address token) external onlyOwner {
        baseAssets.remove(token);
        emit BaseAssetRemoved(token);
    }

    function baseAssetsContains(address token) public view returns (bool) {
        return baseAssets.contains(token);
    }

    function isbaseTokenSmaller(address pool0, address pool1)
        internal
        view
        returns (
            bool baseSmaller,
            address baseToken,
            address quoteToken
        )
    {
        require(pool0 != pool1, 'Same pair address');
        (address pool0Token0, address pool0Token1, address pool1Token0, address pool1Token1) =
            (
                IUniswapV2Pair(pool0).token0(),
                IUniswapV2Pair(pool0).token1(),
                IUniswapV2Pair(pool1).token0(),
                IUniswapV2Pair(pool1).token1()
            );
        require(pool0Token0 < pool0Token1 && pool1Token0 < pool1Token1, 'Non standard uniswap AMM pair');
        require(pool0Token0 == pool1Token0 && pool0Token1 == pool1Token1, 'Require same token pair');
        require(baseAssetsContains(pool0Token0) || baseAssetsContains(pool0Token1), 'No base asset in pair');

        (baseSmaller, baseToken, quoteToken) = baseAssetsContains(pool0Token0)
            ? (true, pool0Token0, pool0Token1)
            : (false, pool0Token1, pool0Token0);
    }

    /// @notice Do an arbitrage between two Uniswap-like AMM pools
    /// @dev Two pools must contains same token pair
    function flashArbitrage(address pool0, address pool1) external validatePair(pool0, pool1) {
        ArbitrageInfo memory info;
        (info.baseTokenSmaller, info.baseToken, info.quoteToken) = isbaseTokenSmaller(pool0, pool1);

        PoolReserves memory reserves;
        (reserves.pool0Reserve0, reserves.pool0Reserve1, ) = IUniswapV2Pair(pool0).getReserves();
        (reserves.pool1Reserve0, reserves.pool1Reserve1, ) = IUniswapV2Pair(pool1).getReserves();

        // Calculate the price denominated in quote asset token
        (Decimal.D256 memory price0, Decimal.D256 memory price1) =
            info.baseTokenSmaller
                ? (
                    Decimal.from(reserves.pool0Reserve0).div(reserves.pool0Reserve1),
                    Decimal.from(reserves.pool1Reserve0).div(reserves.pool1Reserve1)
                )
                : (
                    Decimal.from(reserves.pool0Reserve1).div(reserves.pool0Reserve0),
                    Decimal.from(reserves.pool1Reserve1).div(reserves.pool1Reserve0)
                );

        // Compare price denominated in quote asset between two pools
        // We borrow base asset by using flash swap from lower price pool and sell them to higher price pool
        OrderedReserves memory orderedReserves;

        // get a1, b1, a2, b2 with following rule:
        // 1. (a1, b1) represents the pool with lower price,
        // 2. (a1, a2) is the base asset reserves in two pools
        if (price0.lessThan(price1)) {
            (info.lowerPool, info.higherPool) = (pool0, pool1);
            (orderedReserves.a1, orderedReserves.a2, orderedReserves.b1, orderedReserves.b2) = info.baseTokenSmaller
                ? (reserves.pool0Reserve0, reserves.pool0Reserve1, reserves.pool1Reserve0, reserves.pool1Reserve1)
                : (reserves.pool0Reserve1, reserves.pool0Reserve0, reserves.pool1Reserve1, reserves.pool1Reserve0);
        } else {
            (info.lowerPool, info.higherPool) = (pool1, pool0);
            (orderedReserves.a1, orderedReserves.a2, orderedReserves.b1, orderedReserves.b2) = info.baseTokenSmaller
                ? (reserves.pool1Reserve0, reserves.pool1Reserve1, reserves.pool0Reserve0, reserves.pool0Reserve1)
                : (reserves.pool1Reserve1, reserves.pool1Reserve0, reserves.pool0Reserve1, reserves.pool0Reserve0);
        }

        // this must be updated every transaction for callback origin authentication
        permissionedPairAddress = info.lowerPool;

        uint256 balanceBefore = IERC20(info.baseToken).balanceOf(address(this));

        // avoid stack too deep error
        {
            uint256 borrowAmount = calcBorrowAmount(orderedReserves);
            (uint256 amount0Out, uint256 amount1Out) =
                info.baseTokenSmaller ? (uint256(0), borrowAmount) : (borrowAmount, uint256(0));
            // borrow quote token on lower price pool, calculate how much debt we need to pay in base token
            uint256 debtAmount = getAmountIn(borrowAmount, orderedReserves.a1, orderedReserves.b1);
            // sell borrowed quote token on higher price pool, calculate how much base token we can get
            uint256 baseAssetOutAmount = getAmountOut(borrowAmount, orderedReserves.b2, orderedReserves.a2);
            require(baseAssetOutAmount > debtAmount, 'Arbitrage fail, not profit');

            // can only initialize this way to avoid stack too deep error
            CallbackData memory callbackData;
            callbackData.debtPool = info.lowerPool;
            callbackData.targetPool = info.higherPool;
            callbackData.debtTokenSmaller = info.baseTokenSmaller;
            callbackData.borrowedToken = info.quoteToken;
            callbackData.debtToken = info.baseToken;
            callbackData.debtAmount = debtAmount;
            callbackData.debtTokenOutAmount = baseAssetOutAmount;

            bytes memory data = abi.encode(callbackData);
            IUniswapV2Pair(info.lowerPool).swap(amount0Out, amount1Out, address(this), data);
        }

        uint256 balanceAfter = IERC20(info.baseToken).balanceOf(address(this));
        require(balanceAfter > balanceBefore, 'Losing money');

        if (info.baseToken == WETH) {
            IWETH(info.baseToken).withdraw(balanceAfter);
        }
        permissionedPairAddress = address(1);
    }

    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external {
        // access control
        require(msg.sender == permissionedPairAddress, 'Non permissioned address call');
        require(sender == address(this), 'Not from this contract');

        uint256 borrowedAmount = amount0 > 0 ? amount0 : amount1;
        CallbackData memory info = abi.decode(data, (CallbackData));

        IERC20(info.borrowedToken).safeTransfer(info.targetPool, borrowedAmount);

        (uint256 amount0Out, uint256 amount1Out) =
            info.debtTokenSmaller ? (info.debtTokenOutAmount, uint256(0)) : (uint256(0), info.debtTokenOutAmount);
        IUniswapV2Pair(info.targetPool).swap(amount0Out, amount1Out, address(this), new bytes(0));

        IERC20(info.debtToken).safeTransfer(info.debtPool, info.debtAmount);
    }

    /// @dev calculate the maximum base asset amount to borrow in order to get maximum profit during arbitrage
    function calcBorrowAmount(OrderedReserves memory reserves) internal pure returns (uint256 amount) {
        (int256 a1, int256 a2, int256 b1, int256 b2) =
            (int256(reserves.a1), int256(reserves.a2), int256(reserves.b1), int256(reserves.b2));

        int256 a = a1 * b1 - a2 * b1;
        int256 b = 2 * b1 * b2 * (a1 + a2);
        int256 c = b1 * b2 * (a1 * b2 - a2 * b1);

        return calcSolutionForQuadratic(a, b, c);
    }

    /// @dev find solution of quadratic equation: ax^2 + bx + c = 0, only return the positive solution
    function calcSolutionForQuadratic(
        int256 a,
        int256 b,
        int256 c
    ) internal pure returns (uint256 x) {
        int256 m = b**2 - 4 * a * c;
        // m < 0 leads to complex number
        assert(m > 0);

        int256 sqrtM = int256(sqrt(uint256(m)));
        int256 x1 = (-b + sqrtM) / (2 * a);
        int256 x2 = (-b - sqrtM) / (2 * a);
        // at least a positive result
        assert(x1 > 0 || x2 > 0);
        x = x1 > 0 ? uint256(x1) : uint256(x2);
    }

    /// @dev Newton’s method for caculating square root of n
    function sqrt(uint256 n) internal pure returns (uint256 res) {
        assert(n > 1);

        // The scale factor is a crude way to turn everything into integer calcs.
        // Actually do (n * 10 ^ 6) ^ (1/2)
        uint256 _n = n * 10**6;
        uint256 c = _n;
        res = _n;

        uint256 xi;
        while (true) {
            xi = (res + c / res) / 2;
            // don't need be too precise to save gas
            if (res - xi < 1000) {
                break;
            }
            res = xi;
        }
        res = res / 10**3;
    }

    // copy from UniswapV2Library
    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, 'UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        uint256 numerator = reserveIn.mul(amountOut).mul(1000);
        uint256 denominator = reserveOut.sub(amountOut).mul(997);
        amountIn = (numerator / denominator).add(1);
    }

    // copy from UniswapV2Library
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, 'UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        uint256 amountInWithFee = amountIn.mul(997);
        uint256 numerator = amountInWithFee.mul(reserveOut);
        uint256 denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }
}
