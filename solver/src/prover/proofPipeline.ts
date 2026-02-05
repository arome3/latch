/**
 * ZK proof generation pipeline.
 *
 * Executes: nargo execute → bb prove --write_vk -t evm
 * Reads proof and public inputs from target/proof/
 */

import { execSync } from "node:child_process";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import type { Logger } from "../utils/logger.js";
import type { ProofArtifacts } from "../types/batch.js";

export interface ProofPipelineOptions {
  circuitDir: string;
  logger: Logger;
}

/**
 * Write Prover.toml and generate ZK proof.
 */
export async function generateProof(
  proverToml: string,
  opts: ProofPipelineOptions
): Promise<ProofArtifacts> {
  const { circuitDir, logger } = opts;

  // Write Prover.toml
  const tomlPath = join(circuitDir, "Prover.toml");
  writeFileSync(tomlPath, proverToml, "utf-8");
  logger.info({ tomlPath }, "Wrote Prover.toml");

  // Step 1: nargo execute (generate witness)
  logger.info("Running nargo execute...");
  execSync("nargo execute", {
    cwd: circuitDir,
    stdio: "pipe",
    timeout: 120_000,
  });

  // Step 2: bb prove (generate proof + VK)
  logger.info("Running bb prove...");
  execSync(
    [
      "bb prove --write_vk",
      "-b ./target/batch_verifier.json",
      "-w ./target/batch_verifier.gz",
      "-o ./target/proof",
      "-t evm",
    ].join(" "),
    {
      cwd: circuitDir,
      stdio: "pipe",
      timeout: 300_000,
    }
  );

  // Read artifacts
  const proofPath = join(circuitDir, "target/proof/proof");
  const piPath = join(circuitDir, "target/proof/public_inputs");

  if (!existsSync(proofPath) || !existsSync(piPath)) {
    throw new Error("Proof artifacts not found after generation");
  }

  const proof = readFileSync(proofPath);
  const publicInputs = readFileSync(piPath);

  logger.info(
    { proofBytes: proof.length, piBytes: publicInputs.length },
    "Proof generated successfully"
  );

  return {
    proof: new Uint8Array(proof),
    publicInputs: new Uint8Array(publicInputs),
  };
}
