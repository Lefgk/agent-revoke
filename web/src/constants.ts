import type { Address } from "viem";

export const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3" as Address;
export const SPEND_PERMISSION_MANAGER = "0xf85210B21cC50302F477BA56686d2019dC9b67Ad" as Address;
export const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11" as Address;
export const SENTINEL_MODULE = "0x0000000000000000000000000000000000000001" as Address;

export const USDC: Record<number, Address> = {
  1: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  8453: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
};

export const REVOKE_CASH_7702 = "https://revoke.cash/learn/wallets/what-is-eip7702";

export const CAVEATS = [
  "ERC-20 approve(0) has to come from the owner. This contract cannot do it as a third party. Batch via EIP-7702 (designate PanicRevoke and call panic), a Safe MultiSend, or sequential transactions.",
  "Permit2 lockdown must also be sent by the owner. Same batching options. Lockdown does not invalidate already-signed SignatureTransfer permits.",
  "Coinbase SpendPermission.revoke must be sent by the account that granted it (or revokeAsSpender by the agent).",
  "Safe modules are disabled only with a Safe transaction, or via panicAsModule after PanicRevoke is enabled as a module.",
  "EIP-7702 delegation cannot be revoked in this dapp. Your wallet must send a type-4 authorization to address(0). Most wallets block dapp-initiated type-4 txs.",
  "Privy, Turnkey, ERC-7710 delegations and Kernel / 7579 session keys are out of v1. Link out to the issuer to revoke those.",
];
