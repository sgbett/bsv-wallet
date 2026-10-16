# frozen_string_literal: true

# Shared multi-wallet no_send fanout primitive.
#
# "Predicted Change Fanout" is one cascade shape — for each wallet, send
# +count+ payments to a random not-self peer — run through whatever
# transport the caller supplies. The *routing* lives here once; the
# *transport* is the caller's: +Fanout.pass+ yields each hop to a block
# that performs the payment however it needs (in-process
# Engine#send_payment + #internalize_action, or a bin/ CLI create|receive
# pipeline). Neither path broadcasts; this is no_send fanout that builds
# peer-to-peer state. Retained for the #126 e2e on-chain and #129
# CLI-pipeline stress workloads (consumers pending rebuild).
module Fanout
  module_function

  # One fanout pass over +wallets+. Each wallet sends +count+ payments of
  # +satoshis+ to a random not-self peer; the block performs the transport
  # and is called as +pay.call(sender, recipient, satoshis, index)+ with a
  # zero-based +index+ within that wallet's run.
  #
  # Returns a per-route count Hash ("alice→bob" => n) for summary reports.
  def pass(wallets:, count:, satoshis:, &pay)
    raise ArgumentError, 'fanout needs >= 2 wallets to route not-self' if wallets.length < 2

    payment_log = Hash.new(0)
    wallets.each do |sender|
      others = wallets - [sender]
      count.times do |i|
        recipient = others.sample
        pay.call(sender, recipient, satoshis, i)
        payment_log["#{sender}→#{recipient}"] += 1
      end
    end
    payment_log
  end

  # Multi-level cascade: run +pass+ once per +[count, satoshis]+ entry in
  # +passes+ (descending amounts produce the layered fanout). Returns an
  # array of per-route logs, one per level, in pass order.
  def run(wallets:, passes:, &pay)
    passes.map { |count, satoshis| pass(wallets: wallets, count: count, satoshis: satoshis, &pay) }
  end
end
