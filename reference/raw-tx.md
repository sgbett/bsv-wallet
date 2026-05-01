# Reference Transaction (P2PKH, 1-in/1-out, 191 bytes)

```
01000000016ce7229f014164e254aad172b1f8b40d496942ad7e323b47e0424c2b2e2e3772010000006a4730440220463fcf8f57a61c4f8ede208773db8732bf
3a0757d929a8cbbe29bf4905fe5ef6022005d74398faf5b24912821836171af44f55f89858f3edf92863cde4823da11d4641210362f5fb9274834bb0cd0376a8
d5d02bdbf459a37a62c5baef3fb06d1159b55597ffffffff01f0991600000000001976a9141f36a49fcf6ada1f74f82377b33b17b68f7a016188acd3740e00
```

## Chunks by protocol

```
╔═══════╗
║ rawTX ║
╚╤══════╝
 ├─ version................. 01000000
 ├─ inputs.................. 01
 │ ╔════════╗
 ├─╢ vin.0  ║
 │ ╚╤═══════╝
 │  ├─ txid................. 6ce7229f014164e2 54aad172b1f8b40d 496942ad7e323b47e 0424c2b2e2e3772
 │  ├─ vout................. 01000000
 │  │ ╔══════════════╗
 │  ├─╢ scriptSig    ║
 │  │ ║ length (106) ║...... 6a
 │  │ ╚╤═════════════╝
 │  │  ├─ OP_PUSH(71)....... 47
 │  │  │   └┬───────────────────────────────────────────────────────────────────────────────────
 │  │  │    ├─ Signature
 │  │  │    │  ↪32 bytes.... 30440220463fcf8f 57a61c4f8ede2087 73db8732bf3a0757 d929a8cbbe29bf49
 │  │  │    │  ↪64 bytes.... 05fe5ef6022005d7 4398faf5b2491282 1836171af44f55f8 9858f3edf92863cd
 │  │  │    │  ↪70 bytes.... e4823da11d46
 │  │  │    ├─ sighash
 │  │  │    │  ↪71 bytes.... 41
 │  │  │    └───────────────────────────────────────────────────────────────────────────────────
 │  │  └─ OP_PUSH(33)....... 21
 │  │      └┬───────────────────────────────────────────────────────────────────────────────────
 │  │       ├─ Compressed PubKey
 │  │       │  ↪32.......... 0362f5fb9274834b b0cd0376a8d5d02b dbf459a37a62c5ba ef3fb06d1159b555
 │  │       │  ↪33 bytes.... 97
 │  │       └───────────────────────────────────────────────────────────────────────────────────
 │  └─ nsequence............ ffffffff
 ├─ outputs................. 01
 │ ╔════════╗
 ├─╢ vout.0 ║
 │ ╚╤═══════╝
 │  ├─ amount............... f099160000000000
 │  │ ╔══════════════╗
 │  └─╢ scriptPubKey ║
 │    ║ length (25)  ║...... 19
 │    ╚╤═════════════╝
 │     ├─ OP_DUP............ 76
 │     ├─ OP_HASH160........ a9
 │     ├─ OP_PUSH20......... 14
 │     │   └┬───────────────────────────────────────────────────────────────────────────────────
 │     │    ├─ PubKey hash
 │     │    │  ↪20 bytes.... 1f36a49fcf6ada1f 74f82377b33b17b6 8f7a0161
 │     │    └───────────────────────────────────────────────────────────────────────────────────
 │     ├─ OP_EQUALVERIFY.... 88
 │     └─ OP_CHECKSIG....... ac
 └─ nlocktime............... d3740e00
```

## Processing the TX

TX are predicate scripts — they must evaluate to TRUE (0x01)

1. scriptSig execution
  - 0x47 pushes 71 bytes (der_sig + sighash) to [1]
  - 0x21 pushes 33 bytes (pubkey 🗜️) to [2]

Stack:
```
[1] 30440220463fcf8f57a61c4f8ede208773db8732bf3a0757d929a8cbbe29bf4905fe5ef6022005d74398faf5b24912821836171af44f55f89858f3edf92863cde4823da11d4641
[2] 0362f5fb9274834bb0cd0376a8d5d02bdbf459a37a62c5baef3fb06d1159b55597
```

2. scriptPubKey execution
  - OP_DUP duplicates [2] to [3]
  - OP_HASH160 pops [3], hashes it, and pushes it back to [3]
  - 0x14 pushes 20 bytes (pubkey #️⃣) to [4]
  - OP_EQUALVERIFY pops [4] and [3] and compares them, aborts if not equal
  - OP_CHECKSIG pops [2] and [1] pushes TRUE if valid

Stack:
```
[1] 0x01
```

The stack now contains TRUE (0x01) therefore the TX is valid.

## Byte Offsets

| Offset | Size | Hex | Field |
|-------:|-----:|-----|-------|
| 0 | 4 | `01000000` | version (1) |
| 4 | 1 | `01` | input count (1) |
| 5 | 32 | `6ce7229f...2e2e3772` | prev txid (wire order: `wtxid`) |
| 37 | 4 | `01000000` | prev vout (1) |
| 41 | 1 | `6a` | scriptSig length (106 bytes) |
| 42 | 1 | `47` | . push 71 bytes |
| 43 | 70 | `30440220...da11d46` | . . DER signature |
| 113 | 1 | `41` | . . sighash: FORKID + ALL |
| 114 | 1 | `21` | . push 33 bytes |
| 115 | 33 | `0362f5fb...b55597` | . . compressed pubkey (33 bytes) |
| 148 | 4 | `ffffffff` | sequence (0xFFFFFFFF) |
| 152 | 1 | `01` | output count (1) |
| 153 | 8 | `f099160000000000` | satoshis (1,481,200) |
| 161 | 1 | `19` | scriptPubKey length (25) |
| 162 | 1 | `76` | . OP_DUP |
| 163 | 1 | `a9` | . OP_HASH160 |
| 164 | 1 | `14` | . push 20 bytes |
| 165 | 20 | `1f36a49f...7a0161` | . . |
| 185 | 1 | `88` | . OP_EQUALVERIFY |
| 186 | 1 | `ac` | . OP_CHECKSIG |
| 187 | 4 | `d3740e00` | locktime (947,411) |

**191 bytes total.** Used in test suite as `DUMMY_RAW_TX` — parseable by `Transaction.from_binary` and satisfies the `tx_proofs.raw_tx >= 20` constraint.

## DER signature size distribution

The DER-encoded ECDSA signature uses two integers (r, s), each 32 bytes when fully populated. Leading zeros are stripped, and a sign byte is prepended when the high bit is set. The r and s values are effectively random mod n (≈2^256), so shorter encodings require the value to fall below exponentially smaller thresholds.

| Signature size | Probability | Frequency |
|---------------:|------------:|-----------|
| 70–72 bytes | ≈99.8% | Standard |
| 69 bytes | ≈1 in 512 | Uncommon |
| 68 bytes | ≈1 in 131,072 | Rare |
| 60 bytes | ≈1 in 2^80 | Near impossible |
| 8 bytes | ≈1 in 2^496 | Practically impossible |

Each byte below 70 requires the value to be ≈256x smaller. A minimum signed P2PKH transaction (1-in/1-out) is 191 bytes with a typical 70-byte signature, 189 bytes with a 68-byte signature. The database constraint uses 20 bytes (minimum 1-output tx with 1-byte script) because unsigned transactions during deferred signing are ~85 bytes.

## PubKey

Pubkey is used twice, in *scriptSig* where it is compressed and in *scriptPubKey* where it is hashed

### Compressed

When an output is spent the scriptsig must reveal the pubkey so that proof can be verified, to save space the key is compressed.

A public key is a point x,y on a graph. Because the curve is mathematically defined as y^2 = x^3 + 7, if we know x, we can solve the equation to find y. Therefore to save space we just send x.

However y^2 = b has two solutions for b, positive and negative, so the first byte is used to indicate which of these it is 0x02 is even, 0x03 is odd.

### Hash

Hashing the pubkey affords privacy to unspent outputs until such time as they need to be spent. The pubkey is hashed using:

```pseudocode
ripemd160(sha256(pubkey))
```

When the output is spent the scriptSig reveals the actual pubkey and this can be hashed to verify it matches the output, which is exactly what the P2PKH script does.

## nlocktime

Prevents tx from being mined until a specified time (blockheight or real-time). There are two types of nlocktime, determined by the value.

**NB:** for nlocktime to be enforced at least one input must have nsequence below 0xffffffff — this applies regardless of which type of nlocktime is used.

### 0-500,000,000 block height type

**Decimal Range** 0 to 500,000,000

The transaction cannot be mined until the specified blockheight

Based on the average interval of 10 mins between blocks, it will take ≈9,506 years to reach blockheight 500,000,000.

### 0x1dcd6500 to 0xffffffff - Unix Time

**Decimal Range** 500,000,000+

**NB:** Unix time is implicitly Coordinated Universal Time (UTC).

The transaction cannot be mined until nlocktime seconds after the Unix epoch 00:00:00 on 1 Jan 1970

The earliest possible nlocktime specified this way is 00:53:20 on 5 Nov 1985, well before the first block was mined.

The first block mined at 18:15:05 on 3 Jan 2009 corresponds to the nlocktime 0x495fab29 of (1,231,006,505). The actual nlocktime of this block was zero.

The maximum nlocktime 0xffffffff corresponds to 06:28:15 on 7 Feb 2106

## Unix Time, Leap Seconds and Median-Time-Past (MTP)

In unix time, every day is treated as having exactly 86,400 seconds. When a leap second occurs, the Unix clock typically "repeats" a second or steps backward to stay in sync with UTC. It does not increment the counter for that extra second. A Unix timestamp of 500,000,000 represents exactly 500,000,000 ÷ 86,400 days since the Epoch. The leap second system was not introduced until 1 Jan 1972, by which time atomic clocks were already 10 seconds ahead of UTC, and so an initial 10 second offset was applied, and a further 27 leap seconds have been applied since [1]

Practically speaking this additional 37 seconds (in total, as of 3 May 2026) has no effect on Bitcoin nodes. Due to the economic incentives, around mining nodes will converge on using the same Unix-based timestamp and sync their clocks via NTP (Network Time Protocol). Any leap-second drift is therefore already accounted for.

Furthermore nodes rely on the Median-Time-Past (MTP) of the last 11 blocks to determine the "current time" for nLockTime validation.

Consensus on the validity of including a transaction with a unix-time style nlocktime naturally emerges as a confluence of the factors described.

[1. https://data.iana.org/time-zones/data/leap-seconds.list](https://data.iana.org/time-zones/data/leap-seconds.list)
