# Plan: Translate TAIA-X mligo Smart Contracts to Solidity

## Contract Structure Summary

The TAIA-X contract is a **Tezos FA2 (TZIP-12) NFT marketplace** written in CameLIGO. It combines:
1. **FA2 Token Standard** — Tezos equivalent of ERC-721; handles NFT ownership, transfers, operators (approvals)
2. **Dataset Marketplace** — Datasets minted as NFTs with prices, buying/selling with native currency
3. **Role-Based Access Control** — Consumer, Provider, Certifier roles
4. **Certification System** — Datasets go through Pending → Certified/Rejected lifecycle

### Storage (contracts/src/domain_storage/storage_definition.mligo)
- `taia_x_storage`:
  - `market.datasets`: (token_id → dataset) — dataset metadata per token
  - `market.datasetIds`: set of all token IDs
  - `market.nextDatasetId`: auto-incrementing counter
  - `market.owners`: (address → set of token_ids) — reverse index of ownership
  - `certificates`: (token_id → cert) — certification state per dataset
  - `users`: ((address, role) → unit) — role assignments
  - `ledger`: (token_id → address) — single NFT owner per token
  - `operators`: ((owner, (operator, token_id)) → unit) — operator permissions
  - `token_metadata`: (token_id → {token_id, token_info map})

### Entrypoints (contracts/src/taia_x_main.mligo)
| mligo Entrypoint | Purpose |
|---|---|
| `Fa2 > Transfer` | Transfer NFTs between addresses |
| `Fa2 > Balance_of` | Query NFT balance (callback-based) |
| `Fa2 > Update_operators` | Add/remove operators (approvals) |
| `Mint` | Provider mints a new dataset NFT with price, metadata, cert |
| `Update_token_metadata` | Owner updates token metadata URI |
| `Buy` | Consumer purchases dataset (sends native currency to seller) |
| `Update_user_roles` | User adds/removes own Consumer/Provider role |
| `Update_certs` | Certifier certifies or rejects dataset |

### Key Business Rules
- Only Providers can mint
- Only Consumers can buy
- Only Certifiers can update certs
- Dataset owner cannot certify own dataset
- Users can only update their own roles (not Certifier role)
- Buying requires valid certificate + matching price
- Buying transfers funds but NOT the NFT (transfer is separate via FA2)

## Translation Plan

### Concept Mapping

| CameLIGO / Tezos | Solidity / EVM |
|---|---|
| FA2 (TZIP-12) | ERC-721 (OpenZeppelin) |
| `big_map(K, V)` | `mapping(K => V)` |
| `token_id` (nat) | `uint256` |
| `address` | `address` |
| `tez` / `Tezos.amount` | `msg.value` (wei) |
| `Tezos.sender` | `msg.sender` |
| `failwith("...")` | `require(..., "...")` / `revert(...)` |
| Operators (FA2) | `approve()` / `setApprovalForAll()` (ERC-721) |
| `cert_state` variant | Solidity `enum CertState { Pending, Certified, Rejected }` |
| `user_role` variant | Solidity `enum UserRole { Consumer, Provider }` |
| `role` variant | Solidity `enum Role { Consumer, Provider, Certifier }` |
| `(address * role) -> unit` big_map | `mapping(address => mapping(uint8 => bool))` or EnumerableSet |
| `(address * (address * token_id)) -> unit` | Handled natively by ERC-721 approvals |
| `owners: (address -> token_id set)` | `ERC721Enumerable` provides `tokenOfOwnerByIndex` |
| `datasets: (nat -> dataset)` | `mapping(uint256 => Dataset)` struct mapping |
| `certificates: (nat -> cert)` | `mapping(uint256 => Cert)` struct mapping |
| `List.fold` / `List.map` | Solidity for-loops |

### Architecture Decision: Contract Structure

**Recommended: Inheritance-based single deployable contract**

```
ERC721 (OpenZeppelin)
  └── ERC721Enumerable (OpenZeppelin) — replaces owners reverse-index
        └── TaiaXMarketplace — main contract with all business logic
```

Alternatively, split into modules using Solidity inheritance:
- `TaiaXRoles.sol` — role management (could use OpenZeppelin AccessControl, but the original allows self-assignment so custom logic is needed)
- `TaiaXCerts.sol` — certification logic
- `TaiaXMarketplace.sol` — mint, buy, dataset management (inherits from above + ERC721)

### Phase 1: Project Setup
1. Initialize a Hardhat or Foundry project inside `contracts/` (or a new `contracts-solidity/` directory)
2. Install OpenZeppelin contracts (`@openzeppelin/contracts`)
3. Configure Solidity compiler version (0.8.20+)

### Phase 2: Data Structures & Storage
Create `TaiaXStorage.sol` (or define in main contract):
- `struct Dataset { bool isOwned; address owner; uint256 price; bool hasPrice; uint256 id; }`
- `struct Cert { uint256 datasetId; address issuer; bytes32 hash; CertState state; }`
- `enum CertState { Pending, Certified, Rejected }`
- `enum Role { Consumer, Provider, Certifier }`
- State variables:
  - `mapping(uint256 => Dataset) public datasets`
  - `uint256[] public datasetIds` (or use EnumerableSet)
  - `uint256 public nextDatasetId`
  - `mapping(uint256 => Cert) public certificates`
  - `mapping(address => mapping(uint8 => bool)) public userRoles` (address → Role → bool)
  - Inherit `ERC721Enumerable` for ledger + owners functionality

### Phase 3: Role Management
Implement role functions:
- `updateUserRoles(UpdateRole[] calldata updates)` — batch add/remove Consumer/Provider roles for msg.sender
- `_isRole(address user, Role role)` — internal check, revert on failure
- Only users can modify their own roles; Certifier role must be assigned at deploy time or by admin
- Custom error messages matching the original contract

### Phase 4: Certification System
Implement cert functions:
- `updateCerts(UpdateCertParam[] calldata updates)` — batch certify/reject (only Certifier)
- `_setCertState(uint256 datasetId, bytes32 hash, CertState state)` — internal helper
- Checks: certifier role, cert exists, dataset exists, owner ≠ certifier
- Events: `CertUpdated(uint256 indexed datasetId, CertState state, address issuer)`

### Phase 5: Minting
Implement `mint(MintParam calldata param)`:
- Only Provider can call
- Auto-increment `nextDatasetId`
- `_safeMint(owner, tokenId)` (ERC-721)
- Create Dataset struct in `datasets` mapping
- Add to `datasetIds`
- Set token URI / metadata
- Create initial Cert with Pending state
- Optionally `approve(operator, tokenId)` if operator is provided
- Events: `DatasetMinted(uint256 indexed tokenId, address indexed owner, uint256 price)`

### Phase 6: Buy
Implement `buy(uint256 tokenId) payable`:
- Only Consumer can call
- Check dataset exists, has valid cert, buyer ≠ owner
- Check `msg.value == dataset.price`
- Transfer ETH to seller via `call{value: msg.value}("")`
- NOTE: The original contract does NOT transfer NFT ownership on buy — it only transfers funds. FA2 transfer is separate. Preserve this behavior or decide to combine transfer + payment.
- Events: `DatasetBought(uint256 indexed tokenId, address indexed buyer, address indexed seller, uint256 price)`

### Phase 7: Token Metadata Update
Implement `updateTokenMetadata(uint256 tokenId, string calldata uri)`:
- Only token owner can call
- Update token URI (use ERC721URIStorage from OpenZeppelin)
- Events: `TokenMetadataUpdated(uint256 indexed tokenId)`

### Phase 8: FA2 → ERC-721 Transfer Adaptation
The original FA2 transfer also updates `datasets.owner` and `owners` mapping. In Solidity:
- Override `_update()` (or `_beforeTokenTransfer` in older OZ) in ERC721 to also update `datasets[tokenId].owner`
- `ERC721Enumerable` already handles the per-owner token tracking (replacing `owners` big_map)

### Phase 9: Testing
- Port test scenarios from `backend/app/test_main.py` and any existing contract tests
- Test role-based access control for each entrypoint
- Test buy flow (price matching, cert validation, fund transfer)
- Test mint flow (provider only, auto-increment IDs, cert creation)
- Test cert flow (certifier only, owner cannot self-certify)
- Test transfer hooks (dataset owner updates on transfer)

### Phase 10: Deploy Script
- Create deploy script (Hardhat ignition or Foundry script)
- Set initial certifier role at construction
- Mirror the existing `scripts/deploy.js` logic

## Relevant Files

### Source (CameLIGO — to read/reference)
- `contracts/contracts/src/taia_x_main.mligo` — main entrypoint dispatcher
- `contracts/contracts/src/domain_storage/storage_definition.mligo` — top-level storage type
- `contracts/contracts/src/domain_storage/dataset_definition.mligo` — Dataset struct
- `contracts/contracts/src/domain_storage/cert_definition.mligo` — Cert struct + enum
- `contracts/contracts/src/domain_storage/user_definition.mligo` — role types
- `contracts/contracts/src/domain_storage/marketplace_definition.mligo` — marketplace types
- `contracts/contracts/src/entrypoints/dataset_entrypoints/mint.mligo` — mint logic
- `contracts/contracts/src/entrypoints/dataset_entrypoints/buy.mligo` — buy logic
- `contracts/contracts/src/entrypoints/dataset_entrypoints/update_token_metadata.mligo` — metadata update
- `contracts/contracts/src/entrypoints/cert_entrypoints/update_certs.mligo` — cert update
- `contracts/contracts/src/entrypoints/user_entrypoints/update_user_roles.mligo` — role management
- `contracts/contracts/src/entrypoints/helpers/*.mligo` — helper functions
- `contracts/contracts/src/tzip-12/fa2_interface.mligo` — FA2 types
- `contracts/contracts/src/tzip-12/lib/fa2_operator_lib.mligo` — operator logic

### Target (Solidity — to create)
- `contracts-solidity/contracts/TaiaXMarketplace.sol` — main contract
- `contracts-solidity/contracts/interfaces/ITaiaXMarketplace.sol` — interface (optional)
- `contracts-solidity/test/TaiaXMarketplace.test.js` — tests
- `contracts-solidity/scripts/deploy.js` — deployment
- `contracts-solidity/hardhat.config.js` — Hardhat config

## Verification
1. Compile with `npx hardhat compile` — zero errors/warnings
2. Run unit tests covering: mint (provider-only, auto-ID), buy (consumer-only, price match, cert check, ETH transfer), updateCerts (certifier-only, owner ≠ certifier), updateUserRoles (self-only, no certifier), transfer (dataset.owner sync), updateTokenMetadata (owner-only)
3. Gas report: verify no unbounded loops (batch operations should have reasonable max sizes)
4. Static analysis with Slither for security vulnerabilities
5. Manual review: compare each entrypoint's behavior to original mligo logic side-by-side

## Decisions
- **Buy behavior**: The original buy only transfers funds, NOT the NFT. Decision needed: keep this (two-step: buy pays + separate transfer) or combine into atomic buy-and-transfer.
- **Framework**: Hardhat recommended (more ecosystem support, matches existing JS deploy script style).
- **Operator storage**: ERC-721's native approve/setApprovalForAll replaces FA2 operator_storage. No custom operator mapping needed.
- **Token metadata**: Use `ERC721URIStorage` from OpenZeppelin to store per-token URI, replacing the raw `token_metadata` big_map.
- **Owners reverse index**: `ERC721Enumerable` replaces the manual `owners: (address → token_id set)` big_map.
- **Hook system**: FA2 sender/receiver hooks (fa2_owner_hooks_lib, fa2_transfer_hook_lib) are NOT used in the main contract logic — they are library code. Skip translating these unless needed.
- **Scope**: Translate the core marketplace contract. The TZIP-12 library code (hooks, permissions descriptor) is reference implementation — only translate what's actually used.
