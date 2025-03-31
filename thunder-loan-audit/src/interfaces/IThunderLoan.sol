// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// @audit-info: This interface should be a part of the `ThunderLoan` contract.
interface IThunderLoan {
    function repay(address token, uint256 amount) external;
}
