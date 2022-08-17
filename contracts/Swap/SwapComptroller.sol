// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import "../Access/LocatorBasedProxyV2.sol";
import "./interfaces/IUniswapV2Pair.sol";
import './interfaces/IERC20.sol';
import "./interfaces/IPriceOracle.sol";
import "./libraries/UniswapV2Library.sol";

interface IZeroSwapPair is IUniswapV2Pair {
    function swapInFeeRate(uint amount0Out, uint amount1Out, uint256 feeRate, address to, bytes calldata data) external returns (uint256, uint256);
}

contract SwapComptroller is LocatorBasedProxyV2 {
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory;
    mapping(address => OracleInfo) public priceOracles;
    uint256 public discountRate; // 0 for no discount, 10000 for 100% discount, substracted from feeRate, 1e4
    uint256 public fee;
    address public feeTo;
    address public feeToken;
    uint256 public feeReserve;
    mapping(address => uint256) public receivedFeeForPair;
    address public pivotToken;

    struct OracleInfo {
        IPriceOracle oracle;
        uint8 decimals;
    }

    modifier onlyManager() {
        managerPermissionRequired();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _locatorAddress,
        address _factory,
        address _feeToken,
        uint256 _fee,
        uint256 _discountRate
    ) public initializer {
        require(_discountRate >= 0 && _discountRate <= 1e6, "out of discount range");

        LocatorBasedProxyV2.initializeLocatorBasedProxy(_locatorAddress);

        factory = _factory;
        feeToken = _feeToken;
        fee = _fee;
        discountRate = _discountRate;
    }

    function discountedFee() public view returns (uint256) {
        return fee > discountRate ? fee - discountRate : 0;
    }

    function isDiscountable(address token0, address token1) public view returns (bool) {
        return feeToken != address(0) && pivotToken != address(0) && (token0 == pivotToken || token1 == pivotToken || token0 == feeToken || token1 == feeToken);
    }

    // function getOracle(address tokenA, address tokenB) public view returns (OracleInfo memory oracle, address oracleToken, uint256 unitAmount) {
    //     if (tokenA == feeToken || tokenB == feeToken) {
    //         return (priceOracles[feeToken], feeToken, 10 ** IERC20(feeToken).decimals());
    //     }
    //     (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    //     OracleInfo memory oracle0 = priceOracles[token0];
    //     OracleInfo memory oracle1 = priceOracles[token1];

    //     uint8 decimals0 = IERC20(token0).decimals();
    //     uint8 decimals1 = IERC20(token1).decimals();

    //     if (address(oracle0.oracle) != address(0) && (address(oracle1.oracle) == address(0) || decimals0 >= decimals1)) {
    //         return (oracle0,  token0, 10 ** decimals0);
    //     } else if (address(oracle1.oracle) != address(0)) {
    //         return (oracle1,  token1, 10 ** decimals1);
    //     }
    // }

    function getRequiredFee(address token0, address token1, uint256 amount0, uint256 amount1) external view returns (uint256) {
        uint256 feeRate = discountedFee();
        // (OracleInfo memory oracle, address oracleToken, uint256 unitAmount) = getOracle(token0, token1);
        return _getRequiredFee(token0, token1, amount0, amount1, feeRate);
    }

    function _getPivotPairReserves() view internal returns (uint256 pairFeeReserve, uint256 pairPivotReserve) {
        IZeroSwapPair pair = IZeroSwapPair(UniswapV2Library.pairFor(factory, pivotToken, feeToken));
        (address token0, ) = UniswapV2Library.sortTokens(pivotToken, feeToken);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (pairFeeReserve, pairPivotReserve) = token0 == pivotToken ? (r1, r0) : (r0, r1);
    }

    function _getRequiredFee(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint256 feeRate
    ) internal view returns (uint256) {
        (uint256 pairFeeReserve, uint256 pairPivotReserve) = (token0 != feeToken && token1 != feeToken) ? _getPivotPairReserves() : (1, 1);
        return _calcRequiredFeeFor(feeToken, pivotToken, pairFeeReserve, pairPivotReserve, token0, token1, amount0, amount1, feeRate);
    }

    function _calcRequiredFeeFor(
        address _feeToken,
        address _pivotToken,
        uint256 pairFeeReserve,
        uint256 pairPivotReserve,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint256 feeRate
    ) internal pure returns (uint256) {
        if (token0 == _feeToken) return amount0 * feeRate / 1e4;
        if (token1 == _feeToken) return amount1 * feeRate / 1e4;
        if (token0 == _pivotToken) {
            return ((amount0 * pairFeeReserve) / pairPivotReserve) * feeRate / 1e4;
        }
        if (token1 == _pivotToken) {
            return ((amount1 * pairFeeReserve) / pairPivotReserve) * feeRate / 1e4;
        }
        revert("pivot or fee token required");
    }

    function _swapPairWithFee(
        IZeroSwapPair pair,
        address token0,
        address token1,
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes memory data
    ) internal returns (uint256 requiredFee) {
        // save pair reserves before swap occurred
        (uint256 pairFeeReserve, uint256 pairPivotReserve) = _getPivotPairReserves();

        {
            // avoid stack too deep
            (uint256 amount0In, uint256 amount1In) = pair.swapInFeeRate(amount0Out, amount1Out, 0, to, data);
            amount0Out += amount0In;
            amount1Out += amount1In;
        }

        uint256 feeRate = discountedFee();
        requiredFee = _calcRequiredFeeFor(
            feeToken,
            pivotToken,
            pairFeeReserve,
            pairPivotReserve,
            token0,
            token1,
            amount0Out,
            amount1Out,
            feeRate);
    }

    function swap(address tokenA, address tokenB, uint256 amountAOut, uint256 amountBOut, address to, bytes memory data) public {
        IZeroSwapPair pair = IZeroSwapPair(UniswapV2Library.pairFor(factory, tokenA, tokenB));

        {
            // sort tokens & amounts
            (address token0, ) = UniswapV2Library.sortTokens(tokenA, tokenB);
            if (token0 != tokenA) {
                (tokenA, tokenB, amountAOut, amountBOut) = (tokenB, tokenA, amountBOut, amountAOut);
            }
        }
        if (!isDiscountable(tokenA, tokenB)) {
            pair.swap(amountAOut, amountBOut, to, data);
            return;
        }
        // reserves before swap
        uint256 requiredFee = _swapPairWithFee(pair, tokenA, tokenB, amountAOut, amountBOut, to, data);

        uint256 feeBalance = IERC20(feeToken).balanceOf(address(this));
        require(feeBalance - feeReserve >= requiredFee, "Not enough fee token received");
        feeReserve += requiredFee;
        receivedFeeForPair[address(pair)] += requiredFee;
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    function setDiscountRate(uint256 _discountRate) external onlyManager {
        require(_discountRate >= 0 && _discountRate <= 1e6, "out of discount range");
        discountRate = _discountRate;
    }

    function setFeeToken(address _token) external onlyManager {
        feeToken = _token;
    }

    function setPivotToken(address _token) external onlyManager {
        pivotToken = _token;
    }

    function recoverERC20(address token, address to, uint256 amount) external onlyManager {
        require(token != feeToken, "use withdrawFee");
        _safeTransfer(token, to, amount);
    }

    function withdrawFee(address to, uint256 amount) external onlyManager {
        _safeTransfer(feeToken, to, amount);
        feeReserve -= amount;
    }

    function skimFee(address to) external {
        uint256 skimable = IERC20(feeToken).balanceOf(address(this)) - feeReserve;
        if (skimable > 0) {
            _safeTransfer(feeToken, to, skimable);
        }
    }

    // performs chained getAmountOut calculations on any number of pairs
    function getAmountsOut(
        uint256 amountIn,
        address[] memory path
    ) external view returns (uint256[] memory amounts, uint256 requiredFee) {
        require(path.length >= 2, "UniswapV2Library: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        (uint256 pairFeeReserve, uint256 pairPivotReserve) = _getPivotPairReserves();
        uint256 tokenFee = discountedFee();
        for (uint256 i; i < path.length - 1; i++) {
            (uint256 reserveIn, uint256 reserveOut) = UniswapV2Library.getReserves(
                factory,
                path[i],
                path[i + 1]
            );
            if (!isDiscountable(path[i], path[i + 1])) {
                amounts[i + 1] = UniswapV2Library.getAmountOut(amounts[i], reserveIn, reserveOut, fee);
            } else {
                amounts[i + 1] = UniswapV2Library.getAmountOut(amounts[i], reserveIn, reserveOut, 0);

                requiredFee += _calcRequiredFeeFor(feeToken, pivotToken, pairFeeReserve, pairPivotReserve, path[i], path[i + 1], amounts[i], amounts[i + 1], tokenFee);
            }

            if (path[i] == feeToken && path[i + 1] == pivotToken) {
                pairFeeReserve += amounts[i];
                pairPivotReserve -= amounts[i + 1];
            } else if (path[i] == pivotToken && path[i + 1] == feeToken) {
                pairFeeReserve -= amounts[i + 1];
                pairPivotReserve += amounts[i];
            }
        }
    }

    // performs chained getAmountIn calculations on any number of pairs
    function getAmountsIn(
        uint256 amountOut,
        address[] memory path
    ) external view returns (uint256[] memory amounts, uint256 requiredFee) {
        require(path.length >= 2, "UniswapV2Library: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;

        (uint256 pairFeeReserve, uint256 pairPivotReserve) = _getPivotPairReserves();
        uint256 tokenFee = fee > discountRate ? fee - discountRate : 0;
        for (uint256 i = path.length - 1; i > 0; i--) {
            (uint256 reserveIn, uint256 reserveOut) = UniswapV2Library.getReserves(factory, path[i - 1], path[i]);

            if (!isDiscountable(path[i - 1], path[i])) {
                amounts[i - 1] = UniswapV2Library.getAmountIn(amounts[i], reserveIn, reserveOut, fee);
            } else {
                amounts[i - 1] = UniswapV2Library.getAmountIn(amounts[i], reserveIn, reserveOut, 0);

                requiredFee += _calcRequiredFeeFor(feeToken, pivotToken, pairFeeReserve, pairPivotReserve, path[i - 1], path[i], amounts[i - 1], amounts[i], tokenFee);
            }

            if (path[i - 1] == feeToken && path[i] == pivotToken) {
                pairFeeReserve += amounts[i - 1];
                pairPivotReserve -= amounts[i];
            } else if (path[i - 1] == pivotToken && path[i] == feeToken) {
                pairFeeReserve -= amounts[i];
                pairPivotReserve += amounts[i - 1];
            }
        }
    }

    function setFee(uint256 _fee) external onlyManager {
        fee = _fee;
    }

    function setFeeTo(address _feeTo) external onlyManager {
        feeTo = _feeTo;
    }
}
