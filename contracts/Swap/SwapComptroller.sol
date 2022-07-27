// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import "../Access/LocatorBasedProxyV2.sol";
import "./interfaces/IUniswapV2Pair.sol";
import './interfaces/IERC20.sol';
import "./interfaces/IPriceOracle.sol";
import "./libraries/UniswapV2Library.sol";
import "hardhat/console.sol";

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
        return(address(priceOracles[token0].oracle) != address(0) || address(priceOracles[token1].oracle) != address(0));
    }

    function getOracle(address tokenA, address tokenB) public view returns (OracleInfo memory oracle, address oracleToken, uint256 unitAmount) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        OracleInfo memory oracle0 = priceOracles[token0];
        OracleInfo memory oracle1 = priceOracles[token1];

        uint8 decimals0 = IERC20(token0).decimals();
        uint8 decimals1 = IERC20(token1).decimals();

        if (address(oracle0.oracle) != address(0) && (address(oracle1.oracle) == address(0) || decimals0 >= decimals1)) {
            return (oracle0,  token0, 10 ** decimals0);
        } else if (address(oracle1.oracle) != address(0)) {
            return (oracle1,  token1, 10 ** decimals1);
        }
    }

    function getRequiredFee(address token0, address token1, uint256 amount0, uint256 amount1) external view returns (uint256) {
        (OracleInfo memory oracle, address oracleToken, uint256 unitAmount) = getOracle(token0, token1);
        return _getRequiredFee(oracle, unitAmount, oracleToken == token0 ? amount0 : amount1, discountedFee());
    }

    function _getRequiredFee(OracleInfo memory oracleInfo, uint256 unitAmount, uint256 amount, uint256 feeRate) public view returns (uint256) {
        require(address(oracleInfo.oracle) != address(0), "no available oracle for tokens");
        uint256 amountInUsd = amount * oracleInfo.oracle.getLatestPrice() / unitAmount;
        uint256 pricePrecision = 10 ** oracleInfo.decimals;

        OracleInfo memory feeOracleInfo = priceOracles[feeToken];
        require(address(feeOracleInfo.oracle) != address(0), "fee token oracle required");
        uint256 feePricePrecision = 10 ** feeOracleInfo.decimals;

        uint256 feeUnitAmount = 10 ** IERC20(feeToken).decimals();
        return ((amountInUsd * feeUnitAmount / pricePrecision) * feePricePrecision / feeOracleInfo.oracle.getLatestPrice()) * feeRate / 1e4;
    }

    function _swapPairWithFee(
        IZeroSwapPair pair,
        OracleInfo memory oracleInfo,
        address oracleToken,
        uint256 unitAmount,
        address token0,
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes memory data
    ) internal returns (uint256 requiredFee) {
        (uint256 amount0In, uint256 amount1In) = pair.swapInFeeRate(amount0Out, amount1Out, 0, to, data);

        uint256 feeRate = discountedFee();
        requiredFee = _getRequiredFee(
            oracleInfo,
            unitAmount,
            oracleToken == token0 ? amount0In + amount0Out : amount1In + amount1Out,
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
        (OracleInfo memory oracleInfo, address oracleToken, uint256 unitAmount) = getOracle(tokenA, tokenB);

        // reserves before swap
        uint256 requiredFee = _swapPairWithFee(pair, oracleInfo, oracleToken, unitAmount, tokenA, amountAOut, amountBOut, to, data);

        uint256 feeBalance = IERC20(feeToken).balanceOf(address(this));
        require(feeBalance - feeReserve >= requiredFee, "Not enough fee token received");
        feeReserve += requiredFee;
        receivedFeeForPair[address(pair)] = requiredFee;
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    function setDiscountRate(uint256 _discountRate) external onlyManager {
        require(_discountRate >= 0 && _discountRate <= 1e6, "out of discount range");
        discountRate = _discountRate;
    }

    function setFeeToken(address _feeToken) external onlyManager {
        feeToken = _feeToken;
    }

    function setPriceOracle(address token, address _oracleAddress) external onlyManager {
        IPriceOracle oracle = IPriceOracle(_oracleAddress);
        if (_oracleAddress == address(0)) {
            priceOracles[token] = OracleInfo(oracle, 0);
        } else {
            // validate oracle
            uint256 decimals = oracle.getDecimals();
            require(uint256(uint8(decimals)) == decimals, "invalid decimals");
            priceOracles[token] = OracleInfo(oracle, uint8(decimals));
        }
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
        uint256 tokenFee = fee > discountRate ? fee - discountRate : 0;
        for (uint256 i; i < path.length - 1; i++) {
            (uint256 reserveIn, uint256 reserveOut) = UniswapV2Library.getReserves(
                factory,
                path[i],
                path[i + 1]
            );
            (OracleInfo memory oracleInfo, address oracleToken, uint256 unitAmount) = getOracle(path[i], path[i + 1]);
            if (address(oracleInfo.oracle) == address(0)) {
                amounts[i + 1] = UniswapV2Library.getAmountOut(amounts[i], reserveIn, reserveOut, fee);
            } else {
                amounts[i + 1] = UniswapV2Library.getAmountOut(amounts[i], reserveIn, reserveOut, 0);
                requiredFee += _getRequiredFee(oracleInfo, unitAmount, oracleToken == path[i] ? amounts[i] : amounts[i + 1], tokenFee);
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
        uint256 tokenFee = fee > discountRate ? fee - discountRate : 0;
        for (uint256 i = path.length - 1; i > 0; i--) {
            address tokenIn = path[i - 1];
            address tokenOut = path[i];

            (uint256 reserveIn, uint256 reserveOut) = UniswapV2Library.getReserves(factory, tokenIn, tokenOut);

            (OracleInfo memory oracleInfo, address oracleToken, uint256 unitAmount) = getOracle(tokenIn, tokenOut);
            if (address(oracleInfo.oracle) == address(0)) {
                amounts[i - 1] = UniswapV2Library.getAmountIn(amounts[i], reserveIn, reserveOut, fee);
            } else {
                amounts[i - 1] = UniswapV2Library.getAmountIn(amounts[i], reserveIn, reserveOut, 0);
                requiredFee += _getRequiredFee(oracleInfo, unitAmount, oracleToken == tokenIn ? amounts[i - 1] : amounts[i], tokenFee);
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
