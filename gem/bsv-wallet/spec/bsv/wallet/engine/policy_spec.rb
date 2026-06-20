# frozen_string_literal: true

require 'bsv-wallet'
require 'bsv/wallet/engine/policy'

RSpec.describe BSV::Wallet::Engine::Policy do
  subject(:policy) { described_class.new(threshold: 50_000) }

  describe '#guard_balance!' do
    context 'without spending (limp-mode check)' do
      it 'raises when balance is below threshold' do
        expect { policy.guard_balance!(balance: 49_999) }
          .to raise_error(BSV::Wallet::LimpModeError) { |e|
            expect(e.balance).to eq(49_999)
            expect(e.threshold).to eq(50_000)
          }
      end

      it 'does not raise when balance equals threshold (strict-less-than)' do
        expect { policy.guard_balance!(balance: 50_000) }.not_to raise_error
      end

      it 'does not raise when balance is above threshold' do
        expect { policy.guard_balance!(balance: 100_000) }.not_to raise_error
      end
    end

    context 'with spending (projected-headroom check)' do
      it 'raises when balance - spending would drop below threshold' do
        expect { policy.guard_balance!(balance: 100_000, spending: 60_000) }
          .to raise_error(BSV::Wallet::LimpModeError) { |e|
            expect(e.balance).to eq(40_000)
            expect(e.threshold).to eq(50_000)
          }
      end

      it 'does not raise when balance - spending equals threshold' do
        expect { policy.guard_balance!(balance: 100_000, spending: 50_000) }.not_to raise_error
      end

      it 'does not raise when spending leaves headroom above threshold' do
        expect { policy.guard_balance!(balance: 100_000, spending: 10_000) }.not_to raise_error
      end
    end

    context 'with bypass: true' do
      it 'does not raise even when balance is below threshold' do
        expect { policy.guard_balance!(balance: 0, bypass: true) }.not_to raise_error
      end

      it 'does not raise even when projected balance is negative' do
        expect { policy.guard_balance!(balance: 100, spending: 1_000_000, bypass: true) }
          .not_to raise_error
      end
    end

    context 'error payload' do
      it 'reports the projected balance, not the gross balance' do
        expect { policy.guard_balance!(balance: 100_000, spending: 60_000) }
          .to raise_error(BSV::Wallet::LimpModeError) { |e|
            expect(e.balance).to eq(40_000) # 100_000 - 60_000
          }
      end
    end
  end
end
