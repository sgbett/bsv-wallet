# frozen_string_literal: true

require 'bsv-wallet'
require 'net/http'

# Wallet→peer HTTP delivery specs (HLR #385 Task 5, #390).
#
# +EndpointPolicy+ is stubbed via +instance_double+ so each spec
# isolates one transport / ACK rule. Net::HTTP is stubbed at the
# +PeerDelivery#post+ seam — no real sockets are opened, so the suite
# runs in milliseconds and is OS-independent. Real HTTP coverage rides
# in the e2e harness, not the unit suite.
RSpec.describe BSV::Network::PeerDelivery do
  using BSV::Wallet::Txid

  let(:policy) { instance_double(BSV::Network::EndpointPolicy) }
  let(:delivery) { described_class.new(policy: policy) }
  let(:endpoint) { 'https://peer.example.com/transmit' }
  let(:uri) { URI('https://peer.example.com/transmit') }
  let(:ip) { '203.0.113.5' }
  let(:subject_wtxid) { ([0x42] * 32).pack('C*').b }
  let(:subject_dtxid) { subject_wtxid.to_dtxid }
  let(:beef_binary) { "\x01\x02\x03".b }
  let(:envelope) do
    {
      beef: beef_binary,
      outputs: [{ vout: 0, satoshis: 500, derivation_prefix: 'p', derivation_suffix: '1' }],
      sender_identity_key: "02#{'a' * 64}",
      protocol_version: 1
    }
  end

  # Stub the policy to accept the endpoint and return the canned
  # uri/ip. Each spec then stubs +Net::HTTP.new+ to either raise (for
  # the error-class specs) or return a fake connection object whose
  # +#request+ returns a canned response.
  def stub_policy_accept
    allow(policy).to receive(:validate!).with(endpoint).and_return(uri: uri, ip: ip)
    allow(policy).to receive_messages(allow_body?: true, max_body_bytes: 32 * 1024 * 1024)
  end

  # Drive Net::HTTP into a single canned response object without
  # touching the network. The block is the +http.start { |conn|
  # conn.request(...) }+ body; +Net::HTTP#start+ is the unit under
  # control here so we don't need to plumb a full request object.
  #
  # IMPORTANT: +Net::HTTP.new+ MUST receive the *hostname*, not the
  # resolved IP. The pre-fix code dialled +Net::HTTP.new(ip, port)+
  # which placed the IP into +@address+ — used by Net::HTTP for BOTH
  # SNI AND certificate hostname verification — so VERIFY_PEER would
  # fail against every legitimate peer cert (whose SAN names the
  # hostname, not the IP). The mock asserts the post-fix signature so
  # a regression to +Net::HTTP.new(ip, ...)+ would fail this expect
  # chain.
  def stub_http_response(response)
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).with(uri.host, 443).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:verify_mode=)
    allow(http).to receive(:ipaddr=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:respond_to?).with(:ipaddr=).and_return(true)
    allow(http).to receive(:start).and_yield(http)
    allow(http).to receive(:request).and_return(response)
    http
  end

  # Drive Net::HTTP into raising a transport error. Used for the
  # timeout / TLS / DNS / socket-error classes. Uses the post-fix
  # +Net::HTTP.new(hostname, port)+ signature — see +stub_http_response+.
  def stub_http_raise(error)
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).with(uri.host, 443).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:verify_mode=)
    allow(http).to receive(:ipaddr=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:respond_to?).with(:ipaddr=).and_return(true)
    allow(http).to receive(:start).and_raise(error)
    http
  end

  def http_response(status:, body: '', content_type: 'application/json',
                    message: 'OK')
    resp = instance_double(Net::HTTPResponse)
    allow(resp).to receive_messages(code: status.to_s, body: body, message: message)
    allow(resp).to receive(:[]).with('Content-Type').and_return(content_type)
    resp
  end

  describe '#initialize' do
    it 'defaults the policy to a fresh EndpointPolicy' do
      expect(described_class.new.policy).to be_a(BSV::Network::EndpointPolicy)
    end
  end

  describe '#deliver' do
    describe 'happy path (delivered)' do
      before { stub_policy_accept }

      it 'returns Result(:delivered) when the ACK wtxid matches' do
        ack = { 'accepted' => true, 'wtxid' => subject_dtxid }
        stub_http_response(http_response(status: 200, body: JSON.generate(ack)))

        result = delivery.deliver(endpoint: endpoint, envelope: envelope, subject_wtxid: subject_wtxid)

        expect(result).to be_delivered
        expect(result.outcome).to eq(:delivered)
        expect(result.wtxid).to eq(subject_dtxid)
        expect(result.http_status).to eq(200)
      end

      it 'POSTs the envelope with BEEF hex-encoded' do
        ack = { 'accepted' => true, 'wtxid' => subject_dtxid }
        http = stub_http_response(http_response(status: 200, body: JSON.generate(ack)))

        delivery.deliver(endpoint: endpoint, envelope: envelope, subject_wtxid: subject_wtxid)

        # The request the PeerDelivery hands to #request should carry
        # the hex-encoded BEEF and a JSON Content-Type. The +Host:+
        # header is NOT set explicitly — +Net::HTTP+ derives it from
        # +@address+ (the hostname we pass to +Net::HTTP.new+), so an
        # explicit +request['Host'] = uri.host+ would be redundant
        # and could mask the underlying bug class (cert hostname
        # check disagreeing with +Host:+).
        expect(http).to have_received(:request) do |req|
          expect(req['Content-Type']).to eq('application/json')
          body = JSON.parse(req.body)
          expect(body['beef']).to eq(beef_binary.unpack1('H*'))
          expect(body['protocol_version']).to eq(1)
        end
      end
    end

    # TLS hostname-verification regression guard (HLR #385 / Copilot
    # security gate C2). The pre-fix code passed the resolved IP as
    # the first arg to +Net::HTTP.new+, which placed the IP into
    # +@address+. +Net::HTTP+ uses +@address+ for BOTH SNI AND
    # +OpenSSL::SSL::VERIFY_PEER+ hostname verification, so every
    # legitimate peer's certificate (whose SAN names the hostname,
    # not the IP) would fail handshake. The fix dials
    # +Net::HTTP.new(hostname, port)+ + +http.ipaddr = ip+, which
    # preserves the DNS-TOCTOU mitigation (dial the
    # policy-approved IP) while letting TLS complete.
    #
    # A real-TLS WEBrick spec is the gold standard but heavy + flaky
    # in this unit suite. The API-contract guard below is what locks
    # the regression: a future change to +Net::HTTP.new(ip, ...)+
    # would have no stub matching it, fail with a "no stub"
    # double-mismatch, and the bug would surface in CI before merge.
    describe 'TLS hostname verification (regression guard — C2)' do
      before { stub_policy_accept }

      it 'constructs Net::HTTP with the hostname (NOT the resolved IP) so SNI + cert hostname-check pass' do
        ack = { 'accepted' => true, 'wtxid' => subject_dtxid }
        stub_http_response(http_response(status: 200, body: JSON.generate(ack)))

        delivery.deliver(endpoint: endpoint, envelope: envelope, subject_wtxid: subject_wtxid)

        expect(Net::HTTP).to have_received(:new).with(uri.host, 443)
        expect(Net::HTTP).not_to have_received(:new).with(ip, 443)
      end

      it 'sets http.ipaddr to the resolved IP (preserves DNS TOCTOU mitigation)' do
        ack = { 'accepted' => true, 'wtxid' => subject_dtxid }
        http = stub_http_response(http_response(status: 200, body: JSON.generate(ack)))

        delivery.deliver(endpoint: endpoint, envelope: envelope, subject_wtxid: subject_wtxid)

        # The policy resolved +endpoint+ to +ip+; we dial that exact
        # IP via +http.ipaddr=+. Net::HTTP's @address stays the
        # hostname (asserted above) so SNI + hostname verification
        # still target the original name.
        expect(http).to have_received(:ipaddr=).with(ip)
      end

      it 'sets verify_mode to VERIFY_PEER for https endpoints' do
        ack = { 'accepted' => true, 'wtxid' => subject_dtxid }
        http = stub_http_response(http_response(status: 200, body: JSON.generate(ack)))

        delivery.deliver(endpoint: endpoint, envelope: envelope, subject_wtxid: subject_wtxid)

        expect(http).to have_received(:verify_mode=).with(OpenSSL::SSL::VERIFY_PEER)
      end
    end

    describe 'ACK wtxid mismatch (crypto gate — HLR #385 H-severity)' do
      before { stub_policy_accept }

      it 'returns Result(:wrong_acked_wtxid) when ACK names a different wtxid' do
        other_dtxid = ("\x99" * 32).b.to_dtxid
        ack = { 'accepted' => true, 'wtxid' => other_dtxid }
        stub_http_response(http_response(status: 200, body: JSON.generate(ack)))

        result = delivery.deliver(endpoint: endpoint, envelope: envelope, subject_wtxid: subject_wtxid)

        expect(result.outcome).to eq(:wrong_acked_wtxid)
        expect(result).not_to be_delivered
        expect(result.wtxid).to eq(other_dtxid)
        expect(result.error_message).to include(other_dtxid)
        expect(result.error_message).to include(subject_dtxid)
      end
    end

    describe 'malformed ACK' do
      before { stub_policy_accept }

      it 'returns Result(:malformed_ack) on non-JSON body with json Content-Type' do
        stub_http_response(http_response(status: 200, body: 'OK'))
        result = delivery.deliver(endpoint: endpoint, envelope: envelope, subject_wtxid: subject_wtxid)
        expect(result.outcome).to eq(:malformed_ack)
        expect(result.error_message).to include('JSON parse failed')
      end

      it 'returns Result(:malformed_ack) when Content-Type is not application/json' do
        ack = { 'accepted' => true, 'wtxid' => subject_dtxid }
        stub_http_response(http_response(status: 200, body: JSON.generate(ack), content_type: 'text/plain'))

        result = delivery.deliver(endpoint: endpoint, envelope: envelope, subject_wtxid: subject_wtxid)
        expect(result.outcome).to eq(:malformed_ack)
        expect(result.error_message).to include('text/plain')
      end

      it 'returns Result(:malformed_ack) when accepted: false' do
        ack = { 'accepted' => false, 'wtxid' => subject_dtxid }
        stub_http_response(http_response(status: 200, body: JSON.generate(ack)))
        result = delivery.deliver(endpoint: endpoint, envelope: envelope, subject_wtxid: subject_wtxid)
        expect(result.outcome).to eq(:malformed_ack)
      end

      it 'returns Result(:malformed_ack) when wtxid field is missing' do
        ack = { 'accepted' => true }
        stub_http_response(http_response(status: 200, body: JSON.generate(ack)))
        result = delivery.deliver(endpoint: endpoint, envelope: envelope, subject_wtxid: subject_wtxid)
        expect(result.outcome).to eq(:malformed_ack)
      end
    end

    describe 'non-200 response' do
      before { stub_policy_accept }

      it 'returns Result(:non_200) on 400 Bad Request' do
        stub_http_response(http_response(status: 400, body: '{"error":"bad envelope"}', message: 'Bad Request'))
        result = delivery.deliver(endpoint: endpoint, envelope: envelope, subject_wtxid: subject_wtxid)
        expect(result.outcome).to eq(:non_200)
        expect(result.http_status).to eq(400)
        expect(result.error_message).to include('400')
      end

      it 'returns Result(:non_200) on 500 server error' do
        stub_http_response(http_response(status: 500, body: '', message: 'Internal Server Error'))
        result = delivery.deliver(endpoint: endpoint, envelope: envelope, subject_wtxid: subject_wtxid)
        expect(result.outcome).to eq(:non_200)
        expect(result.http_status).to eq(500)
      end
    end

    describe 'transport errors' do
      before { stub_policy_accept }

      it 'returns Result(:timeout) on Net::OpenTimeout' do
        stub_http_raise(Net::OpenTimeout.new('connection took too long'))
        result = delivery.deliver(endpoint: endpoint, envelope: envelope, subject_wtxid: subject_wtxid)
        expect(result.outcome).to eq(:timeout)
        expect(result.error_message).to include('connection took too long')
      end

      it 'returns Result(:timeout) on Net::ReadTimeout' do
        stub_http_raise(Net::ReadTimeout.new('read too slow'))
        result = delivery.deliver(endpoint: endpoint, envelope: envelope, subject_wtxid: subject_wtxid)
        expect(result.outcome).to eq(:timeout)
      end

      it 'returns Result(:tls_failure) on OpenSSL::SSL::SSLError' do
        stub_http_raise(OpenSSL::SSL::SSLError.new('certificate verify failed'))
        result = delivery.deliver(endpoint: endpoint, envelope: envelope, subject_wtxid: subject_wtxid)
        expect(result.outcome).to eq(:tls_failure)
        expect(result.error_message).to include('certificate verify')
      end

      it 'returns Result(:dns_failure) on SocketError' do
        stub_http_raise(SocketError.new('getaddrinfo: nodename nor servname provided'))
        result = delivery.deliver(endpoint: endpoint, envelope: envelope, subject_wtxid: subject_wtxid)
        expect(result.outcome).to eq(:dns_failure)
      end

      it 'returns Result(:transport_error) on ECONNREFUSED' do
        stub_http_raise(Errno::ECONNREFUSED.new('Connection refused'))
        result = delivery.deliver(endpoint: endpoint, envelope: envelope, subject_wtxid: subject_wtxid)
        expect(result.outcome).to eq(:transport_error)
      end
    end

    describe 'policy violation' do
      it 'returns Result(:endpoint_policy_violation) propagating policy message' do
        allow(policy).to receive(:validate!)
          .with(endpoint)
          .and_raise(BSV::Network::EndpointPolicy::Violation, 'endpoint rejected: scheme=http')

        result = delivery.deliver(endpoint: endpoint, envelope: envelope, subject_wtxid: subject_wtxid)
        expect(result.outcome).to eq(:endpoint_policy_violation)
        expect(result.error_message).to include('scheme=http')
      end
    end

    describe 'body cap' do
      it 'returns Result(:body_too_large) when the JSON body exceeds policy cap' do
        allow(policy).to receive(:validate!).with(endpoint).and_return(uri: uri, ip: ip)
        allow(policy).to receive_messages(allow_body?: false, max_body_bytes: 10)

        result = delivery.deliver(endpoint: endpoint, envelope: envelope, subject_wtxid: subject_wtxid)
        expect(result.outcome).to eq(:body_too_large)
        expect(result.error_message).to include('exceeds cap 10')
      end
    end
  end
end
