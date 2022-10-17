// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IPoint {
    event Mint(address indexed to, uint256 value);

    event Consume(address indexed consumer, address indexed from, uint256 value);

    event Approval(address indexed owner, address indexed spender, uint256 value);

    function gainOf(address account) external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function consume(address spender, uint256 amount) external;

    function mint(address to, uint256 amount) external;

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);
}
