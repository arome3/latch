#!/usr/bin/env npx tsx
/**
 * Latch Audit Access CLI
 *
 * A command-line tool for auditors to:
 * - Generate RSA key pairs
 * - Request access to batch data
 * - Decrypt batch data after approval
 * - List pending access requests
 *
 * Usage:
 *   npx tsx scripts/audit/cli.ts generate-keys [output-dir]
 *   npx tsx scripts/audit/cli.ts request-access <rpc> <contract> <poolId> <batchId>
 *   npx tsx scripts/audit/cli.ts decrypt-batch <encrypted-key> <data-path> [private-key-path]
 *   npx tsx scripts/audit/cli.ts list-requests <rpc> <contract> [poolId]
 */

import { Command } from "commander";
import * as fs from "fs";
import * as path from "path";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  getContract,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  generateAuditorKeyPair,
  saveKeyPair,
  loadKeyPair,
  loadPrivateKey,
  decryptKey,
  decryptBatchData,
  importKey,
  type BatchData,
} from "./encryption";

// ============ ABI Definitions ============

const AUDIT_ACCESS_ABI = parseAbi([
  // View functions
  "function poolOperators(bytes32 poolId) external view returns (address)",
  "function isAuditorAuthorized(bytes32 poolId, address auditor) external view returns (bool)",
  "function hasRole(bytes32 poolId, address auditor, uint8 requiredRole) external view returns (bool)",
  "function getEncryptedBatchData(bytes32 poolId, uint64 batchId) external view returns ((bytes encryptedOrders, bytes encryptedFills, bytes32 ordersHash, bytes32 fillsHash, bytes32 keyHash, bytes16 iv, uint64 storedAtBlock, uint64 orderCount))",
  "function getAccessRequest(uint256 requestId) external view returns ((bytes32 poolId, uint64 batchId, address requester, uint64 requestedAt, uint8 status, bytes encryptedKey, string reason))",
  "function getPendingRequests(bytes32 poolId) external view returns (uint256[])",
  "function nextRequestId() external view returns (uint256)",

  // Write functions
  "function requestAccess(bytes32 poolId, uint64 batchId, string reason) external returns (uint256 requestId)",
  "function recordDataAccess(bytes32 poolId, uint64 batchId) external",

  // Events
  "event AccessRequested(uint256 indexed requestId, bytes32 indexed poolId, uint64 indexed batchId, address requester)",
  "event AccessApproved(uint256 indexed requestId, address indexed approver)",
]);

// ============ Types ============

interface EncryptedBatchDataResult {
  encryptedOrders: Hex;
  encryptedFills: Hex;
  ordersHash: Hex;
  fillsHash: Hex;
  keyHash: Hex;
  iv: Hex;
  storedAtBlock: bigint;
  orderCount: bigint;
}

interface AccessRequestResult {
  poolId: Hex;
  batchId: bigint;
  requester: Address;
  requestedAt: bigint;
  status: number;
  encryptedKey: Hex;
  reason: string;
}

const REQUEST_STATUS = ["PENDING", "APPROVED", "REJECTED", "EXPIRED"] as const;

// ============ CLI Setup ============

const program = new Command();

program
  .name("latch-audit")
  .description("Latch Audit Access CLI for auditors")
  .version("1.0.0");

// ============ Generate Keys Command ============

program
  .command("generate-keys")
  .description("Generate RSA-2048 key pair for audit access")
  .argument("[output-dir]", "Directory to save keys", "./audit-keys")
  .option("-p, --prefix <prefix>", "Filename prefix", "auditor")
  .action((outputDir: string, options: { prefix: string }) => {
    console.log("\nGenerating RSA-2048 key pair...\n");

    const keyPair = generateAuditorKeyPair();
    saveKeyPair(keyPair, outputDir, options.prefix);

    console.log("\n--- Key Generation Complete ---");
    console.log(`Public key:  ${outputDir}/${options.prefix}_public.pem`);
    console.log(`Private key: ${outputDir}/${options.prefix}_private.pem`);
    console.log(`\nPublic key hash (for on-chain authorization):`);
    console.log(`  ${keyPair.publicKeyHash}`);
    console.log(
      "\nProvide this hash to the pool operator to authorize your access."
    );
    console.log("Keep your private key SECURE and never share it!\n");
  });

// ============ Request Access Command ============

program
  .command("request-access")
  .description("Request access to encrypted batch data")
  .requiredOption("-r, --rpc <url>", "RPC endpoint URL")
  .requiredOption("-c, --contract <address>", "AuditAccessModule contract address")
  .requiredOption("-p, --pool <poolId>", "Pool ID (bytes32 hex)")
  .requiredOption("-b, --batch <batchId>", "Batch ID (number)")
  .requiredOption("-k, --private-key <key>", "Your private key for signing")
  .option("--reason <reason>", "Reason for access request", "Audit investigation")
  .action(
    async (options: {
      rpc: string;
      contract: string;
      pool: string;
      batch: string;
      privateKey: string;
      reason: string;
    }) => {
      console.log("\nRequesting access to batch data...\n");

      try {
        const account = privateKeyToAccount(options.privateKey as Hex);
        const client = createWalletClient({
          account,
          transport: http(options.rpc),
        });

        const publicClient = createPublicClient({
          transport: http(options.rpc),
        });

        const contract = getContract({
          address: options.contract as Address,
          abi: AUDIT_ACCESS_ABI,
          client: { public: publicClient, wallet: client },
        });

        // Check if authorized
        const isAuthorized = await contract.read.isAuditorAuthorized([
          options.pool as Hex,
          account.address,
        ]);

        if (!isAuthorized) {
          console.error("Error: You are not authorized as an auditor for this pool.");
          console.log("Please contact the pool operator to get authorization.");
          process.exit(1);
        }

        // Check role (ANALYST = 2)
        const hasAnalystRole = await contract.read.hasRole([
          options.pool as Hex,
          account.address,
          2, // ANALYST
        ]);

        if (!hasAnalystRole) {
          console.error("Error: You need ANALYST or FULL_ACCESS role to request data.");
          process.exit(1);
        }

        // Submit request
        const hash = await contract.write.requestAccess([
          options.pool as Hex,
          BigInt(options.batch),
          options.reason,
        ]);

        console.log("Transaction submitted:", hash);
        console.log("\nWaiting for confirmation...");

        const receipt = await publicClient.waitForTransactionReceipt({ hash });
        console.log("Transaction confirmed in block:", receipt.blockNumber);

        // Get request ID from logs
        const nextId = await contract.read.nextRequestId();
        const requestId = nextId - 1n;

        console.log("\n--- Access Request Submitted ---");
        console.log(`Request ID: ${requestId}`);
        console.log(`Pool ID:    ${options.pool}`);
        console.log(`Batch ID:   ${options.batch}`);
        console.log(`Reason:     ${options.reason}`);
        console.log("\nWait for the pool operator to approve your request.");
        console.log(
          "Check the status with: latch-audit list-requests -r <rpc> -c <contract> -p <poolId>\n"
        );
      } catch (error) {
        console.error("Error submitting request:", error);
        process.exit(1);
      }
    }
  );

// ============ Decrypt Batch Command ============

program
  .command("decrypt-batch")
  .description("Decrypt batch data after access approval")
  .requiredOption("-e, --encrypted-key <hex>", "Encrypted AES key from approval")
  .requiredOption("-d, --data <path>", "Path to encrypted batch data JSON file")
  .option("-k, --private-key <path>", "Path to RSA private key", "./audit-keys/auditor_private.pem")
  .option("-o, --output <path>", "Output path for decrypted data")
  .action(
    async (options: {
      encryptedKey: string;
      data: string;
      privateKey: string;
      output?: string;
    }) => {
      console.log("\nDecrypting batch data...\n");

      try {
        // Load private key
        const privateKeyPem = loadPrivateKey(options.privateKey);
        console.log("Loaded private key from:", options.privateKey);

        // Decrypt AES key
        const encryptedKeyBuffer = Buffer.from(options.encryptedKey.replace("0x", ""), "hex");
        const aesKey = decryptKey(encryptedKeyBuffer, privateKeyPem);
        console.log("Decrypted AES key successfully");

        // Load encrypted data
        const dataJson = fs.readFileSync(options.data, "utf-8");
        const encryptedData = JSON.parse(dataJson) as EncryptedBatchDataResult;

        // Decrypt batch data
        const batchData = decryptBatchData(
          encryptedData.encryptedOrders,
          encryptedData.encryptedFills,
          encryptedData.iv,
          aesKey
        );

        console.log("\n--- Decrypted Batch Data ---");
        console.log(`Orders: ${batchData.orders.length}`);
        console.log(`Fills:  ${batchData.fills.length}`);

        // Output
        const output = JSON.stringify(batchData, (_, v) =>
          typeof v === "bigint" ? v.toString() : v, 2
        );

        if (options.output) {
          fs.writeFileSync(options.output, output);
          console.log(`\nDecrypted data saved to: ${options.output}`);
        } else {
          console.log("\n--- Orders ---");
          batchData.orders.forEach((order, i) => {
            console.log(`  [${i}] ${order.trader}`);
            console.log(`      Amount: ${order.amount}`);
            console.log(`      Price:  ${order.limitPrice}`);
            console.log(`      Side:   ${order.isBuy ? "BUY" : "SELL"}`);
          });

          console.log("\n--- Fills ---");
          batchData.fills.forEach((fill, i) => {
            console.log(`  [${i}] ${fill.trader}`);
            console.log(`      Amount: ${fill.amount}`);
            console.log(`      Price:  ${fill.price}`);
          });
        }
      } catch (error) {
        console.error("Error decrypting data:", error);
        process.exit(1);
      }
    }
  );

// ============ List Requests Command ============

program
  .command("list-requests")
  .description("List access requests for a pool")
  .requiredOption("-r, --rpc <url>", "RPC endpoint URL")
  .requiredOption("-c, --contract <address>", "AuditAccessModule contract address")
  .option("-p, --pool <poolId>", "Pool ID (bytes32 hex) to filter")
  .option("-a, --all", "Show all requests (not just pending)")
  .action(
    async (options: {
      rpc: string;
      contract: string;
      pool?: string;
      all?: boolean;
    }) => {
      console.log("\nFetching access requests...\n");

      try {
        const publicClient = createPublicClient({
          transport: http(options.rpc),
        });

        const contract = getContract({
          address: options.contract as Address,
          abi: AUDIT_ACCESS_ABI,
          client: publicClient,
        });

        if (options.pool) {
          // Get pending requests for specific pool
          const pendingIds = await contract.read.getPendingRequests([
            options.pool as Hex,
          ]);

          console.log(`--- Pending Requests for Pool ${options.pool} ---\n`);

          if (pendingIds.length === 0) {
            console.log("No pending requests.\n");
            return;
          }

          for (const requestId of pendingIds) {
            const request = await contract.read.getAccessRequest([requestId]) as AccessRequestResult;
            console.log(`Request #${requestId}:`);
            console.log(`  Pool:      ${request.poolId}`);
            console.log(`  Batch:     ${request.batchId}`);
            console.log(`  Requester: ${request.requester}`);
            console.log(`  Status:    ${REQUEST_STATUS[request.status]}`);
            console.log(`  Reason:    ${request.reason}`);
            console.log(`  Block:     ${request.requestedAt}`);
            console.log("");
          }
        } else {
          // List recent requests (scan from nextRequestId backwards)
          const nextId = await contract.read.nextRequestId();
          const startId = nextId > 10n ? nextId - 10n : 1n;

          console.log("--- Recent Access Requests ---\n");

          for (let id = startId; id < nextId; id++) {
            try {
              const request = await contract.read.getAccessRequest([id]) as AccessRequestResult;

              if (!options.all && request.status !== 0) {
                continue; // Skip non-pending if not showing all
              }

              console.log(`Request #${id}:`);
              console.log(`  Pool:      ${request.poolId}`);
              console.log(`  Batch:     ${request.batchId}`);
              console.log(`  Requester: ${request.requester}`);
              console.log(`  Status:    ${REQUEST_STATUS[request.status]}`);
              console.log(`  Reason:    ${request.reason}`);

              if (request.status === 1 && request.encryptedKey !== "0x") {
                console.log(`  Key:       ${request.encryptedKey.slice(0, 20)}...`);
              }

              console.log("");
            } catch {
              // Request doesn't exist
              continue;
            }
          }
        }
      } catch (error) {
        console.error("Error fetching requests:", error);
        process.exit(1);
      }
    }
  );

// ============ Fetch Batch Data Command ============

program
  .command("fetch-data")
  .description("Fetch encrypted batch data from chain and save to file")
  .requiredOption("-r, --rpc <url>", "RPC endpoint URL")
  .requiredOption("-c, --contract <address>", "AuditAccessModule contract address")
  .requiredOption("-p, --pool <poolId>", "Pool ID (bytes32 hex)")
  .requiredOption("-b, --batch <batchId>", "Batch ID (number)")
  .option("-o, --output <path>", "Output file path", "./batch_data.json")
  .action(
    async (options: {
      rpc: string;
      contract: string;
      pool: string;
      batch: string;
      output: string;
    }) => {
      console.log("\nFetching encrypted batch data...\n");

      try {
        const publicClient = createPublicClient({
          transport: http(options.rpc),
        });

        const contract = getContract({
          address: options.contract as Address,
          abi: AUDIT_ACCESS_ABI,
          client: publicClient,
        });

        const data = await contract.read.getEncryptedBatchData([
          options.pool as Hex,
          BigInt(options.batch),
        ]) as EncryptedBatchDataResult;

        if (data.storedAtBlock === 0n) {
          console.error("Error: No batch data found for this pool/batch.");
          process.exit(1);
        }

        // Convert BigInts to strings for JSON
        const jsonData = {
          encryptedOrders: data.encryptedOrders,
          encryptedFills: data.encryptedFills,
          ordersHash: data.ordersHash,
          fillsHash: data.fillsHash,
          keyHash: data.keyHash,
          iv: data.iv,
          storedAtBlock: data.storedAtBlock.toString(),
          orderCount: data.orderCount.toString(),
        };

        fs.writeFileSync(options.output, JSON.stringify(jsonData, null, 2));

        console.log("--- Encrypted Batch Data ---");
        console.log(`Pool:         ${options.pool}`);
        console.log(`Batch:        ${options.batch}`);
        console.log(`Order Count:  ${data.orderCount}`);
        console.log(`Stored Block: ${data.storedAtBlock}`);
        console.log(`\nData saved to: ${options.output}`);
        console.log("\nTo decrypt, request access and use the decrypt-batch command.\n");
      } catch (error) {
        console.error("Error fetching data:", error);
        process.exit(1);
      }
    }
  );

// ============ Record Access Command ============

program
  .command("record-access")
  .description("Record that you accessed batch data (audit trail)")
  .requiredOption("-r, --rpc <url>", "RPC endpoint URL")
  .requiredOption("-c, --contract <address>", "AuditAccessModule contract address")
  .requiredOption("-p, --pool <poolId>", "Pool ID (bytes32 hex)")
  .requiredOption("-b, --batch <batchId>", "Batch ID (number)")
  .requiredOption("-k, --private-key <key>", "Your private key for signing")
  .action(
    async (options: {
      rpc: string;
      contract: string;
      pool: string;
      batch: string;
      privateKey: string;
    }) => {
      console.log("\nRecording data access...\n");

      try {
        const account = privateKeyToAccount(options.privateKey as Hex);
        const client = createWalletClient({
          account,
          transport: http(options.rpc),
        });

        const publicClient = createPublicClient({
          transport: http(options.rpc),
        });

        const contract = getContract({
          address: options.contract as Address,
          abi: AUDIT_ACCESS_ABI,
          client: { public: publicClient, wallet: client },
        });

        const hash = await contract.write.recordDataAccess([
          options.pool as Hex,
          BigInt(options.batch),
        ]);

        console.log("Transaction submitted:", hash);

        const receipt = await publicClient.waitForTransactionReceipt({ hash });
        console.log("Transaction confirmed in block:", receipt.blockNumber);

        console.log("\n--- Access Recorded ---");
        console.log(`Pool:  ${options.pool}`);
        console.log(`Batch: ${options.batch}`);
        console.log("Your access has been logged in the immutable audit trail.\n");
      } catch (error) {
        console.error("Error recording access:", error);
        process.exit(1);
      }
    }
  );

// ============ Run CLI ============

program.parse();
