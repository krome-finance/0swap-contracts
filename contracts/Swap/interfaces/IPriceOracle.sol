// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

interface IPriceOracle {
    // returns 1e18 usd price of 1 unit amount in usd
    function getLatestPrice() external view returns (uint256);
    function getDecimals() external view returns (uint256);
}
