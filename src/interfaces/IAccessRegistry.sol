// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IAccessRegistry {
    function isAccessible(address user) external view returns (bool) ;
    function isTokenCreationAllowed(address user) external view returns (bool);
}