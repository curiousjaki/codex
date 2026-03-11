// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./CodexRoles.sol";

/// @title CodexCertification
/// @notice Certification lifecycle: Pending → Certified / Rejected.
abstract contract CodexCertification is CodexRoles {
    mapping(uint256 => Cert) public certificates;

    /// @dev Hook: subclass provides dataset storage lookup.
    function _getDataset(uint256 tokenId) internal view virtual returns (Dataset storage);

    /// @notice Certify or reject a single dataset. Only callable by a Certifier.
    /// @param datasetId The dataset to certify or reject.
    /// @param hash The certification data hash.
    /// @param isCertify True to certify, false to reject.
    function updateCert(uint256 datasetId, bytes32 hash, bool isCertify) public {
        _checkRole(msg.sender, Role.Certifier);
        _setCertState(datasetId, hash, isCertify ? CertState.Certified : CertState.Rejected);
    }

    /// @notice Batch certify or reject datasets. Only callable by a Certifier.
    /// @param updates Array of certification decisions to apply.
    function updateCerts(UpdateCertParam[] calldata updates) external {
        for (uint256 i = 0; i < updates.length; i++) {
            updateCert(updates[i].datasetId, updates[i].hash, updates[i].isCertify);
        }
    }

    /// @dev Update a certificate's state.
    function _setCertState(uint256 datasetId, bytes32 hash, CertState state) internal {
        Dataset storage ds = _getDataset(datasetId);
        if (!ds.isOwned) revert DatasetNotFound();
        if (ds.owner == msg.sender) revert OwnerCannotCertifyOwnDataset();

        Cert storage cert = certificates[datasetId];
        // For non-zero datasetId, an uninitialized cert has datasetId == 0
        if (cert.datasetId == 0 && datasetId != 0) revert CertNotFound();

        cert.issuer = msg.sender;
        cert.hash = hash;
        cert.state = state;

        emit CertUpdated(datasetId, state, msg.sender);
    }

    /// @notice Check if a certificate is valid (Certified).
    /// @param tokenId The dataset token ID.
    /// @return True if the certificate is in Certified state.
    function isCertValid(uint256 tokenId) external view returns (bool) {
        return certificates[tokenId].state == CertState.Certified;
    }
}