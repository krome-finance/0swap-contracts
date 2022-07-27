// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import '@openzeppelin/contracts/access/Ownable.sol';

contract MockOracle is Ownable {
    uint256 public getPrice;
    uint256 public getDecimals;

    constructor(
        uint256 _price,
        uint256 _decimals
    ) {
        getPrice = _price;
        getDecimals = _decimals;
    }

    function setPrice(uint256 _price, uint256 _decimals) external onlyOwner {
        getPrice = _price;
        getDecimals = _decimals;
    }
}
