# frozen_string_literal: true

module BSV
  module Wallet
    class Engine
      # Wire format of a BEEF hint on the hints socket: a single frame of
      # one version byte, the action id as an unsigned 64-bit big-endian
      # integer, then the Atomic BEEF bytes.
      #
      # Data only: decoding yields an Integer and a String and constructs
      # nothing else, so whoever reaches the socket can hand +walletd+
      # bytes to parse but never an object to instantiate (#556).
      module HintEnvelope
        VERSION = 1
        HEADER_BYTES = 9
        # The same cap +bin/wallet receive+ puts on a BEEF. Dropping a
        # larger hint costs its broadcast only the JOIN it would have saved.
        MAX_BEEF_BYTES = 32 * 1024 * 1024
        MAX_ACTION_ID = (2**64) - 1

        class MalformedError < BSV::Wallet::Error; end

        module_function

        # @param action_id [Integer] the action the BEEF belongs to
        # @param beef [String] Atomic BEEF bytes
        # @return [String] the frame to push
        # @raise [ArgumentError] for an action id outside 0..2**64-1, or an
        #   empty or over-cap BEEF
        def encode(action_id:, beef:)
          unless action_id.is_a?(Integer) && action_id.between?(0, MAX_ACTION_ID)
            raise ArgumentError, "action_id must be an Integer in 0..#{MAX_ACTION_ID}, got #{action_id.inspect}"
          end
          raise ArgumentError, 'BEEF is empty' if beef.empty?
          raise ArgumentError, "BEEF of #{beef.bytesize} bytes exceeds #{MAX_BEEF_BYTES}" if beef.bytesize > MAX_BEEF_BYTES

          [VERSION, action_id].pack('CQ>') + beef.b
        end

        # @param frames [Array<String>] the message as received
        # @return [Hash] +{ action_id: Integer, beef: String }+, the BEEF binary
        # @raise [MalformedError] unless +frames+ is one well-formed frame
        def decode(frames)
          raise MalformedError, "expected 1 frame, got #{frames.size}" unless frames.size == 1

          message = frames.first
          raise MalformedError, "#{message.bytesize} bytes is too short" if message.bytesize <= HEADER_BYTES

          version, action_id = message.unpack('CQ>')
          raise MalformedError, "unknown version #{version}" unless version == VERSION

          beef_bytes = message.bytesize - HEADER_BYTES
          raise MalformedError, "BEEF of #{beef_bytes} bytes exceeds #{MAX_BEEF_BYTES}" if beef_bytes > MAX_BEEF_BYTES

          { action_id: action_id, beef: message.byteslice(HEADER_BYTES..).force_encoding(Encoding::BINARY) }
        end

        # @return [Integer] the largest frame a valid hint needs
        def max_bytes
          HEADER_BYTES + MAX_BEEF_BYTES
        end
      end
    end
  end
end
