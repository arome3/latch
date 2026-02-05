/**
 * Generate Prover.toml from batch data.
 *
 * Critical details:
 * - Trader addresses encoded as 20-byte arrays: [0xAB, 0xCD, ...]
 * - All arrays padded to 16 entries
 * - Boolean fields: true/false (lowercase)
 * - Numeric fields: quoted strings for bigint compatibility
 */

import type { Order } from "../types/order.js";
import type { PublicInputs } from "../types/batch.js";

/**
 * Convert an Ethereum address to a 20-byte array string for TOML.
 * e.g. "0x1111...1111" → "[0x11, 0x11, ..., 0x11]"
 */
function addressToByteArray(address: string): string {
  const hex = address.toLowerCase().replace("0x", "");
  const bytes: string[] = [];
  for (let i = 0; i < 40; i += 2) {
    bytes.push("0x" + hex.slice(i, i + 2));
  }
  return `[${bytes.join(", ")}]`;
}

/**
 * Generate the Prover.toml content for the given batch.
 */
export function generateProverToml(
  orders: Order[],
  pi: PublicInputs
): string {
  const lines: string[] = [];

  // Public inputs
  lines.push("# ===== PUBLIC INPUTS =====");
  lines.push(`batch_id = "${pi.batchId}"`);
  lines.push(`clearing_price = "${pi.clearingPrice}"`);
  lines.push(`total_buy_volume = "${pi.buyVolume}"`);
  lines.push(`total_sell_volume = "${pi.sellVolume}"`);
  lines.push(`order_count = "${pi.orderCount}"`);
  lines.push(`orders_root = "0x${pi.ordersRoot.toString(16)}"`);
  lines.push(`whitelist_root = "0x${pi.whitelistRoot.toString(16)}"`);
  lines.push(`fee_rate = "${pi.feeRate}"`);
  lines.push(`protocol_fee = "${pi.protocolFee}"`);

  // Fills array (16 elements)
  const fillsStr = pi.fills.map((f) => `"${f}"`).join(", ");
  lines.push(`fills = [${fillsStr}]`);

  lines.push("");
  lines.push("# ===== PRIVATE INPUTS =====");
  lines.push("");

  // Orders (pad to 16)
  for (let i = 0; i < 16; i++) {
    if (i < orders.length) {
      const order = orders[i];
      lines.push("[[orders]]");
      lines.push(`amount = "${order.amount}"`);
      lines.push(`limit_price = "${order.limitPrice}"`);
      lines.push(`trader = ${addressToByteArray(order.trader)}`);
      lines.push(`is_buy = ${order.isBuy}`);
    } else {
      // Padding order
      lines.push("[[orders]]");
      lines.push('amount = "0"');
      lines.push('limit_price = "0"');
      lines.push(
        "trader = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]"
      );
      lines.push("is_buy = false");
    }
    lines.push("");
  }

  // Whitelist proofs (16, all zeros for PERMISSIONLESS)
  for (let i = 0; i < 16; i++) {
    lines.push("[[whitelist_proofs]]");
    lines.push(
      'path = ["0", "0", "0", "0", "0", "0", "0", "0"]'
    );
    lines.push(
      "indices = [false, false, false, false, false, false, false, false]"
    );
    lines.push("");
  }

  return lines.join("\n");
}
