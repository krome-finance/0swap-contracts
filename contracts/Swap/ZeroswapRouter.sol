// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IZeroswapComptroller.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/UniswapV2Library.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IWKLAY.sol";

contract ZeroswapRouter {
    // using SafeMath for uint256;

    address public factory;
    IZeroswapComptroller public swapComptroller;
    address public WKLAY;

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "UniswapV2Router: EXPIRED");
        _;
    }

    constructor(address _factory, address _WKLAY, address _swapComptroller) {
        factory = _factory;
        WKLAY = _WKLAY;
        swapComptroller = IZeroswapComptroller(_swapComptroller);
    }

    receive() external payable {
        assert(msg.sender == WKLAY); // only accept KLAY via fallback from the WKLAY contract
    }

    // **** ADD LIQUIDITY ****
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal returns (uint256 amountA, uint256 amountB) {
        // create the pair if it doesn't exist yet
        if (IUniswapV2Factory(factory).getPair(tokenA, tokenB) == address(0)) {
            IUniswapV2Factory(factory).createPair(tokenA, tokenB);
        }
        (uint256 reserveA, uint256 reserveB) = UniswapV2Library.getReserves(
            factory,
            tokenA,
            tokenB
        );
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = UniswapV2Library.quote(
                amountADesired,
                reserveA,
                reserveB
            );
            if (amountBOptimal <= amountBDesired) {
                require(
                    amountBOptimal >= amountBMin,
                    "UniswapV2Router: INSUFFICIENT_B_AMOUNT"
                );
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = UniswapV2Library.quote(
                    amountBDesired,
                    reserveB,
                    reserveA
                );
                assert(amountAOptimal <= amountADesired);
                require(
                    amountAOptimal >= amountAMin,
                    "UniswapV2Router: INSUFFICIENT_A_AMOUNT"
                );
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        ensure(deadline)
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {
        (amountA, amountB) = _addLiquidity(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = IUniswapV2Pair(pair).mint(to);
    }

    function addLiquidityKLAY(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountKLAYMin,
        address to,
        uint256 deadline
    )
        external
        payable
        ensure(deadline)
        returns (
            uint256 amountToken,
            uint256 amountKLAY,
            uint256 liquidity
        )
    {
        (amountToken, amountKLAY) = _addLiquidity(
            token,
            WKLAY,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountKLAYMin
        );
        address pair = UniswapV2Library.pairFor(factory, token, WKLAY);
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        IWKLAY(WKLAY).deposit{value: amountKLAY}();
        assert(IWKLAY(WKLAY).transfer(pair, amountKLAY));
        liquidity = IUniswapV2Pair(pair).mint(to);
        // refund dust KLAY, if any
        if (msg.value > amountKLAY)
            TransferHelper.safeTransferETH(msg.sender, msg.value - amountKLAY);
    }

    function _getRequiredFeeToAddLiquidityOptimal(
        address tokenIn,
        address tokenOut,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 amountInDesired,
        uint256 amountOutDesired
    ) internal view returns (uint256) {
        uint256 feeRate = swapComptroller.discountedFee();
        uint256 swapAmountIn = UniswapV2Library.getSwapInAmountToAddLiquidity(reserveIn, reserveOut, amountInDesired, amountOutDesired, feeRate);
        uint256 swapAmountOut = UniswapV2Library.getAmountOut(swapAmountIn, reserveIn, reserveOut, feeRate);
        // console.log("swap", swapAmountIn, swapAmountOut);
        // console.log("reserveIn", reserveIn, reserveIn + swapAmountIn);
        // console.log("reserveOut", reserveOut, reserveOut - swapAmountOut);
        // console.log("amountIn", amountInDesired, amountInDesired - swapAmountIn);
        // console.log("amountIOut", amountOutDesired, amountOutDesired + swapAmountOut );
        return swapComptroller.getRequiredFee(tokenIn, tokenOut, swapAmountIn, swapAmountOut);
    }

    function getRequiredFeeToAddLiquidityOptimal(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired
    ) external view returns (uint256) {
        bool discountable = swapComptroller.isDiscountable(tokenA, tokenB);
        if (!discountable) return 0;
        (uint256 reserveA, uint256 reserveB) = UniswapV2Library.getReserves(
            factory,
            tokenA,
            tokenB
        );
        if (reserveB * amountADesired >= reserveA * amountBDesired) {
            return _getRequiredFeeToAddLiquidityOptimal(tokenA, tokenB, reserveA, reserveB, amountADesired, amountBDesired);
        } else {
            return _getRequiredFeeToAddLiquidityOptimal(tokenB, tokenA, reserveB, reserveA, amountBDesired, amountADesired);
        }
    }

    function _swapToAddLiquidityOptimalInternalD1(
        address pair,
        address tokenIn,
        address tokenOut,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 amountInDesired,
        uint256 amountOutDesired,
        uint256 maxFee
    ) 
        internal
        returns (
            uint256 swapAmountIn,
            uint256 swapAmountOut
        )
    {
        bool discountable = swapComptroller.isDiscountable(tokenIn, tokenOut);
        uint256 feeRate = discountable ? swapComptroller.discountedFee() : swapComptroller.fee();
        swapAmountIn = UniswapV2Library.getSwapInAmountToAddLiquidity(reserveIn, reserveOut, amountInDesired, amountOutDesired, feeRate);
        swapAmountOut = UniswapV2Library.getAmountOut(swapAmountIn, reserveIn, reserveOut, feeRate);
        uint256 requiredFee = discountable ? swapComptroller.getRequiredFee(tokenIn, tokenOut, swapAmountIn, swapAmountOut) : 0;
        require(requiredFee <= maxFee, "ZeroswapRouter: EXCESSIVE_FEE");
        if (requiredFee > 0) {
            TransferHelper.safeTransferFrom(
                swapComptroller.feeToken(),
                msg.sender,
                address(swapComptroller),
                requiredFee
            );
        }

        TransferHelper.safeTransferFrom(
            tokenIn,
            msg.sender,
            pair,
            swapAmountIn
        );

        swapComptroller.swap(tokenIn, tokenOut, 0, swapAmountOut, address(this), new bytes(0));

        TransferHelper.safeTransfer(
            tokenOut,
            pair,
            swapAmountOut
        );
    }

    function _swapToAddLiquidityOptimalInternalD2(
        address pair,
        address tokenIn,
        address tokenOut,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 amountInDesired,
        uint256 amountOutDesired,
        uint256 amountInMin,
        uint256 amountOutMin,
        uint256 maxFee
    ) 
        internal
        returns (
            uint256 amountIn,
            uint256 amountOut
        )
    {
        uint256 swapAmountOut;
        // reuse to save local variable
        (amountIn, swapAmountOut) = _swapToAddLiquidityOptimalInternalD1(pair, tokenIn, tokenOut, reserveIn, reserveOut, amountInDesired, amountOutDesired, maxFee);
        (amountIn, amountOut) = _addLiquidity(
            tokenIn,
            tokenOut,
            amountInDesired - amountIn,
            amountOutDesired + swapAmountOut,
            amountInMin > amountIn ? amountInMin - amountIn : 0,
            amountOutMin + swapAmountOut
        );
        // reduce as already transfered to pair
        amountOut -= swapAmountOut;
    }

    function _swapToAddLiquidityOptimal(
        address pair,
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 maxFee
    )
        internal
        returns (
            uint256 amountA,
            uint256 amountB
        )
    {
        (uint256 reserveA, uint256 reserveB) = UniswapV2Library.getReserves(
            factory,
            tokenA,
            tokenB
        );
        {
            if (reserveB * amountADesired >= reserveA * amountBDesired) {
                (amountA, amountB) = _swapToAddLiquidityOptimalInternalD2(pair, tokenA, tokenB, reserveA, reserveB, amountADesired, amountBDesired, amountAMin, amountBMin, maxFee);
            } else {
                (amountB, amountA) = _swapToAddLiquidityOptimalInternalD2(pair, tokenB, tokenA, reserveB, reserveA, amountBDesired, amountADesired, amountBMin, amountAMin, maxFee);
            }
        }
    }

    function addLiquidityOptimal(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 maxFee,
        address to,
        uint256 deadline
    )
        external
        ensure(deadline)
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {
        address pair = IUniswapV2Factory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) {
            (amountA, amountB) = _addLiquidity(
                tokenA,
                tokenB,
                amountADesired,
                amountBDesired,
                amountAMin,
                amountBMin
            );
            pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        } else {
            (amountA, amountB) = _swapToAddLiquidityOptimal(
                pair,
                tokenA,
                tokenB,
                amountADesired,
                amountBDesired,
                amountAMin,
                amountBMin,
                maxFee
            );
        }
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = IUniswapV2Pair(pair).mint(to);
    }

    function addLiquidityKLAYOptimal(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountKLAYMin,
        uint256 maxFee,
        address to,
        uint256 deadline
    )
        external
        payable
        ensure(deadline)
        returns (
            uint256 amountToken,
            uint256 amountKLAY,
            uint256 liquidity
        )
    {
        address pair = IUniswapV2Factory(factory).getPair(token, WKLAY);
        if (pair == address(0)) {
            (amountToken, amountKLAY) = _addLiquidity(
                token,
                WKLAY,
                amountTokenDesired,
                msg.value,
                amountTokenMin,
                amountKLAYMin
    
            );
            pair = UniswapV2Library.pairFor(factory, token, WKLAY);
            IWKLAY(WKLAY).deposit{value: amountKLAY}();
        } else {
            IWKLAY(WKLAY).deposit{value: msg.value}();
            (amountToken, amountKLAY) = _swapToAddLiquidityOptimal(
                pair,
                token,
                WKLAY,
                amountTokenDesired,
                msg.value,
                amountTokenMin,
                amountKLAYMin,
                maxFee
            );
            if (msg.value > amountKLAY)
                IWKLAY(WKLAY).withdraw(msg.value - amountKLAY);
        }
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        assert(IWKLAY(WKLAY).transfer(pair, amountKLAY));
        liquidity = IUniswapV2Pair(pair).mint(to);
        // refund dust KLAY, if any
        if (msg.value > amountKLAY)
            TransferHelper.safeTransferETH(msg.sender, msg.value - amountKLAY);
    }

    // **** REMOVE LIQUIDITY ****
    function removeLiquidityForPair(
        address pair,
        uint256 liquidity,
        address to,
        uint256 deadline
    ) public ensure(deadline) returns (uint256 amount0, uint256 amount1) {
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        (amount0, amount1) = IUniswapV2Pair(pair).burn(to);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        (uint256 amount0, uint256 amount1) = IUniswapV2Pair(pair).burn(to);
        (address token0, ) = UniswapV2Library.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0
            ? (amount0, amount1)
            : (amount1, amount0);
        require(
            amountA >= amountAMin,
            "UniswapV2Router: INSUFFICIENT_A_AMOUNT"
        );
        require(
            amountB >= amountBMin,
            "UniswapV2Router: INSUFFICIENT_B_AMOUNT"
        );
    }

    function removeLiquidityKLAY(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountKLAYMin,
        address to,
        uint256 deadline
    )
        public
        ensure(deadline)
        returns (uint256 amountToken, uint256 amountKLAY)
    {
        (amountToken, amountKLAY) = removeLiquidity(
            token,
            WKLAY,
            liquidity,
            amountTokenMin,
            amountKLAYMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(token, to, amountToken);
        IWKLAY(WKLAY).withdraw(amountKLAY);
        TransferHelper.safeTransferETH(to, amountKLAY);
    }

    // **** REMOVE LIQUIDITY (supporting fee-on-transfer tokens) ****
    function removeLiquidityKLAYSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountKLAYMin,
        address to,
        uint256 deadline
    ) public ensure(deadline) returns (uint256 amountKLAY) {
        (, amountKLAY) = removeLiquidity(
            token,
            WKLAY,
            liquidity,
            amountTokenMin,
            amountKLAYMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(
            token,
            to,
            IERC20(token).balanceOf(address(this))
        );
        IWKLAY(WKLAY).withdraw(amountKLAY);
        TransferHelper.safeTransferETH(to, amountKLAY);
    }

    // **** SWAP ****
    // requires
    // - the initial amount to have already been sent to the first pair
    // - required fee token to be sent to the comptroller
    function _swap(
        uint256[] memory amounts,
        address[] memory path,
        address _to
    ) internal {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            uint256 amountOut = amounts[i + 1];
            address to = i < path.length - 2
                ? UniswapV2Library.pairFor(factory, output, path[i + 2])
                : _to;
            swapComptroller.swap(input, output, 0, amountOut, to, new bytes(0));
        }
        swapComptroller.skimFee(_to);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 maxFee,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        uint256 requiredFee;
        (amounts, requiredFee) = swapComptroller.getAmountsOut(amountIn, path);
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        require(requiredFee <= maxFee, "ZeroswapRouter: EXCESSIVE_FEE");
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        if (requiredFee > 0) {
            TransferHelper.safeTransferFrom(
                swapComptroller.feeToken(),
                msg.sender,
                address(swapComptroller),
                requiredFee
            );
        }
        _swap(amounts, path, to);
    }

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        uint256 maxFee,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        uint256 requiredFee;
        (amounts, requiredFee) = swapComptroller.getAmountsIn(amountOut, path);
        require(
            amounts[0] <= amountInMax,
            "UniswapV2Router: EXCESSIVE_INPUT_AMOUNT"
        );
        require(requiredFee <= maxFee, "ZeroswapRouter: EXCESSIVE_FEE");
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        if (requiredFee > 0) {
            TransferHelper.safeTransferFrom(
                swapComptroller.feeToken(),
                msg.sender,
                address(swapComptroller),
                requiredFee
            );
        }
        _swap(amounts, path, to);
    }

    function swapExactKLAYForTokens(
        uint256 amountOutMin,
        uint256 maxFee,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint256[] memory amounts) {
        require(path[0] == WKLAY, "UniswapV2Router: INVALID_PATH");
        uint256 requiredFee;
        (amounts, requiredFee) = swapComptroller.getAmountsOut(msg.value, path);
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        require(requiredFee <= maxFee, "ZeroswapRouter: EXCESSIVE_FEE");
        IWKLAY(WKLAY).deposit{ value: amounts[0] }();
        assert(
            IWKLAY(WKLAY).transfer(
                UniswapV2Library.pairFor(factory, path[0], path[1]),
                amounts[0]
            )
        );
        if (requiredFee > 0) {
            TransferHelper.safeTransferFrom(
                swapComptroller.feeToken(),
                msg.sender,
                address(swapComptroller),
                requiredFee
            );
        }
        _swap(amounts, path, to);
    }

    function swapTokensForExactKLAY(
        uint256 amountOut,
        uint256 amountInMax,
        uint256 maxFee,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        require(
            path[path.length - 1] == WKLAY,
            "UniswapV2Router: INVALID_PATH"
        );
        uint256 requiredFee;
        (amounts, requiredFee) = swapComptroller.getAmountsIn(amountOut, path);
        require(
            amounts[0] <= amountInMax,
            "UniswapV2Router: EXCESSIVE_INPUT_AMOUNT"
        );
        require(requiredFee <= maxFee, "ZeroswapRouter: EXCESSIVE_FEE");
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        if (requiredFee > 0) {
            TransferHelper.safeTransferFrom(
                swapComptroller.feeToken(),
                msg.sender,
                address(swapComptroller),
                requiredFee
            );
        }
        _swap(amounts, path, address(this));

        IWKLAY(WKLAY).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    function swapExactTokensForKLAY(
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 maxFee,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        require(
            path[path.length - 1] == WKLAY,
            "UniswapV2Router: INVALID_PATH"
        );
        uint256 requiredFee;
        (amounts, requiredFee) = swapComptroller.getAmountsOut(amountIn, path);
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        require(requiredFee <= maxFee, "ZeroswapRouter: EXCESSIVE_FEE");
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        if (requiredFee > 0) {
            TransferHelper.safeTransferFrom(
                swapComptroller.feeToken(),
                msg.sender,
                address(swapComptroller),
                requiredFee
            );
        }
        _swap(amounts, path, address(this));

        IWKLAY(WKLAY).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    function swapKLAYForExactTokens(
        uint256 amountOut,
        uint256 maxFee,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint256[] memory amounts) {
        require(path[0] == WKLAY, "UniswapV2Router: INVALID_PATH");
        uint256 requiredFee;
        (amounts, requiredFee) = swapComptroller.getAmountsIn(amountOut, path);
        require(
            amounts[0] <= msg.value,
            "UniswapV2Router: EXCESSIVE_INPUT_AMOUNT"
        );
        require(requiredFee <= maxFee, "ZeroswapRouter: EXCESSIVE_FEE");
        IWKLAY(WKLAY).deposit{ value: amounts[0] }();
        assert(
            IWKLAY(WKLAY).transfer(
                UniswapV2Library.pairFor(factory, path[0], path[1]),
                amounts[0]
            )
        );
        if (requiredFee > 0) {
            TransferHelper.safeTransferFrom(
                swapComptroller.feeToken(),
                msg.sender,
                address(swapComptroller),
                requiredFee
            );
        }
        _swap(amounts, path, to);
        // refund dust KLAY, if any
        if (msg.value > amounts[0])
            TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    function _getRealSwapAmounts(
        IUniswapV2Pair pair,
        address token0,
        address input,
        uint256 fee
    ) internal view returns (uint256 amountInput, uint256 amountOutput) {
        // scope to avoid stack too deep errors
        (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
        (uint256 reserveInput, uint256 reserveOutput) = input == token0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);
        amountInput = IERC20(input).balanceOf(address(pair)) - reserveInput;
        amountOutput = UniswapV2Library.getAmountOut(
            amountInput,
            reserveInput,
            reserveOutput,
            fee
        );
    }

    // requires
    // - the initial amount to have already been sent to the first pair
    // - required fee token to be allowed to this router
    function _swapSupportingFeeOnTransferTokens(
        uint256 maxFee,
        address[] memory path,
        address _to
    ) internal {
        uint256 fee = swapComptroller.fee();
        address feeToken = swapComptroller.feeToken();
        uint256 totalFeeRequired = 0;
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            IUniswapV2Pair pair = IUniswapV2Pair(
                UniswapV2Library.pairFor(factory, input, output)
            );
            uint256 amountInput;
            uint256 amountOutput;
            {
                bool isDiscountable = swapComptroller.isDiscountable(input, output);
                uint256 discountedFee = swapComptroller.discountedFee();
                // to avoid stack too deep errors
                (amountInput, amountOutput) = _getRealSwapAmounts(pair, token0, input, isDiscountable ? discountedFee : fee);
                if (isDiscountable) {
                    uint256 requiredFee = swapComptroller.getRequiredFee(input, output, amountInput, amountOutput);
                    totalFeeRequired += requiredFee;
                    require(totalFeeRequired < maxFee, "ZeroswapRouter: EXCESSIVE_FEE");
                    if (requiredFee > 0) {
                        TransferHelper.safeTransferFrom(feeToken, msg.sender, address(swapComptroller), requiredFee);
                    }
                }
            }

            address to = i < path.length - 2
                ? UniswapV2Library.pairFor(factory, output, path[i + 2])
                : _to;
            swapComptroller.swap(input, output, 0, amountOutput, to, new bytes(0));
        }
        swapComptroller.skimFee(_to);
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 maxFee,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) {
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amountIn
        );
        uint256 balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(maxFee, path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to) - balanceBefore >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
    }

    function swapExactKLAYForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        uint256 maxFee,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable ensure(deadline) {
        require(path[0] == WKLAY, "UniswapV2Router: INVALID_PATH");
        uint256 amountIn = msg.value;
        IWKLAY(WKLAY).deposit{ value: amountIn }();
        assert(
            IWKLAY(WKLAY).transfer(
                UniswapV2Library.pairFor(factory, path[0], path[1]),
                amountIn
            )
        );
        uint256 balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(maxFee, path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to) - balanceBefore >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
    }

    function swapExactTokensForKLAYSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 maxFee,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) {
        require(
            path[path.length - 1] == WKLAY,
            "UniswapV2Router: INVALID_PATH"
        );
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amountIn
        );
        _swapSupportingFeeOnTransferTokens(maxFee, path, address(this));
        uint256 amountOut = IERC20(WKLAY).balanceOf(address(this));
        require(
            amountOut >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        IWKLAY(WKLAY).withdraw(amountOut);
        TransferHelper.safeTransferETH(to, amountOut);
    }

    // **** LIBRARY FUNCTIONS ****
    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) public pure returns (uint256 amountB) {
        return UniswapV2Library.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 fee
    ) public pure returns (uint256 amountOut) {
        return UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut, fee);
    }

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 fee
    ) public pure returns (uint256 amountIn) {
        return UniswapV2Library.getAmountIn(amountOut, reserveIn, reserveOut, fee);
    }

    function getAmountsOut(uint256 amountIn, address[] memory path)
        public
        view
        returns (uint256[] memory amounts, uint256 requiredFee)
    {
        return swapComptroller.getAmountsOut(amountIn, path);
    }

    function getAmountsIn(uint256 amountOut, address[] memory path)
        public
        view
        returns (uint256[] memory amounts, uint256 requiredFee)
    {
        return swapComptroller.getAmountsIn(amountOut, path);
    }
}