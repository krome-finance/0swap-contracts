// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

interface IZeroswapComptroller {
    function fee() external view returns (uint256);
    function feeTo() external view returns (address);
    function feeToken() external view returns (address);
    function discountRate() external view returns (uint256);
    function discountedFee() external view returns (uint256);
    function isDiscountable(address token0, address token1) external view returns (bool);
    function getRequiredFee(address token0, address token1, uint256 amount0, uint256 amount1) external view returns (uint256);
    function getAmountsOut(
        uint256 amountIn,
        address[] memory path
    ) external view returns (uint256[] memory amounts, uint256 requiredFee);
    function getAmountsIn(
        uint256 amountOut,
        address[] memory path
    ) external view returns (uint256[] memory amounts, uint256 requiredFee);

    function swap(address token0, address token1, uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skimFee(address to) external;
}