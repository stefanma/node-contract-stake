// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

//奖励代币合约，用于奖励用户质押代币获得的奖励
contract NodeToken is ERC20, Ownable{

    constructor() ERC20("NodeToken", "NT") Ownable(msg.sender){
        _mint(msg.sender, 1000000 * 10 ** decimals());// 初始 100 万枚
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public onlyOwner {
        _burn(from, amount);
    }

}