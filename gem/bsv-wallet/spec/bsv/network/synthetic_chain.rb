# frozen_string_literal: true

require 'bsv-wallet'

# Deterministic synthetic header chain for the +spv_headers+ sync/tracker
# specs (HLR #335). Easy regtest difficulty (+bits = 0x207fffff+) so PoW is
# trivially satisfiable — the nonce is ground (from 0) until +valid_pow?+
# holds, which lands within a handful of tries and keeps the fixture fast
# and reproducible. Each header's +prev_hash+ is its parent's +block_hash+,
# so the chain links cleanly. No live network.
module SyntheticChain
  # Regtest target — enormous, so almost any hash is at/below it.
  REGTEST_BITS = 0x207fffff

  module_function

  # Mine one valid header.
  #
  # @return [BSV::Network::BlockHeader]
  def mine(prev_wire:, merkle_wire:, time:, version: 1, bits: REGTEST_BITS)
    nonce = 0
    loop do
      raw = [version].pack('V') + prev_wire + merkle_wire +
            [time].pack('V') + [bits].pack('V') + [nonce].pack('V')
      header = BSV::Network::BlockHeader.parse(raw)
      return header if header.valid_pow?

      nonce += 1
    end
  end

  # Build a contiguous chain of +count+ headers starting at +start_height+,
  # rooted on +genesis_prev+ (the first header's prev_hash). Returns a Hash
  # of +height => BlockHeader+.
  #
  # @return [Hash{Integer => BSV::Network::BlockHeader}]
  def build(start_height:, count:, genesis_prev: ("\x00".b * 32))
    prev = genesis_prev
    chain = {}
    count.times do |i|
      height = start_height + i
      # Distinct, non-palindromic merkle root per height so byte-order bugs
      # surface (a reversed root would mismatch).
      merkle = "merkle-root-h#{height}".b.ljust(32, "\x00".b)[0, 32]
      header = mine(prev_wire: prev, merkle_wire: merkle, time: 1_700_000_000 + i)
      chain[height] = header
      prev = header.block_hash
    end
    chain
  end

  # The WhatsOnChain-shaped +:get_block_header+ field hash for +header+
  # (display-hex hashes, hex +bits+, +merkle_root+ key — matching the
  # wallet Services layer's normalised payload).
  #
  # @return [Hash{String => Object}]
  def service_fields(header)
    {
      'version' => header.version,
      'previousblockhash' => header.prev_hash.reverse.unpack1('H*'),
      'merkle_root' => header.merkle_root.reverse.unpack1('H*'),
      'time' => header.time,
      'bits' => format('%08x', header.bits),
      'nonce' => header.nonce,
      'hash' => header.block_hash.reverse.unpack1('H*')
    }
  end

  # A successful ProtocolResponse wrapping +service_fields(header)+.
  def success_response(header)
    BSV::Network::ProtocolResponse.new(nil, data: service_fields(header), http_success: true)
  end

  # A failed (5xx-shaped) ProtocolResponse — fail-closed trigger.
  def error_response
    BSV::Network::ProtocolResponse.new(nil, http_success: false, error_message: 'network error')
  end

  # A checkpoint Hash (+{ height:, header: }+) for the header at
  # +start_height+ in +chain+ — the synthetic trust anchor injected via
  # +config.spv_checkpoint+ / the tracker's +checkpoint:+ kwarg.
  def checkpoint_for(chain, start_height)
    { height: start_height, header: chain.fetch(start_height) }
  end
end
