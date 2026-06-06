# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

require "spec_helper"

RSpec.describe Igniter::Hub::LocalCatalog do
  it "loads local capsule catalog entries with absolute bundle paths" do
    Dir.mktmpdir("igniter-hub") do |root|
      FileUtils.mkdir_p(File.join(root, "bundles/horoscope"))
      catalog = File.join(root, "catalog.json")
      File.write(
        catalog,
        JSON.pretty_generate(
          entries: [
            {
              name: :horoscope,
              title: "Daily Horoscope",
              version: "0.1.0",
              bundle_path: "bundles/horoscope",
              capabilities: %i[daily_horoscope],
              metadata: { audience: :companion }
            }
          ]
        )
      )

      loaded = described_class.load(catalog)
      entry = loaded.fetch(:horoscope)

      expect(loaded.names).to eq([:horoscope])
      expect(entry.bundle_path).to eq(File.join(root, "bundles/horoscope"))
      expect(entry.to_h).to include(
        name: :horoscope,
        title: "Daily Horoscope",
        capabilities: [:daily_horoscope],
        metadata: { audience: "companion" }
      )
    end
  end
end
