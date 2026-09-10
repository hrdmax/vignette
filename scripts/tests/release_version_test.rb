require 'minitest/autorun'
require 'yaml'
require 'open3'
require 'tmpdir'

class ReleaseVersionTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  WORKFLOW = YAML.load_file(File.join(ROOT, '.github/workflows/release.yml'))
  VERSION_STEP = WORKFLOW.fetch('jobs').fetch('release').fetch('steps')
                         .find { |step| step['name'] == 'Work out the version' }

  def test_version_inputs_are_passed_as_data
    assert_equal '${{ github.event.inputs.version }}', VERSION_STEP.fetch('env').fetch('INPUT_VERSION')
    refute_includes VERSION_STEP.fetch('run'), '${{'
  end

  def test_valid_manual_and_tag_versions
    [['workflow_dispatch', '1.2.3', 'main', '1.2.3'],
     ['push', '', 'v0.12.345', '0.12.345']].each do |event, input, ref, expected|
      with_version(event, input, ref) do |status, output|
        assert status.success?
        assert_equal "VERSION=#{expected}\nTAG=v#{expected}\n", output
      end
    end
  end

  def test_invalid_versions_cannot_execute_or_write_environment_entries
    Dir.mktmpdir('vignette-injection-test-') do |dir|
      marker = File.join(dir, 'executed')
      ['', '01.2.3', '1.2', '1.2.3-beta', "1.2.3\nINJECTED=yes",
       "$(touch #{marker})", "`touch #{marker}`", "\"; touch #{marker}; #",
       '#{system("id")}'].each do |input|
        ['workflow_dispatch', 'push'].each do |event|
          with_version(event, input, "v#{input}") do |status, output|
            refute status.success?, "accepted #{input.inspect} via #{event}"
            assert_empty output
            refute File.exist?(marker)
          end
        end
      end
    end
  end

  private

  def with_version(event, input, ref)
    Dir.mktmpdir('vignette-version-test-') do |dir|
      output = File.join(dir, 'github-env')
      _, _, status = Open3.capture3(
        { 'GITHUB_EVENT_NAME' => event, 'INPUT_VERSION' => input,
          'GITHUB_REF_NAME' => ref, 'GITHUB_ENV' => output },
        '/bin/bash', '-e', '-o', 'pipefail', '-c', VERSION_STEP.fetch('run')
      )
      yield status, File.exist?(output) ? File.read(output) : ''
    end
  end
end
