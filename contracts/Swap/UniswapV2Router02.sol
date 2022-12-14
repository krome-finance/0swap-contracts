// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IZeroswapComptroller.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/UniswapV2Library.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IWKLAY.sol";

contract UniswapV2Router02 {
    // using SafeMath for uint256;

    address public factory;
    address public WKLAY;

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "UniswapV2Router: EXPIRED");
        _;
    }

    constructor(address _factory, address _WKLAY) {
        factory = _factory;
        WKLAY = _WKLAY;
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

    struct AddLiquidityParams {
        address token;
        uint256 amountDesired;
        uint256 amountMin;
    }

    function _swapToAddLiquidityOptimalInternalD1(
        address pair,
        AddLiquidityParams memory pIn,
        AddLiquidityParams memory pOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) 
        internal
        returns (
            uint256 swapAmountIn,
            uint256 swapAmountOut
        )
    {
        uint256 feeRate = IZeroswapComptroller(IUniswapV2Factory(factory).swapComptroller()).fee();
        swapAmountIn = UniswapV2Library.getSwapInAmountToAddLiquidity(reserveIn, reserveOut, pIn.amountDesired, pOut.amountDesired, feeRate);
        if (swapAmountIn == 0) return (0, 0);
        swapAmountOut = UniswapV2Library.getAmountOut(swapAmountIn, reserveIn, reserveOut, feeRate);
        if (swapAmountOut == 0) return (0, 0);
        TransferHelper.safeTransferFrom(
            pIn.token,
            pIn.token == WKLAY && msg.value > 0 ? address(this) : msg.sender,
            pair,
            swapAmountIn
        );

        (address token0, ) = UniswapV2Library.sortTokens(pIn.token, pOut.token);
        IUniswapV2Pair(pair)
            .swap(token0 == pIn.token ? 0 : swapAmountOut, token0 == pIn.token ? swapAmountOut : 0, address(this), new bytes(0));

        TransferHelper.safeTransfer(
            pOut.token,
            pair,
            swapAmountOut
        );
    }

    function _swapToAddLiquidityOptimalInternalD2(
        address pair,
        AddLiquidityParams memory pIn,
        AddLiquidityParams memory pOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) 
        internal
        returns (
            uint256 amountIn,
            uint256 amountOut,
            uint256 swapAmountIn
        )
    {
        uint256 swapAmountOut;
        (swapAmountIn, swapAmountOut) = _swapToAddLiquidityOptimalInternalD1(pair, pIn, pOut, reserveIn, reserveOut);
        (amountIn, amountOut) = _addLiquidity(
            pIn.token,
            pOut.token,
            pIn.amountDesired - swapAmountIn,
            pOut.amountDesired + swapAmountOut,
            pIn.amountMin > swapAmountIn ? pIn.amountMin - swapAmountIn : 0,
            pOut.amountMin + swapAmountOut
        );
        // reduce as already transfered to pair
        amountOut -= swapAmountOut;
    }

    function _swapToAddLiquidityOptimal(
        address pair,
        AddLiquidityParams memory pA,
        AddLiquidityParams memory pB
    )
        internal
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 swapAmountA,
            uint256 swapAmountB
        )
    {
        (uint256 reserveA, uint256 reserveB) = UniswapV2Library.getReserves(
            factory,
            pA.token,
            pB.token
        );
        {
            if (reserveB * pA.amountDesired >= reserveA * pB.amountDesired) {
                (amountA, amountB, swapAmountA) = _swapToAddLiquidityOptimalInternalD2(pair, pA, pB, reserveA, reserveB);
            } else {
                (amountB, amountA, swapAmountB) = _swapToAddLiquidityOptimalInternalD2(pair, pB, pA, reserveB, reserveA);
            }
        }
    }

    function _addLiquidityOptimal(
        AddLiquidityParams memory pA,
        AddLiquidityParams memory pB,
        address to
    )
        internal
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {
        address pair = IUniswapV2Factory(factory).getPair(pA.token, pB.token);
        if (pair == address(0)) {
            (amountA, amountB) = _addLiquidity(
                pA.token,
                pB.token,
                pA.amountDesired,
                pB.amountDesired,
                pA.amountMin,
                pB.amountMin
            );
            pair = UniswapV2Library.pairFor(factory, pA.token, pB.token);
        } else {
            (amountA, amountB,,) = _swapToAddLiquidityOptimal(pair, pA, pB);
        }
        TransferHelper.safeTransferFrom(pA.token, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(pB.token, msg.sender, pair, amountB);
        liquidity = IUniswapV2Pair(pair).mint(to);
    }

    function addLiquidityOptimal(
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
        ) {
        return _addLiquidityOptimal(
            AddLiquidityParams(tokenA, amountADesired, amountAMin),
            AddLiquidityParams(tokenB, amountBDesired, amountBMin),
            to
        );
    }

    function _addLiquidityKLAYOptimal(
        AddLiquidityParams memory pToken,
        uint256 amountKLAYMin,
        address to
    )
        internal
        returns (
            uint256 amountToken,
            uint256 amountKLAY,
            uint256 liquidity
        )
    {
        address pair = IUniswapV2Factory(factory).getPair(pToken.token, WKLAY);
        uint256 swappedKLAY;
        if (pair == address(0)) {
            (amountToken, amountKLAY) = _addLiquidity(
                pToken.token,
                WKLAY,
                pToken.amountDesired,
                msg.value,
                pToken.amountMin,
                amountKLAYMin
    
            );
            pair = UniswapV2Library.pairFor(factory, pToken.token, WKLAY);
            IWKLAY(WKLAY).deposit{value: amountKLAY}();
        } else {
            IWKLAY(WKLAY).deposit{value: msg.value}();
            AddLiquidityParams memory pWklay = AddLiquidityParams(WKLAY, msg.value, amountKLAYMin);
            (amountToken, amountKLAY, ,swappedKLAY) = _swapToAddLiquidityOptimal(
                pair,
                pToken,
                pWklay
            );
            if (msg.value > amountKLAY + swappedKLAY)
                IWKLAY(WKLAY).withdraw(msg.value - (amountKLAY + swappedKLAY));
        }
        TransferHelper.safeTransferFrom(pToken.token, msg.sender, pair, amountToken);
        assert(IWKLAY(WKLAY).transfer(pair, amountKLAY));
        liquidity = IUniswapV2Pair(pair).mint(to);
        // refund dust KLAY, if any
        if (msg.value > amountKLAY + swappedKLAY)
            TransferHelper.safeTransferETH(msg.sender, msg.value - (amountKLAY + swappedKLAY));
    }

    function addLiquidityKLAYOptimal(
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
        return _addLiquidityKLAYOptimal(
            AddLiquidityParams(token, amountTokenDesired, amountTokenMin),
            amountKLAYMin,
            to
        );
    }

    // **** REMOVE LIQUIDITY ****
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
    // requires the initial amount to have already been sent to the first pair
    function _swap(
        uint256[] memory amounts,
        address[] memory path,
        address _to
    ) internal {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = UniswapV2Library.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) = input == token0
                ? (uint256(0), amountOut)
                : (amountOut, uint256(0));
            address to = i < path.length - 2
                ? UniswapV2Library.pairFor(factory, output, path[i + 2])
                : _to;
            IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output))
                .swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, to);
    }

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(
            amounts[0] <= amountInMax,
            "UniswapV2Router: EXCESSIVE_INPUT_AMOUNT"
        );
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, to);
    }

    function swapExactKLAYForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint256[] memory amounts) {
        require(path[0] == WKLAY, "UniswapV2Router: INVALID_PATH");
        amounts = UniswapV2Library.getAmountsOut(factory, msg.value, path);
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        IWKLAY(WKLAY).deposit{ value: amounts[0] }();
        assert(
            IWKLAY(WKLAY).transfer(
                UniswapV2Library.pairFor(factory, path[0], path[1]),
                amounts[0]
            )
        );
        _swap(amounts, path, to);
    }

    function swapTokensForExactKLAY(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        require(
            path[path.length - 1] == WKLAY,
            "UniswapV2Router: INVALID_PATH"
        );
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(
            amounts[0] <= amountInMax,
            "UniswapV2Router: EXCESSIVE_INPUT_AMOUNT"
        );
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, address(this));
        IWKLAY(WKLAY).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    function swapExactTokensForKLAY(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        require(
            path[path.length - 1] == WKLAY,
            "UniswapV2Router: INVALID_PATH"
        );
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, address(this));
        IWKLAY(WKLAY).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    function swapKLAYForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint256[] memory amounts) {
        require(path[0] == WKLAY, "UniswapV2Router: INVALID_PATH");
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(
            amounts[0] <= msg.value,
            "UniswapV2Router: EXCESSIVE_INPUT_AMOUNT"
        );
        IWKLAY(WKLAY).deposit{ value: amounts[0] }();
        assert(
            IWKLAY(WKLAY).transfer(
                UniswapV2Library.pairFor(factory, path[0], path[1]),
                amounts[0]
            )
        );
        _swap(amounts, path, to);
        // refund dust KLAY, if any
        if (msg.value > amounts[0])
            TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    // requires the initial amount to have already been sent to the first pair
    function _swapSupportingFeeOnTransferTokens(
        address[] memory path,
        address _to
    ) internal {
        uint256 fee = IZeroswapComptroller(IUniswapV2Factory(factory).swapComptroller()).fee();
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = UniswapV2Library.sortTokens(input, output);
            IUniswapV2Pair pair = IUniswapV2Pair(
                UniswapV2Library.pairFor(factory, input, output)
            );
            uint256 amountInput;
            uint256 amountOutput;
            {
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
            (uint256 amount0Out, uint256 amount1Out) = input == token0
                ? (uint256(0), amountOutput)
                : (amountOutput, uint256(0));
            address to = i < path.length - 2
                ? UniswapV2Library.pairFor(factory, output, path[i + 2])
                : _to;
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
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
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to) - balanceBefore >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
    }

    function swapExactKLAYForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
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
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to) - balanceBefore >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
    }

    function swapExactTokensForKLAYSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
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
        _swapSupportingFeeOnTransferTokens(path, address(this));
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
        returns (uint256[] memory amounts)
    {
        return UniswapV2Library.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint256 amountOut, address[] memory path)
        public
        view
        returns (uint256[] memory amounts)
    {
        return UniswapV2Library.getAmountsIn(factory, amountOut, path);
    }
}