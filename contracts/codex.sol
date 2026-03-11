// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./CodexMarketplace.sol";

/// @title Codex
/// @notice Carbon emission Decentralized EXchange (CODEX).
///         Concrete contract combining roles, certification, and marketplace.
contract Codex is CodexMarketplace {

    /// @param initialCertifier Address granted the Certifier role at deployment.
    constructor(address initialCertifier)
        ERC721("Codex Carbon Data", "CODEX")
        Ownable(msg.sender)
    {
        userRoles[initialCertifier][Role.Certifier] = true;
    }
}