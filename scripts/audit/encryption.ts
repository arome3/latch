/**
 * Encryption utilities for the Latch Audit Access System
 *
 * This module provides cryptographic functions for:
 * - AES-256-GCM encryption/decryption of batch data
 * - RSA-2048 key pair generation and key encryption
 * - Key derivation and hashing
 *
 * Security Model:
 * - Batch data is encrypted with AES-256-GCM (symmetric)
 * - AES keys are encrypted with auditor's RSA public key (asymmetric)
 * - All operations use Node.js crypto module for security
 */

import * as crypto from "crypto";
import { keccak256, encodePacked, toHex, bytesToHex, hexToBytes } from "viem";

// ============ Types ============

export interface EncryptedData {
  ciphertext: Buffer;
  iv: Buffer;
  authTag: Buffer;
}

export interface RSAKeyPair {
  publicKey: string;
  privateKey: string;
  publicKeyHash: `0x${string}`;
}

export interface BatchData {
  orders: OrderData[];
  fills: FillData[];
}

export interface OrderData {
  trader: `0x${string}`;
  amount: bigint;
  limitPrice: bigint;
  isBuy: boolean;
}

export interface FillData {
  trader: `0x${string}`;
  amount: bigint;
  price: bigint;
}

export interface EncryptedBatchResult {
  encryptedOrders: `0x${string}`;
  encryptedFills: `0x${string}`;
  ordersHash: `0x${string}`;
  fillsHash: `0x${string}`;
  keyHash: `0x${string}`;
  iv: `0x${string}`;
  key: Buffer; // Keep this private, only share encrypted version
}

// ============ AES-256-GCM Functions ============

/**
 * Generate a random AES-256 encryption key
 * @returns 32-byte random key
 */
export function generateEncryptionKey(): Buffer {
  return crypto.randomBytes(32);
}

/**
 * Generate a random initialization vector for AES-GCM
 * @returns 16-byte random IV
 */
export function generateIV(): Buffer {
  return crypto.randomBytes(16);
}

/**
 * Encrypt data using AES-256-GCM
 * @param data The plaintext data to encrypt
 * @param key 32-byte AES key
 * @param iv 16-byte initialization vector
 * @returns Encrypted data with auth tag
 */
export function encryptAES256GCM(
  data: Buffer | string,
  key: Buffer,
  iv: Buffer
): EncryptedData {
  if (key.length !== 32) {
    throw new Error("AES-256 requires a 32-byte key");
  }
  if (iv.length !== 16) {
    throw new Error("AES-GCM requires a 16-byte IV");
  }

  const cipher = crypto.createCipheriv("aes-256-gcm", key, iv);
  const inputBuffer = typeof data === "string" ? Buffer.from(data, "utf-8") : data;

  const ciphertext = Buffer.concat([cipher.update(inputBuffer), cipher.final()]);
  const authTag = cipher.getAuthTag();

  return {
    ciphertext,
    iv,
    authTag,
  };
}

/**
 * Decrypt data using AES-256-GCM
 * @param encrypted The encrypted data object
 * @param key 32-byte AES key
 * @returns Decrypted plaintext
 */
export function decryptAES256GCM(encrypted: EncryptedData, key: Buffer): Buffer {
  if (key.length !== 32) {
    throw new Error("AES-256 requires a 32-byte key");
  }

  const decipher = crypto.createDecipheriv("aes-256-gcm", key, encrypted.iv);
  decipher.setAuthTag(encrypted.authTag);

  const decrypted = Buffer.concat([
    decipher.update(encrypted.ciphertext),
    decipher.final(),
  ]);

  return decrypted;
}

// ============ RSA Functions ============

/**
 * Generate an RSA-2048 key pair for auditors
 * @returns RSA key pair with public key hash
 */
export function generateAuditorKeyPair(): RSAKeyPair {
  const { publicKey, privateKey } = crypto.generateKeyPairSync("rsa", {
    modulusLength: 2048,
    publicKeyEncoding: {
      type: "spki",
      format: "pem",
    },
    privateKeyEncoding: {
      type: "pkcs8",
      format: "pem",
    },
  });

  // Hash the public key for on-chain storage
  const publicKeyHash = keccak256(
    encodePacked(["string"], [publicKey])
  ) as `0x${string}`;

  return {
    publicKey,
    privateKey,
    publicKeyHash,
  };
}

/**
 * Encrypt an AES key using RSA-OAEP for secure key distribution
 * @param aesKey The AES key to encrypt
 * @param publicKeyPem RSA public key in PEM format
 * @returns Encrypted key buffer
 */
export function encryptKeyForAuditor(
  aesKey: Buffer,
  publicKeyPem: string
): Buffer {
  const encryptedKey = crypto.publicEncrypt(
    {
      key: publicKeyPem,
      padding: crypto.constants.RSA_PKCS1_OAEP_PADDING,
      oaepHash: "sha256",
    },
    aesKey
  );

  return encryptedKey;
}

/**
 * Decrypt an AES key using RSA-OAEP
 * @param encryptedKey The encrypted AES key
 * @param privateKeyPem RSA private key in PEM format
 * @returns Decrypted AES key
 */
export function decryptKey(
  encryptedKey: Buffer,
  privateKeyPem: string
): Buffer {
  const decryptedKey = crypto.privateDecrypt(
    {
      key: privateKeyPem,
      padding: crypto.constants.RSA_PKCS1_OAEP_PADDING,
      oaepHash: "sha256",
    },
    encryptedKey
  );

  return decryptedKey;
}

// ============ Batch Data Encryption ============

/**
 * Serialize orders to JSON buffer
 * @param orders Array of order data
 * @returns JSON buffer
 */
function serializeOrders(orders: OrderData[]): Buffer {
  const serialized = orders.map((order) => ({
    trader: order.trader,
    amount: order.amount.toString(),
    limitPrice: order.limitPrice.toString(),
    isBuy: order.isBuy,
  }));
  return Buffer.from(JSON.stringify(serialized), "utf-8");
}

/**
 * Serialize fills to JSON buffer
 * @param fills Array of fill data
 * @returns JSON buffer
 */
function serializeFills(fills: FillData[]): Buffer {
  const serialized = fills.map((fill) => ({
    trader: fill.trader,
    amount: fill.amount.toString(),
    price: fill.price.toString(),
  }));
  return Buffer.from(JSON.stringify(serialized), "utf-8");
}

/**
 * Deserialize orders from JSON buffer
 * @param buffer JSON buffer
 * @returns Array of order data
 */
function deserializeOrders(buffer: Buffer): OrderData[] {
  const parsed = JSON.parse(buffer.toString("utf-8"));
  return parsed.map((order: { trader: `0x${string}`; amount: string; limitPrice: string; isBuy: boolean }) => ({
    trader: order.trader as `0x${string}`,
    amount: BigInt(order.amount),
    limitPrice: BigInt(order.limitPrice),
    isBuy: order.isBuy,
  }));
}

/**
 * Deserialize fills from JSON buffer
 * @param buffer JSON buffer
 * @returns Array of fill data
 */
function deserializeFills(buffer: Buffer): FillData[] {
  const parsed = JSON.parse(buffer.toString("utf-8"));
  return parsed.map((fill: { trader: `0x${string}`; amount: string; price: string }) => ({
    trader: fill.trader as `0x${string}`,
    amount: BigInt(fill.amount),
    price: BigInt(fill.price),
  }));
}

/**
 * Encrypt batch data (orders and fills) for audit storage
 * @param batchData The batch data to encrypt
 * @returns Encrypted batch result with all necessary hashes
 */
export function encryptBatchData(batchData: BatchData): EncryptedBatchResult {
  // Generate encryption key and IV
  const key = generateEncryptionKey();
  const iv = generateIV();

  // Serialize data
  const ordersBuffer = serializeOrders(batchData.orders);
  const fillsBuffer = serializeFills(batchData.fills);

  // Compute plaintext hashes for integrity verification
  const ordersHash = keccak256(ordersBuffer) as `0x${string}`;
  const fillsHash = keccak256(fillsBuffer) as `0x${string}`;
  const keyHash = keccak256(key) as `0x${string}`;

  // Encrypt data
  const encryptedOrders = encryptAES256GCM(ordersBuffer, key, iv);
  const encryptedFills = encryptAES256GCM(fillsBuffer, key, iv);

  // Combine ciphertext and auth tag for storage
  const ordersPayload = Buffer.concat([
    encryptedOrders.ciphertext,
    encryptedOrders.authTag,
  ]);
  const fillsPayload = Buffer.concat([
    encryptedFills.ciphertext,
    encryptedFills.authTag,
  ]);

  return {
    encryptedOrders: bytesToHex(ordersPayload) as `0x${string}`,
    encryptedFills: bytesToHex(fillsPayload) as `0x${string}`,
    ordersHash,
    fillsHash,
    keyHash,
    iv: bytesToHex(iv.subarray(0, 16)) as `0x${string}`, // bytes16 for Solidity
    key,
  };
}

/**
 * Decrypt batch data using the AES key
 * @param encryptedOrders Encrypted orders hex string
 * @param encryptedFills Encrypted fills hex string
 * @param iv Initialization vector
 * @param key AES decryption key
 * @returns Decrypted batch data
 */
export function decryptBatchData(
  encryptedOrders: `0x${string}`,
  encryptedFills: `0x${string}`,
  iv: `0x${string}`,
  key: Buffer
): BatchData {
  const ivBuffer = Buffer.from(hexToBytes(iv));

  // Parse orders payload (ciphertext + 16-byte auth tag)
  const ordersPayload = Buffer.from(hexToBytes(encryptedOrders));
  const ordersAuthTag = ordersPayload.subarray(ordersPayload.length - 16);
  const ordersCiphertext = ordersPayload.subarray(0, ordersPayload.length - 16);

  // Parse fills payload
  const fillsPayload = Buffer.from(hexToBytes(encryptedFills));
  const fillsAuthTag = fillsPayload.subarray(fillsPayload.length - 16);
  const fillsCiphertext = fillsPayload.subarray(0, fillsPayload.length - 16);

  // Decrypt
  const ordersBuffer = decryptAES256GCM(
    { ciphertext: ordersCiphertext, iv: ivBuffer, authTag: ordersAuthTag },
    key
  );
  const fillsBuffer = decryptAES256GCM(
    { ciphertext: fillsCiphertext, iv: ivBuffer, authTag: fillsAuthTag },
    key
  );

  return {
    orders: deserializeOrders(ordersBuffer),
    fills: deserializeFills(fillsBuffer),
  };
}

// ============ Utility Functions ============

/**
 * Compute the hash of a public key for on-chain verification
 * @param publicKeyPem RSA public key in PEM format
 * @returns keccak256 hash of the public key
 */
export function computePublicKeyHash(publicKeyPem: string): `0x${string}` {
  return keccak256(encodePacked(["string"], [publicKeyPem])) as `0x${string}`;
}

/**
 * Verify that decrypted data matches expected hash
 * @param data Decrypted data buffer
 * @param expectedHash Expected hash
 * @returns True if hash matches
 */
export function verifyDataIntegrity(
  data: Buffer,
  expectedHash: `0x${string}`
): boolean {
  const computedHash = keccak256(data);
  return computedHash.toLowerCase() === expectedHash.toLowerCase();
}

/**
 * Export encryption key to hex format for storage
 * @param key AES key buffer
 * @returns Hex string
 */
export function exportKey(key: Buffer): `0x${string}` {
  return bytesToHex(key) as `0x${string}`;
}

/**
 * Import encryption key from hex format
 * @param keyHex Hex string
 * @returns AES key buffer
 */
export function importKey(keyHex: `0x${string}`): Buffer {
  return Buffer.from(hexToBytes(keyHex));
}

// ============ File I/O Helpers ============

import * as fs from "fs";
import * as path from "path";

/**
 * Save RSA key pair to files
 * @param keyPair RSA key pair
 * @param outputDir Directory to save keys
 * @param prefix Filename prefix
 */
export function saveKeyPair(
  keyPair: RSAKeyPair,
  outputDir: string,
  prefix: string = "auditor"
): void {
  fs.mkdirSync(outputDir, { recursive: true });

  fs.writeFileSync(
    path.join(outputDir, `${prefix}_public.pem`),
    keyPair.publicKey
  );
  fs.writeFileSync(
    path.join(outputDir, `${prefix}_private.pem`),
    keyPair.privateKey
  );
  fs.writeFileSync(
    path.join(outputDir, `${prefix}_pubkey_hash.txt`),
    keyPair.publicKeyHash
  );

  console.log(`Keys saved to ${outputDir}/`);
  console.log(`Public key hash: ${keyPair.publicKeyHash}`);
}

/**
 * Load RSA key pair from files
 * @param publicKeyPath Path to public key PEM file
 * @param privateKeyPath Path to private key PEM file
 * @returns RSA key pair
 */
export function loadKeyPair(
  publicKeyPath: string,
  privateKeyPath: string
): RSAKeyPair {
  const publicKey = fs.readFileSync(publicKeyPath, "utf-8");
  const privateKey = fs.readFileSync(privateKeyPath, "utf-8");
  const publicKeyHash = computePublicKeyHash(publicKey);

  return {
    publicKey,
    privateKey,
    publicKeyHash,
  };
}

/**
 * Load only the private key for decryption
 * @param privateKeyPath Path to private key PEM file
 * @returns Private key PEM string
 */
export function loadPrivateKey(privateKeyPath: string): string {
  return fs.readFileSync(privateKeyPath, "utf-8");
}

// ============ Export for CLI ============

export default {
  generateEncryptionKey,
  generateIV,
  encryptAES256GCM,
  decryptAES256GCM,
  generateAuditorKeyPair,
  encryptKeyForAuditor,
  decryptKey,
  encryptBatchData,
  decryptBatchData,
  computePublicKeyHash,
  verifyDataIntegrity,
  exportKey,
  importKey,
  saveKeyPair,
  loadKeyPair,
  loadPrivateKey,
};
