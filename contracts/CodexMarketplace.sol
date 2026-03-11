// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./CodexCertification.sol";

/// @title CodexMarketplace
/// @notice Mint, buy, and metadata management for carbon data NFTs.
abstract contract CodexMarketplace is CodexCertification, ERC721Enumerable, ERC721URIStorage, ReentrancyGuard {
    mapping(uint256 => Dataset) public datasets;
    uint256[] public datasetIds;
    uint256 public nextDatasetId;

    /// @dev Implement the dataset lookup hook for CodexCertification.
    function _getDataset(uint256 tokenId) internal view override returns (Dataset storage) {
        return datasets[tokenId];
    }

    /// @dev Return the current nextDatasetId and increment it.
    function _newTokenId() internal returns (uint256 tokenId) {
        tokenId = nextDatasetId;
        nextDatasetId = tokenId + 1;
    }

    /// @notice Mint a new dataset NFT. Only callable by a Provider.
    /// @param param Minting parameters (owner, operator, URI, price, hash).
    function mint(MintParam calldata param) external {
        _checkRole(msg.sender, Role.Provider);

        uint256 tokenId = _newTokenId();
        if (_ownerOf(tokenId) != address(0)) revert TokenAlreadyExists();

        datasets[tokenId] = Dataset({
            isOwned: true,
            owner: param.owner,
            price: param.price,
            hasPrice: true,
            id: tokenId
        });
        datasetIds.push(tokenId);

        certificates[tokenId] = Cert({
            datasetId: tokenId,
            issuer: address(0),
            hash: param.hash,
            state: CertState.Pending
        });

        _safeMint(param.owner, tokenId);
        _setTokenURI(tokenId, param.tokenMetadataUri);

        if (param.operator != address(0)) {
            _approve(param.operator, tokenId, param.owner);
        }

        emit DatasetMinted(tokenId, param.owner, param.price);
    }

    /// @notice Buy a dataset by sending the exact price in ETH.
    ///         Atomically transfers the NFT to the buyer and funds to the seller.
    /// @param tokenId The dataset token to purchase.
    function buy(uint256 tokenId) external payable nonReentrant {
        _checkRole(msg.sender, Role.Consumer);

        Dataset storage ds = datasets[tokenId];
        if (!ds.isOwned) revert DatasetNotFound();
        if (!ds.hasPrice || ds.price != msg.value) revert PriceMismatch();

        address seller = ownerOf(tokenId);
        if (msg.sender == seller) revert BuyerIsOwner();
        if (certificates[tokenId].state != CertState.Certified) revert CertInvalid();

        // Effects: transfer NFT (syncs dataset.owner via _update)
        _transfer(seller, msg.sender, tokenId);

        emit DatasetBought(tokenId, msg.sender, seller, msg.value);

        // Interaction: send ETH to seller (after all state changes)
        (bool success, ) = payable(seller).call{value: msg.value}("");
        if (!success) revert TransferFailed();
    }

    /// @notice Update the token metadata URI. Only callable by the token owner.
    /// @param tokenId The token to update.
    /// @param uri The new metadata URI.
    function updateTokenMetadata(uint256 tokenId, string calldata uri) external {
        if (ownerOf(tokenId) != msg.sender) revert OnlyTokenOwner();
        _setTokenURI(tokenId, uri);
        emit TokenMetadataUpdated(tokenId, uri);
    }

    /// @notice Return total number of datasets created.
    function datasetCount() external view returns (uint256) {
        return datasetIds.length;
    }

    // =====================================================================
    //                     ERC-721 OVERRIDES
    // =====================================================================

    /// @dev Sync dataset.owner on every transfer.
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        address from = super._update(to, tokenId, auth);
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
}