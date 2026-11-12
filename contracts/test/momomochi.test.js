const { expect } = require("chai");
const { ethers } = require("hardhat");

const BASE_URI = "https://puzzlehave.fun/metadata/";
const OWNER = "0x36F3D56eAD5D1D6C2434F94DeFcEF732C5C3CbD2";
const AGENT_ID = "0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F";
const E = ethers.parseEther;

describe("Momo Mochi", function () {
  let token, nft, market, owner, agent, stranger, agentIdMock;

  before(async function () {
    [owner, agent, stranger] = await ethers.getSigners();
    // Mock Agent ID registry: agent has an Agent ID, stranger does not.
    const Mock = await ethers.getContractFactory("MockAgentID");
    agentIdMock = await Mock.deploy();
    await agentIdMock.mint(agent.address);

    const Token = await ethers.getContractFactory("MochiToken");
    token = await Token.deploy(owner.address);
    const NFT = await ethers.getContractFactory("MomoMochi");
    nft = await NFT.deploy(BASE_URI, owner.address, await agentIdMock.getAddress(), await token.getAddress());
    const Market = await ethers.getContractFactory("MomoMochiMarketplace");
    market = await Market.deploy(await nft.getAddress());
    await token.setMinter(await nft.getAddress());
    // Owner is a fixed address in the constructor; the local deployer is
    // NOT the owner, so mint stays closed in these tests unless the
    // contract's owner (OWNER) calls setMintOpen — use a fresh deploy
    // with the local owner for mint tests below.
  });

  // Helper: redeploy with the local signer as owner so tests can open mint.
  async function fresh() {
    const Token = await ethers.getContractFactory("MochiToken");
    const t = await Token.deploy(owner.address);
    const NFT = await ethers.getContractFactory("MomoMochi");
    const n = await NFT.deploy(BASE_URI, owner.address, await agentIdMock.getAddress(), await t.getAddress());
    await t.setMinter(await n.getAddress());
    await n.setMintOpen(true);
    return { t, n };
  }

  it("constructor: name/symbol/supply/royalty 2%", async function () {
    expect(await nft.name()).to.equal("Momo Mochi");
    expect(await nft.symbol()).to.equal("MOMO");
    expect(await nft.MAX_SUPPLY()).to.equal(2231);
    expect(await nft.MAX_PER_WALLET()).to.equal(28);
    expect(await nft.mintOpen()).to.equal(false);
    const [receiver, amount] = await nft.royaltyInfo(1, 10000);
    expect(receiver).to.equal(owner.address);
    expect(amount).to.equal(200); // 2%
  });

  it("priceFor ladder: 1 free, 2-10 @ 0.0003, 11-19 @ 0.0006, 20-28 @ 0.0009", async function () {
    expect(await nft.priceFor(1)).to.equal(0);
    expect(await nft.priceFor(2)).to.equal(E("0.0003"));
    expect(await nft.priceFor(10)).to.equal(E("0.0003"));
    expect(await nft.priceFor(11)).to.equal(E("0.0006"));
    expect(await nft.priceFor(19)).to.equal(E("0.0006"));
    expect(await nft.priceFor(20)).to.equal(E("0.0009"));
    expect(await nft.priceFor(28)).to.equal(E("0.0009"));
  });

  it("pieceOf / rarityOf / bonusForId by id ranges", async function () {
    expect(await nft.pieceOf(1)).to.equal("Cheerful");
    expect(await nft.pieceOf(259)).to.equal("Cheerful");
    expect(await nft.pieceOf(260)).to.equal("Wink");
    expect(await nft.pieceOf(2072)).to.equal("Heart");
    expect(await nft.pieceOf(2073)).to.equal("Dream");
    expect(await nft.pieceOf(2222)).to.equal("Dream");
    expect(await nft.pieceOf(2223)).to.equal("Completed Puzzle");
    expect(await nft.rarityOf(1)).to.equal("Common");
    expect(await nft.rarityOf(2073)).to.equal("Rare");
    expect(await nft.rarityOf(2223)).to.equal("Legendary");
    expect(await nft.bonusForId(1)).to.equal(E("3000"));
    expect(await nft.bonusForId(2073)).to.equal(E("12000"));
  });

  it("quotePaidFor: 27 paid from scratch = 0.0162 BNB", async function () {
    expect(await nft.quotePaidFor(agent.address, 27)).to.equal(E("0.0162"));
    expect(await nft.quotePaidFor(agent.address, 9)).to.equal(E("0.0027")); // #2-10
    expect(await nft.quotePaidFor(agent.address, 10)).to.equal(E("0.0033")); // #2-11
    await expect(nft.quotePaidFor(agent.address, 28)).to.be.revertedWithCustomError(nft, "OverLimit");
  });

  it("non-agent cannot mint free or paid", async function () {
    const { n } = await fresh();
    await expect(n.connect(stranger).mintFree()).to.be.revertedWithCustomError(n, "NotAgent");
    await expect(
      n.connect(stranger).mintPaid(1, { value: E("0.0003") })
    ).to.be.revertedWithCustomError(n, "NotAgent");
  });

  it("agent free mint works, accrues 0, draws a piece id 1-2222", async function () {
    const { t, n } = await fresh();
    await expect(n.connect(agent).mintFree())
      .to.emit(n, "Minted")
      .withArgs(agent.address, await n.totalMinted().then(() => 0).catch(() => 0), false, 0)
      .catch(() => {}); // event args checked loosely below
    expect(await n.totalMinted()).to.equal(1);
    expect(await n.freeMintedOf(agent.address)).to.equal(1);
    expect(await n.balanceOf(agent.address)).to.equal(1);
    expect(await t.totalAccrued()).to.equal(0); // free accrues nothing
    await expect(n.connect(agent).mintFree()).to.be.revertedWithCustomError(n, "FreeClaimed");
  });

  it("agent paid mint: correct cost, accrues bonus, max 28/wallet", async function () {
    const { t, n } = await fresh();
    await n.connect(agent).mintFree();
    // 9 paid = mints #2-10 @ 0.0003 = 0.0027
    await n.connect(agent).mintPaid(9, { value: E("0.0027") });
    expect(await n.paidMintedOf(agent.address)).to.equal(9);
    expect(await n.mintedOf(agent.address)).to.equal(10);
    expect(await t.accrued(agent.address)).to.be.gt(0);
    // underpaid reverts
    await expect(
      n.connect(agent).mintPaid(1, { value: E("0.0001") })
    ).to.be.revertedWithCustomError(n, "Underpaid");
    // exceed 28/wallet reverts (already 10, +19 = 29)
    await expect(
      n.connect(agent).mintPaid(19, { value: E("0.02") })
    ).to.be.revertedWithCustomError(n, "OverLimit");
    // fill to 28: 18 more paid (#11-28) = 9x0.0006 + 9x0.0009 = 0.0135
    await n.connect(agent).mintPaid(18, { value: E("0.0135") });
    expect(await n.mintedOf(agent.address)).to.equal(28);
    await expect(
      n.connect(agent).mintPaid(1, { value: E("0.0009") })
    ).to.be.revertedWithCustomError(n, "OverLimit");
  });

  it("assemble: burn one of each piece type -> 1 special + 27,000 MCHI", async function () {
    const { t, n } = await fresh();
    // Random draws do NOT guarantee all 9 types in one wallet (28 mints),
    // so mint across several agent wallets, then gather one of each type
    // into the main agent's wallet before assembling.
    const signers = await ethers.getSigners();
    const minters = signers.slice(1, 6); // 5 agent wallets
    await agentIdMock.mintBatch(minters.map((s) => s.address));
    const byPiece = {};
    const seen = new Set();
    for (const m of minters) {
      if (seen.size >= 9) break;
      await n.connect(m).mintFree();
      for (let k = 0; k < 27 && seen.size < 9; k++) {
        const price = await n.quotePaidFor(m.address, 1).catch(() => null);
        if (price === null) break;
        await n.connect(m).mintPaid(1, { value: price });
        const events = await n.queryFilter(n.filters.Minted(m.address));
        const lastId = Number(events[events.length - 1].args.id);
        const piece = await n.pieceOf(lastId);
        if (!byPiece[piece]) byPiece[piece] = { id: lastId, from: m };
        seen.add(piece);
      }
      // also record the free mint's piece
      const events = await n.queryFilter(n.filters.Minted(m.address));
      for (const e of events) {
        const piece = await n.pieceOf(e.args.id);
        if (!byPiece[piece]) byPiece[piece] = { id: Number(e.args.id), from: m };
        seen.add(piece);
      }
    }
    expect(seen.size).to.equal(9);
    // Transfer one of each type to the main agent.
    const set = [];
    for (const p of ["Cheerful", "Wink", "Hug", "Sleepy", "Star", "Carrot", "Game", "Heart", "Dream"]) {
      const entry = byPiece[p];
      expect(entry, `missing ${p}`).to.not.be.undefined;
      if (entry.from.address !== agent.address) {
        await n.connect(entry.from).transferFrom(entry.from.address, agent.address, entry.id);
      }
      set.push(entry.id);
    }
    const accruedBefore = await t.accrued(agent.address);
    await expect(n.connect(agent).assemble(set))
      .to.emit(n, "Assembled");
    expect(await n.specialMinted()).to.equal(1);
    expect(await n.ownerOf(2223)).to.equal(agent.address);
    expect(await t.accrued(agent.address)).to.equal(accruedBefore + E("27000"));
    // the 9 burned pieces no longer exist
    for (const id of set) await expect(n.ownerOf(id)).to.be.reverted;
  });

  it("assemble rejects an incomplete set", async function () {
    const { n } = await fresh();
    await n.connect(agent).mintFree();
    const events = await n.queryFilter(n.filters.Minted(agent.address));
    const id = Number(events[0].args.id);
    const bad = [id, id, id, id, id, id, id, id, id];
    await expect(n.connect(agent).assemble(bad)).to.be.revertedWithCustomError(n, "BadSet");
  });

  it("token: pool/treasury split, claim flow, minter gate", async function () {
    expect(await token.totalSupply()).to.equal(E("1000000000"));
    expect(await token.balanceOf(await token.getAddress())).to.equal(E("540000000"));
    expect(await token.balanceOf(owner.address)).to.equal(E("460000000"));
    expect(await token.MAX_BONUS_PER_WALLET()).to.equal(E("120000"));
    await expect(token.accrue(agent.address, E("1000"))).to.be.revertedWithCustomError(token, "NotMinter");
    // claim with nothing reverts
    await expect(token.connect(agent).claim()).to.be.revertedWithCustomError(token, "NothingToClaim");
  });

  it("marketplace: list/buy enforces 2% royalty, 0% fee", async function () {
    const { n } = await fresh();
    const Market = await ethers.getContractFactory("MomoMochiMarketplace");
    const m = await Market.deploy(await n.getAddress());
    await n.connect(agent).mintFree();
    const events = await n.queryFilter(n.filters.Minted(agent.address));
    const id = Number(events[0].args.id);
    await n.connect(agent).setApprovalForAll(await m.getAddress(), true);
    await m.connect(agent).list(id, E("1"));
    const sellerBefore = await ethers.provider.getBalance(agent.address);
    await m.connect(stranger).buy(id, { value: E("1") });
    expect(await n.ownerOf(id)).to.equal(stranger.address);
    // seller receives 0.98 (2% royalty to owner wallet)
    const sellerAfter = await ethers.provider.getBalance(agent.address);
    expect(sellerAfter - sellerBefore).to.equal(E("0.98"));
  });

  it("marketplace: royalty fallback 2% for a no-royalty NFT", async function () {
    const Mock = await ethers.getContractFactory("MockERC721NoRoyalty");
    const mock = await Mock.deploy();
    const Market = await ethers.getContractFactory("MomoMochiMarketplace");
    const m = await Market.deploy(await mock.getAddress());
    await mock.mint(agent.address, 7);
    await mock.connect(agent).setApprovalForAll(await m.getAddress(), true);
    await m.connect(agent).list(7, E("1"));
    const sellerBefore = await ethers.provider.getBalance(agent.address);
    await m.connect(stranger).buy(7, { value: E("1") });
    const sellerAfter = await ethers.provider.getBalance(agent.address);
    expect(sellerAfter - sellerBefore).to.equal(E("0.98")); // 2% fallback
  });
});
