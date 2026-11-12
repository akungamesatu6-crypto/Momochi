// Momo Mochi deploy SIMULATION ONLY — no mainnet transaction is sent.
// Computes CREATE2 predicted addresses exactly as the deterministic-proxy
// route did for BNTB/SAKURA, and measures gas on the local network.
// Deploy order: MCHI token first (constructor: owner only), then the
// Momo Mochi NFT (constructor: baseURI, owner, Agent ID registry,
// predicted MCHI address), then the marketplace (constructor: predicted
// NFT address). After deploy the owner must call token.setMinter(nft).
// Mint stays CLOSED (mintOpen=false) until the owner calls setMintOpen(true).
// Model (user-confirmed 2026-11-13): supply 2,222 pieces + 9 special;
// price ladder #1 FREE, #2-10 @ 0.0003, #11-19 @ 0.0006, #20-28 @ 0.0009;
// max 28/wallet; Agent ID gate on BOTH free and paid mints; public can
// connect wallet to browse but cannot mint without an Agent ID.
// Bonus: regular 3,000 / Dream 12,000 / special burn 27,000 $MCHI.
// Royalty 2%. assemble() burns a 9-piece set -> 1 special (cap 9).
// Run: npx hardhat run scripts/deploy_simulation.js
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

const BASE_URI = "https://puzzlehave.fun/metadata/";
const OWNER = "0x36F3D56eAD5D1D6C2434F94DeFcEF732C5C3CbD2";
const AGENT_ID = "0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F"; // SPACE ID Agent ID registry
const PROXY = "0x4e59b44847b379578588920cA78FbF26c0B4956C"; // deterministic deployment proxy
const PROXY_CREATION =
  "0x604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

function predict(artifact, argTypes, argValues) {
  const args = ethers.AbiCoder.defaultAbiCoder().encode(argTypes, argValues);
  const creation = artifact.bytecode + args.slice(2);
  const predicted = ethers.getCreate2Address(PROXY, ethers.ZeroHash, ethers.keccak256(creation));
  const inputData = "0x" + "00".repeat(32) + creation.slice(2);
  return { creation, predicted, inputData };
}

async function main() {
  const outDir = path.join(__dirname, "..");
  const [deployer, agent] = await ethers.getSigners();

  // --- MCHI token: predict first (constructor args: owner) ---
  const tokenArtifact = await hre.artifacts.readArtifact("MochiToken");
  const tokenPred = predict(tokenArtifact, ["address"], [OWNER]);

  // --- NFT: predict (constructor args: baseURI, owner, agentId, token=<redacted>) ---
  const nftArtifact = await hre.artifacts.readArtifact("MomoMochi");
  const nftPred = predict(
    nftArtifact,
    ["string", "address", "address", "address"],
    [BASE_URI, OWNER, AGENT_ID, tokenPred.predicted]
  );

  // --- Marketplace: predict (constructor args: nft=predicted) ---
  const marketFactory = await ethers.getContractFactory("MomoMochiMarketplace");
  const marketDeployTx = await marketFactory.getDeployTransaction(nftPred.predicted);
  const marketCreation = marketDeployTx.data;
  const marketPredicted = ethers.getCreate2Address(PROXY, ethers.ZeroHash, ethers.keccak256(marketCreation));
  const marketInputData = ethers.hexlify(ethers.concat([ethers.ZeroHash, marketCreation]));

  fs.writeFileSync(path.join(outDir, "token_creation.txt"), tokenPred.creation);
  fs.writeFileSync(path.join(outDir, "token_inputdata.txt"), tokenPred.inputData);
  fs.writeFileSync(path.join(outDir, "token_predicted.txt"), tokenPred.predicted);
  fs.writeFileSync(path.join(outDir, "nft_creation.txt"), nftPred.creation);
  fs.writeFileSync(path.join(outDir, "nft_inputdata.txt"), nftPred.inputData);
  fs.writeFileSync(path.join(outDir, "nft_predicted.txt"), nftPred.predicted);
  fs.writeFileSync(path.join(outDir, "market_creation.txt"), marketCreation);
  fs.writeFileSync(path.join(outDir, "market_inputdata.txt"), marketInputData);
  fs.writeFileSync(path.join(outDir, "market_predicted.txt"), marketPredicted);

  console.log("MCHI token predicted:", tokenPred.predicted);
  console.log("MomoMochi NFT predicted:", nftPred.predicted);
  console.log("Marketplace predicted:", marketPredicted);

  // --- Local deploy + gas measurements ---
  const Token = await ethers.getContractFactory("MochiToken");
  const token = await Token.deploy(OWNER);
  const tokenReceipt = await token.deploymentTransaction().wait();
  console.log("token gas:", tokenReceipt.gasUsed.toString());

  const NFT = await ethers.getContractFactory("MomoMochi");
  const nft = await NFT.deploy(BASE_URI, OWNER, AGENT_ID, await token.getAddress());
  const nftReceipt = await nft.deploymentTransaction().wait();
  console.log("nft gas:", nftReceipt.gasUsed.toString());

  const Market = await ethers.getContractFactory("MomoMochiMarketplace");
  const market = await Market.deploy(await nft.getAddress());
  const marketReceipt = await market.deploymentTransaction().wait();
  console.log("market gas:", marketReceipt.gasUsed.toString());

  // --- Wire token minter ---
  // In production BAW (the token owner) calls setMinter(nft) after deploy.
  // Locally the deployer is not BAW, so this reverts here — expected.
  try {
    await token.setMinter(await nft.getAddress());
    console.log("token minter set to NFT");
  } catch (e) {
    console.log("setMinter skipped locally (owner is BAW in production, not the local deployer)");
  }

  // --- Sanity checks ---
  console.log("NFT name:", await nft.name(), "symbol:", await nft.symbol());
  console.log("MAX_SUPPLY:", (await nft.MAX_SUPPLY()).toString());
  console.log("royaltyInfo(1, 10000):", await nft.royaltyInfo(1, 10000));
  console.log("priceFor(1):", ethers.formatEther(await nft.priceFor(1)));
  console.log("priceFor(2):", ethers.formatEther(await nft.priceFor(2)));
  console.log("priceFor(10):", ethers.formatEther(await nft.priceFor(10)));
  console.log("priceFor(11):", ethers.formatEther(await nft.priceFor(11)));
  console.log("priceFor(19):", ethers.formatEther(await nft.priceFor(19)));
  console.log("priceFor(20):", ethers.formatEther(await nft.priceFor(20)));
  console.log("priceFor(28):", ethers.formatEther(await nft.priceFor(28)));
  console.log("bonusForId(1):", ethers.formatEther(await nft.bonusForId(1)));
  console.log("bonusForId(2073):", ethers.formatEther(await nft.bonusForId(2073)));
  console.log("pieceOf(1):", await nft.pieceOf(1), "| pieceOf(2073):", await nft.pieceOf(2073), "| pieceOf(2223):", await nft.pieceOf(2223));
  console.log("token totalSupply:", ethers.formatEther(await token.totalSupply()));
  console.log("token BONUS_POOL:", ethers.formatEther(await token.BONUS_POOL()));

  fs.writeFileSync(
    path.join(outDir, "deploy_simulation.json"),
    JSON.stringify(
      {
        token: tokenPred.predicted,
        nft: nftPred.predicted,
        market: marketPredicted,
        tokenGas: tokenReceipt.gasUsed.toString(),
        nftGas: nftReceipt.gasUsed.toString(),
        marketGas: marketReceipt.gasUsed.toString(),
      },
      null,
      2
    )
  );
  console.log("simulation done");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
