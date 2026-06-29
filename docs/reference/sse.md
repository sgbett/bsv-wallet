---
title: SSE
parent: Reference
nav_order: 9
---

BSV Arcade uses Server-Sent Events (SSE) as a lightweight, real-time bridge to track Bitcoin transaction status from submission through its entire lifecycle on the network. [1]

## Core Mechanism
The Arcade service acts as an intermediary between your application and the Teranode network. It provides a streaming interface that avoids the overhead of constant client polling by pushing updates to the browser as they happen. [1, 2, 3]

* Listening to Network Events: Arcade listens to Bitcoin network events (via libp2p gossip) and updates transaction statuses in its storage (SQLite).
* Persistent HTTP Connection: A client initiates a connection to Arcade's /events endpoint using a standard HTTP request.
* Unidirectional Data Flow: Once established, Arcade pushes updates (like transaction confirmation or failure) directly to the client. The client does not send data back over this specific connection. [1, 3, 4, 5, 6]

## Key Features of the SSE Implementation

* Automatic Reconnection: If the connection drops, the browser's EventSource API automatically reconnects. Arcade then uses the Last-Event-ID header to replay any missed events from that specific timestamp, ensuring no status updates are lost.
* Token-Based Filtering: To ensure security and privacy, each SSE connection only receives events for transactions submitted with a matching callback token. This allows multiple users to have isolated, scoped event streams without complex authentication.
* Efficiency: Because it uses the standard text/event-stream media type over HTTP, it is compatible with most modern browsers and network infrastructures (like firewalls) that might otherwise block more complex protocols like WebSockets. [1, 4, 7]

## Typical Lifecycle

   1. Transaction Submission: You submit a transaction to Arcade via its HTTP API.
   2. Connection Setup: Your frontend connects to the SSE stream using a callback token.
   3. Real-Time Pushes: As the transaction moves from "broadcast" to "seen" and finally "mined," Arcade pushes these status changes as individual events to the client. [1, 8]

[1] [https://github.com](https://github.com/bsv-blockchain/arcade)
[2] [https://gokhana.medium.com](https://gokhana.medium.com/what-is-server-sent-events-sse-and-how-to-implement-it-904938bffd73)
[3] [https://maximilian-schwarzmueller.com](https://maximilian-schwarzmueller.com/articles/server-sent-events-sse-the-champion-no-one-knows/)
[4] [https://amitavroy.com](https://amitavroy.com/articles/2025-04-01-server-sent-events-what-are-they-why-you-should-use-them)
[5] [https://blogs.embarcadero.com](https://blogs.embarcadero.com/server-sent-events-sse-getting-real-time-updates-in-your-apps/)
[6] [https://medium.com](https://medium.com/double-pointer/system-design-server-sent-events-sse-b375339bc662)
[7] [https://en.wikipedia.org](https://en.wikipedia.org/wiki/Server-sent_events)
[8] [https://dev.to](https://dev.to/zacharylee/how-server-sent-events-sse-work-450a)
