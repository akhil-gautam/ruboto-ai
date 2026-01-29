# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/ruboto/workflow"

class RuntimeTest < Minitest::Test
  def setup
    @steps = [
      Ruboto::Workflow::Step.new(
        id: 1,
        tool: "file_glob",
        params: { path: "/tmp", pattern: "*.txt" },
        output_key: "files",
        description: "Find text files"
      ),
      Ruboto::Workflow::Step.new(
        id: 2,
        tool: "file_read",
        params: { files: "$files" },
        output_key: "contents",
        description: "Read file contents"
      )
    ]
  end

  def test_runtime_initializes_with_steps
    runtime = Ruboto::Workflow::Runtime.new(@steps)
    assert_equal 2, runtime.steps.length
  end

  def test_runtime_tracks_state
    runtime = Ruboto::Workflow::Runtime.new(@steps)
    assert runtime.state.is_a?(Hash)
  end

  def test_runtime_resolves_variable_references
    runtime = Ruboto::Workflow::Runtime.new(@steps)
    runtime.state["files"] = ["/tmp/a.txt", "/tmp/b.txt"]
    resolved = runtime.resolve_params({ files: "$files" })
    assert_equal ["/tmp/a.txt", "/tmp/b.txt"], resolved[:files]
  end

  def test_runtime_can_preview_step
    runtime = Ruboto::Workflow::Runtime.new(@steps)
    preview = runtime.preview_step(@steps.first)
    assert preview.include?("file_glob")
  end
end
