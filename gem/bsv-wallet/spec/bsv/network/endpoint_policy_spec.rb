# frozen_string_literal: true

require 'bsv-wallet'

# Pure-validator specs for the SSRF gate (HLR #385 Task 5, #390).
#
# No network I/O happens here — DNS is stubbed via +Resolv.getaddress+
# so each rejection rule can be exercised against a known IP class
# without touching the real resolver. The cloud-metadata case
# (169.254.169.254) is the one nobody can afford to miss.
RSpec.describe BSV::Network::EndpointPolicy do
  describe '#initialize' do
    it 'freezes the instance' do
      expect(described_class.new).to be_frozen
    end

    it 'defaults +allow_private+ from BSV_WALLET_ALLOW_PRIVATE_ENDPOINTS=1' do
      stub_const('ENV', ENV.to_h.merge('BSV_WALLET_ALLOW_PRIVATE_ENDPOINTS' => '1'))
      expect(described_class.new.allow_private).to be true
    end

    it 'defaults +allow_private+ to false when the env var is unset' do
      stub_const('ENV', ENV.to_h.except('BSV_WALLET_ALLOW_PRIVATE_ENDPOINTS'))
      expect(described_class.new.allow_private).to be false
    end

    it 'defaults +allow_private+ to false for any value other than "1"' do
      stub_const('ENV', ENV.to_h.merge('BSV_WALLET_ALLOW_PRIVATE_ENDPOINTS' => 'true'))
      expect(described_class.new.allow_private).to be false
    end

    it 'defaults max_body_bytes to 32 MiB' do
      expect(described_class.new.max_body_bytes).to eq(32 * 1024 * 1024)
    end
  end

  describe '#allow_body?' do
    let(:policy) { described_class.new(max_body_bytes: 1024) }

    it 'accepts bodies at or below the cap' do
      expect(policy.allow_body?(1024)).to be true
      expect(policy.allow_body?(1)).to be true
    end

    it 'rejects bodies above the cap' do
      expect(policy.allow_body?(1025)).to be false
    end
  end

  describe '#validate!' do
    subject(:policy) { described_class.new }

    # Each described_class.validate! call ultimately calls Resolv.getaddress.
    # We stub it per example to exercise the rejection rule under test.
    def stub_dns(host:, address:)
      allow(Resolv).to receive(:getaddress).with(host).and_return(address)
    end

    context 'with malformed input' do
      it 'rejects non-string endpoints' do
        expect { policy.validate!(nil) }
          .to raise_error(described_class::Violation, /non-empty string/)
      end

      it 'rejects empty strings' do
        expect { policy.validate!('') }
          .to raise_error(described_class::Violation, /non-empty string/)
      end

      it 'rejects malformed URIs' do
        expect { policy.validate!('https://host:not-a-port/') }
          .to raise_error(described_class::Violation, /malformed URI/)
      end

      it 'rejects URIs without a host' do
        expect { policy.validate!('https:///path') }
          .to raise_error(described_class::Violation, /missing host/)
      end
    end

    context 'with disallowed schemes' do
      it 'rejects plain http://' do
        expect { policy.validate!('http://peer.example.com/') }
          .to raise_error(described_class::Violation, /scheme.*https.*required/)
      end

      it 'rejects ws://' do
        expect { policy.validate!('ws://peer.example.com/') }
          .to raise_error(described_class::Violation, /scheme/)
      end

      it 'rejects file://' do
        expect { policy.validate!('file:///etc/passwd') }
          .to raise_error(described_class::Violation, /scheme/)
      end
    end

    context 'with the require_https flag off' do
      subject(:policy) { described_class.new(require_https: false) }

      it 'accepts http:// when DNS resolves to a public IP' do
        stub_dns(host: 'peer.example.com', address: '203.0.113.1')
        expect { policy.validate!('http://peer.example.com/') }.not_to raise_error
      end
    end

    context 'with DNS resolution failure' do
      it 'maps Resolv::ResolvError into a Violation' do
        allow(Resolv).to receive(:getaddress).with('does-not-resolve.example')
                                             .and_raise(Resolv::ResolvError, 'no answer')
        expect { policy.validate!('https://does-not-resolve.example/') }
          .to raise_error(described_class::Violation, /DNS resolution failed.*does-not-resolve/)
      end
    end

    context 'with public-IP destinations (happy path)' do
      it 'returns the parsed URI and resolved IP' do
        stub_dns(host: 'peer.example.com', address: '203.0.113.1')
        result = policy.validate!('https://peer.example.com/transmit')
        expect(result[:uri]).to be_a(URI)
        expect(result[:uri].host).to eq('peer.example.com')
        expect(result[:ip]).to eq('203.0.113.1')
      end

      it 'accepts public IPv6 destinations' do
        stub_dns(host: 'peer.example.com', address: '2001:db8::1')
        expect { policy.validate!('https://peer.example.com/') }.not_to raise_error
      end

      it 'accepts a literal public IP host (Resolv.getaddress passes through)' do
        # When the host is already a literal IP, Resolv.getaddress returns it.
        allow(Resolv).to receive(:getaddress).with('203.0.113.1').and_return('203.0.113.1')
        expect { policy.validate!('https://203.0.113.1/') }.not_to raise_error
      end
    end

    context 'with IPv4 private/loopback/link-local destinations' do
      # One spec per PRIVATE_RANGES class — keeps the surface explicit
      # so a future maintainer can't accidentally remove a guard.
      {
        'IPv4 wildcard (0.0.0.0 — Linux/macOS routes to loopback)' => '0.0.0.0',
        'IPv4 loopback (127.0.0.1)' => '127.0.0.1',
        'IPv4 loopback range (127.5.6.7)' => '127.5.6.7',
        'RFC1918 10.0.0.0/8' => '10.1.2.3',
        'RFC1918 172.16.0.0/12' => '172.20.5.6',
        'RFC1918 192.168.0.0/16' => '192.168.1.1',
        'CGNAT 100.64.0.0/10 (RFC 6598)' => '100.64.5.6',
        'link-local 169.254.0.0/16' => '169.254.1.1',
        'cloud-metadata service (169.254.169.254)' => '169.254.169.254',
        'IPv4 multicast (224.0.0.1)' => '224.0.0.1',
        'IPv4 limited broadcast (255.255.255.255)' => '255.255.255.255'
      }.each do |label, ip|
        it "rejects #{label}" do
          stub_dns(host: 'peer.example.com', address: ip)
          expect { policy.validate!('https://peer.example.com/') }
            .to raise_error(described_class::Violation, %r{private/loopback/link-local})
        end
      end
    end

    context 'with IPv6 private/loopback/unique-local destinations' do
      {
        'IPv6 loopback (::1)' => '::1',
        'IPv6 unique-local (fc00::/7)' => 'fc00::1',
        'IPv6 unique-local (fd00::/8)' => 'fd00::1'
      }.each do |label, ip|
        it "rejects #{label}" do
          stub_dns(host: 'peer.example.com', address: ip)
          expect { policy.validate!('https://peer.example.com/') }
            .to raise_error(described_class::Violation, %r{private/loopback/link-local})
        end
      end
    end

    # IPv4-mapped IPv6 (RFC 4291 § 2.5.5.2) is the SSRF bypass class
    # missed by the v1 ranges-only check: +PRIVATE_RANGES+ contains the
    # IPv4 +127.0.0.0/8+ + +169.254.0.0/16+ rules, but those never
    # match a +::ffff:1.2.3.4+ +IPAddr+ — different family. On a
    # dual-stack Linux/macOS host the kernel routes
    # +::ffff:127.0.0.1+ to loopback and +::ffff:169.254.169.254+ to
    # the cloud-metadata IP, so without unwrap an attacker who can
    # influence DNS (or a typo'd literal endpoint) reaches both.
    # +EndpointPolicy#validate_ip!+ calls +IPAddr#native+ on any
    # +ipv4_mapped?+ address before the membership check so the IPv4
    # rules apply.
    context 'with IPv4-mapped IPv6 addresses (SSRF bypass class — RFC 4291 § 2.5.5.2)' do
      {
        'IPv4-mapped loopback (::ffff:127.0.0.1)' => '::ffff:127.0.0.1',
        'IPv4-mapped RFC1918 (::ffff:10.0.0.1)' => '::ffff:10.0.0.1',
        'IPv4-mapped wildcard (::ffff:0.0.0.0)' => '::ffff:0.0.0.0'
      }.each do |label, ip|
        it "rejects #{label}" do
          stub_dns(host: 'peer.example.com', address: ip)
          expect { policy.validate!('https://peer.example.com/') }
            .to raise_error(described_class::Violation, %r{private/loopback/link-local})
        end
      end

      it 'rejects IPv4-mapped cloud-metadata IP (::ffff:169.254.169.254)' do
        # The credential-exfiltration end-state for the bypass class.
        # AWS / GCP / Azure all serve metadata at 169.254.169.254;
        # routing reaches it via the IPv4-mapped form on dual-stack
        # hosts. This spec is named explicitly so a future maintainer
        # can't quietly drop the guard without noticing what they're
        # opening up.
        stub_dns(host: 'peer.example.com', address: '::ffff:169.254.169.254')
        expect { policy.validate!('https://peer.example.com/') }
          .to raise_error(described_class::Violation, %r{private/loopback/link-local})
      end

      it 'rejects DNS-rebinding to IPv4-mapped cloud-metadata IP' do
        # Same attack surface, framed as the DNS-rebinding case: a
        # public-looking hostname that resolves (now, after the
        # policy check would otherwise be safe) to the IPv4-mapped
        # metadata IP.
        stub_dns(host: 'attacker.example', address: '::ffff:169.254.169.254')
        expect { policy.validate!('https://attacker.example/transmit') }
          .to raise_error(described_class::Violation, /private/)
      end
    end

    # DNS rebinding: a host name that looks public but resolves to a
    # private address. The defence is to validate on the RESOLVED IP,
    # not the lexical hostname. (And then to dial that IP, not the
    # hostname — see PeerDelivery#post for the TOCTOU closure.)
    context 'with DNS rebinding (public name, private IP)' do
      it 'rejects when a public-looking hostname resolves to 169.254.169.254' do
        stub_dns(host: 'attacker.example', address: '169.254.169.254')
        expect { policy.validate!('https://attacker.example/transmit') }
          .to raise_error(described_class::Violation, /private/)
      end

      it 'rejects when a public-looking hostname resolves to RFC1918' do
        stub_dns(host: 'attacker.example', address: '10.0.0.1')
        expect { policy.validate!('https://attacker.example/') }
          .to raise_error(described_class::Violation, /private/)
      end
    end

    context 'with the allow_private opt-out (e2e harness)' do
      subject(:policy) { described_class.new(allow_private: true) }

      it 'permits 127.0.0.1' do
        stub_dns(host: 'localhost', address: '127.0.0.1')
        expect { policy.validate!('https://localhost/') }.not_to raise_error
      end

      it 'permits 169.254.169.254 (escape hatch is total — operator owns the risk)' do
        stub_dns(host: 'metadata.local', address: '169.254.169.254')
        expect { policy.validate!('https://metadata.local/') }.not_to raise_error
      end

      it 'permits RFC1918' do
        stub_dns(host: 'peer.local', address: '10.0.0.5')
        expect { policy.validate!('https://peer.local/') }.not_to raise_error
      end
    end
  end
end
