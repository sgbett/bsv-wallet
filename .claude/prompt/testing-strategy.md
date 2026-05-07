I think that these findings define a bright line for multi-wallet testing. This all needs to be done using the CLI tools, and this "functional" testing seems to be to constitute *feature* testing as a third category in addition to unit integration tests.

This reduced the scope of integration tests to single wallet operations, and I think this naturally splits into integration testing of the Ruby code, and integration testing of the CLI tools.

I think this is starting to help define the shape needed for #64's testing strategy.


## A Proposal for #64

The layers that are falling out here seem to be:

1) Unit tests
2) Integration
  a) “Components" - the glue that transforms the Engine's orchestration of method calls into the low-level Data manipulation calls.
  b) "Engine" - that higher-level methods correctly orchestrate calls to the lower-level methods
  c) CLI tools match the shape of the API. Make the correct calls, handle the responses, produce the expected changes in the database [S:DI] (whilst being unable to do unexpected things!) and generate the right outputs for the purposes of piping date [E:IO] or reporting success/failure

3) Feature Tests -
  a) "Functionality" - A suite of narrative examples, scenarios that exercise the interactions between multiple independent wallets. These real-world interactions are driven (necessarily, due to the inherent single-user database design) by the CLI tools performing actions that might otherwise originate from third parties using wallet software to send and receive.
  b) “Interoperability" - Orchestrates a similar set of tests using the ts-sdk/wallet-tools as a counterparty and ensures that basic interoperability works as expected e.g. I can send a transaction to an alternative provider wallet, and internalise a transaction received.

The cross-cutting vertical concerns still exist as defined in 64: [E:IO] Engine (intent/outcome) and [S:DI] Store (data invariants), the split being more structurally separable at the unit test level and perhaps the lower-level integrations.

## Expanding on the initial 2000sats

The initial WIF_ALICE served as a proof of concept.

We will create three new keys, two to replace the existing WIF_ALICE and WIF_BOB, and we will introduce a third actor, WIF_CAROL. I will create a funding UTXO for each root_key of 1m sats, and we will use a baseline of 5k sats for our minimum 'unit' payment.

This sets up economics whereby fees are generally <1% of a tx, which allows testing to focus on tx value without outsized effects from non-deterministic fee calculations, making tests brittle.

This should also mitigate issues running into dust limits at the edges.

### Predicted Change Fanout

1. Layer 1
- the root UTXO is processed on wallet startup as a single self-payment
- 1 output with a BEEF ancestry depth n=1 to the merkle proof for the original utxo
2. Layer 2 (ancestry depth n=1)
- 1 payment @ 5000 sats from the layer 1 utxo
- 8 change outputs of ~124k sats
3. Layer 3 (ancestry depth n=2)
- 8 x payments @ 5000 sats from layer 2 change outputs
- 8 x 8 = 64 change outputs of ~14k sats
4. Layer 4 (ancestry depth n=3)
- 64 x 8 = 512 payments @ 5000 sats from layer 3 change outputs
- 64 x 512 = 4096 change outputs of ~1k sats

This provides potential for around 500 payments at a beef ancestry of n=3, which should still be relatively modest, attracting perhaps a few hundred sat fees at most.

## Broadcasting: "Test wallets, not networks!"

It is easy to fall into the trap of thinking that the best way to test a wallet is to see if you make a "real" payment.

Now it is clear that every tx has two recipients, and only one of them gets to spend the payment, which makes them arguably the recipient of most concern (the miner gets the fees but this is a fraction). Verifying that transactions are accepted by the network is a valid concern, and should be tested separately outside of CI, but spending money on-chain offers no real advantage to wallet-to-wallet validation, and carries a very real disadvantage of persistent wallet maintenance, which might be better achieved using a wallet store that we have not yet scoped. (e.g. sqlite restore/backup, remote RDS wallet service, filestore + cloud sync or some other method).

So on-chain verification can be added at a later date. We will then define WIFs that are attached to a persistent wallet store that will maintain running balances that circulate, with appropriate warnings should wallet balances decay below a functional threshold. This "End to End (e2e)" testing is deferred for now.

### Mocks, stubs and nosend

For the most part, the use of nosend should prevent inadvertent broadcasts, as fallback the test suite should mock/stub ARC broadcasts by default. So that any specs which would take a different codepath if they did not specify "nosend“ can be duplicated to a corresponding test that uses the stubbed ARC responses. In both cases, error handling can also be exercised, overriding the default ARC response with error responses to either directly verify synchronous broadcast error handling, or to confirm that deferred asynchronous broadcasts also handle errors correctly.

This maximises what can be done in CI using the WIF_ALICE, WIF_BOB and WIF_CAROL each with its own corresponding unspent root_utxo

## Final thoughts

specs should be organised broadly by layers, and the beneath that they should correspond to the field under test. This breaks down at feature level, where sementic meaning creates clusters of related functionality and each file covers a specific scenario that tests for success, and “successful failure”. Feature specs do not exhaustively test failures.
