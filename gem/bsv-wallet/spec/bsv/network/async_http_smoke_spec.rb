# frozen_string_literal: true

require 'async'
require 'async/http/client'
require 'async/http/endpoint'

RSpec.describe Async::HTTP::Client do # rubocop:disable RSpec/SpecFilePathFormat
  it 'is loadable and constructible inside an Async reactor' do
    client = nil
    Async do
      endpoint = Async::HTTP::Endpoint.parse('https://example.com')
      client = described_class.new(endpoint)
      client.close
    end.wait

    expect(client).to be_a(described_class)
  end
end
