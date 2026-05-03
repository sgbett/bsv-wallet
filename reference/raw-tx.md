# Reference Transaction (P2PKH, 1-in/1-out, 191 bytes)

```
01000000016ce7229f014164e254aad172b1f8b40d496942ad7e323b47e0424c2b2e2e3772010000006a4730440220463fcf8f57a61c4f8ede208773db8732bf3a0757d929a8cbbe29bf4905fe5ef6022005d74398faf5b24912821836171af44f55f89858f3edf92863cde4823da11d4641210362f5fb9274834bb0cd0376a8d5d02bdbf459a37a62c5baef3fb06d1159b55597ffffffff01f0991600000000001976a9141f36a49fcf6ada1f74f82377b33b17b68f7a016188acd3740e00
```

## Byte-level breakdown

| Offset | Size | Hex | Field |
|-------:|-----:|-----|-------|
| 0 | 4 | `01000000` | version (1) |
| 4 | 1 | `01` | input count (1) |
| 5 | 32 | `6ce7229f...2e2e3772` | prev wtxid (wire order) |
| 37 | 4 | `01000000` | prev vout (1) |
| 41 | 1 | `6a` | scriptSig length (106) |
| 42 | 1 | `47` | . push 71 bytes |
| 43 | 70 | `30440220...da11d46` | . . DER signature |
| 113 | 1 | `41` | . . sighash: FORKID + ALL |
| 114 | 1 | `21` | . push 33 bytes |
| 115 | 33 | `0362f5fb...b55597` | . . compressed pubkey |
| 148 | 4 | `ffffffff` | sequence (0xFFFFFFFF) |
| 152 | 1 | `01` | output count (1) |
| 153 | 8 | `f099160000000000` | satoshis (1,481,200) |
| 161 | 1 | `19` | scriptPubKey length (25) |
| 162 | 1 | `76` | . OP_DUP |
| 163 | 1 | `a9` | . OP_HASH160 |
| 164 | 1 | `14` | . push 20 bytes |
| 165 | 20 | `1f36a49f...7a0161` | . . pubkey hash |
| 185 | 1 | `88` | . OP_EQUALVERIFY |
| 186 | 1 | `ac` | . OP_CHECKSIG |
| 187 | 4 | `d3740e00` | locktime (947,411) |

**191 bytes total.** Used in test suite as `DUMMY_RAW_TX` — parseable by `Transaction.from_binary` and satisfies the `tx_proofs.raw_tx >= 10` constraint.

## DER signature size distribution

The DER-encoded ECDSA signature uses two integers (r, s), each 32 bytes when fully populated. Leading zeros are stripped, and a sign byte is prepended when the high bit is set. The r and s values are effectively random mod n (~2^256), so shorter encodings require the value to fall below exponentially smaller thresholds.

| Signature size | Probability | Frequency |
|---------------:|------------:|-----------|
| 70–72 bytes | ~99.8% | Standard |
| 69 bytes | ~1 in 512 | Uncommon |
| 68 bytes | ~1 in 131,072 | Rare |
| 60 bytes | ~1 in 2^80 | Near impossible |
| 8 bytes | ~1 in 2^496 | Practically impossible |

Each byte below 70 requires the value to be ~256x smaller. A minimum signed P2PKH transaction (1-in/1-out) is 191 bytes with a typical 70-byte signature, 189 bytes with a 68-byte signature. The database constraint uses 10 bytes (structural minimum) because unsigned transactions during deferred signing are ~85 bytes.
