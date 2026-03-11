import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { network } from "hardhat";
import { parseEther, keccak256, toHex, zeroAddress, getAddress } from "viem";

const { viem, networkHelpers } = await network.connect();

// Role enum values (must match contract)
const Role = { Consumer: 0, Provider: 1, Certifier: 2 } as const;
const CertState = { Pending: 0, Certified: 1, Rejected: 2 } as const;

// Helper to create a keccak256 hash from a string
function dataHash(data: string) {
  return keccak256(toHex(data));
}

// =========================================================================
//  FIXTURE
// =========================================================================

async function deployCodexFixture() {
  const [ownerWallet, certifierWallet, providerWallet, consumerWallet, otherWallet] =
    await viem.getWalletClients();

  const codex = await viem.deployContract("Codex", [
    certifierWallet.account.address,
  ]);

  // Setup roles: provider registers as Provider, consumer registers as Consumer
  await codex.write.addRole(
    [Role.Provider],
    { account: providerWallet.account }
  );
  await codex.write.addRole(
    [Role.Consumer],
    { account: consumerWallet.account }
  );

  return { codex, ownerWallet, certifierWallet, providerWallet, consumerWallet, otherWallet };
}

// Helper fixture: deploys + mints one dataset (token 0)
async function deployAndMintFixture() {
  const fixture = await deployCodexFixture();
  const { codex, providerWallet } = fixture;

  await codex.write.mint(
    [
      {
        owner: providerWallet.account.address,
        operator: zeroAddress,
        tokenMetadataUri: "ipfs://QmTest",
        price: parseEther("1"),
        hash: dataHash("data"),
      },
    ],
    { account: providerWallet.account }
  );

  return fixture;
}

// Helper fixture: deploys + mints + certifies one dataset (token 0)
async function deployMintAndCertifyFixture() {
  const fixture = await deployAndMintFixture();
  const { codex, certifierWallet } = fixture;

  await codex.write.updateCerts(
    [[{ isCertify: true, datasetId: 0n, hash: dataHash("cert") }]],
    { account: certifierWallet.account }
  );

  return fixture;
}

// =========================================================================
//  ROLE MANAGEMENT
// =========================================================================

describe("Codex", function () {
  describe("Role Management", function () {
    it("should set certifier role at deployment", async function () {
      const { codex, certifierWallet } = await networkHelpers.loadFixture(deployCodexFixture);

      const hasCertifier = await codex.read.hasRole([
        certifierWallet.account.address,
        Role.Certifier,
      ]);
      assert.equal(hasCertifier, true);
    });

    it("should allow user to add Consumer/Provider roles", async function () {
      const { codex, otherWallet } = await networkHelpers.loadFixture(deployCodexFixture);

      await codex.write.addRole(
        [Role.Consumer],
        { account: otherWallet.account }
      );
      await codex.write.addRole(
        [Role.Provider],
        { account: otherWallet.account }
      );

      assert.equal(
        await codex.read.hasRole([otherWallet.account.address, Role.Consumer]),
        true
      );
      assert.equal(
        await codex.read.hasRole([otherWallet.account.address, Role.Provider]),
        true
      );
    });

    it("should allow user to remove own role", async function () {
      const { codex, providerWallet } = await networkHelpers.loadFixture(deployCodexFixture);

      await codex.write.removeRole(
        [Role.Provider],
        { account: providerWallet.account }
      );

      assert.equal(
        await codex.read.hasRole([providerWallet.account.address, Role.Provider]),
        false
      );
    });

    it("should prevent self-assignment of Certifier role", async function () {
      const { codex, otherWallet } = await networkHelpers.loadFixture(deployCodexFixture);

      await viem.assertions.revertWithCustomError(
        codex.write.addRole(
          [Role.Certifier],
          { account: otherWallet.account }
        ),
        codex,
        "CannotModifyCertifierRole"
      );
    });

    it("should allow owner to grant/revoke certifier", async function () {
      const { codex, ownerWallet, otherWallet } =
        await networkHelpers.loadFixture(deployCodexFixture);

      await codex.write.grantCertifier([otherWallet.account.address], {
        account: ownerWallet.account,
      });
      assert.equal(
        await codex.read.hasRole([otherWallet.account.address, Role.Certifier]),
        true
      );

      await codex.write.revokeCertifier([otherWallet.account.address], {
        account: ownerWallet.account,
      });
      assert.equal(
        await codex.read.hasRole([otherWallet.account.address, Role.Certifier]),
        false
      );
    });

    it("should prevent non-owner from granting certifier", async function () {
      const { codex, otherWallet } = await networkHelpers.loadFixture(deployCodexFixture);

      await viem.assertions.revertWithCustomError(
        codex.write.grantCertifier([otherWallet.account.address], {
          account: otherWallet.account,
        }),
        codex,
        "OwnableUnauthorizedAccount"
      );
    });

    it("should emit UserRoleUpdated events", async function () {
      const { codex, otherWallet } = await networkHelpers.loadFixture(deployCodexFixture);

      await viem.assertions.emitWithArgs(
        codex.write.addRole(
          [Role.Consumer],
          { account: otherWallet.account }
        ),
        codex,
        "UserRoleUpdated",
        [getAddress(otherWallet.account.address), Role.Consumer, true]
      );
    });
  });

  // =========================================================================
  //  MINTING
  // =========================================================================

  describe("Minting", function () {
    it("should mint a dataset NFT", async function () {
      const { codex, providerWallet } = await networkHelpers.loadFixture(deployCodexFixture);

      await viem.assertions.emitWithArgs(
        codex.write.mint(
          [
            {
              owner: providerWallet.account.address,
              operator: zeroAddress,
              tokenMetadataUri: "ipfs://QmTest",
              price: parseEther("1"),
              hash: dataHash("data"),
            },
          ],
          { account: providerWallet.account }
        ),
        codex,
        "DatasetMinted",
        [0n, getAddress(providerWallet.account.address), parseEther("1")]
      );

      assert.equal(
        getAddress(await codex.read.ownerOf([0n])),
        getAddress(providerWallet.account.address)
      );
      assert.equal(await codex.read.tokenURI([0n]), "ipfs://QmTest");
      assert.equal(await codex.read.nextDatasetId(), 1n);

      const [isOwned, owner, price] = await codex.read.datasets([0n]);
      assert.equal(isOwned, true);
      assert.equal(getAddress(owner), getAddress(providerWallet.account.address));
      assert.equal(price, parseEther("1"));

      const [, , , state] = await codex.read.certificates([0n]);
      assert.equal(state, CertState.Pending);
    });

    it("should mint with operator approval", async function () {
      const { codex, providerWallet, otherWallet } =
        await networkHelpers.loadFixture(deployCodexFixture);

      await codex.write.mint(
        [
          {
            owner: providerWallet.account.address,
            operator: otherWallet.account.address,
            tokenMetadataUri: "ipfs://QmTest",
            price: parseEther("1"),
            hash: dataHash("data"),
          },
        ],
        { account: providerWallet.account }
      );

      assert.equal(
        getAddress(await codex.read.getApproved([0n])),
        getAddress(otherWallet.account.address)
      );
    });

    it("should auto-increment dataset IDs", async function () {
      const { codex, providerWallet } = await networkHelpers.loadFixture(deployCodexFixture);

      for (let i = 0; i < 3; i++) {
        await codex.write.mint(
          [
            {
              owner: providerWallet.account.address,
              operator: zeroAddress,
              tokenMetadataUri: `ipfs://Qm${i}`,
              price: parseEther("1"),
              hash: dataHash(`data${i}`),
            },
          ],
          { account: providerWallet.account }
        );
      }

      assert.equal(await codex.read.nextDatasetId(), 3n);
      assert.equal(await codex.read.datasetCount(), 3n);
    });

    it("should reject mint from non-provider", async function () {
      const { codex, consumerWallet } = await networkHelpers.loadFixture(deployCodexFixture);

      await viem.assertions.revertWithCustomError(
        codex.write.mint(
          [
            {
              owner: consumerWallet.account.address,
              operator: zeroAddress,
              tokenMetadataUri: "ipfs://QmTest",
              price: parseEther("1"),
              hash: dataHash("data"),
            },
          ],
          { account: consumerWallet.account }
        ),
        codex,
        "OnlyProvider"
      );
    });
  });

  // =========================================================================
  //  CERTIFICATION
  // =========================================================================

  describe("Certification", function () {
    it("should allow certifier to certify a dataset", async function () {
      const { codex, certifierWallet } =
        await networkHelpers.loadFixture(deployAndMintFixture);

      const hash = dataHash("cert-data");

      await viem.assertions.emitWithArgs(
        codex.write.updateCerts(
          [[{ isCertify: true, datasetId: 0n, hash }]],
          { account: certifierWallet.account }
        ),
        codex,
        "CertUpdated",
        [0n, CertState.Certified, getAddress(certifierWallet.account.address)]
      );

      const [, issuer, , state] = await codex.read.certificates([0n]);
      assert.equal(state, CertState.Certified);
      assert.equal(getAddress(issuer), getAddress(certifierWallet.account.address));
    });

    it("should allow certifier to reject a dataset", async function () {
      const { codex, certifierWallet } =
        await networkHelpers.loadFixture(deployAndMintFixture);

      await codex.write.updateCerts(
        [[{ isCertify: false, datasetId: 0n, hash: dataHash("cert-data") }]],
        { account: certifierWallet.account }
      );

      const [, , , state] = await codex.read.certificates([0n]);
      assert.equal(state, CertState.Rejected);
    });

    it("should reject certification from non-certifier", async function () {
      const { codex, otherWallet } =
        await networkHelpers.loadFixture(deployAndMintFixture);

      await viem.assertions.revertWithCustomError(
        codex.write.updateCerts(
          [[{ isCertify: true, datasetId: 0n, hash: dataHash("cert-data") }]],
          { account: otherWallet.account }
        ),
        codex,
        "OnlyCertifier"
      );
    });

    it("should prevent dataset owner from certifying own dataset", async function () {
      const { codex, ownerWallet, providerWallet } =
        await networkHelpers.loadFixture(deployAndMintFixture);

      // Grant certifier role to provider (who is also the dataset owner)
      await codex.write.grantCertifier([providerWallet.account.address], {
        account: ownerWallet.account,
      });

      await viem.assertions.revertWithCustomError(
        codex.write.updateCerts(
          [[{ isCertify: true, datasetId: 0n, hash: dataHash("cert-data") }]],
          { account: providerWallet.account }
        ),
        codex,
        "OwnerCannotCertifyOwnDataset"
      );
    });

    it("should reject certification for non-existent dataset", async function () {
      const { codex, certifierWallet } =
        await networkHelpers.loadFixture(deployAndMintFixture);

      await viem.assertions.revertWithCustomError(
        codex.write.updateCerts(
          [[{ isCertify: true, datasetId: 999n, hash: dataHash("cert-data") }]],
          { account: certifierWallet.account }
        ),
        codex,
        "DatasetNotFound"
      );
    });

    it("should handle batch certifications", async function () {
      const { codex, providerWallet, certifierWallet } =
        await networkHelpers.loadFixture(deployAndMintFixture);

      // Mint a second dataset
      await codex.write.mint(
        [
          {
            owner: providerWallet.account.address,
            operator: zeroAddress,
            tokenMetadataUri: "ipfs://QmTest2",
            price: parseEther("2"),
            hash: dataHash("data2"),
          },
        ],
        { account: providerWallet.account }
      );

      const hash = dataHash("cert-data");
      await codex.write.updateCerts(
        [
          [
            { isCertify: true, datasetId: 0n, hash },
            { isCertify: false, datasetId: 1n, hash },
          ],
        ],
        { account: certifierWallet.account }
      );

      const [, , , state0] = await codex.read.certificates([0n]);
      const [, , , state1] = await codex.read.certificates([1n]);
      assert.equal(state0, CertState.Certified);
      assert.equal(state1, CertState.Rejected);
    });
  });

  // =========================================================================
  //  BUY
  // =========================================================================

  describe("Buy", function () {
    const price = parseEther("1");

    it("should allow consumer to buy a certified dataset", async function () {
      const { codex, providerWallet, consumerWallet } =
        await networkHelpers.loadFixture(deployMintAndCertifyFixture);

      await viem.assertions.balancesHaveChanged(
        codex.write.buy([0n], {
          account: consumerWallet.account,
          value: price,
        }),
        [{ address: providerWallet.account.address, amount: price }]
      );

      // NFT should now belong to the buyer
      assert.equal(
        getAddress(await codex.read.ownerOf([0n])),
        getAddress(consumerWallet.account.address)
      );
      const [, owner] = await codex.read.datasets([0n]);
      assert.equal(getAddress(owner), getAddress(consumerWallet.account.address));
    });

    it("should emit DatasetBought on buy", async function () {
      const { codex, providerWallet, consumerWallet } =
        await networkHelpers.loadFixture(deployMintAndCertifyFixture);

      await viem.assertions.emitWithArgs(
        codex.write.buy([0n], {
          account: consumerWallet.account,
          value: price,
        }),
        codex,
        "DatasetBought",
        [
          0n,
          getAddress(consumerWallet.account.address),
          getAddress(providerWallet.account.address),
          price,
        ]
      );
    });

    it("should reject buy from non-consumer", async function () {
      const { codex, otherWallet } =
        await networkHelpers.loadFixture(deployMintAndCertifyFixture);

      await viem.assertions.revertWithCustomError(
        codex.write.buy([0n], { account: otherWallet.account, value: price }),
        codex,
        "OnlyConsumer"
      );
    });

    it("should reject buy with wrong price", async function () {
      const { codex, consumerWallet } =
        await networkHelpers.loadFixture(deployMintAndCertifyFixture);

      await viem.assertions.revertWithCustomError(
        codex.write.buy([0n], {
          account: consumerWallet.account,
          value: parseEther("0.5"),
        }),
        codex,
        "PriceMismatch"
      );
    });

    it("should reject buy if buyer is owner", async function () {
      const { codex, providerWallet } =
        await networkHelpers.loadFixture(deployMintAndCertifyFixture);

      // Provider is also a consumer for this test
      await codex.write.addRole(
        [Role.Consumer],
        { account: providerWallet.account }
      );

      await viem.assertions.revertWithCustomError(
        codex.write.buy([0n], {
          account: providerWallet.account,
          value: price,
        }),
        codex,
        "BuyerIsOwner"
      );
    });

    it("should reject buy if certificate is not valid", async function () {
      const { codex, consumerWallet } =
        await networkHelpers.loadFixture(deployAndMintFixture);

      await viem.assertions.revertWithCustomError(
        codex.write.buy([0n], {
          account: consumerWallet.account,
          value: price,
        }),
        codex,
        "CertInvalid"
      );
    });

    it("should reject buy for non-existent dataset", async function () {
      const { codex, consumerWallet } =
        await networkHelpers.loadFixture(deployMintAndCertifyFixture);

      await viem.assertions.revertWithCustomError(
        codex.write.buy([999n], {
          account: consumerWallet.account,
          value: price,
        }),
        codex,
        "DatasetNotFound"
      );
    });
  });

  // =========================================================================
  //  TOKEN METADATA UPDATE
  // =========================================================================

  describe("Token Metadata Update", function () {
    it("should allow owner to update token metadata", async function () {
      const { codex, providerWallet } =
        await networkHelpers.loadFixture(deployAndMintFixture);

      await viem.assertions.emitWithArgs(
        codex.write.updateTokenMetadata([0n, "ipfs://QmUpdated"], {
          account: providerWallet.account,
        }),
        codex,
        "TokenMetadataUpdated",
        [0n, "ipfs://QmUpdated"]
      );

      assert.equal(await codex.read.tokenURI([0n]), "ipfs://QmUpdated");
    });

    it("should reject non-owner from updating metadata", async function () {
      const { codex, otherWallet } =
        await networkHelpers.loadFixture(deployAndMintFixture);

      await viem.assertions.revertWithCustomError(
        codex.write.updateTokenMetadata([0n, "ipfs://QmEvil"], {
          account: otherWallet.account,
        }),
        codex,
        "OnlyTokenOwner"
      );
    });
  });

  // =========================================================================
  //  TRANSFER & DATASET OWNER SYNC
  // =========================================================================

  describe("Transfer & Dataset Owner Sync", function () {
    it("should sync dataset.owner on ERC721 transfer", async function () {
      const { codex, providerWallet, consumerWallet } =
        await networkHelpers.loadFixture(deployAndMintFixture);

      await codex.write.transferFrom(
        [providerWallet.account.address, consumerWallet.account.address, 0n],
        { account: providerWallet.account }
      );

      assert.equal(
        getAddress(await codex.read.ownerOf([0n])),
        getAddress(consumerWallet.account.address)
      );

      const [, owner] = await codex.read.datasets([0n]);
      assert.equal(getAddress(owner), getAddress(consumerWallet.account.address));
    });

    it("should track per-owner tokens via ERC721Enumerable", async function () {
      const { codex, providerWallet, consumerWallet } =
        await networkHelpers.loadFixture(deployAndMintFixture);

      // Mint a second token
      await codex.write.mint(
        [
          {
            owner: providerWallet.account.address,
            operator: zeroAddress,
            tokenMetadataUri: "ipfs://QmTest2",
            price: parseEther("2"),
            hash: dataHash("data2"),
          },
        ],
        { account: providerWallet.account }
      );

      assert.equal(await codex.read.balanceOf([providerWallet.account.address]), 2n);
      assert.equal(
        await codex.read.tokenOfOwnerByIndex([providerWallet.account.address, 0n]),
        0n
      );
      assert.equal(
        await codex.read.tokenOfOwnerByIndex([providerWallet.account.address, 1n]),
        1n
      );

      // Transfer token 0 to consumer
      await codex.write.transferFrom(
        [providerWallet.account.address, consumerWallet.account.address, 0n],
        { account: providerWallet.account }
      );

      assert.equal(await codex.read.balanceOf([providerWallet.account.address]), 1n);
      assert.equal(await codex.read.balanceOf([consumerWallet.account.address]), 1n);
    });
  });

  // =========================================================================
  //  VIEW HELPERS
  // =========================================================================

  describe("View Helpers", function () {
    it("should report cert validity", async function () {
      const { codex, certifierWallet } =
        await networkHelpers.loadFixture(deployAndMintFixture);

      assert.equal(await codex.read.isCertValid([0n]), false);

      await codex.write.updateCerts(
        [[{ isCertify: true, datasetId: 0n, hash: dataHash("cert") }]],
        { account: certifierWallet.account }
      );

      assert.equal(await codex.read.isCertValid([0n]), true);
    });
  });
});
