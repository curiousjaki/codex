// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICodex
/// @notice Shared types, events, and errors for the Codex contract system.
interface ICodex {
    // =====================================================================
    //                              ENUMS
    // =====================================================================

    enum CertState { Pending, Certified, Rejected }
    enum Role { Consumer, Provider, Certifier }

    // =====================================================================
    //                             STRUCTS
    // =====================================================================

    struct Dataset {
        bool isOwned;
        address owner;
        uint256 price;
        bool hasPrice;
        uint256 id;
    }

    struct Cert {
        uint256 datasetId;
        address issuer;
        bytes32 hash;
        CertState state;
    }

    struct UpdateCertParam {
        bool isCertify;
        uint256 datasetId;
        bytes32 hash;
    }

    struct MintParam {
        address owner;
        address operator;
        string tokenMetadataUri;
        uint256 price;
        bytes32 hash;
    }

    // =====================================================================
    //                             EVENTS
    // =====================================================================

    event DatasetMinted(uint256 indexed tokenId, address indexed owner, uint256 price);
    event DatasetBought(uint256 indexed tokenId, address indexed buyer, address indexed seller, uint256 price);
    event CertUpdated(uint256 indexed datasetId, CertState state, address indexed issuer);
    event UserRoleUpdated(address indexed user, Role role, bool isAdd);
    event TokenMetadataUpdated(uint256 indexed tokenId, string uri);

    // =====================================================================
    //                             ERRORS
    // =====================================================================

    error OnlyProvider();
    error OnlyConsumer();
    error OnlyCertifier();
    error OnlyTokenOwner();
    error TokenAlreadyExists();
    error DatasetNotFound();
    error CertNotFound();
    error CertInvalid();
    error PriceMismatch();
    error BuyerIsOwner();
    error OwnerCannotCertifyOwnDataset();
    error CannotModifyCertifierRole();
    error TransferFailed();
}