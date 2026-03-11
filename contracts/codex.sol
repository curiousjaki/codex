// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Codex
 * @notice Carbon emission Decentralized EXchange (CODEX).
 *         Combines ERC-721 NFTs with a carbon data marketplace, role-based
 *         access control, and a certification system.
 *
 * Entrypoint mapping (mligo → Solidity):
 *   Fa2.Transfer          → ERC-721 transferFrom / safeTransferFrom
 *   Fa2.Balance_of        → ERC-721 balanceOf / ownerOf
 *   Fa2.Update_operators   → ERC-721 approve / setApprovalForAll
 *   Mint                  → mint()
 *   Update_token_metadata → updateTokenMetadata()
 *   Buy                   → buy()
 *   Update_user_roles     → updateUserRoles()
 *   Update_certs          → updateCerts()
 */
contract Codex is ERC721Enumerable, ERC721URIStorage, Ownable, ReentrancyGuard {

    // =========================================================================
    //                              ENUMS
    // =========================================================================

    /// @notice Certificate lifecycle states (mirrors mligo cert_state)
    enum CertState { Pending, Certified, Rejected }

    /// @notice User roles (mirrors mligo role: User of Consumer | User of Provider | Certifier)
    enum Role { Consumer, Provider, Certifier }

    // =========================================================================
    //                              STRUCTS
    // =========================================================================

    /// @notice Dataset metadata (mirrors mligo dataset type)
    struct Dataset {
        bool isOwned;
        address owner;
        uint256 price;
        bool hasPrice;
        uint256 id;
    }

    /// @notice Certificate for a dataset (mirrors mligo cert type)
    struct Cert {
        uint256 datasetId;
        address issuer;     // certifier address; address(0) while pending
        bytes32 hash;
        CertState state;
    }

    /// @notice Parameters for a single role update
    struct UpdateRoleParam {
        bool isAdd;          // true = Add_role, false = Remove_role
        Role role;           // Consumer or Provider only
    }

    /// @notice Parameters for a single cert update
    struct UpdateCertParam {
        bool isCertify;      // true = Certify, false = Reject
        uint256 datasetId;
        bytes32 hash;
    }

    /// @notice Parameters for minting a new dataset NFT
    struct MintParam {
        address owner;
        address operator;    // address(0) if no operator
        string tokenMetadataUri;
        uint256 price;
        bytes32 hash;
    }

    // =========================================================================
    //                              STATE
    // =========================================================================

    // --- Marketplace ---
    mapping(uint256 => Dataset) public datasets;
    uint256[] public datasetIds;
    uint256 public nextDatasetId;

    // --- Certificates ---
    mapping(uint256 => Cert) public certificates;

    // --- User roles: userRoles[user][role] = true/false ---
    mapping(address => mapping(Role => bool)) public userRoles;

    // =========================================================================
    //                              EVENTS
    // =========================================================================

    event DatasetMinted(uint256 indexed tokenId, address indexed owner, uint256 price);
    event DatasetBought(uint256 indexed tokenId, address indexed buyer, address indexed seller, uint256 price);
    event CertUpdated(uint256 indexed datasetId, CertState state, address indexed issuer);
    event UserRoleUpdated(address indexed user, Role role, bool isAdd);
    event TokenMetadataUpdated(uint256 indexed tokenId, string uri);

    // =========================================================================
    //                              ERRORS
    // =========================================================================

    error OnlyProvider();
    error OnlyConsumer();
    error OnlyCertifier();
    error OnlyTokenOwner();
    error MissingRole(string message);
    error TokenAlreadyExists();
    error DatasetNotFound();
    error CertNotFound();
    error CertNotSet();
    error CertInvalid();
    error PriceMismatch();
    error BuyerIsOwner();
    error DatasetNotOwned();
    error OwnerCannotCertifyOwnDataset();
    error CannotModifyCertifierRole();
    error OnlySelfRoleUpdate();
    error InconsistentOwnership();
    error MintError();
    error TransferFailed();

    // =========================================================================
    //                           CONSTRUCTOR
    // =========================================================================

    /**
     * @param initialCertifier Address granted the Certifier role at deployment
     */
    constructor(address initialCertifier) ERC721("Codex Carbon Data", "CODEX") Ownable(msg.sender) {
        userRoles[initialCertifier][Role.Certifier] = true;
    }

    // =========================================================================
    //                       ROLE MANAGEMENT
    // =========================================================================

    /**
     * @notice Batch add/remove Consumer or Provider roles for msg.sender.
     *         Mirrors mligo `update_user_roles` entrypoint.
     *         Users can only update their own roles; Certifier cannot be
     *         added/removed through this function.
     */
    function updateUserRoles(UpdateRoleParam[] calldata updates) external {
        for (uint256 i = 0; i < updates.length; i++) {
            if (updates[i].role == Role.Certifier) revert CannotModifyCertifierRole();

            if (updates[i].isAdd) {
                userRoles[msg.sender][updates[i].role] = true;
            } else {
                userRoles[msg.sender][updates[i].role] = false;
            }

            emit UserRoleUpdated(msg.sender, updates[i].role, updates[i].isAdd);
        }
    }

    /**
     * @notice Grant Certifier role to an address. Only contract owner.
     */
    function grantCertifier(address certifier) external onlyOwner {
        userRoles[certifier][Role.Certifier] = true;
        emit UserRoleUpdated(certifier, Role.Certifier, true);
    }

    /**
     * @notice Revoke Certifier role from an address. Only contract owner.
     */
    function revokeCertifier(address certifier) external onlyOwner {
        userRoles[certifier][Role.Certifier] = false;
        emit UserRoleUpdated(certifier, Role.Certifier, false);
    }

    // =========================================================================
    //                       CERTIFICATION SYSTEM
    // =========================================================================

    /**
     * @notice Batch certify or reject datasets. Only callable by a Certifier.
     *         Mirrors mligo `update_certs` entrypoint.
     */
    function updateCerts(UpdateCertParam[] calldata updates) external {
        if (!userRoles[msg.sender][Role.Certifier]) revert OnlyCertifier();

        for (uint256 i = 0; i < updates.length; i++) {
            _setCertState(
                updates[i].datasetId,
                updates[i].hash,
                updates[i].isCertify ? CertState.Certified : CertState.Rejected
            );
        }
    }

    /**
     * @dev Internal: update a certificate's state.
     *      Mirrors mligo `set_cert_state` helper.
     */
    function _setCertState(uint256 datasetId, bytes32 hash, CertState state) internal {
        // Dataset must exist
        Dataset storage ds = datasets[datasetId];
        if (!ds.isOwned) revert DatasetNotFound();

        // Dataset owner cannot certify their own dataset
        if (ds.owner == msg.sender) revert OwnerCannotCertifyOwnDataset();

        // Certificate must exist
        Cert storage cert = certificates[datasetId];
        if (cert.datasetId == 0 && datasetId != 0) {
            // Check for uninitialized cert (datasetId 0 is valid for the first token)
            revert CertNotFound();
        }
        // For datasetId 0, check if cert was ever created
        if (datasetId == 0 && cert.hash == bytes32(0) && cert.issuer == address(0) && cert.state == CertState.Pending) {
            // This could be an uninitialized cert for token 0 — need to verify it was minted
            if (!ds.isOwned) revert CertNotFound();
        }

        cert.issuer = msg.sender;
        cert.hash = hash;
        cert.state = state;

        emit CertUpdated(datasetId, state, msg.sender);
    }

    // =========================================================================
    //                            MINTING
    // =========================================================================

    /**
     * @notice Mint a new dataset NFT. Only callable by a Provider.
     *         Mirrors mligo `mint` entrypoint.
     *         Creates the dataset, a pending certificate, mints the ERC-721
     *         token, and optionally approves an operator.
     */
    function mint(MintParam calldata param) external {
        if (!userRoles[msg.sender][Role.Provider]) revert OnlyProvider();

        uint256 tokenId = nextDatasetId;

        // Token must not already exist (ERC721 _safeMint will also check, but explicit for clarity)
        if (_exists(tokenId)) revert TokenAlreadyExists();

        // Create dataset
        datasets[tokenId] = Dataset({
            isOwned: true,
            owner: param.owner,
            price: param.price,
            hasPrice: true,
            id: tokenId
        });
        datasetIds.push(tokenId);

        // Create pending certificate
        certificates[tokenId] = Cert({
            datasetId: tokenId,
            issuer: address(0),
            hash: param.hash,
            state: CertState.Pending
        });

        // Mint the ERC-721 token
        _safeMint(param.owner, tokenId);

        // Set token metadata URI
        _setTokenURI(tokenId, param.tokenMetadataUri);

        // Optionally approve an operator
        if (param.operator != address(0)) {
            // We use _approve to bypass the "caller is not token owner or approved" check
            // since we're minting on behalf of the owner
            _approve(param.operator, tokenId, param.owner);
        }

        nextDatasetId = tokenId + 1;

        emit DatasetMinted(tokenId, param.owner, param.price);
    }

    // =========================================================================
    //                              BUY
    // =========================================================================

    /**
     * @notice Buy a dataset by sending the exact price in ETH.
     *         Atomically transfers funds to the seller and the NFT to the buyer.
     */
    function buy(uint256 tokenId) external payable nonReentrant {
        if (!userRoles[msg.sender][Role.Consumer]) revert OnlyConsumer();

        // Dataset must exist
        Dataset storage ds = datasets[tokenId];
        if (!ds.isOwned) revert DatasetNotFound();

        // Price must match
        if (!ds.hasPrice || ds.price != msg.value) revert PriceMismatch();

        // Buyer must not be the current owner
        address datasetOwner = ownerOf(tokenId);
        if (msg.sender == datasetOwner) revert BuyerIsOwner();

        // Certificate must be valid (Certified)
        Cert storage cert = certificates[tokenId];
        if (cert.state != CertState.Certified) revert CertInvalid();

        // Transfer NFT from seller to buyer (also syncs dataset.owner via _update)
        _transfer(datasetOwner, msg.sender, tokenId);

        // Transfer funds to the seller
        (bool success, ) = payable(datasetOwner).call{value: msg.value}("");
        if (!success) revert TransferFailed();

        emit DatasetBought(tokenId, msg.sender, datasetOwner, msg.value);
    }

    // =========================================================================
    //                       TOKEN METADATA UPDATE
    // =========================================================================

    /**
     * @notice Update the token metadata URI. Only callable by the token owner.
     *         Mirrors mligo `update_token_metadata` entrypoint.
     */
    function updateTokenMetadata(uint256 tokenId, string calldata uri) external {
        if (ownerOf(tokenId) != msg.sender) revert OnlyTokenOwner();

        _setTokenURI(tokenId, uri);

        emit TokenMetadataUpdated(tokenId, uri);
    }

    // =========================================================================
    //                     ERC-721 OVERRIDES
    // =========================================================================

    /**
     * @dev Override _update to sync dataset.owner on every transfer.
     *      Mirrors mligo `set_new_dataset_owner` + `transfer_token_in_owners`
     *      which ran on every FA2 transfer.
     *      ERC721Enumerable already handles per-owner token tracking.
     */
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        address from = super._update(to, tokenId, auth);

        // Sync dataset owner (only for tokens that have a dataset)
        if (datasets[tokenId].isOwned && to != address(0)) {
            datasets[tokenId].owner = to;
        }

        return from;
    }

    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._increaseBalance(account, value);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Enumerable, ERC721URIStorage)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // =========================================================================
    //                          VIEW HELPERS
    // =========================================================================

    /**
     * @notice Check whether a token has been minted.
     */
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    /**
     * @notice Check if a certificate is valid (Certified).
     *         Mirrors mligo `check_cert_valid`.
     */
    function isCertValid(uint256 tokenId) external view returns (bool) {
        return certificates[tokenId].state == CertState.Certified;
    }

    /**
     * @notice Check if an address holds a given role.
     *         Mirrors mligo `is_role`.
     */
    function hasRole(address user, Role role) external view returns (bool) {
        return userRoles[user][role];
    }

    /**
     * @notice Return total number of datasets created.
     */
    function datasetCount() external view returns (uint256) {
        return datasetIds.length;
    }
}
