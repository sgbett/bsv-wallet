# frozen_string_literal: true

require 'benchmark'
require_relative 'shared_context'

# HLR #516 Sub 6.2 — the structural descent walk.
#
# +Store#descendant_action_ids_of(action_ids:, max_depth: 100)+ is a
# recursive CTE that follows the +inputs.output_id → outputs.id →
# outputs.action_id+ edge transitively. The primitive is opaque to
# newcomers (Sequel's +Dataset#with_recursive+ is not everyday DSL), so
# this spec exists as the reference example: read here to understand
# the shape and the edge cases.
#
# The pattern:
#
#   seed_ds  = DB.select(action_id_1 AS action_id, 0 AS depth) UNION
#              DB.select(action_id_2 AS action_id, 0 AS depth) ...
#   step_ds  = outputs JOIN descent ON descent.action_id = outputs.action_id
#                       JOIN inputs  ON inputs.output_id  = outputs.id
#              WHERE descent.depth < max_depth
#              SELECT inputs.action_id, descent.depth + 1
#   descent  = seed_ds ⋃ step_ds   (union_all: false → dedup)
#
# +union_all: false+ deduplicates each recursion step against the CTE
# contents so far. Diamond ancestry (two paths from X to Y) reaches Y
# once. Cyclic edges terminate at +max_depth+ recursion levels — the
# dedup collapses same-action_id-different-depth rows in the Ruby-side
# +Set.new(...)+ wrapper, so pathological cycles produce bounded
# runtime.
RSpec.describe BSV::Wallet::Store, '#descendant_action_ids_of', :store do
  include_context 'store setup'

  let(:models) { BSV::Wallet::Store::Models }

  # Create a bare action row (no wtxid, no raw_tx). We're testing the
  # graph walk, not the transaction lifecycle.
  def make_action
    models::Action.create(description: 'graph test action', broadcast_intent: 'none')
  end

  # Create an output belonging to +action+ with a synthetic locking
  # script. Non-root, no controls, +'none'+ intent — the outbound
  # branch of the +spendable_recoverable+ CHECK, which needs no
  # promotion row.
  def make_output(action)
    vout = models::Output.where(action_id: action.id).count
    models::Output.create(
      action_id: action.id,
      satoshis: 1000,
      vout: vout,
      locking_script: SecureRandom.random_bytes(25),
      spendable_intent: 'none'
    )
  end

  # Create an input on +consumer+ that consumes +output+ (produced by
  # some upstream action). This is the descent edge.
  def make_input(consumer:, output:)
    vin = models::Input.where(action_id: consumer.id).count
    models::Input.create(
      action_id: consumer.id,
      output_id: output.id,
      vin: vin
    )
  end

  describe 'empty seed' do
    it 'returns an empty Set (no DB round-trip)' do
      expect(store.descendant_action_ids_of(action_ids: [])).to eq(Set.new)
    end
  end

  describe 'single seed with no descendants' do
    it 'returns the seed alone' do
      a = make_action
      make_output(a)
      result = store.descendant_action_ids_of(action_ids: [a.id])
      expect(result).to eq(Set[a.id])
    end
  end

  describe 'linear chain A -> B -> C' do
    # A produces output oA. B consumes oA and produces oB. C consumes
    # oB. Seeding with A must walk down to {A, B, C}.
    it 'walks the descent from A to reach B and C' do
      a = make_action
      b = make_action
      c = make_action
      oa = make_output(a)
      make_input(consumer: b, output: oa)
      ob = make_output(b)
      make_input(consumer: c, output: ob)

      result = store.descendant_action_ids_of(action_ids: [a.id])
      expect(result).to eq(Set[a.id, b.id, c.id])
    end
  end

  describe 'multiple seeds' do
    it 'unions descendants of each seed' do
      a1 = make_action
      a2 = make_action
      b1 = make_action
      b2 = make_action
      make_input(consumer: b1, output: make_output(a1))
      make_input(consumer: b2, output: make_output(a2))

      result = store.descendant_action_ids_of(action_ids: [a1.id, a2.id])
      expect(result).to eq(Set[a1.id, a2.id, b1.id, b2.id])
    end
  end

  describe 'diamond ancestry (union_all: false dedup)' do
    # X produces two outputs oX1 and oX2. Y consumes oX1 and produces
    # oY. Z consumes oX2 and produces oZ. W consumes both oY and oZ.
    # The two paths X→Y→W and X→Z→W both reach W. With +union_all:
    # false+, W appears exactly once in the descent set.
    it 'reaches the diamond apex once, not twice' do
      x = make_action
      y = make_action
      z = make_action
      w = make_action
      ox1 = make_output(x)
      ox2 = make_output(x)
      make_input(consumer: y, output: ox1)
      make_input(consumer: z, output: ox2)
      oy = make_output(y)
      oz = make_output(z)
      make_input(consumer: w, output: oy)
      make_input(consumer: w, output: oz)

      result = store.descendant_action_ids_of(action_ids: [x.id])
      expect(result).to eq(Set[x.id, y.id, z.id, w.id])
    end
  end

  describe 'depth cap termination' do
    # A 150-deep synthetic chain. With +max_depth: 100+ (the default,
    # matching the coinbase-maturity ceiling), the walk stops before
    # reaching the last 50 hops. With a large +max_depth+, the whole
    # chain descends. Wall-clock is bounded regardless.
    it 'stops at max_depth (default 100)' do
      actions = Array.new(151) { make_action }
      # Wire each action's output as the next action's input.
      150.times do |i|
        make_input(consumer: actions[i + 1], output: make_output(actions[i]))
      end

      # Wall-clock cap: the coarse cap is 500ms per the task
      # description. Local runs sit well under this even on SQLite.
      result = nil
      duration = Benchmark.realtime do
        result = store.descendant_action_ids_of(action_ids: [actions[0].id])
      end
      expect(duration).to be < 0.5

      # Depth 0 = seed; depth 100 = 100 hops beyond seed → 101 rows.
      expect(result.size).to eq(101)
      expect(result).to include(actions[0].id, actions[100].id)
      expect(result).not_to include(actions[101].id)
    end

    it 'walks the whole chain when max_depth is raised' do
      actions = Array.new(30) { make_action }
      29.times do |i|
        make_input(consumer: actions[i + 1], output: make_output(actions[i]))
      end
      result = store.descendant_action_ids_of(action_ids: [actions[0].id], max_depth: 200)
      expect(result.size).to eq(30)
    end
  end

  describe 'cycle handling' do
    # Real tx graphs are DAGs (an input consumes an output by id, and
    # ids are stable; a later action cannot "consume" an earlier
    # action's input). The CHECKs don't structurally forbid a cyclic
    # +inputs.output_id → outputs.action_id → inputs.output_id+ loop,
    # so guard the CTE anyway. The termination proof: +union_all:
    # false+ dedups + the depth counter halts recursion at
    # +max_depth+.
    it 'terminates in bounded time on a cyclic input graph' do
      a = make_action
      b = make_action
      oa = make_output(a)
      ob = make_output(b)
      make_input(consumer: b, output: oa) # A -> B
      make_input(consumer: a, output: ob) # B -> A (cycle)

      duration = Benchmark.realtime do
        result = store.descendant_action_ids_of(action_ids: [a.id])
        # Set-deduplicated in Ruby: only two unique action_ids.
        expect(result).to eq(Set[a.id, b.id])
      end
      expect(duration).to be < 0.5
    end
  end
end
