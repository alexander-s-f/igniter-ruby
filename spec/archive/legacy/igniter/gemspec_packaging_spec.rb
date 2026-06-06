# frozen_string_literal: true

require "spec_helper"

RSpec.describe "gemspec packaging" do
  GEMSPEC_PACKAGING_ROOT = File.expand_path("../..", __dir__)

  def load_gemspec(path)
    absolute_path = File.join(GEMSPEC_PACKAGING_ROOT, path)

    Dir.chdir(File.dirname(absolute_path)) do
      Gem::Specification.load(File.basename(absolute_path))
    end
  end

  it "includes dashboard generator templates in the root igniter gem" do
    spec = load_gemspec("igniter.gemspec")

    expect(spec.files).to include(
      "packages/igniter-app/lib/igniter/app/generators/templates/dashboard/app.rb.erb",
      "packages/igniter-app/lib/igniter/app/generators/templates/dashboard/contexts/home_context.rb.erb",
      "packages/igniter-app/lib/igniter/app/generators/templates/dashboard/support/stack_overview.rb.erb",
      "packages/igniter-app/lib/igniter/app/generators/templates/dashboard/web/views/layout.arb.erb",
      "packages/igniter-app/lib/igniter/app/generators/templates/dashboard/web/views/home_page.arb.erb"
    )
  end

  it "includes dashboard generator templates in the igniter-app package gem" do
    spec = load_gemspec("packages/igniter-app/igniter-app.gemspec")

    expect(spec.files).to include(
      "lib/igniter/app/generators/templates/dashboard/app.rb.erb",
      "lib/igniter/app/generators/templates/dashboard/contexts/home_context.rb.erb",
      "lib/igniter/app/generators/templates/dashboard/support/stack_overview.rb.erb",
      "lib/igniter/app/generators/templates/dashboard/web/views/layout.arb.erb",
      "lib/igniter/app/generators/templates/dashboard/web/views/home_page.arb.erb"
    )
  end
end
