// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ICodex.sol";

/// @title CodexRoles
/// @notice Role management: Consumer, Provider (self-service), Certifier (owner-managed).
abstract contract CodexRoles is Ownable, ICodex {
    mapping(address => mapping(Role => bool)) public userRoles;

    /// @dev Revert if `user` does not hold `role`, using the role-specific error.
    function _checkRole(address user, Role role) internal view {
        if (!userRoles[user][role]) {
            if (role == Role.Provider) revert OnlyProvider();
            if (role == Role.Consumer) revert OnlyConsumer();
            revert OnlyCertifier();
        }
    }

    /// @notice Add a Consumer or Provider role for msg.sender.
    /// @param role The role to add.
    function addRole(Role role) external {
        if (role == Role.Certifier) revert CannotModifyCertifierRole();
        userRoles[msg.sender][role] = true;
        emit UserRoleUpdated(msg.sender, role, true);
    }

    /// @notice Remove a Consumer or Provider role for msg.sender.
    /// @param role The role to remove.
    function removeRole(Role role) external {
        if (role == Role.Certifier) revert CannotModifyCertifierRole();
        userRoles[msg.sender][role] = false;
        emit UserRoleUpdated(msg.sender, role, false);
    }

    /// @notice Grant Certifier role to an address. Only contract owner.
    /// @param certifier Address to grant the role to.
    function grantCertifier(address certifier) external onlyOwner {
        userRoles[certifier][Role.Certifier] = true;
        emit UserRoleUpdated(certifier, Role.Certifier, true);
    }

    /// @notice Revoke Certifier role from an address. Only contract owner.
    /// @param certifier Address to revoke the role from.
    function revokeCertifier(address certifier) external onlyOwner {
        userRoles[certifier][Role.Certifier] = false;
        emit UserRoleUpdated(certifier, Role.Certifier, false);
    }

    /// @notice Check if an address holds a given role.
    /// @param user Address to check.
    /// @param role Role to check.
    /// @return True if the user holds the role.
    function hasRole(address user, Role role) external view returns (bool) {
        return userRoles[user][role];
    }
}